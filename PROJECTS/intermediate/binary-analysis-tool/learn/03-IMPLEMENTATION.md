# Binary Analysis Tool: Implementation

This module walks through how each major component is built, using real code from the codebase. We'll trace the analysis pipeline from binary upload to threat score.

## File Structure Walkthrough

```
backend/crates/
├── axumortem-engine/src/
│   ├── lib.rs              Engine orchestrator — registers passes, computes SHA-256
│   ├── types.rs            Enums shared across passes (BinaryFormat, RiskLevel, etc.)
│   ├── context.rs          AnalysisContext — the mutable state bag for the pipeline
│   ├── pass.rs             AnalysisPass trait, PassManager, topological sort
│   ├── error.rs            EngineError enum (parse failures, missing dependencies)
│   ├── yara.rs             YaraScanner with 14 built-in detection rules
│   ├── formats/
│   │   ├── mod.rs          FormatResult structs, anomaly enums, parse dispatch
│   │   ├── elf.rs          ELF parser (sections, segments, RELRO, PIE detection)
│   │   ├── pe.rs           PE parser (imports, TLS callbacks, overlay detection)
│   │   └── macho.rs        Mach-O parser (universal binaries, code signatures)
│   └── passes/
│       ├── format.rs       Pass 1 — binary format identification
│       ├── imports.rs      Pass 2 — import/export extraction + suspicious API flagging
│       ├── strings.rs      Pass 3 — string extraction in ASCII and UTF-16LE
│       ├── entropy.rs      Pass 4 — Shannon entropy + packer detection
│       ├── disasm.rs       Pass 5 — x86/x86_64 disassembly + CFG construction
│       └── threat.rs       Pass 6 — 8-category scoring + MITRE mapping
│
└── axumortem/src/
    ├── main.rs             Server startup, signal handling, graceful shutdown
    ├── config.rs           CLI args + environment configuration
    ├── state.rs            AppState (database pool, engine Arc, config)
    ├── error.rs            API error types → HTTP status codes
    ├── routes/
    │   ├── upload.rs       PUT /api/upload — multipart handling + analysis dispatch
    │   ├── analysis.rs     GET /api/analysis/{slug} — result retrieval
    │   └── health.rs       GET /health — liveness probe
    ├── db/
    │   ├── models.rs       Database row structs (AnalysisRow, PassResultRow)
    │   └── queries.rs      SQL operations (insert, find by SHA-256, find by slug)
    └── middleware/
        └── cors.rs         CORS layer configuration
```

## Building the Engine

The engine is the entry point that wires everything together. When `AnalysisEngine::new()` is called, it creates all six passes and hands them to the `PassManager`, which topologically sorts them:

```rust
pub struct AnalysisEngine {
    pass_manager: PassManager,
}

impl AnalysisEngine {
    pub fn new() -> Result<Self, EngineError> {
        let passes: Vec<Box<dyn pass::AnalysisPass>> =
            vec![
                Box::new(FormatPass),
                Box::new(ImportPass),
                Box::new(StringPass),
                Box::new(EntropyPass),
                Box::new(DisasmPass),
                Box::new(ThreatPass),
            ];

        let pass_manager = PassManager::new(passes);

        Ok(Self { pass_manager })
    }
}
```

The registration order doesn't matter — passes can be listed in any order because the topological sort resolves execution order from their declared dependencies. `ThreatPass` could be first in the vec and it would still run last, because it depends on everything else.

The `analyze` method creates a fresh `AnalysisContext`, runs all passes, and returns both the context (with results) and a report (with timing/error info):

```rust
pub fn analyze(
    &self,
    data: &[u8],
    file_name: &str,
) -> (AnalysisContext, PassReport) {
    let sha256 = compute_sha256(data);
    let file_size = data.len() as u64;
    let mut ctx = AnalysisContext::new(
        BinarySource::Buffered(Arc::from(data.to_vec())),
        sha256,
        file_name.to_string(),
        file_size,
    );
    let report = self.pass_manager.run_all(&mut ctx);
    (ctx, report)
}
```

The binary data is wrapped in `Arc<[u8]>` so it can be shared without copying. The `BinarySource::Buffered` variant is used for HTTP uploads; `BinarySource::Mapped` would be used for memory-mapped files from disk.

## Building the Format Parser

The format pass is the simplest — it delegates to `formats::parse_format()`:

