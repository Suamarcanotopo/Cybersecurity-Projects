# Binary Analysis Tool: Architecture

This module covers the system design of AXUMORTEM: how the pass-based pipeline works, how components interact, and the reasoning behind each design decision.

## High-Level Architecture

```
                         ┌─────────────────────────────────────┐
                         │            Nginx (port 22784)       │
                         │    static files + reverse proxy     │
                         └──────────────┬──────────────────────┘
                                        │
                           ┌────────────┴────────────┐
                           │                         │
                      GET /index.html           POST /api/*
                      GET /assets/*             GET /api/*
                           │                         │
                           v                         v
                  ┌─────────────────┐     ┌─────────────────────┐
                  │  React Frontend │     │  Axum Backend (:3000)│
                  │  (static build) │     │                     │
                  └─────────────────┘     │  ┌───────────────┐  │
                                          │  │ Upload Route  │  │
                                          │  └───────┬───────┘  │
                                          │          │          │
                                          │  ┌───────v───────┐  │
                                          │  │AnalysisEngine │  │
                                          │  │(spawn_blocking)│  │
                                          │  └───────┬───────┘  │
                                          │          │          │
                                          │  ┌───────v───────┐  │
                                          │  │  PostgreSQL   │  │
                                          │  │  (port 5432)  │  │
                                          │  └───────────────┘  │
                                          └─────────────────────┘
```

The frontend is a static React build served by Nginx. All API requests proxy through Nginx to the Axum backend on port 3000. The analysis engine runs CPU-intensive work on a blocking thread pool (`spawn_blocking`) to avoid starving the async runtime. Results persist to PostgreSQL so repeated uploads of the same binary return cached results instantly.

## Component Breakdown

### Analysis Engine (`axumortem-engine` crate)

The core library. Zero knowledge of HTTP, databases, or frontend concerns. It takes raw bytes in and produces structured analysis results.

**Responsibilities:**
- Register and order analysis passes
- Execute passes in dependency order
- Provide a shared context for passes to store results
- Compute file hashes

**Key types:**
- `AnalysisEngine` — top-level orchestrator
- `AnalysisContext` — mutable state bag passed between passes
- `PassManager` — dependency resolution and sequential execution
- `AnalysisPass` — trait that every pass implements

### HTTP Server (`axumortem` crate)

A thin wrapper that exposes the engine over HTTP. It handles file uploads, database persistence, and result retrieval.

**Responsibilities:**
- Accept multipart file uploads
- Delegate analysis to the engine (on a blocking thread)
- Persist results to PostgreSQL
- Retrieve cached results by slug
- Health check endpoint

**Routes:**
- `PUT /api/upload` — upload a binary, receive a slug
- `GET /api/analysis/{slug}` — retrieve full analysis results
- `GET /health` — liveness check

### Frontend (`frontend/`)

React 19 SPA with tabbed analysis results. No business logic — it renders whatever the API returns.

**Responsibilities:**
- Drag-and-drop file upload with progress
- Display analysis results across six tabs
- Render CFG visualizations using dagre graph layout
- Validate API responses with Zod schemas

## Pass-Based Pipeline

The analysis pipeline is the architectural centerpiece. Every analysis capability is a "pass" — an isolated unit that reads from the shared context, does its work, and writes results back.

### The AnalysisPass Trait

Every pass implements this trait:

```rust
pub trait AnalysisPass: Sealed + Send + Sync {
    fn name(&self) -> &'static str;
    fn dependencies(&self) -> &[&'static str];
    fn run(
        &self,
        ctx: &mut AnalysisContext,
    ) -> Result<(), EngineError>;
}
```

`name()` returns a unique identifier. `dependencies()` returns the names of passes that must run first. `run()` does the actual work, reading inputs from `ctx` and writing outputs back to `ctx`.

The `Sealed` supertrait prevents external code from implementing `AnalysisPass`. This is the sealed trait pattern — only the `axumortem-engine` crate can define passes:

```rust
mod private {
    pub trait Sealed {}
}

pub trait AnalysisPass: private::Sealed + Send + Sync {
    // ...
}
```

### The AnalysisContext

Context is the shared state bag that flows through the pipeline:

```rust
pub struct AnalysisContext {
    source: BinarySource,
    pub sha256: String,
    pub file_name: String,
    pub file_size: u64,
    pub format_result: Option<FormatResult>,
    pub import_result: Option<ImportResult>,
    pub string_result: Option<StringResult>,
    pub entropy_result: Option<EntropyResult>,
    pub disassembly_result: Option<DisassemblyResult>,
    pub threat_result: Option<ThreatResult>,
}
```

