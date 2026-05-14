# Binary Analysis Tool: Concepts

This module covers the security fundamentals behind static binary analysis. Every concept here maps directly to a component in AXUMORTEM's analysis pipeline.

## Binary Executable Formats

### What They Are

Every compiled program is stored as a binary executable in a format that tells the operating system how to load it into memory and start executing. The three dominant formats are:

- **ELF** (Executable and Linkable Format) — Linux, BSD, most Unix systems
- **PE** (Portable Executable) — Windows
- **Mach-O** (Mach Object) — macOS, iOS

These aren't just "containers for machine code." They're structured metadata that describes memory layout, dynamic library dependencies, symbol tables, relocation info, and security properties. Every field in these headers is something an analyst can use to determine whether a binary is legitimate.

### Why They Matter

Understanding binary formats is foundational because every other analysis technique depends on correctly parsing the format first. If you can't find the `.text` section, you can't disassemble. If you can't parse the import table, you can't flag suspicious API usage. If you can't identify sections, you can't calculate per-section entropy.

**The ELF format** uses a layered structure:

```
+------------------+
| ELF Header       |  Magic bytes (7f 45 4c 46), architecture, entry point
+------------------+
| Program Headers  |  Segments — what the kernel loads into memory
+------------------+
| .text            |  Executable code
| .rodata          |  Read-only data (strings, constants)
| .data            |  Initialized writable data
| .bss             |  Uninitialized data (zero-filled at load)
| .symtab          |  Symbol table (function/variable names)
| .strtab          |  String table (names referenced by symbols)
| .dynamic         |  Dynamic linking information
| .got / .plt      |  Global offset table / procedure linkage table
+------------------+
| Section Headers  |  Metadata about each section
+------------------+
```

**The PE format** is Windows-specific and more complex:

```
+------------------+
| DOS Header       |  Legacy MS-DOS stub (the "MZ" signature)
+------------------+
| PE Signature     |  "PE\0\0" (50 45 00 00)
+------------------+
| COFF Header      |  Machine type, number of sections, timestamp
+------------------+
| Optional Header  |  Entry point, image base, subsystem, data directories
+------------------+
| Section Table    |  .text, .rdata, .data, .rsrc, .reloc
+------------------+
| Sections         |  Actual code and data
+------------------+
```

PE binaries carry extra metadata that ELF doesn't: a rich header (compiler fingerprint), TLS callback table (code that runs before `main`), and a data directory pointing to imports, exports, debug info, and more. Malware authors abuse TLS callbacks to run anti-debugging code before the debugger's breakpoint at the entry point even triggers.

### How AXUMORTEM Parses Them

AXUMORTEM uses the `goblin` crate to parse all three formats through a single entry point. The `FormatPass` dispatches to format-specific parsers that extract a unified `FormatResult`:

```rust
pub struct FormatResult {
    pub format: BinaryFormat,
    pub architecture: Architecture,
    pub bits: u8,
    pub endianness: Endianness,
    pub entry_point: u64,
    pub is_stripped: bool,
    pub is_pie: bool,
    pub has_debug_info: bool,
    pub sections: Vec<SectionInfo>,
    pub segments: Vec<SegmentInfo>,
    pub anomalies: Vec<FormatAnomaly>,
    pub pe_info: Option<PeInfo>,
    pub elf_info: Option<ElfInfo>,
    pub macho_info: Option<MachOInfo>,
    pub function_hints: Vec<u64>,
}
```

Format-specific details go into their own optional structs (`PeInfo`, `ElfInfo`, `MachOInfo`), while common properties like sections and segments use the same types across all formats.

### Anomaly Detection

The format parser doesn't just extract data, it flags structural problems. Each anomaly is a specific enum variant:

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

An entry point in the last section is suspicious because packers (UPX, Themida, ASPack) unpack code at runtime and jump to the original entry point, which they store in the final section. Legitimate compilers put the entry point in `.text`, which is almost never the last section.

### Real-World Example: Stuxnet