```rust
pub struct FormatPass;

impl AnalysisPass for FormatPass {
    fn name(&self) -> &'static str {
        "format"
    }

    fn dependencies(&self) -> &[&'static str] {
        &[]
    }

    fn run(
        &self,
        ctx: &mut AnalysisContext,
    ) -> Result<(), EngineError> {
        let result = formats::parse_format(ctx.data())?;
        ctx.format_result = Some(result);
        Ok(())
    }
}
```

No dependencies — this pass always runs first. The `parse_format` function uses `goblin`'s auto-detection to identify the format from magic bytes and dispatch to the appropriate parser (ELF, PE, or Mach-O).

The result includes structural anomaly detection. The anomaly enum covers specific red flags:

```rust
pub enum FormatAnomaly {
    EntryPointOutsideText { ep: u64, text_range: (u64, u64) },
    EntryPointInLastSection { ep: u64, section: String },
    EntryPointOutsideSections { ep: u64 },
    RwxSection { name: String },
    EmptySectionName { index: usize },
    StrippedBinary,
    SuspiciousSectionName { name: String, reason: String },
    HighVirtualToRawRatio { section: String, ratio: f64 },
    TlsCallbackPresent { count: usize },
    OverlayPresent { offset: u64, size: u64 },
}
```

Each anomaly variant carries its own evidence — the entry point address, the section name, the ratio value. This isn't just "something is wrong," it's "here's exactly what's wrong and the numbers to prove it."

### Section Hashing

Every section gets its own SHA-256 hash. This enables section-level diffing between binaries — if two binaries share the same `.text` hash but different `.rsrc` hashes, the modification was in the resource section (common in trojanized software where the code is identical but the payload is embedded in resources).

## Building the Import Analysis Pass

The import pass extracts function imports, flags suspicious APIs, and detects dangerous combinations:

```rust
pub struct SuspiciousApiDef {
    pub name: &'static str,
    pub tag: &'static str,
    pub mitre_id: &'static str,
}

pub const SUSPICIOUS_APIS: &[SuspiciousApiDef] = &[
    SuspiciousApiDef {
        name: "VirtualAllocEx",
        tag: "injection",
        mitre_id: "T1055",
    },
    SuspiciousApiDef {
        name: "WriteProcessMemory",
        tag: "injection",
        mitre_id: "T1055",
    },
    SuspiciousApiDef {
        name: "CreateRemoteThread",
        tag: "injection",
        mitre_id: "T1055",
    },
    SuspiciousApiDef {
        name: "IsDebuggerPresent",
        tag: "anti-debug",
        mitre_id: "T1622",
    },
    // ... 22 suspicious APIs total
];
```

Each API definition includes a `tag` for grouping (injection, hollowing, anti-debug, persistence) and a MITRE ATT&CK technique ID. The pass matches import names against this list and also checks for combinations — groups of APIs that together indicate a specific attack technique.

Combination detection works by collecting all imported APIs into a `HashSet` and then checking whether specific groups are all present. The process injection chain requires three specific APIs to all be present in the same binary. Finding just one of them is notable; finding all three is a strong indicator.

### Linux Import Handling

Linux ELF binaries don't have a Windows-style import table. Instead, the pass extracts dynamic symbols and matches them against Linux-specific suspicious APIs: `ptrace` (process debugging/injection), `mmap` + `mprotect` (runtime code generation), `dlopen` + `dlsym` (dynamic loading), and network APIs combined with `execve` (reverse shell pattern).

## Building the String Extraction Pass

String extraction is deceptively complex. The pass handles two encodings, 14 categories, and multiple detection strategies:

```rust
pub struct ExtractedString {
    pub value: String,
    pub offset: u64,
    pub encoding: StringEncoding,
    pub length: usize,
    pub category: StringCategory,
    pub is_suspicious: bool,
    pub section: Option<String>,
}
```

Each string gets an offset (position in the binary), encoding, category, suspicion flag, and the section it was found in (if it falls within a known section boundary).

### ASCII Extraction

The ASCII extractor walks every byte in the binary, building strings from sequences of printable characters (0x20-0x7E plus tab, newline, carriage return). When the sequence reaches `MIN_STRING_LENGTH` (4 characters) and a non-printable byte is hit, the string is finalized.

### UTF-16LE Extraction

