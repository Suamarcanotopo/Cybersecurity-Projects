# Binary Analysis Tool: Challenges

Extension challenges organized by difficulty. Each builds on the existing codebase — you'll work with the same pass-based pipeline, the same type system, and the same patterns established in the implementation.

## Easy Challenges

### 1. Add Custom YARA Rule Loading

**What to build:** Let users upload their own YARA rules alongside the built-in rules. Accept `.yar` files through a new API endpoint and compile them into the scanner.

**Why it's useful:** Every SOC team has custom YARA rules for threats specific to their environment. Hardcoded rules can't cover organization-specific indicators.

**What you'll learn:** YARA rule compilation, file-based configuration, extending the API without changing the engine's core interface.

**Hints:**
- Look at how `YaraScanner::new()` in `yara.rs` compiles the built-in rules string
- `yara-x` supports compiling multiple rule sources into a single scanner
- Store uploaded rules in a directory and recompile the scanner when rules change
- Add a `GET /api/rules` endpoint to list active rules

**How to verify it works:**
```bash
# Create a custom rule
cat > /tmp/custom.yar << 'EOF'
rule detect_hello_world {
    strings:
        $hello = "Hello, world"
    condition:
        $hello
}
EOF

# Upload the rule (you'll need to build this endpoint)
curl -X POST -F "rule=@/tmp/custom.yar" http://localhost:3000/api/rules

# Upload a binary containing "Hello, world" and check YARA results
```

### 2. Export Analysis as PDF Report

**What to build:** Add a "Download Report" button to the frontend that generates a PDF summary of the analysis. Include the threat score, key findings from each pass, and MITRE technique mappings.

**Why it's useful:** Analysts need to share findings with non-technical stakeholders. A PDF report is the standard deliverable in incident response.

**What you'll learn:** PDF generation in the browser or server-side, data summarization, report formatting.

**Hints:**
- Client-side: use `jspdf` or `@react-pdf/renderer` to generate PDFs in the browser
- Server-side: add a `GET /api/analysis/{slug}/report` endpoint that returns `application/pdf`
- Prioritize the most important findings — a 50-page PDF of every string isn't useful
- Include the ASCII threat score breakdown from the overview tab

**How to verify it works:**
- Upload a test binary, navigate to the analysis page
- Click "Download Report" and open the resulting PDF
- Verify it includes: file metadata, threat score, top scoring categories, MITRE techniques

### 3. Add File Type Detection Beyond Executables

**What to build:** When a non-executable file is uploaded (PDF, ZIP, Office document), return a helpful error message that identifies the file type and suggests what to do instead of a generic "unsupported format" error.

**Why it's useful:** Users will upload all sorts of files. Telling them "this is a PDF, not an executable — try extracting embedded objects first" is more helpful than "parse error."

**What you'll learn:** Magic byte detection for common file types, user-facing error design.

**Hints:**
- Common magic bytes: PDF (`%PDF`), ZIP/DOCX/XLSX (`PK\x03\x04`), GZIP (`\x1f\x8b`), Java class (`\xca\xfe\xba\xbe`)
- Add detection in `formats::parse_format()` before the `goblin` parse attempt
- Return a structured error with the detected file type and guidance
- Office documents (DOCX, XLSX) are ZIP archives — mention that macros can be extracted as separate analysis targets

**How to verify it works:**
```bash
# Upload a PDF
curl -X PUT -F "file=@test.pdf" http://localhost:3000/api/upload
# Should return: { "error": "Detected PDF file. Binary analysis requires an executable (ELF, PE, or Mach-O)." }
```

## Intermediate Challenges

### 4. Add ARM/AArch64 Disassembly

**What to build:** Extend the disassembly pass to support ARM and AArch64 architectures. Currently, non-x86 binaries get an empty disassembly result.

**Why it's useful:** ARM binaries are everywhere — Android apps (native libraries), IoT firmware, macOS Apple Silicon binaries. Skipping disassembly for ARM misses a huge class of targets.

**What you'll learn:** ARM instruction set basics, multi-architecture disassembly, extending the pass system.

**Implementation approach:**
1. Add the `capstone` crate (or `bad64` for AArch64) to `axumortem-engine`
2. Modify `DisasmPass::run()` to dispatch to an ARM disassembler when the architecture is ARM/AArch64
3. The basic block and CFG construction logic should be reusable — ARM has the same concept of branch instructions creating block boundaries
4. ARM has unique considerations: Thumb mode (16-bit instructions mixed with 32-bit), conditional execution on every instruction (ARM32), and the link register instead of stack-based return addresses