Stuxnet (2010) was a PE binary that targeted Iranian nuclear centrifuges. Format analysis revealed multiple anomalies: its PE header had an unusual timestamp (a compilation date of 2001, clearly forged), it contained a signed Authenticode certificate stolen from Realtek Semiconductor, and its sections included encrypted payloads with entropy values above 7.9. The import table referenced `DeviceIoControl` for communicating with Siemens S7-300 PLC hardware — an API that no legitimate office software would ever need.

### Common Pitfalls

**Trusting the section name.** Section names are advisory, not enforced. Malware routinely names packed code sections `.text` or `.code` to look normal. AXUMORTEM checks entropy and permissions rather than relying on names alone.

**Ignoring stripped binaries.** When a binary is stripped (no symbol table), you lose function names. This isn't always malicious — release builds are commonly stripped. But combined with other indicators (high entropy, suspicious imports), stripping adds to the threat score.

## Entropy Analysis

### What It Is

Shannon entropy measures the randomness of data. For binary analysis, entropy tells you what kind of data is in each section: plain text hovers around 3-4 bits/byte, compiled native code sits at 5-6, compressed data reaches 6.5-7, and encrypted or packed data approaches the theoretical maximum of 8 bits/byte.

The formula calculates how "surprising" each byte is on average:

```
H = -Σ p(x) * log₂(p(x))    for each possible byte value (0-255)
```

If every byte value appears equally often (perfectly random), entropy is 8.0. If only one byte value appears (all zeros), entropy is 0.0.

### Why It Matters

Packing and encryption are the two most common ways malware authors hide their payloads. A packed binary compresses the real code and includes a small unpacker stub that decompresses everything at runtime. An encrypted binary does the same thing but with encryption. Both techniques produce sections with entropy above 7.0 — and that's a dead giveaway during triage.

AXUMORTEM classifies entropy into five levels:

```
Plaintext    : < 3.5    (config files, string tables)
Native Code  : < 6.0    (compiled x86/x64/ARM instructions)
Compressed   : < 7.0    (zlib, gzip, resource data)
Packed       : < 7.2    (UPX, Themida, ASPack)
Encrypted    : >= 7.2   (AES-encrypted payloads, XOR-obfuscated code)
```

### Packer Detection

Entropy alone isn't enough. AXUMORTEM combines multiple signals to detect packing:

**Known section names.** Packers leave fingerprints in section names:

```rust
const PACKER_SECTION_NAMES: &[(&str, &str)] = &[
    ("UPX0", "UPX"),
    ("UPX1", "UPX"),
    (".themida", "Themida"),
    (".vmp0", "VMProtect"),
    (".vmp1", "VMProtect"),
    (".aspack", "ASPack"),
    (".MPRESS1", "MPRESS"),
    (".MPRESS2", "MPRESS"),
    (".enigma1", "Enigma"),
    (".enigma2", "Enigma"),
];
```

**Virtual-to-raw size ratio.** Packers allocate large virtual memory regions but store minimal data on disk (the compressed payload). A ratio above 10:1 is suspicious.

**PUSHAD at entry point.** UPX and many other packers begin with `PUSHAD` (opcode `0x60`) to save all registers before the unpacking routine. AXUMORTEM checks the first byte at the entry point offset.

**RWX sections.** Legitimate binaries almost never have sections that are readable, writable, AND executable. Packers need RWX because they write decompressed code into the same section they execute from.

### Real-World Example: WannaCry

The WannaCry ransomware (May 2017) infected over 200,000 systems across 150 countries. The initial dropper was a PE binary with a massive resource section (`.rsrc`) that had an entropy of 7.89 — clearly encrypted. Inside that section was the actual ransomware payload, AES-encrypted with a key derived from the binary's own import table hash. Entropy analysis flagged the payload instantly during triage, even though the rest of the binary looked like a normal Windows service.

### Real-World Example: NotPetya

NotPetya (June 2017) caused an estimated $10 billion in damages globally. The wiper disguised as ransomware was distributed through a trojanized update to M.E.Doc, a Ukrainian tax software. The modified binary had two high-entropy sections that didn't match the original: one contained the EternalBlue exploit, the other contained the Mimikatz credential dumper. The entropy delta between the legitimate M.E.Doc binary and the trojanized version was the first indicator that caught researchers' attention.

