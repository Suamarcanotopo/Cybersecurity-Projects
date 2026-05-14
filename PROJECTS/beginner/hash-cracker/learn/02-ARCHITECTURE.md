# System Architecture

This document breaks down how the system is designed and why certain architectural decisions were made.

## High Level Architecture

```
┌────────────────────┐
│     CLI Layer      │  (main.cpp)
│  - parse args      │  Boost.program_options
│  - detect hash     │  Auto-type from length
│  - dispatch        │  Template instantiation
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│   Engine Layer     │  (Engine.hpp)
│  - create threads  │  std::jthread pool
│  - partition work  │  Per-thread attack slices
│  - coordinate      │  Shared atomics
│  - display         │  Progress thread
└─────────┬──────────┘
          │
    ┌─────┴─────┐
    ▼           ▼
┌────────┐ ┌──────────┐
│ Hasher │ │ Attack   │
│ Policy │ │ Strategy │
└────────┘ └──────────┘
    │           │
    ▼           ▼
┌────────┐ ┌──────────────────────────────────┐
│ EVP    │ │ DictionaryAttack (mmap)          │
│ Hasher │ │ BruteForceAttack (keyspace math) │
│        │ │ RuleAttack (dict + mutations)    │
└────────┘ └──────────────────────────────────┘
```

### Component Breakdown

**CLI Layer (main.cpp)**
- Purpose: Parse command line arguments and dispatch to the correct Engine instantiation
- Responsibilities: Argument validation, hash type detection, charset construction, JSON output
- Key design choice: Uses a template lambda to avoid runtime polymorphism. The `switch` on hash type creates a compile-time-resolved call path

**Engine Layer (Engine.hpp)**
- Purpose: Coordinate hashing, attack strategy, threading, and progress display
- Responsibilities: Thread pool management, salt application, result collection, timing
- Key design choice: Header-only template function. The hasher and attack strategy types are template parameters, so the compiler inlines the hash function directly into the cracking loop

**Hasher Policy (EVPHasher.hpp)**
- Purpose: Compute cryptographic hashes via OpenSSL
- Responsibilities: EVP context management, digest computation, hex encoding
- Key design choice: Single template parameterized by algorithm function pointer. All four hash types are type aliases of the same implementation

**Attack Strategies (attack/)**
- Purpose: Generate candidate passwords
- Responsibilities: Wordlist reading, keyspace generation, mutation application, thread partitioning
- Key design choice: Each strategy satisfies the `AttackStrategy` concept and handles its own partitioning via `create(path, thread_index, total_threads)`

**Progress Display (display/)**
- Purpose: Show real-time cracking progress
- Responsibilities: Progress bar rendering, speed/ETA calculation, result formatting
- Key design choice: Runs on its own thread, reads shared atomics with relaxed ordering, no-ops when stdout isn't a terminal

## Core Design: Policy-Based Templates

The central architectural decision is resolving the hasher and attack strategy at compile time rather than runtime. Compare the two approaches:

**Runtime polymorphism (what we didn't do):**
```cpp
class IHasher {
public:
    virtual std::string hash(std::string_view input) = 0;
    virtual ~IHasher() = default;
};

void crack(IHasher* hasher, ...) {
    for (each candidate) {
        hasher->hash(candidate);  // virtual call every iteration
    }
}
```

Every `hash()` call goes through the vtable, which means an indirect branch. The CPU can't inline the function body, can't optimize across the call boundary, and pays a branch prediction penalty. In a loop that runs millions of times per second, this adds up.

**Compile-time polymorphism (what we did):**
```cpp
template <Hasher H, AttackStrategy A>
auto crack(const CrackConfig& cfg) -> std::expected<CrackResult, CrackError> {
    H hasher;
    // ... hasher.hash(candidate) is a direct call, gets inlined
}
```

When you write `Engine::crack<SHA256Hasher, DictionaryAttack>(cfg)`, the compiler generates a version of `crack` with SHA256Hasher hardcoded. The `hash()` call becomes a direct function call that gets inlined into the loop. No vtable, no indirection, no overhead.

The tradeoff: you get a separate copy of the function for each hasher/attack combination (12 total: 4 hashers x 3 attacks). This increases binary size slightly. For a CLI tool, that's irrelevant.

## Concepts as Contracts

C++20 concepts define what a Hasher or AttackStrategy must provide:

```cpp
template <typename T>
concept Hasher = requires(T h, std::string_view input) {
    { h.hash(input) } -> std::same_as<std::string>;
    { T::name() } -> std::convertible_to<std::string_view>;
    { T::digest_length() } -> std::same_as<std::size_t>;
};
```

This is a compile-time contract. If you write a new hasher that doesn't satisfy `Hasher`, you get a clear error message at compile time instead of a mysterious linker error or runtime crash. It documents the interface without requiring inheritance.

## Data Flow

### Dictionary Attack Flow

```
1. CLI parses --hash and --wordlist
   main.cpp dispatches Engine::crack<SHA256Hasher, DictionaryAttack>(cfg)

2. Engine resolves thread count (hardware_concurrency if 0)
   Creates ThreadPool, spawns N jthreads

3. Each thread calls DictionaryAttack::create(path, thread_id, N)
   create() opens the file with mmap, counts lines,
   computes this thread's byte range [start_offset, end_offset)

4. Thread loop:
   a. attack.next() reads the next word from the mmap region
   b. If salt is set, prepend/append it to the candidate
   c. hasher.hash(candidate) computes the digest
   d. Compare to target hash
   e. If match: set atomic found flag, store result, break
   f. Increment local counter, flush to shared atomic every 1024 iterations

5. Display thread wakes every 100ms, reads shared atomics,
   renders progress bar to terminal

6. All threads join (jthread RAII)
   Engine returns CrackResult or CrackError::Exhausted
```

### Brute Force Partitioning

The total keyspace for a charset of size C and max length L is:

```
total = C^1 + C^2 + C^3 + ... + C^L
```

Each thread gets a contiguous slice of the flat index space. Thread 0 gets indices `[0, total/N)`, thread 1 gets `[total/N, 2*total/N)`, and so on. Converting a flat index to a candidate string uses mixed-radix decomposition, similar to converting a decimal number to an arbitrary base but with variable-length output.

This means threads never communicate during the cracking loop. No shared queue, no work stealing, no locks. Each thread is completely independent.

## Threading Model

### Shared State

Only two values are shared between threads:

```cpp
struct SharedState {
    alignas(64) std::atomic<bool> found{false};
    alignas(64) std::atomic<std::size_t> tested_count{0};
    std::mutex result_mutex;
    std::optional<std::string> result;
};
```

The `alignas(64)` places each atomic on its own cache line. Without this, writes to `tested_count` from one thread would invalidate reads of `found` on other threads because they share a 64-byte cache line. This is called false sharing and can cause a 5x slowdown.

### Counter Batching

Instead of doing an atomic increment on every candidate:

```cpp
// Bad: atomic write every iteration (cross-core cache traffic)
state.tested_count.fetch_add(1, std::memory_order_relaxed);
```

Each thread maintains a local counter and flushes every 1024 iterations:

```cpp
++local_count;
if ((local_count & 0x3FF) == 0) {
    state.tested_count.fetch_add(local_count, std::memory_order_relaxed);
    local_count = 0;
}
```

This reduces cross-core atomic traffic by 1024x. The progress display reads an approximate count, which is fine for a UI update every 100ms.

## Error Handling Strategy

All fallible operations return `std::expected<T, CrackError>`. There are no exceptions in the codebase.

```cpp
enum class CrackError {
    FileNotFound,
    InvalidHash,
    UnsupportedAlgorithm,
    OpenSSLError,
    InvalidConfig,
    Exhausted
};
```

The error type is in the function signature. Callers are forced to handle it:

```cpp
auto attack = DictionaryAttack::create(path, tid, total);
if (!attack.has_value()) { return; }
```

This makes error paths explicit and visible. You never have to guess whether a function might throw.

## Memory-Mapped I/O

DictionaryAttack uses `mmap` instead of `std::ifstream` for reading wordlists:

```cpp
auto* mapped = static_cast<const char*>(
    mmap(nullptr, file_size, PROT_READ, MAP_PRIVATE, fd, 0));
madvise(mapped, file_size, MADV_SEQUENTIAL);
```

The file's contents are mapped directly into the process address space. Reading a word is pointer arithmetic (advance to the next newline). No `read()` syscalls, no kernel-to-user buffer copies. For a 140MB wordlist like rockyou.txt, this matters.

The `MappedFile` RAII wrapper handles cleanup:

```cpp
class MappedFile {
    ~MappedFile() {
        munmap(data_, size_);
        close(fd_);
    }
};
```

DictionaryAttack holds a `MappedFile` member. The compiler generates correct move operations automatically (Rule of Zero).

## Configuration

All magic numbers live in `Config.hpp`:

```cpp
namespace config {
constexpr unsigned DEFAULT_THREAD_COUNT = 0;
constexpr std::size_t DEFAULT_MAX_BRUTE_LENGTH = 6;
constexpr int PROGRESS_UPDATE_MS = 100;
constexpr std::string_view CHARSET_LOWER = "abcdefghijklmnopqrstuvwxyz";
// ...
}
```

Runtime configuration flows through `CrackConfig`, populated by the CLI parser and passed to the Engine. No globals are mutated after startup.

## Performance Considerations

**Hot path**: The inner loop in `Engine.hpp` is hash-and-compare. Every microsecond saved here multiplies by millions of iterations. The EVPHasher uses a lookup-table hex encoder instead of `std::ostringstream`, avoiding heap allocation per hash.

**Bottleneck**: On CPU, the bottleneck is the hash computation itself (OpenSSL's EVP internals). The surrounding code (candidate generation, comparison, counter update) is negligible in comparison. GPU acceleration (CUDA/OpenCL) would be the next step for real performance gains.

**Memory**: mmap means the wordlist is paged in on demand by the kernel. The tool's actual memory footprint is small regardless of wordlist size.

## Design Decisions

| Decision | Alternative | Why This Way |
|----------|------------|-------------|
| Template policies | Virtual interfaces | Zero overhead in hot loop |
| `std::expected` | Exceptions | Explicit error paths, no hidden control flow |
| `std::generator` | Return `vector<string>` | Lazy evaluation, early termination |
| mmap | `std::ifstream` | Zero-copy, no syscall per line |
| Work partitioning | Work stealing queue | Zero contention between threads |
| Relaxed atomics | seq_cst | Approximate progress is fine, saves fence cost |
| Header-only Engine | Compiled .cpp | Template must be in header anyway |

## Extensibility

**Adding a new hash algorithm:**
1. Add a type alias in a new header:
   ```cpp
   using SHA3_256Hasher = EVPHasher<EVP_sha3_256, "SHA3-256", 64>;
   ```
2. Add a case in `HashDetector::detect()` (if the digest length is unique)
3. Add a case in `main.cpp`'s dispatch switch
4. Write tests against known vectors

**Adding a new attack strategy:**
1. Create a class satisfying the `AttackStrategy` concept (needs `next()`, `total()`, `progress()`)
2. Add a `create(path, thread_index, total_threads)` factory
3. Add a dispatch path in `main.cpp` and `Engine.hpp`

Both extension points require zero changes to the Engine itself.

## Limitations

- CPU only. No GPU acceleration. A dedicated tool like hashcat on a modern GPU is ~1000x faster
- No bcrypt/scrypt/argon2 support. These require different libraries and fundamentally different cracking strategies (the intentional slowness changes the economics)
- No distributed cracking. Each run uses one machine
- The `--chain-rules` flag generates a large number of candidates per word, which can make rule attacks slow on large wordlists
- Linux/macOS only (mmap is POSIX). Windows would need `CreateFileMapping` instead