**Edge cases to test:**
- Thumb/ARM mode switching within a single function
- AArch64 binaries from Apple Silicon Macs
- Android NDK compiled shared libraries (`.so` files)

**Hints:**
- The `iced-x86` crate is x86-only by design. You need a separate decoder for ARM.
- ARM branch instructions: `B`, `BL`, `BX`, `BLX`, `CBZ`, `CBNZ`, `TBB`, `TBH`
- AArch64 branch instructions: `B`, `BL`, `BR`, `BLR`, `RET`, `CBZ`, `CBNZ`, `TBZ`, `TBNZ`

### 5. Add a Comparison View

**What to build:** Allow uploading two binaries and comparing their analysis results side-by-side. Highlight differences in sections, imports, strings, and threat scores.

**Why it's useful:** Diffing is fundamental to malware analysis. Comparing a known-good binary to a suspected-trojanized version reveals exactly what changed. This is how the CCleaner and 3CX supply chain attacks were analyzed — by diffing the legitimate binary against the compromised one.

**What you'll learn:** Diff algorithms, UI design for comparison views, efficient database queries for multi-binary analysis.

**Implementation approach:**
1. Add a `POST /api/compare` endpoint that accepts two slugs and returns a diff
2. Section-level diffing: compare section names, sizes, permissions, and SHA-256 hashes
3. Import diffing: imports added, removed, or changed between versions
4. String diffing: new suspicious strings in the modified binary
5. Entropy diffing: sections that changed entropy classification
6. Frontend: split-pane view with color-coded differences

**Edge cases to test:**
- Comparing binaries of different formats (ELF vs PE)
- Comparing binaries with different numbers of sections
- Comparing a stripped binary to its non-stripped counterpart

**Hints:**
- Section SHA-256 hashes make section-level comparison trivial — if the hash matches, the content is identical
- Start with imports and strings — these are the highest-signal diffs for supply chain analysis
- Consider a three-column layout: left binary, diff indicator, right binary

### 6. Add Behavioral Pattern Detection

**What to build:** Create a new analysis pass that identifies high-level behavioral patterns by combining findings from imports, strings, and YARA matches. Instead of "these APIs are suspicious," report "this binary exhibits ransomware behavior" or "this binary implements a reverse shell."

**Why it's useful:** Individual indicators (an import, a string, a YARA match) are noisy. Behavioral patterns are high-confidence detections that map directly to threat categories.

**What you'll learn:** Building a new pass, threat intelligence correlation, pattern matching across pass results.

**Implementation approach:**
1. Create `passes/behavior.rs` implementing `AnalysisPass`
2. Declare dependencies on `imports`, `strings`, `entropy`, and `threat`
3. Define behavioral patterns as combinations of indicators:
   - **Ransomware**: encryption APIs + file enumeration + ransom note strings + high entropy sections
   - **Reverse shell**: socket APIs + exec/spawn + shell command strings
   - **Dropper**: high entropy + few imports + `URLDownloadToFile` or `wget`/`curl` strings
   - **Keylogger**: keyboard hook APIs + file write + persistence mechanisms
   - **Rootkit**: `ptrace` + kernel module strings + hidden file paths
4. Add `behavior_result` to `AnalysisContext`
5. Register the pass in `AnalysisEngine::new()`
6. Add a new tab in the frontend

**Hints:**
- Start with 3-4 patterns and expand — don't try to cover everything
- Each pattern should require at least 3 independent indicators to fire
- False positives are worse than false negatives for behavioral detection

## Advanced Challenges

### 7. Add Dynamic Import Resolution Detection

**What to build:** Detect when a binary resolves imports dynamically at runtime (using `GetProcAddress` on Windows or `dlsym` on Linux) by cross-referencing string analysis with import analysis.

**Why this is hard:** Malware hides its true imports by not listing them in the import table. Instead, it stores API names as strings (sometimes obfuscated) and resolves them at runtime. Detecting this requires correlating string findings with import behavior patterns.

**Architecture changes needed:**
1. Extend `ImportResult` with a `dynamic_imports: Vec<DynamicImportCandidate>` field
2. The import pass needs access to string results (add "strings" as a dependency)
3. Cross-reference strings that look like Windows API names against the suspicious API database
4. Flag the gap: "binary imports `GetProcAddress` but not `VirtualAllocEx`, yet `VirtualAllocEx` appears as a string"