## Import and API Analysis

### What It Is

When a binary calls operating system functions (opening files, allocating memory, creating network connections), it lists those functions in its import table. The import table is a map from library names to function names that the dynamic linker resolves at load time.

Certain API combinations are essentially a signature for specific attack techniques. `VirtualAllocEx` + `WriteProcessMemory` + `CreateRemoteThread` is process injection. `NtUnmapViewOfSection` + `SetThreadContext` is process hollowing. These combinations appear in nearly every piece of Windows malware that uses those techniques.

### Suspicious API Definitions

AXUMORTEM maintains a database of suspicious APIs, each tagged with a technique category and MITRE ATT&CK ID:

```rust
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
        name: "NtUnmapViewOfSection",
        tag: "hollowing",
        mitre_id: "T1055.012",
    },
    SuspiciousApiDef {
        name: "IsDebuggerPresent",
        tag: "anti-debug",
        mitre_id: "T1622",
    },
    // ... 22 suspicious APIs total
];
```

The system also detects 14 suspicious API *combinations* — groups of imports that together indicate a specific technique. A binary importing `VirtualAllocEx` alone is suspicious. A binary importing `VirtualAllocEx` + `WriteProcessMemory` + `CreateRemoteThread` together is almost certainly doing process injection.

### Linux-Specific Analysis

Import analysis isn't Windows-only. AXUMORTEM flags Linux-specific indicators:

- `ptrace` with `PTRACE_ATTACH` — process injection on Linux (T1055.008)
- `mmap` + `mprotect` with `PROT_EXEC` — runtime code generation or injection
- `dlopen` + `dlsym` — dynamic library loading, common in rootkits
- `connect` + `execve` — reverse shell pattern
- `bind` + `listen` + `accept` — network listener (potential backdoor)

### Real-World Example: Mirai Botnet

The Mirai botnet (2016) was an ELF binary targeting IoT devices. Its import table was unusual for an embedded device binary: `socket`, `connect`, `send`, `recv` (expected for a network scanner), but also `execve`, `fork`, and `kill`. The combination of network APIs with process management APIs flagged it as a likely bot agent. Mirai's stripped binary had only 14 unique imports — far fewer than a legitimate application, which itself was suspicious because it suggested hand-optimized malware.

### Common Pitfalls

**Looking at imports in isolation.** `VirtualAlloc` is one of the most commonly used Windows APIs — every large application calls it. Only the combination with `WriteProcessMemory` and `CreateRemoteThread` is suspicious. AXUMORTEM's combination detection avoids this false-positive trap.

**Forgetting about dynamic resolution.** Malware frequently avoids static imports by using `GetProcAddress` or `dlsym` to resolve APIs at runtime. The import table looks clean, but string analysis reveals the API names embedded in the binary. This is why AXUMORTEM's string pass works alongside import analysis.

## String Analysis

### What It Is

Strings are the quickest intelligence you can extract from a binary. File paths reveal targets. URLs reveal C2 servers. Registry keys reveal persistence mechanisms. Shell commands reveal post-exploitation behavior. Even debug artifacts can reveal the developer's build environment.

AXUMORTEM extracts strings in multiple encodings (ASCII, UTF-16LE) and classifies them into 14 categories:

```rust
pub enum StringCategory {
    Url,              // http://, https://, ftp://
    IpAddress,        // IPv4 and IPv6 addresses
    FilePath,         // /etc/passwd, C:\Windows\System32
    RegistryKey,      // HKEY_LOCAL_MACHINE\...
    ShellCommand,     // cmd.exe /c, powershell, /bin/bash
    CryptoWallet,     // Bitcoin, Ethereum addresses
    Email,            // user@domain.com
    SuspiciousApi,    // API names that didn't appear in imports
    PackerSignature,  // UPX!, .themida, MPRESS
    DebugArtifact,    // /rustc/, .pdb, DWARF
    AntiAnalysis,     // VMware, VirtualBox, Sandboxie, x64dbg
    PersistencePath,  // CurrentVersion\Run, crontab, systemd
    EncodedData,      // Base64-encoded blobs (min 20 chars)
    Generic,          // Everything else
}
```