Each pass checks for its dependencies via `Option`. If `EntropyPass` needs format data, it calls `ctx.format_result.as_ref().ok_or_else(...)`. If the dependency isn't there, the pass fails with a `MissingDependency` error.

`BinarySource` supports two modes:

```rust
pub enum BinarySource {
    Mapped(Mmap),
    Buffered(Arc<[u8]>),
}
```

Memory-mapped files for large binaries analyzed from disk. Buffered byte arrays for binaries received over HTTP. Both implement `AsRef<[u8]>`, so passes don't care which mode is active.

### Topological Ordering

The PassManager sorts passes using Kahn's algorithm (BFS-based topological sort). This guarantees that every pass runs after its dependencies, regardless of registration order:

```rust
fn topological_order(
    passes: &[Box<dyn AnalysisPass>],
) -> Vec<usize> {
    let name_to_idx: HashMap<&str, usize> = passes
        .iter()
        .enumerate()
        .map(|(i, p)| (p.name(), i))
        .collect();

    let n = passes.len();
    let mut in_degree = vec![0usize; n];
    let mut adjacency: Vec<Vec<usize>> = vec![vec![]; n];

    for (idx, pass) in passes.iter().enumerate() {
        for dep_name in pass.dependencies() {
            if let Some(&dep_idx) = name_to_idx.get(dep_name) {
                adjacency[dep_idx].push(idx);
                in_degree[idx] += 1;
            }
        }
    }

    let mut queue: VecDeque<usize> = in_degree
        .iter()
        .enumerate()
        .filter(|&(_, deg)| *deg == 0)
        .map(|(i, _)| i)
        .collect();

    let mut order = Vec::with_capacity(n);

    while let Some(node) = queue.pop_front() {
        order.push(node);
        for &neighbor in &adjacency[node] {
            in_degree[neighbor] -= 1;
            if in_degree[neighbor] == 0 {
                queue.push_back(neighbor);
            }
        }
    }

    assert_eq!(
        order.len(), n,
        "cycle detected in pass dependencies"
    );

    order
}
```

The algorithm builds an adjacency list from dependency declarations, computes in-degrees, then processes nodes with zero in-degree first. If the final order doesn't include all passes, there's a cycle — which panics at engine construction time rather than failing silently at analysis time.

### Pass Dependency Graph

```
  FormatPass (no dependencies)
       │
       ├──────────┬──────────┬──────────┐
       │          │          │          │
       v          v          v          v
  ImportPass  StringPass  EntropyPass  DisasmPass
       │          │          │
       │          │          │
       └──────────┴──────────┘
                  │
                  v
             ThreatPass (depends on all previous)
```

`FormatPass` runs first because it has no dependencies. The four middle passes all depend on `FormatPass` but not on each other. `ThreatPass` depends on imports, strings, and entropy (it reads their results to compute the score).

### Execution and Error Handling

The PassManager runs all passes in order, timing each one. If a pass fails, the error is recorded but execution continues — a failure in disassembly shouldn't prevent threat scoring from running on the import and entropy data that's already available:

```rust
pub fn run_all(
    &self,
    ctx: &mut AnalysisContext,
) -> PassReport {
    let mut outcomes = Vec::with_capacity(self.passes.len());

    for &idx in &self.order {
        let pass = &self.passes[idx];
        let start = Instant::now();
        let result = pass.run(ctx);
        let duration_ms = start.elapsed().as_millis() as u64;

        let outcome = match result {
            Ok(()) => PassOutcome {
                name: pass.name(),
                success: true,
                duration_ms,
                error_message: None,
            },
            Err(e) => PassOutcome {
                name: pass.name(),
                success: false,
                duration_ms,
                error_message: Some(e.to_string()),
            },
        };

        outcomes.push(outcome);
    }

    PassReport { outcomes }
}
```

`PassReport` collects every outcome so the caller can inspect what succeeded, what failed, and how long each pass took.

## Data Flow

### Upload Flow