**Implementation phases:**
1. **Research (1-2 hours):** Study how `GetProcAddress`/`dlsym` are used in malware. Read about import table reconstruction.
2. **Design (1 hour):** Define `DynamicImportCandidate` struct. Decide how to score dynamic imports vs static imports.
3. **Implementation (3-4 hours):** Modify the import pass to cross-reference strings. Build the detection logic. Update threat scoring.
4. **Testing (1-2 hours):** Write a test binary that uses `GetProcAddress`. Verify detection works.

**Gotchas:**
- API names in strings might be XOR-encoded or split across multiple strings
- `GetProcAddress` is used legitimately by plugin systems — don't flag it alone
- The dependency change (imports now depends on strings) changes the topological order

### 8. Build a Retrohunt System

**What to build:** When new YARA rules are added, automatically re-scan all previously analyzed binaries against the new rules and update their threat scores.

**Why this is hard:** This touches storage, background processing, and the caching system. You need to invalidate cached results selectively (only the YARA and threat portions) without re-running expensive passes like disassembly.

**Architecture changes needed:**
1. Store raw binary data (or a reference to it) in addition to analysis results
2. Build a background job system that processes re-scans
3. Implement partial pass re-execution (re-run only ThreatPass with new YARA rules)
4. Update the database schema to track which rule version produced each result
5. Add a `POST /api/retrohunt` endpoint that triggers re-scanning

**Implementation phases:**
1. **Research (2-3 hours):** Study how VirusTotal and other platforms handle retrohunting. Understand the scale challenges.
2. **Design (2 hours):** Design the job queue, rule versioning scheme, and partial re-execution strategy.
3. **Implementation (5-6 hours):** Build the retrohunt system. This is a significant addition — take it in stages.
4. **Testing (2-3 hours):** Upload multiple binaries, add a new rule, trigger retrohunt, verify scores update.

**Gotchas:**
- Binary storage increases disk usage significantly — consider optional storage vs re-upload
- Retrohunt on thousands of binaries needs a progress indicator and cancellation support
- Updating threat scores changes risk levels, which might trigger alerts in downstream systems

### 9. Add Signature-Based Packer Unpacking

**What to build:** For binaries detected as UPX-packed, automatically unpack them and re-analyze the unpacked binary. Display both the packed and unpacked analysis results.

**Why this is hard:** Unpacking modifies the binary. You need to handle the unpacking process safely, store both versions, and present a meaningful comparison. UPX is the easiest target because the `upx` tool can unpack most UPX binaries, but other packers require custom unpackers.

**Architecture changes needed:**
1. After the entropy pass detects UPX packing, invoke the `upx` command-line tool with `--decompress`
2. Run the full analysis pipeline on the unpacked binary
3. Store both analysis results linked by a parent-child relationship
4. Frontend: show "packed" and "unpacked" tabs with comparison

**Implementation phases:**
1. **Research (1-2 hours):** Study UPX internals and the `upx --decompress` command. Understand failure modes.
2. **Design (1 hour):** Design the parent-child schema, decide where in the pipeline unpacking happens.
3. **Implementation (4-5 hours):** Add the unpacking step, second analysis pass, database schema changes, and frontend updates.
4. **Testing (2-3 hours):** Pack binaries with UPX, upload them, verify unpacking and re-analysis.