Seven of these categories are flagged as suspicious and feed directly into threat scoring: `SuspiciousApi`, `PackerSignature`, `AntiAnalysis`, `PersistencePath`, `EncodedData`, `ShellCommand`, and `CryptoWallet`.

### UTF-16LE Extraction

Windows binaries frequently store strings in UTF-16LE encoding (two bytes per character, little-endian). A URL like `http://evil.com` stored in UTF-16LE looks like `h\x00t\x00t\x00p\x00:\x00/\x00/\x00e\x00v\x00i\x00l\x00.\x00c\x00o\x00m\x00` in a hex dump. If you only scan for ASCII strings, you miss half the intelligence in a PE binary. AXUMORTEM scans both encodings.

### Base64 Detection

Malware encodes payloads, commands, and URLs in Base64 to evade simple string matching. AXUMORTEM flags Base64-encoded strings that are at least 20 characters long and have proper padding. It specifically looks for `TVqQ`, `TVpQ`, `TVoA`, and `TVpB` prefixes — these are the Base64 encodings of the "MZ" PE header signature, indicating an embedded executable hidden inside a Base64 blob.

### Real-World Example: APT29 (Cozy Bear)

APT29's SUNBURST backdoor embedded in the SolarWinds Orion update (December 2020) was sophisticated, but string analysis still caught it. The malware contained hardcoded domain generation algorithm seeds, Base64-encoded configuration blocks, and strings referencing anti-analysis tools (`apimonitor`, `dnspy`, `ilspy`, `fiddler`, `wireshark`). The anti-analysis strings were used to detect analyst environments and disable the backdoor — but they also served as signatures for detection.

## YARA Rules

### What They Are

YARA is a pattern matching engine designed for malware identification. A YARA rule defines a set of string patterns and a boolean condition. If the condition matches, the rule fires. YARA rules are the industry standard for sharing malware signatures — threat intelligence feeds, antivirus engines, and EDR products all use YARA.

A rule has three parts: metadata (description, severity), strings (patterns to search for), and a condition (boolean logic combining those patterns):

```yara
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

This rule fires if the binary contains the classic process injection trio (`VirtualAllocEx` + `WriteProcessMemory` + `CreateRemoteThread`) OR the process hollowing pair (`NtUnmapViewOfSection` + `WriteProcessMemory`).

### AXUMORTEM's Built-In Rules

AXUMORTEM ships with 14 YARA rules covering major malware categories:

| Rule | Category | Severity | What It Detects |
|------|----------|----------|----------------|
| `suspicious_upx_packed` | packer | medium | UPX section names + magic bytes |
| `suspicious_anti_debug` | evasion | high | `IsDebuggerPresent`, `INT 2Dh` trap |
| `suspicious_process_injection` | injection | critical | Classic injection API chains |
| `suspicious_keylogger` | spyware | high | `GetAsyncKeyState`, `SetWindowsHookEx` |
| `suspicious_crypto_mining` | miner | medium | Stratum pool URLs, mining algorithms |
| `suspicious_persistence` | persistence | high | Run keys, service creation, schtasks |
| `suspicious_network_backdoor` | backdoor | high | Bind/listen/accept + cmd/shell patterns |
| `suspicious_ransomware` | ransomware | critical | Encryption APIs + ransom note strings |
| `suspicious_shellcode` | shellcode | critical | NOP sleds, egg hunters, common stubs |
| `suspicious_obfuscation` | obfuscation | medium | XOR loops, self-modifying code patterns |
| `suspicious_linux_anti_debug` | evasion | high | `/proc/self/status` TracerPid checks |
| `suspicious_linux_persistence` | persistence | high | crontab, systemd, `.bashrc` modification |
| `suspicious_linux_c2` | c2 | critical | Reverse shell patterns, encoded commands |
| `suspicious_mpress` | packer | medium | MPRESS packer section signatures |

### How YARA-X Differs from Classic YARA

AXUMORTEM uses `yara-x` (the Rust rewrite of YARA) rather than the original C implementation. `yara-x` is fully compatible with existing YARA rules but adds compile-time validation, better error messages, and native Rust integration without FFI overhead. The scanner compiles rules once at engine initialization and reuses the compiled ruleset for every binary.

### Real-World Example: Flame (sKyWIper)

Flame (discovered May 2012) was one of the most complex pieces of malware ever found — a 20MB modular cyberespionage toolkit targeting Middle Eastern countries. It was identified partly through YARA rules that matched its unusual Lua scripting engine embedded in a Windows DLL, plus YARA signatures for its custom SQLite database used to store stolen data. Flame demonstrated why having a broad set of detection rules matters: no single rule caught it, but the combination of multiple low-confidence matches produced a high-confidence detection.

## Disassembly and Control Flow Graphs

### What It Is

Disassembly converts raw machine code bytes back into human-readable assembly instructions. A control flow graph (CFG) maps how execution flows between basic blocks — sequences of instructions with a single entry point and a single exit point.

AXUMORTEM uses the `iced-x86` crate to disassemble x86 and x86_64 binaries. Starting from the entry point and any symbol table hints, it uses recursive descent disassembly: follow each instruction, and when you hit a branch, add both targets to the worklist.

```
Basic Block: 0x401000 - 0x40100F
┌────────────────────────────────────────┐
│ push rbp                               │
│ mov rbp, rsp                           │
│ sub rsp, 0x20                          │
│ cmp dword [rbp-4], 0                   │
│ jne 0x401020                           │
└──────────┬────────────────┬────────────┘
           │ (false)        │ (true)
           v                v