Windows binaries store many strings in UTF-16LE. The extractor scans for pairs of bytes where the second byte is 0x00 (the common case for ASCII characters encoded as UTF-16LE). This catches most English-language strings in PE binaries that ASCII extraction would miss.

### Category Detection

Each extracted string runs through a categorization pipeline. The detection logic is pattern-based without using regex for performance:

```rust
const URL_PREFIXES: &[&str] = &["http://", "https://", "ftp://"];

const SHELL_INDICATORS: &[&str] = &[
    "cmd.exe", "cmd /c", "cmd /k",
    "powershell", "pwsh",
    "/bin/sh", "/bin/bash", "/bin/zsh",
    "bash -c", "sh -c",
    "| bash", "|bash",
    "| /bin/sh", "|/bin/sh",
];

const PACKER_SIGNATURES: &[&str] = &[
    "UPX!", "MPRESS", ".themida", ".vmp", ".enigma",
    "PEC2", "ASPack", "MEW ",
];

const ANTI_ANALYSIS_INDICATORS: &[&str] = &[
    "VMware", "VirtualBox", "VBox", "QEMU",
    "sandbox", "Sandboxie", "wireshark", "procmon",
    "x64dbg", "x32dbg", "ollydbg", "IDA Pro", "Ghidra",
];
```

URL detection checks prefixes. IP address detection validates four dot-separated octets in the 0-255 range. Shell command detection matches against known shell interpreters and pipe patterns. Anti-analysis detection looks for debugger, VM, and sandbox tool names.

### Base64 Detection

The pass flags potential Base64-encoded data using structural validation rather than attempting to decode:

- Minimum 20 characters
- Only valid Base64 characters (A-Z, a-z, 0-9, +, /)
- Proper padding (= or == at end, if present)
- Specifically flags `TVqQ`, `TVpQ`, `TVoA`, `TVpB` prefixes — these are Base64 encodings of the MZ PE header, indicating an embedded Windows executable

### Statistics

The pass computes aggregate statistics alongside the raw string list:

```rust
pub struct StringStatistics {
    pub total: usize,
    pub by_encoding: HashMap<StringEncoding, usize>,
    pub by_category: HashMap<StringCategory, usize>,
    pub suspicious_count: usize,
}
```

This gives the threat scorer and the frontend quick summary data without reprocessing the full string list.

## Building the Entropy Analysis Pass

The entropy pass combines Shannon entropy calculation with structural analysis to detect packing:

```rust
impl AnalysisPass for EntropyPass {
    fn name(&self) -> &'static str {
        "entropy"
    }

    fn dependencies(&self) -> &[&'static str] {
        &["format"]
    }

    fn run(
        &self,
        ctx: &mut AnalysisContext,
    ) -> Result<(), EngineError> {
        let format_result = ctx
            .format_result
            .as_ref()
            .ok_or_else(|| EngineError::MissingDependency {
                pass: "entropy".into(),
                dependency: "format".into(),
            })?;

        let data = ctx.data();
        let result = analyze_entropy(
            data,
            &format_result.sections,
            format_result.entry_point,
        );
        ctx.entropy_result = Some(result);
        Ok(())
    }
}
```

The dependency check pattern appears in every pass that requires prior results. If `format_result` is `None` (because `FormatPass` failed), the entropy pass returns a `MissingDependency` error rather than panicking.

### Shannon Entropy Implementation

The core entropy calculation is compact:

```rust
fn shannon_entropy(data: &[u8]) -> f64 {
    if data.is_empty() {
        return 0.0;
    }
    let mut freq = [0u64; BYTE_RANGE];
    for &byte in data {
        freq[byte as usize] += 1;
    }
    let len = data.len() as f64;
    freq.iter()
        .filter(|&&c| c > 0)
        .map(|&c| {
            let p = c as f64 / len;
            -p * p.log2()
        })
        .sum()
}
```

A fixed-size array of 256 counters (one per possible byte value). Single pass through the data to count frequencies. Then the Shannon formula: for each byte value that appears at least once, compute `-(p * log2(p))` and sum. The result ranges from 0.0 (all identical bytes) to 8.0 (perfectly random).

The `filter(|&&c| c > 0)` is important — `log2(0)` is negative infinity. Byte values that never appear are skipped entirely.

### Per-Section Analysis

The pass calculates entropy for each section individually, not just the binary as a whole:

```rust
for section in sections {
    let section_data = read_section_data(
        data,
        section.raw_offset,
        section.raw_size,
    );
    let entropy = if section_data.is_empty() {
        0.0
    } else {
        shannon_entropy(section_data)
    };
    let classification = classify_entropy(entropy);
    let vr_ratio = if section.raw_size > 0 {
        section.virtual_size as f64 / section.raw_size as f64
    } else {
        0.0
    };

    let mut flags = Vec::new();

    if entropy > HIGH_ENTROPY_THRESHOLD {
        flags.push(EntropyFlag::HighEntropy);
    }
    if vr_ratio > VIRTUAL_RAW_RATIO_THRESHOLD {
        flags.push(EntropyFlag::HighVirtualToRawRatio);
    }
    if section.raw_size == 0 && section.virtual_size > 0 {
        flags.push(EntropyFlag::EmptyRawData);
    }
    if section.permissions.is_rwx() {
        flags.push(EntropyFlag::Rwx);
    }
    // ...
}
```

Per-section analysis matters because a binary can have a normal `.text` section (entropy ~5.5) but a packed `.rsrc` section (entropy ~7.8). Overall entropy might average out to ~6.5, which looks like compressed data. Per-section analysis catches the packed section that overall analysis would miss.

### PUSHAD Detection

A simple but effective heuristic: check if the first byte at the entry point is `0x60` (the x86 PUSHAD opcode). UPX and many other packers save all registers with PUSHAD before executing the unpacking stub:

```rust
if first_byte == PUSHAD_OPCODE {
    packing_indicators.push(PackingIndicator {
        indicator_type: "entry_point".into(),
        description: "PUSHAD at entry point".into(),
        evidence: format!(
            "byte 0x{PUSHAD_OPCODE:02x} at EP offset 0x{ep_file_offset:x}"
        ),
        packer_name: None,
    });
}
```

### Packing Decision

Packing detection combines all signals: known section names set `packer_name` directly. Structural indicators (empty raw data with virtual allocation, high V/R ratio) accumulate a count. If a packer name is identified OR enough structural indicators fire, packing is flagged:

```rust
let packing_detected = packer_name.is_some()
    || structural_count >= STRUCTURAL_INDICATORS_FOR_PACKING;
```

`STRUCTURAL_INDICATORS_FOR_PACKING` is 2 — you need at least two structural indicators to flag packing without a known packer name. This prevents false positives from a single anomalous section.

## Building the Disassembly Pass

The disassembly pass converts raw machine code into structured instructions, basic blocks, and control flow graphs:

```rust
impl AnalysisPass for DisasmPass {
    fn name(&self) -> &'static str {
        "disasm"
    }

    fn dependencies(&self) -> &[&'static str] {
        &["format"]
    }

    fn run(
        &self,
        ctx: &mut AnalysisContext,
    ) -> Result<(), EngineError> {
        let format_result = ctx.format_result.as_ref()
            .ok_or_else(|| EngineError::MissingDependency {
                pass: "disasm".into(),
                dependency: "format".into(),
            })?;

        let arch = &format_result.architecture;
        let bits = match arch {
            Architecture::X86 => 32u32,
            Architecture::X86_64 => 64,
            _ => {
                ctx.disassembly_result = Some(empty_result(
                    format_result.bits,
                    format_result.entry_point,
                ));
                return Ok(());
            }
        };

        let data = ctx.data();
        let sections = &format_result.sections;
        let entry_point = format_result.entry_point;

        let mut seeds = vec![entry_point];
        seeds.extend_from_slice(&format_result.function_hints);

        let result = disassemble(data, sections, bits, entry_point, &seeds);
        ctx.disassembly_result = Some(result);
        Ok(())
    }
}
```

Non-x86 architectures get an empty result rather than an error. This is intentional — a Mach-O AArch64 binary should still get format parsing, import analysis, strings, entropy, and threat scoring. Only disassembly is skipped.

### Recursive Descent

The disassembler uses a worklist-based recursive descent approach. Starting from seed addresses (entry point + symbol table hints), it discovers functions by following call instructions:

```rust
fn disassemble(
    data: &[u8],
    sections: &[SectionInfo],
    bits: u32,
    entry_point: u64,
    seeds: &[u64],
) -> DisassemblyResult {
    let exec_sections: Vec<&SectionInfo> = sections
        .iter()
        .filter(|s| s.permissions.execute && s.raw_size > 0)
        .collect();

    let mut functions = Vec::new();
    let mut visited_functions = HashSet::new();
    let mut total_instructions = 0;
    let mut function_queue: VecDeque<u64> =
        seeds.iter().copied().collect();

    while let Some(func_addr) = function_queue.pop_front() {
        if functions.len() >= MAX_FUNCTIONS
            || total_instructions >= MAX_INSTRUCTIONS
        {
            break;
        }
        if !visited_functions.insert(func_addr) {
            continue;
        }
        if vaddr_to_offset(sections, func_addr).is_none() {
            continue;
        }

        let (func_info, discovered_calls) =
            disassemble_function(
                data, sections, &exec_sections,
                bits, func_addr,
                func_addr == entry_point,
                MAX_INSTRUCTIONS - total_instructions,
            );

        total_instructions += func_info.instruction_count;
        functions.push(func_info);

        for call_target in discovered_calls {
            if !visited_functions.contains(&call_target) {
                function_queue.push_back(call_target);
            }
        }
    }
    // ...
}
```

The `visited_functions` set prevents infinite loops (recursive calls). The `MAX_FUNCTIONS` (1,000) and `MAX_INSTRUCTIONS` (50,000) caps prevent pathological binaries from causing the analyzer to hang. Each function's `disassemble_function` call returns both the function info AND a list of call targets it discovered — those targets get pushed onto the worklist for later processing.

### CFG Construction

Each function produces a control flow graph with nodes (basic blocks) and edges (control flow transitions):

```rust
pub struct FunctionCfg {
    pub nodes: Vec<CfgNode>,
    pub edges: Vec<CfgEdge>,
}

pub struct CfgNode {
    pub id: u64,
    pub label: String,
    pub instruction_count: usize,
    pub instructions_preview: String,
}

pub struct CfgEdge {
    pub from: u64,
    pub to: u64,
    pub edge_type: CfgEdgeType,
}
```

Basic block boundaries are determined by branch targets (the start of a block) and branch instructions (the end of a block). The edge type distinguishes between conditional branches (true/false), unconditional jumps, function calls, and fallthroughs (sequential execution to the next block).

## Building the Threat Scoring Pass

The threat pass is the most complex — it aggregates findings from every other pass into a unified score:

```rust
impl AnalysisPass for ThreatPass {
    fn name(&self) -> &'static str {
        "threat"
    }

    fn dependencies(&self) -> &[&'static str] {
        &["format", "imports", "strings", "entropy", "disasm"]
    }

    fn run(
        &self,
        ctx: &mut AnalysisContext,
    ) -> Result<(), EngineError> {
        let yara_scanner = YaraScanner::new()?;
        let yara_matches = yara_scanner.scan(ctx.data())?;

        let format_result = ctx.format_result.as_ref();
        let import_result = ctx.import_result.as_ref();
        let string_result = ctx.string_result.as_ref();
        let entropy_result = ctx.entropy_result.as_ref();

        let result = compute_threat_score(
            format_result,
            import_result,
            string_result,
            entropy_result,
            &yara_matches,
        );
        ctx.threat_result = Some(result);
        Ok(())
    }
}
```

Notice that ThreatPass depends on all five other passes. It also runs YARA scanning here rather than in a separate pass, because YARA matches feed directly into the threat score and nowhere else in the pipeline.

### Scoring Architecture

Each scoring category is an independent function that returns a `ScoringCategory`:

```rust
pub fn compute_threat_score(
    format_result: Option<&FormatResult>,
    import_result: Option<&ImportResult>,
    string_result: Option<&StringResult>,
    entropy_result: Option<&EntropyResult>,
    yara_matches: &[YaraMatch],
) -> ThreatResult {
    let cat_import = score_imports(import_result, string_result);
    let cat_entropy = score_entropy(entropy_result);
    let cat_packing = score_packing(entropy_result, format_result, string_result);
    let cat_strings = score_strings(string_result);
    let cat_sections = score_sections(format_result);
    let cat_ep = score_entry_point(format_result);
    let cat_anti = score_anti_analysis(import_result, string_result);
    let cat_yara = score_yara(yara_matches);
    // ...
}
```