```
Client                    Axum                     Engine              PostgreSQL
  │                         │                        │                     │
  │── PUT /api/upload ─────>│                        │                     │
  │   (multipart file)      │                        │                     │
  │                         │── sha256_hex(data) ──> │                     │
  │                         │                        │                     │
  │                         │── find_slug_by_sha256 ─┼────────────────────>│
  │                         │<── Some(slug) ─────────┼────────────────────┤│
  │<── { slug, cached: true }                        │       (if exists)  │
  │                         │                        │                     │
  │                         │  (if not cached)       │                     │
  │                         │── spawn_blocking ─────>│                     │
  │                         │                        │── FormatPass.run()  │
  │                         │                        │── ImportPass.run()  │
  │                         │                        │── StringPass.run()  │
  │                         │                        │── EntropyPass.run() │
  │                         │                        │── DisasmPass.run()  │
  │                         │                        │── ThreatPass.run()  │
  │                         │<── (ctx, report) ──────│                     │
  │                         │                        │                     │
  │                         │── BEGIN TRANSACTION ───┼────────────────────>│
  │                         │── insert_analysis ─────┼────────────────────>│
  │                         │── insert_pass_result ──┼──── (x6) ─────────>│
  │                         │── COMMIT ──────────────┼────────────────────>│
  │                         │                        │                     │
  │<── { slug, cached: false }                       │                     │
```

The SHA-256 check-and-return pattern means identical binaries are never analyzed twice. The first upload runs the full pipeline (which can take seconds for large binaries), but every subsequent upload of the same file returns instantly from the cache.

The `spawn_blocking` call is critical. Analysis is CPU-bound (parsing, entropy calculation, disassembly). Running it on the async executor would block other requests. `spawn_blocking` moves the work to Tokio's blocking thread pool.

### Retrieval Flow

```
Client                    Axum                    PostgreSQL
  │                         │                         │
  │── GET /analysis/{slug} ─>│                         │
  │                         │── fetch_by_slug ────────>│
  │                         │<── AnalysisRow + ────────│
  │                         │    Vec<PassResultRow>    │
  │                         │                         │
  │                         │── deserialize JSON       │
  │                         │   per pass_name          │
  │                         │                         │
  │<── AnalysisResponse ────│                         │
```

Each pass result is stored as a JSONB column. The API reconstructs the typed response by matching `pass_name` to the appropriate deserializer.

## Design Patterns

### Sealed Trait Pattern

**Where:** `pass.rs`

**What:** The `AnalysisPass` trait requires `Sealed`, which is defined in a `mod private` block. Only types within the `axumortem-engine` crate can implement `Sealed`, which means only this crate can define analysis passes.