┌──────────────────┐  ┌──────────────────┐
│ Block: 0x401010  │  │ Block: 0x401020  │
│ call 0x402000    │  │ xor eax, eax     │
│ jmp 0x401030     │  │ jmp 0x401030     │
└──────────┬───────┘  └──────────┬───────┘
           │                     │
           v                     v
         ┌───────────────────────────┐
         │ Block: 0x401030           │
         │ leave                     │
         │ ret                       │
         └───────────────────────────┘
```

Each node is a basic block. Each edge represents a possible execution path: conditional branches create two edges (true/false), unconditional jumps create one, and calls create edges to the callee.

### Why CFGs Matter

CFGs reveal program structure that raw disassembly listings obscure. An analyst looking at a flat list of 10,000 instructions can't easily see that there's a loop checking for a debugger on every iteration, or that a function has 15 error-handling branches but only one success path. The CFG makes these patterns visually obvious.

CFGs are also the foundation for more advanced analysis: dead code detection, loop identification, function similarity scoring, and decompilation all start with CFG construction.

### Limits

AXUMORTEM caps disassembly at 1,000 functions and 50,000 instructions per binary. This prevents analysis from hanging on large binaries (a full Chromium build has millions of instructions). The CFG visualization caps at 500 instructions per function to keep the frontend responsive.

### Real-World Example: Equation Group

The Equation Group (linked to the NSA, exposed by Shadow Brokers in 2016) created some of the most sophisticated malware ever discovered, including EQUATIONDRUG and GRAYFISH. Kaspersky Lab's analysis relied heavily on control flow graph comparison to link different malware samples to the same development team. Despite heavy obfuscation, the CFG structure of key functions — particularly the custom encryption routines — remained recognizable across variants. This is the power of structural analysis: even when byte-level patterns change, the logic graph is harder to disguise.

## Threat Scoring

### What It Is

Threat scoring takes all the individual findings from every analysis pass and produces a single 0-100 score that quantifies the binary's maliciousness. AXUMORTEM scores across eight independent categories, each with a maximum point cap:

```
┌──────────────────────────────────────────────┐
│ Category                 │ Max Points │       │
├──────────────────────────┼────────────┤       │
│ Import/API Analysis      │    20      │       │
│ Entropy Analysis         │    15      │       │
│ Packing Detection        │    15      │       │
│ String Analysis          │    10      │       │
│ Section Anomalies        │    10      │       │
│ Entry Point Anomalies    │    10      │       │
│ Anti-Analysis Detection  │    10      │       │
│ YARA Matches             │    10      │       │
├──────────────────────────┼────────────┤       │
│ Maximum Total            │   100      │       │
└──────────────────────────────────────────────┘
```

Each category is scored independently and capped at its maximum. A binary that triggers every import rule still gets at most 20 points from imports. This prevents a single noisy category from overwhelming the final score.

### Risk Levels

The total score maps to five risk levels:

| Score Range | Risk Level | Typical Binary |
|-------------|-----------|----------------|
| 0-15 | BENIGN | Standard applications, system utilities |
| 16-35 | LOW | Legitimate tools with some suspicious features |
| 36-55 | MEDIUM | Dual-use tools (Sysinternals, Metasploit modules) |
| 56-75 | HIGH | Likely malicious, strong behavioral indicators |
| 76-100 | CRITICAL | Active malware with multiple confirmed techniques |

The boundaries are defined as constants:

```rust
const BENIGN_MAX: u32 = 15;
const LOW_MAX: u32 = 35;
const MEDIUM_MAX: u32 = 55;
const HIGH_MAX: u32 = 75;
```

### Evidence-Based Scoring

Every point in the threat score comes with a rule name and a reason. This isn't a black-box "it scored 72." The analyst can see exactly which rules fired:

```
Import Analysis: 15/20
  - Process injection chain (VirtualAllocEx + WriteProcessMemory + CreateRemoteThread): +15