**Gotchas:**
- Modified UPX (where section names are changed from UPX0/UPX1) breaks `upx --decompress`
- The unpacking process must run in a sandboxed environment (it's executing a tool on untrusted input)
- Not all UPX-packed binaries can be unpacked — handle failures gracefully
- Consider adding `upx` to the Docker image

## Expert Challenges

### 10. Build a Distributed Analysis Cluster

**What to build:** Scale AXUMORTEM horizontally by distributing analysis work across multiple backend instances with a shared job queue.

**Estimated time:** 15-25 hours

**Prerequisites:** Understanding of message queues, distributed systems concepts, container orchestration.

**High-level architecture:**

```
                    ┌─────────────────┐
                    │   API Gateway   │
                    │   (Nginx/LB)    │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
    ┌─────────v──────┐  ┌───v──────┐  ┌───v──────┐
    │  API Server 1  │  │ API 2    │  │ API 3    │
    │  (web only)    │  │          │  │          │
    └─────────┬──────┘  └───┬──────┘  └───┬──────┘
              │              │              │
              └──────────────┼──────────────┘
                             │
                    ┌────────v────────┐
                    │   Job Queue     │
                    │ (Redis/RabbitMQ)│
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
    ┌─────────v──────┐  ┌───v──────┐  ┌───v──────┐
    │  Worker 1      │  │ Worker 2 │  │ Worker 3 │
    │  (engine only) │  │          │  │          │
    └─────────┬──────┘  └───┬──────┘  └───┬──────┘
              │              │              │
              └──────────────┼──────────────┘
                             │
                    ┌────────v────────┐
                    │   PostgreSQL    │
                    │   (shared)      │
                    └─────────────────┘
```

**Implementation phases:**

1. **Job queue setup (3-4 hours):** Add Redis or RabbitMQ. Modify the upload route to enqueue analysis jobs instead of running them inline. Add a status endpoint for pending jobs.

2. **Worker process (4-5 hours):** Create a separate binary (`axumortem-worker`) that pulls jobs from the queue, runs the engine, and writes results to PostgreSQL. The worker reuses the `axumortem-engine` crate directly.

3. **Result polling (2-3 hours):** The API server returns "pending" status for in-progress analyses. Add WebSocket or SSE support for real-time progress updates. The frontend polls or subscribes for completion.

4. **Scaling and reliability (4-6 hours):** Handle worker failures (job timeouts, dead letter queues). Add health monitoring for workers. Implement job priority (small binaries first). Add Kubernetes manifests or Docker Swarm configuration.

**Testing strategy:**
- Unit tests: job serialization/deserialization, queue operations
- Integration tests: full upload-analyze-retrieve cycle through the queue
- Load tests: submit 100 binaries concurrently, verify all complete
- Chaos tests: kill a worker mid-analysis, verify the job is retried

**Known challenges:**
- Binary data transfer through the queue (pass file paths vs embed data)
- Database connection pool sizing for multiple workers
- Graceful shutdown — workers should finish current analysis before stopping

**Success criteria:**
- [ ] Analysis works identically whether run inline or through the queue
- [ ] Adding/removing workers doesn't require API server restarts
- [ ] Failed analyses are retried with exponential backoff
- [ ] Frontend shows real-time progress for queued analyses
- [ ] System handles 10x the throughput of a single instance

### 11. Add Machine Learning-Based Classification

**What to build:** Train a classifier on the feature vectors extracted by AXUMORTEM (entropy values, import counts, string statistics, section properties) to predict malware family membership.

**Estimated time:** 20-30 hours

**Prerequisites:** Basic ML concepts (feature engineering, train/test split, classification metrics). Python familiarity for the training pipeline.

**High-level architecture:**

```
┌─────────────────────────────────────────────────┐
│ Training Pipeline (Python)                      │
│                                                 │
│  MalwareBazaar ──> Feature Extraction ──> Model │
│  Dataset             (via engine API)    (ONNX) │
└──────────────────────────┬──────────────────────┘
                           │
                    export .onnx file
                           │
┌──────────────────────────v──────────────────────┐
│ Inference (Rust)                                │
│                                                 │
│  AnalysisContext ──> Feature Vector ──> ONNX ──>│
│                         (f32 array)     Runtime │
│                                           │     │
│                                    Classification│
│                                    + Confidence  │
└─────────────────────────────────────────────────┘
```

**Implementation phases:**

1. **Dataset collection (3-4 hours):** Download labeled malware samples from MalwareBazaar or VirusTotal. Analyze each with AXUMORTEM. Export feature vectors (entropy, import count, suspicious API count, string category counts, section count, anomaly count, etc.).

2. **Model training (4-6 hours):** Build a Python training pipeline. Start with a random forest or gradient boosted tree. Feature engineering is the hard part — decide which analysis outputs become numeric features. Evaluate with precision/recall/F1.

3. **Model export (2-3 hours):** Export the trained model to ONNX format. Add the `ort` (ONNX Runtime) crate to the engine.

4. **Inference integration (5-8 hours):** Create a new `ClassificationPass` that extracts the feature vector from `AnalysisContext`, runs ONNX inference, and produces a classification result (malware family + confidence score). Add a frontend tab showing the classification.

**Testing strategy:**
- Feature extraction: verify the same binary always produces the same feature vector
- Model accuracy: hold-out test set with known labels
- Integration: end-to-end upload and classification

**Known challenges:**
- Feature normalization — training and inference must use the same scaling
- Class imbalance — benign samples far outnumber malware in most datasets
- Model drift — malware evolves, the model needs periodic retraining
- ONNX Runtime adds ~50MB to the Docker image

**Success criteria:**
- [ ] Model achieves > 85% F1 score on held-out test set
- [ ] Classification adds < 100ms to analysis time
- [ ] Frontend displays family prediction with confidence percentage
- [ ] False positive rate on legitimate system utilities is < 5%

## Mix and Match

Combine challenges for larger projects:

- **Challenges 1 + 8:** Custom YARA rules + retrohunting = a mini threat intelligence platform
- **Challenges 5 + 9:** Binary comparison + UPX unpacking = compare packed vs unpacked views automatically
- **Challenges 6 + 11:** Behavioral patterns + ML classification = hybrid detection (rules + model)
- **Challenges 4 + 7:** ARM disassembly + dynamic import detection = full IoT malware analysis

## Real-World Integration Challenges

### Integrate with MISP

Connect AXUMORTEM to a [MISP](https://www.misp-project.org/) (Malware Information Sharing Platform) instance. When analysis detects a CRITICAL threat, automatically create a MISP event with indicators of compromise (IOCs): file hashes, C2 URLs, suspicious API chains.

### Add VirusTotal Enrichment

After local analysis, submit the SHA-256 hash to VirusTotal's API and display AV detection ratios alongside AXUMORTEM's own score. Show how AXUMORTEM's scoring compares to the industry consensus.

### Build a CI/CD Security Gate

Create a CLI mode for AXUMORTEM that analyzes binaries produced by a build pipeline and fails the build if the threat score exceeds a threshold. Useful for catching supply chain compromises in compiled artifacts.

## Performance Challenges

### Handle 50MB Binaries in Under 10 Seconds

Profile the current analysis pipeline. Identify which passes are slowest for large binaries. Optimize the critical path:
- Can entropy calculation use SIMD instructions?
- Can string extraction run in parallel across sections?
- Can the disassembler use multiple threads for independent functions?

### Reduce Memory Usage by 50%

Large binaries currently load entirely into memory (`Arc<[u8]>`). Implement streaming analysis where possible:
- Entropy calculation can work with memory-mapped files
- String extraction can process chunks
- Section hashing already works on slices

Profile with `heaptrack` or `dhat` to find allocation hotspots.

## Security Challenges

### Add Binary Integrity Verification

Implement Authenticode signature verification for PE binaries and codesign verification for Mach-O binaries. Display whether the signature is valid, expired, or from a known-compromised certificate (like the stolen Realtek certificate used by Stuxnet).

### Build a Sandbox Evasion Detector

Create a pass that specifically targets sandbox evasion techniques:
- Timing checks (`GetTickCount` deltas, `rdtsc` loops)
- Environment checks (VM artifacts, debugger presence, process list)
- Resource checks (low RAM, single CPU = likely sandbox)
- User interaction checks (no mouse movement, no recent documents)

This is a standalone pass with its own scoring category.

### Implement SSDEEP Fuzzy Hashing

Add [ssdeep](https://ssdeep-project.github.io/ssdeep/) fuzzy hashing to identify binaries that are similar but not identical. Two variants of the same malware family will have different SHA-256 hashes but similar ssdeep hashes. Display a "similar binaries" section that finds fuzzy matches in the database.

## Contribution Ideas

If you build something you're proud of:

1. Fork the repo, create a feature branch
2. Follow the existing code patterns (sealed traits, typed enums, no magic numbers)
3. Add tests for your new pass or feature
4. Update the learn documentation if you add significant functionality
5. Open a PR with before/after screenshots or test output

## Challenge Completion

Track your progress:

- [ ] **Easy 1:** Custom YARA rule loading
- [ ] **Easy 2:** PDF report export
- [ ] **Easy 3:** File type detection
- [ ] **Intermediate 4:** ARM/AArch64 disassembly
- [ ] **Intermediate 5:** Binary comparison view
- [ ] **Intermediate 6:** Behavioral pattern detection
- [ ] **Advanced 7:** Dynamic import resolution
- [ ] **Advanced 8:** Retrohunt system
- [ ] **Advanced 9:** Packer unpacking
- [ ] **Expert 10:** Distributed analysis cluster
- [ ] **Expert 11:** ML-based classification