Each `score_*` function independently evaluates its category and caps the result at the category maximum. The result includes every individual scoring rule that fired, with its point value and evidence string. This makes the scoring fully transparent — the analyst can see exactly why the score is what it is.

### Category Caps

Constants define the maximum points per category:

```rust
const IMPORT_MAX: u32 = 20;
const ENTROPY_MAX: u32 = 15;
const PACKING_MAX: u32 = 15;
const STRING_MAX: u32 = 10;
const SECTION_MAX: u32 = 10;
const ENTRY_POINT_MAX: u32 = 10;
const ANTI_ANALYSIS_MAX: u32 = 10;
const YARA_MAX: u32 = 10;
```

The caps ensure no single category dominates. A binary that triggers every import rule possible still gets at most 20 points from imports, leaving the other 80 points to be determined by the remaining seven categories.

### Risk Level Classification

The total score maps to a risk level through simple threshold comparison:

```rust
const BENIGN_MAX: u32 = 15;
const LOW_MAX: u32 = 35;
const MEDIUM_MAX: u32 = 55;
const HIGH_MAX: u32 = 75;
```

Score 0-15 is BENIGN. 16-35 is LOW. 36-55 is MEDIUM. 56-75 is HIGH. 76+ is CRITICAL.

## Building the YARA Scanner

The YARA scanner compiles 14 built-in rules from a string constant and provides a `scan` method:

```rust
rule suspicious_upx_packed {
    meta:
        description = "Detects UPX packed binaries"
        category = "packer"
        severity = "medium"
    strings:
        $upx0 = "UPX0"
        $upx1 = "UPX1"
        $upx_magic = { 55 50 58 21 }
    condition:
        ($upx0 and $upx1) or $upx_magic
}
```

This rule fires if the binary contains both "UPX0" and "UPX1" strings (the UPX section names) OR the UPX magic bytes `0x55 0x50 0x58 0x21` (ASCII "UPX!"). The hex pattern `{ 55 50 58 21 }` matches raw bytes at any offset.

More complex rules combine multiple indicators:

```rust
rule suspicious_process_injection {
    meta:
        description = "Detects potential process injection capabilities"
        category = "injection"
        severity = "critical"
    strings:
        $api1 = "VirtualAllocEx"
        $api2 = "WriteProcessMemory"
        $api3 = "CreateRemoteThread"
        $api4 = "NtUnmapViewOfSection"
    condition:
        ($api1 and $api2 and $api3) or ($api4 and $api2)
}
```

The condition uses boolean logic: either the classic injection chain (all three APIs) OR the process hollowing pair. YARA's strength is expressing these multi-indicator conditions concisely.

## The Upload Route

The HTTP layer bridges the frontend and the engine. The upload handler receives a multipart file, checks the SHA-256 cache, and dispatches analysis:

```rust
pub async fn handle(
    State(state): State<AppState>,
    mut multipart: Multipart,
) -> Result<Json<UploadResponse>, ApiError> {
    let (file_name, data) = extract_file(&mut multipart).await?;

    let sha256 = axumortem_engine::sha256_hex(&data);

    if let Some(slug) =
        queries::find_slug_by_sha256(&state.db, &sha256).await?
    {
        return Ok(Json(UploadResponse { slug, cached: true }));
    }

    let engine = Arc::clone(&state.engine);
    let name_clone = file_name.clone();

    let (ctx, report) =
        tokio::task::spawn_blocking(move || {
            engine.analyze(&data, &name_clone)
        })
        .await?;

    // ... persist to database ...

    Ok(Json(UploadResponse { slug, cached: false }))
}
```

The SHA-256 check happens before any analysis work. If the binary has been seen before, the response is immediate. The `spawn_blocking` call is critical — analysis is CPU-bound and would block the Tokio runtime if run on an async task.

### Macro-Based Result Persistence

The upload handler uses a macro to serialize each pass result into JSONB:

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

Each pass result that exists in the context gets serialized to a JSON value and paired with its execution duration. The `api_name` function translates internal pass names to API-friendly names (e.g., "disasm" becomes "disassembly").

## Testing Strategy

### Unit Tests

Each pass has its own test suite. The `FormatPass` tests use fixture binaries (real ELF executables compiled for testing):