Entropy Analysis: 9/15
  - Section .upx0 entropy 7.45 exceeds threshold: +6
  - Overall entropy 6.92 exceeds 6.8: +3

Packing Detection: 8/15
  - Known packer section name "UPX0": +5
  - PUSHAD opcode at entry point: +3

YARA Matches: 5/10
  - suspicious_upx_packed (packer): +3
  - suspicious_process_injection (injection): +5 (capped at 10)

Total: 37/100 — MEDIUM
```

### MITRE ATT&CK Mapping

Each finding maps to a MITRE ATT&CK technique ID. This connects static analysis results to the broader threat intelligence ecosystem:

- **T1055** — Process Injection (VirtualAllocEx, WriteProcessMemory)
- **T1055.012** — Process Hollowing (NtUnmapViewOfSection)
- **T1055.004** — Asynchronous Procedure Call Injection (QueueUserAPC)
- **T1622** — Debugger Evasion (IsDebuggerPresent, NtQueryInformationProcess)
- **T1547.001** — Boot/Logon Autostart: Registry Run Keys
- **T1543.003** — Create/Modify System Service
- **T1105** — Ingress Tool Transfer (URLDownloadToFile)
- **T1134** — Access Token Manipulation (OpenProcessToken, AdjustTokenPrivileges)
- **T1140** — Deobfuscate/Decode Data (CryptDecrypt)

## How These Concepts Relate

```
                    Binary Upload
                         │
                         v
              ┌─────────────────────┐
              │    Format Parsing   │ ◄── Binary format knowledge
              │  (ELF / PE / Mach-O)│
              └──────────┬──────────┘
                         │
          ┌──────────────┼──────────────┐
          │              │              │
          v              v              v
   ┌────────────┐ ┌────────────┐ ┌────────────┐
   │  Imports   │ │  Strings   │ │  Entropy   │
   │  Analysis  │ │  Analysis  │ │  Analysis  │
   └──────┬─────┘ └──────┬─────┘ └──────┬─────┘
          │              │              │
          │    ┌─────────┘              │
          │    │                        │
          v    v                        v
   ┌────────────────┐          ┌────────────────┐
   │   Disassembly  │          │    Packing     │
   │   + CFG        │          │   Detection    │
   └────────┬───────┘          └────────┬───────┘
            │                           │
            └───────────┬───────────────┘
                        │
                        v
              ┌─────────────────────┐
              │   Threat Scoring    │ ◄── YARA rules
              │   + MITRE Mapping   │
              └─────────────────────┘
