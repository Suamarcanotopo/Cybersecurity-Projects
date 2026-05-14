# Payload Obfuscation Engine

## Overview
Build a multi-layered payload obfuscation engine in Go that transforms shellcode and executables through encoding, encryption, polymorphism, and structural manipulation to evade signature-based detection. This project teaches the fundamental cat-and-mouse game between malware authors and antivirus vendors by demonstrating how static signatures are defeated and why behavioral analysis became necessary. You will implement the same obfuscation techniques found in real-world frameworks like Veil, Shikata Ga Nai, and Cobalt Strike's artifact kit, then validate your output against YARA rules to measure evasion effectiveness.

## Step-by-Step Instructions
1. **Set up the Go project and define the obfuscation pipeline architecture** Create a new Go module with a pipeline-based architecture where each obfuscation technique is a stage that accepts bytes in and produces bytes out. Define an interface like `Obfuscator` with an `Apply([]byte) ([]byte, error)` method so stages can be chained arbitrarily. Set up a CLI using `cobra` that accepts an input payload file, a list of obfuscation stages to apply (in order), and an output path. Include a `--rounds` flag to apply the full pipeline multiple times. This composable design mirrors how real obfuscation frameworks operate.

2. **Implement encoding-based obfuscation stages** Build three encoding stages: Base64 encoding with a custom alphabet (not the standard one, making signature matching harder), XOR encoding with a randomly generated key that is prepended to the output, and AES-256-CBC encryption where the key is derived from a passphrase via PBKDF2. Each stage must embed a corresponding decoder stub so the payload can self-extract at runtime. For XOR, generate a new random key on every run so the output is never the same twice. Test each encoder independently by verifying round-trip encode/decode produces the original payload.

3. **Build the polymorphic instruction rewriter** Create a stage that disassembles x86-64 instructions (use the `golang.org/x/arch/x86/x86asm` package), identifies equivalent instruction substitutions (e.g., `mov eax, 0` becomes `xor eax, eax`, `add eax, 1` becomes `inc eax`, `push rbx; pop rax` replaces `mov rax, rbx`), and randomly applies them. Maintain a substitution table of at least 15 instruction equivalences. The rewriter should produce functionally identical code that looks completely different to a signature scanner. Log every substitution made so you can verify correctness.

4. **Add dead code insertion and string obfuscation** Implement a dead code insertion stage that adds NOP sleds, do-nothing instruction sequences (e.g., `push rax; pop rax`), opaque predicates (conditional jumps that always take the same path), and junk function calls that return immediately. Build a separate string obfuscation stage that finds ASCII string literals in the payload, splits them into chunks, and reconstructs them at runtime through concatenation. This defeats static string matching, which is one of the simplest and most common detection methods.

5. **Implement control flow flattening** Build a control flow flattening stage that replaces sequential basic blocks with a dispatcher loop. The dispatcher uses a state variable to determine which block to execute next, turning a linear control flow graph into a switch-case structure. This makes static analysis extremely difficult because the execution order is no longer visible in the binary structure. Use a randomly shuffled block ordering so each run produces a different arrangement.

6. **Create a YARA rule test suite** Write a collection of 15-20 YARA rules that detect common payload signatures: known shellcode byte sequences, suspicious API import patterns (VirtualAlloc, CreateRemoteThread), common encoder stubs, high entropy sections, and string indicators. Build a test harness that runs each obfuscated payload against the full YARA ruleset using `go-yara` bindings and reports which rules matched. Track the detection rate before and after each obfuscation stage to measure effectiveness.

7. **Build the analysis and reporting system** Create a reporting module that analyzes each obfuscated output and generates metrics: Shannon entropy per section, file size delta, number of instruction substitutions made, YARA detection rate, and a diff visualization showing what changed between the original and obfuscated versions. Output reports in both JSON (for automation) and a formatted terminal table (for human review). Include a `--benchmark` mode that runs all possible stage combinations and ranks them by evasion effectiveness.

8. **Add an HTTP API and integrate everything** Wrap the obfuscation engine in a lightweight HTTP API using `net/http` so it can be called programmatically. Accept multipart file uploads with a JSON configuration specifying which stages to apply. Return the obfuscated payload and the analysis report. Write integration tests that verify the full pipeline: upload a test payload, apply all stages, run YARA detection, and assert the detection rate dropped below a threshold. Document the ethical and legal boundaries of this tool clearly in the project README.

## Key Concepts to Learn
- Encoding vs encryption vs obfuscation and when each applies
- Polymorphic and metamorphic code generation techniques
- x86-64 instruction semantics and equivalent substitutions
- Control flow flattening and opaque predicates
- YARA rule writing and signature-based detection mechanics
- Shannon entropy analysis as a detection heuristic
- The arms race between evasion techniques and detection engines
- Ethical boundaries of offensive security tooling

## Deliverables
- Go CLI tool with pluggable obfuscation pipeline
- Five obfuscation stages: encoding, encryption, polymorphism, dead code, control flow flattening
- YARA rule test suite with 15-20 detection rules
- Analysis and reporting system with entropy and detection metrics
- HTTP API for programmatic access
- Integration tests proving evasion effectiveness
- Documentation covering ethical use and legal considerations