```rust
fn load_fixture(name: &str) -> Vec<u8> {
    let path = format!(
        "{}/tests/fixtures/{name}",
        env!("CARGO_MANIFEST_DIR"),
    );
    std::fs::read(&path).unwrap_or_else(|e| {
        panic!("fixture {path}: {e}")
    })
}

#[test]
fn parse_elf_basic_metadata() {
    let data = load_fixture("hello_elf");
    let result = formats::parse_format(&data).unwrap();

    assert_eq!(result.format, BinaryFormat::Elf);
    assert_eq!(result.architecture, Architecture::X86_64);
    assert_eq!(result.bits, 64);
    assert_eq!(result.endianness, Endianness::Little);
    assert!(result.entry_point > 0);
    assert!(result.is_pie);
    assert!(!result.is_stripped);
}
```

### PassManager Tests

The pass system itself has tests for dependency ordering, failure handling, and cycle detection using mock passes:

```rust
#[test]
fn topological_sort_respects_dependencies() {
    let log = Arc::new(Mutex::new(Vec::new()));

    let passes: Vec<Box<dyn AnalysisPass>> = vec![
        Box::new(MockPass { name: "c", deps: vec!["b"], /* ... */ }),
        Box::new(MockPass { name: "a", deps: vec![], /* ... */ }),
        Box::new(MockPass { name: "b", deps: vec!["a"], /* ... */ }),
    ];

    let manager = PassManager::new(passes);
    let mut ctx = make_ctx();
    let report = manager.run_all(&mut ctx);

    let execution_order = log.lock().unwrap().clone();
    assert_eq!(execution_order, vec!["a", "b", "c"]);
    assert!(report.all_succeeded());
}

#[test]
#[should_panic(expected = "cycle detected")]
fn detects_cycle() {
    let passes: Vec<Box<dyn AnalysisPass>> = vec![
        Box::new(MockPass { name: "a", deps: vec!["b"], /* ... */ }),
        Box::new(MockPass { name: "b", deps: vec!["a"], /* ... */ }),
    ];
    let _manager = PassManager::new(passes);
}
```

The cycle detection test verifies that the topological sort panics at construction time (not at analysis time) when passes declare circular dependencies.

### Running Tests

```bash
cd backend
cargo test
```

For a specific pass:

```bash
cargo test -p axumortem-engine --lib passes::entropy
```

## Common Implementation Pitfalls

**Forgetting `spawn_blocking` for CPU work.** If the analysis engine runs on an async task instead of a blocking thread, it starves the Tokio runtime. Other requests (health checks, cached retrievals) would hang until analysis completes. Always use `spawn_blocking` for work that takes more than a few milliseconds of CPU time.

**Not capping disassembly limits.** Without `MAX_FUNCTIONS` and `MAX_INSTRUCTIONS`, a binary with many small functions (or worse, obfuscated code that looks like infinite functions) would cause the analyzer to run indefinitely. Caps make worst-case analysis time bounded.

**Treating `None` results as errors.** If `ImportPass` fails, `ThreatPass` should still compute a partial threat score using whatever data is available. The `Option<T>` pattern in the context makes this natural — scoring functions accept `Option<&ImportResult>` and skip import-based scoring if it's `None`.

**Trusting section boundaries.** A malicious binary can declare section sizes that extend past the end of the file. The `read_section_data` function validates that `raw_offset + raw_size` doesn't exceed the file length before slicing.

## Debugging Tips

**Analysis returns no results:** Check the `PassReport` outcomes. If a pass failed, the error message will tell you what went wrong. Common causes: the binary is too small (less than 4 bytes can't be parsed), or the format isn't recognized (not ELF, PE, or Mach-O).

**Threat score seems wrong:** Inspect the `categories` array in the `ThreatResult`. Each category shows its individual score, max, and the specific rules that fired with evidence strings. Compare the evidence against the binary to verify correctness.

**Disassembly is empty for x86 binary:** Check that the entry point address maps to a valid section with execute permissions. If the entry point is in a non-executable section (an anomaly itself), the disassembler can't find the code.

**YARA rules not matching:** Verify the strings actually exist in the binary. Use `strings` (Unix tool) or a hex editor to confirm. YARA string matching is case-sensitive by default — `"VirtualAllocEx"` won't match `"virtualallocex"`.

## Next Steps

Continue to [04 - Challenges](04-CHALLENGES.md) for extension ideas ranging from adding new analysis passes to building a distributed analysis cluster.