```

Format parsing feeds everything downstream. Import and string analysis work in parallel, each providing evidence that the threat scorer combines. Entropy analysis feeds packing detection, which is its own scoring category. Disassembly depends on format parsing for section boundaries and entry points. The threat scorer aggregates everything.

## Industry Standards and Frameworks

### OWASP

While OWASP focuses on web application security, binary analysis intersects with several OWASP concerns:
- **A08:2021 Software and Data Integrity Failures** — binary analysis verifies that distributed software hasn't been tampered with (supply chain attacks like SolarWinds, CCleaner, 3CX)
- **A06:2021 Vulnerable and Outdated Components** — import analysis reveals which libraries a binary links against

### MITRE ATT&CK

AXUMORTEM maps findings to these ATT&CK tactics and techniques:

| Tactic | Techniques Detected |
|--------|-------------------|
| Execution | T1055 (Process Injection), T1055.012 (Hollowing), T1055.004 (APC) |
| Persistence | T1547.001 (Run Keys), T1543.003 (System Service) |
| Defense Evasion | T1622 (Debugger Evasion), T1140 (Deobfuscation), T1027 (Obfuscation) |
| Credential Access | T1134 (Token Manipulation) |
| Command and Control | T1071 (Application Layer Protocol), T1105 (Ingress Tool Transfer) |

### CWE

Binary analysis detects indicators related to:
- **CWE-693** Protection Mechanism Failure (anti-debug bypasses)
- **CWE-506** Embedded Malicious Code (YARA rule matches)
- **CWE-829** Inclusion of Functionality from Untrusted Control Sphere (suspicious imports)

## Testing Your Understanding

1. A binary has an overall entropy of 7.4 and only 3 imports (`GetProcAddress`, `LoadLibraryA`, `VirtualAlloc`). The entry point is in the last section, which is named `UPX1`. What can you conclude about this binary, and which AXUMORTEM scoring categories would fire?

2. You analyze two binaries with identical SHA-256 section hashes for `.text` but different import tables. One imports `ReadFile` + `WriteFile`, the other imports `ReadFile` + `WriteFile` + `CreateRemoteThread` + `VirtualAllocEx`. How would AXUMORTEM's threat scores differ, and why might the second binary have been modified?

3. A PE binary has no suspicious imports, low entropy (5.2 overall), and passes all YARA rules. But string analysis finds `cmd.exe /c`, `powershell -enc`, and three Base64-encoded blobs starting with `TVqQ`. What does this tell you about the binary's behavior, and why didn't import analysis catch it?

## Further Reading

**Essential:**
- [PE Format Specification (Microsoft)](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format) — authoritative reference for PE header structures
- [ELF Specification (Oracle)](https://docs.oracle.com/cd/E19683-01/816-1386/chapter6-46512/index.html) — the original System V ABI ELF specification
- [YARA Documentation](https://yara.readthedocs.io/) — rule syntax, modules, best practices
- [MITRE ATT&CK](https://attack.mitre.org/) — the full technique matrix referenced throughout

**Deep dive:**
- *Practical Malware Analysis* (Sikorski & Honig) — the definitive textbook on binary analysis
- *Practical Binary Analysis* (Andriesse) — focused on ELF with CTF-style exercises
- [The Art of Unpacking (Peter Ferrie)](https://www.virusbulletin.com/uploads/pdf/conference/vb2007/VB2007-Ferrie.pdf) — deep dive into packer internals

**Historical:**
- [SolarWinds SUNBURST Analysis (Microsoft)](https://www.microsoft.com/en-us/security/blog/2020/12/18/analyzing-solorigate-the-compromised-dll-file-that-started-a-sophisticated-cyberattack-and-how-microsoft-defender-helps-protect/) — detailed binary analysis of the trojanized DLL
- [Stuxnet Dossier (Symantec)](https://docs.broadcom.com/doc/security-response-w32-stuxnet-dossier-11-en) — full reverse engineering report
- [WannaCry Analysis (Kaspersky)](https://securelist.com/wannacry-ransomware-used-in-widespread-attacks-all-over-the-world/78351/) — ransomware teardown with entropy observations