**Why:** This prevents downstream consumers from creating their own passes that could break invariants (like declaring circular dependencies or writing to context fields they shouldn't). If extensibility is needed later, it can be added through a plugin system with proper validation rather than through uncontrolled trait implementations.

**Trade-off:** Less flexible than an open trait, but the invariant protection is worth it for a security tool where pass ordering correctness matters.

### Context Object Pattern

**Where:** `context.rs`

**What:** `AnalysisContext` is a mutable struct passed through the entire pipeline. Each pass reads what it needs and writes its results.

**Why:** Passes need to share data without knowing about each other directly. The context acts as a typed blackboard. Using `Option<T>` for each result field means passes can check at runtime whether their dependencies produced output.

**Alternative considered:** Returning results from each pass and threading them through explicitly. Rejected because it creates tight coupling between passes and makes adding new passes require changing the orchestrator's type signature.

### Factory Registration

**Where:** `lib.rs`

**What:** All passes are registered in a single `vec![]` in `AnalysisEngine::new()`:

```rust
let passes: Vec<Box<dyn AnalysisPass>> = vec![
    Box::new(FormatPass),
    Box::new(ImportPass),
    Box::new(StringPass),
    Box::new(EntropyPass),
    Box::new(DisasmPass),
    Box::new(ThreatPass),
];
```

**Why:** Single point of registration. Adding a new pass means adding one line here plus the pass implementation. The topological sort handles ordering automatically — you don't need to worry about insertion order.

### Macro-Based Serialization

**Where:** `upload.rs`

**What:** The `add_pass!` macro generates pass result serialization for all six passes:

```rust
macro_rules! add_pass {
    ($field:ident, $name:expr) => {
        if let Some(ref r) = ctx.$field {
            results.push(NewPassResult {
                analysis_id,
                pass_name: api_name($name).to_string(),
                result: serde_json::to_value(r)?,
                duration_ms: durations.get($name).map(|&d| d as i32),
            });
        }
    };
}

add_pass!(format_result, "format");
add_pass!(import_result, "imports");
add_pass!(string_result, "strings");
add_pass!(entropy_result, "entropy");
add_pass!(disassembly_result, "disasm");
add_pass!(threat_result, "threat");
```

**Why:** Each pass result needs the same treatment: check if it exists, serialize to JSON, pair with its duration. The macro eliminates six near-identical code blocks.

## Data Models

### Database Schema

```sql
CREATE TABLE analyses (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sha256      TEXT NOT NULL UNIQUE,
    file_name   TEXT NOT NULL,
    file_size   BIGINT NOT NULL,
    format      TEXT NOT NULL DEFAULT '',
    architecture TEXT NOT NULL DEFAULT '',
    entry_point BIGINT,
    threat_score INTEGER,
    risk_level  TEXT,
    slug        TEXT NOT NULL UNIQUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE pass_results (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_id UUID NOT NULL REFERENCES analyses(id) ON DELETE CASCADE,
    pass_name   TEXT NOT NULL,
    result      JSONB NOT NULL,
    duration_ms INTEGER
);
```

Two tables. `analyses` holds the summary metadata (what you'd show in a list view). `pass_results` holds the detailed output from each pass as JSONB. This separation means listing recent analyses is a fast indexed query, while detailed results load on demand.

The `sha256` column has a `UNIQUE` constraint — this is the deduplication key. The `slug` (first 12 characters of the SHA-256) serves as a human-friendly URL identifier.

### Engine Type System

The engine uses Rust enums extensively for type safety:

```rust
pub enum BinaryFormat { Elf, Pe, MachO }
pub enum Architecture { X86, X86_64, Arm, Aarch64, Other(String) }
pub enum RiskLevel { Benign, Low, Medium, High, Critical }
pub enum EntropyClassification { Plaintext, NativeCode, Compressed, Packed, Encrypted }
pub enum FlowControlType { Next, Branch, ConditionalBranch, Call, Return, Interrupt }
pub enum CfgEdgeType { Fallthrough, ConditionalTrue, ConditionalFalse, Unconditional, Call }
```

Every enum derives `Serialize` and `Deserialize`. The engine never deals with raw strings for these concepts — pattern matching enforces exhaustive handling.

## Security Architecture

### Threat Model

**What we protect:**
- The analysis server against malicious binary uploads (the binary is untrusted input)
- Analysis results against tampering (SHA-256 integrity verification)
- The database against injection (SQLx compile-time checked queries)

**What we don't protect against:**
- Dynamic analysis escape (AXUMORTEM is static only — it never executes the binary)
- Denial of service from extremely large binaries (mitigated by the 50MB upload limit)
- Side-channel attacks from the analysis timing (pass durations are exposed in the API)

### Defense Layers

1. **Upload size limit** — `MAX_UPLOAD_SIZE` (default 50MB) prevents memory exhaustion
2. **Blocking thread isolation** — CPU-intensive analysis runs on `spawn_blocking`, not the async runtime
3. **Instruction/function caps** — Disassembly limits prevent pathological binaries from causing infinite loops
4. **SQL injection prevention** — All queries use SQLx parameterized statements checked at compile time
5. **CORS configuration** — Configurable origin restrictions
6. **Deduplication** — SHA-256 check prevents re-analysis of known binaries (also prevents repeated expensive computation)

## Performance Considerations

### Bottlenecks

1. **Disassembly** — recursive descent through x86 instructions is the slowest pass. The 50k instruction cap keeps worst-case bounded.
2. **YARA scanning** — compiling rules is expensive, but AXUMORTEM compiles once at engine startup and reuses the compiled scanner.
3. **Entropy calculation** — Shannon entropy requires iterating every byte. For a 50MB binary, that's 50 million byte-frequency lookups.

### Optimizations

- **SHA-256 deduplication** — the most impactful optimization. No analysis work for previously-seen binaries.
- **Compile-once YARA** — rule compilation happens in `YaraScanner::new()`, not per-analysis.
- **Section-level entropy** — instead of byte-by-byte sliding window entropy (which is O(n * window_size)), AXUMORTEM calculates per-section entropy, which is O(total_bytes) with a constant factor of 256 (one counter per possible byte value).
- **`spawn_blocking`** — keeps the async runtime responsive while analysis runs.

### Scaling

**Vertical:** Increase `TOKIO_WORKER_THREADS` and the blocking thread pool size. Each analysis is independent, so more cores means more concurrent analyses.

**Horizontal:** The engine is stateless — the only shared state is PostgreSQL. Multiple backend instances behind a load balancer would work with no code changes. The SHA-256 deduplication in the database prevents duplicate work even across instances.

## Design Decisions

### Why a pass-based pipeline instead of a monolithic analyzer?

**Decision:** Each analysis capability is an independent pass with declared dependencies.

**Alternatives considered:**
- Monolithic function that does everything in sequence
- Event-driven architecture with message passing between analyzers

**Why passes won:** Modularity (add/remove capabilities without touching others), testability (each pass has isolated unit tests), partial results (if disassembly fails, you still get import analysis), and clear dependency management (topological sort handles ordering).

### Why Rust for the engine?

**Decision:** Rust for the analysis engine, which is the performance-critical component.

**Why:** Binary parsing is inherently unsafe territory — you're interpreting untrusted bytes as structured data. Rust's ownership model prevents buffer overflows, use-after-free, and data races that plague C/C++ binary analysis tools. The `goblin` crate handles format parsing safely. `iced-x86` provides high-performance disassembly. And `yara-x` (the official Rust YARA rewrite) eliminates FFI overhead.

### Why store pass results as JSONB?

**Decision:** Each pass result is serialized to JSONB in a single column.

**Alternatives considered:**
- Normalized tables for each pass (separate `entropy_results`, `import_results`, etc.)
- A document database (MongoDB, SurrealDB)

**Why JSONB:** Pass result schemas change as passes evolve. Adding a field to `EntropyResult` requires zero database migrations — the JSONB column accepts whatever the serializer produces. Normalized tables would require a migration for every schema change. PostgreSQL's JSONB indexing means queries into pass results are still fast when needed.

### Why SHA-256 slug instead of auto-increment?

**Decision:** URLs use the first 12 hex characters of the SHA-256 hash (`/analysis/a1b2c3d4e5f6`).

**Why:** Deterministic — the same binary always produces the same URL. No sequential IDs to enumerate. The 12-character hex slug gives 48 bits of collision resistance (2^48 = ~281 trillion possible values), which is more than sufficient for a single-instance tool.

## Deployment Architecture

### Production

```
┌──────────────────────────────────────────────────┐
│ Docker Compose                                   │
│                                                  │
│  ┌──────────────────────┐                        │
│  │ Nginx (:22784)       │                        │
│  │ - serves static SPA  │                        │
│  │ - proxies /api → :3000                        │
│  └──────────┬───────────┘                        │
│             │                                    │
│  ┌──────────v───────────┐  ┌──────────────────┐  │
│  │ axumortem (:3000)    │  │ PostgreSQL       │  │
│  │ - Axum HTTP server   │──│ (:5432)          │  │
│  │ - analysis engine    │  │ - analyses table │  │
│  └──────────────────────┘  │ - pass_results   │  │
│                            └──────────────────┘  │
└──────────────────────────────────────────────────┘
```

### Development

```
┌──────────────────────────────────────────────────┐
│ Docker Compose (dev)                             │
│                                                  │
│  ┌──────────────────────┐                        │
│  │ Vite (:15723)        │                        │
│  │ - HMR dev server     │                        │
│  │ - proxies /api → :3000                        │
│  └──────────────────────┘                        │
│                                                  │
│  ┌──────────────────────┐  ┌──────────────────┐  │
│  │ axumortem (:3000)    │  │ PostgreSQL       │  │
│  │ - cargo watch        │──│ (:5432)          │  │
│  │ - auto-rebuild       │  └──────────────────┘  │
│  └──────────────────────┘                        │
└──────────────────────────────────────────────────┘
```

The development setup swaps Nginx for Vite's dev server (with HMR) and adds cargo watch for backend auto-rebuilds.

## Extensibility

### Adding a New Pass

1. Create `passes/newpass.rs` with a struct that implements `Sealed` and `AnalysisPass`
2. Add a result field to `AnalysisContext` (e.g., `pub newpass_result: Option<NewPassResult>`)
3. Register the pass in `AnalysisEngine::new()` by adding `Box::new(NewPass)` to the vec
4. The topological sort handles ordering automatically based on your `dependencies()` return

### Adding a New Binary Format

1. Create `formats/newformat.rs` with the parser
2. Add a variant to `BinaryFormat` enum
3. Add the magic byte check and dispatch in `formats::parse_format()`
4. Add format-specific info struct if needed (like `PeInfo`, `ElfInfo`)

## Limitations

- **Static analysis only** — no sandbox execution, no behavioral monitoring. A binary that decrypts its payload at runtime will show encrypted entropy but no unpacked code.
- **x86/x86_64 disassembly only** — ARM, MIPS, and RISC-V binaries get all other passes but no disassembly or CFG.
- **No cross-reference analysis** — the disassembler doesn't track data references (which functions read which strings), only control flow.
- **Single-file analysis** — can't analyze multi-binary packages (MSI installers, APKs with native libs) as a unit.
- **No incremental analysis** — changing YARA rules requires re-analyzing all binaries. There's no way to re-run just one pass on cached data.

## Next Steps

Continue to [03 - Implementation](03-IMPLEMENTATION.md) for a code-level walkthrough of how each pass is built, with real snippets from the codebase.
