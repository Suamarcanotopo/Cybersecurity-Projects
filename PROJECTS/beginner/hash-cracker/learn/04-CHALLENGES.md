# Extension Challenges

Ideas for extending this project, ordered by difficulty. Each one teaches a different skill. Don't feel like you need to do them in order.

## Easy Challenges

### 1. Add SHA3 Support

SHA3 (Keccak) is a completely different hash family from SHA2, based on a sponge construction instead of Merkle-Damgard. OpenSSL supports it through the same EVP API.

**What to build:** Add SHA3-256 and SHA3-512 hashers.

**What you'll learn:** How little code a new algorithm requires when the architecture is right. The EVPHasher template means this is a two-line change plus detection logic.

**Hints:**
- `EVP_sha3_256()` and `EVP_sha3_512()` are the OpenSSL functions
- SHA3-256 produces a 64-character hex digest (same length as SHA256), so auto-detection by length alone won't distinguish them. You'll need a `--type sha3-256` flag
- Write tests against known vectors from the NIST SHA3 test suite

### 2. Batch Hash Cracking

Right now the tool cracks one hash at a time. Real breach dumps have millions of hashes.

**What to build:** Accept a file of hashes (one per line) and crack them all in a single run. Report which ones were cracked and which weren't.

**What you'll learn:** Amortizing dictionary reads across multiple targets. Instead of re-reading the wordlist for each hash, you hash each candidate once and compare against all targets simultaneously.

**Hints:**
- Load all target hashes into a `std::unordered_set<std::string>`
- For each candidate, hash it and check `targets.count(hash_result)`
- This is how real cracking tools work. Cracking 1000 hashes is barely slower than cracking 1

### 3. Colored Hash Type Display

When auto-detecting, show the user what type was detected before cracking starts.

**What to build:** Add a colored line to the banner showing the detected algorithm with confidence indicator.

**What you'll learn:** Terminal UI design, ANSI escape sequences, and the ambiguity problem (SHA256 and SHA3-256 have the same digest length).

**Hints:**
- Use the existing color constants in Config.hpp
- Consider showing "SHA256 (auto-detected)" vs "SHA256 (specified)" so the user knows which path was taken

## Intermediate Challenges

### 4. Custom Rule File Format

The current rule set is hardcoded. Real cracking tools like hashcat and john support rule files where users define their own mutation patterns.

**What to build:** A rule file parser that reads rules from a text file:
```
:           # do nothing (try the word as-is)
c           # capitalize first letter
u           # uppercase all
l           # lowercase all
r           # reverse
$[0-9]      # append digit
^[0-9]      # prepend digit
sa@         # substitute a with @
se3         # substitute e with 3
```

**What you'll learn:** Language parsing, the hashcat rule format (which is a real industry standard), and how rule composition creates exponential candidate counts.

**Hints:**
- Start with single-character rule codes, then add parametric rules like `$N` and `sXY`
- hashcat's rule engine documentation describes the full syntax
- A rule file with 50 rules applied to a 10K wordlist produces 500K candidates. That's still fast

### 5. Progress File for Resumable Cracking

If you're brute forcing an 8-character password and your machine crashes at 60% progress, you lose all that work.

**What to build:** Periodically save progress (current index, elapsed time, candidates tested) to a file. On restart with `--resume`, pick up where you left off.

**What you'll learn:** Checkpointing, atomic file writes (write to temp, rename), and the importance of deterministic work partitioning (our index-based brute force makes this easy since each index maps to exactly one candidate).

**Hints:**
- For brute force, save the current flat index. That's all you need
- For dictionary, save the byte offset in the file
- Write the checkpoint every N seconds, not every N candidates (I/O is expensive relative to hashing)

### 6. Mask Attack

A mask attack is a smarter brute force. Instead of trying all characters in every position, you specify a pattern: `?u?l?l?l?d?d?d?d` means uppercase, three lowercase, four digits. This matches passwords like `Pass1234`.

**What to build:** A `--mask` flag that accepts hashcat-style mask syntax:
```
?l = lowercase    ?u = uppercase
?d = digit        ?s = special
?a = all          A  = literal 'A'
```

**What you'll learn:** The massive efficiency gain from constrained search spaces. `?u?l?l?l?d?d?d?d` is 26*26*26*26*10*10*10*10 = 4.5 billion candidates. Full brute force of 8 characters from the same set is 218 trillion. That's a 48,000x reduction.

**Hints:**
- Parse the mask into a vector of character sets, one per position
- The keyspace calculation becomes `product of each position's charset size`
- Partitioning works the same way as brute force (flat index, mixed-radix decomposition)

## Advanced Challenges

### 7. Rainbow Table Generator and Lookup

Rainbow tables are precomputed hash chains that trade disk space for cracking time. Instead of hashing every candidate at runtime, you build a table offline and do a lookup.

**What to build:** Two modes: `--generate-table` creates a rainbow table file for a given charset and length, `--rainbow` cracks using a precomputed table.

**What you'll learn:** The time-memory tradeoff in cryptanalysis, reduction functions, chain construction, and why salts make rainbow tables useless. This is one of the most elegant attacks in all of computer security.

**Hints:**
- A rainbow table doesn't store every hash. It stores chains: start points and end points. Each chain covers thousands of hashes
- The reduction function converts a hash back into a candidate (not a reverse of the hash, just a deterministic mapping)
- Chain length controls the tradeoff: longer chains = smaller table but slower lookup
- Start with a small example (4-char lowercase) to verify correctness before scaling up
- Martin Hellman's original 1980 paper describes the concept. Philippe Oechslin's 2003 paper introduces the "rainbow" improvement

### 8. GPU-Accelerated Cracking with CUDA

The nuclear option. Move the hash-and-compare loop to the GPU.

**What to build:** A CUDA kernel that hashes candidates in parallel on the GPU. The CPU generates candidates and uploads batches; the GPU hashes thousands simultaneously.

**What you'll learn:** GPU programming, CUDA kernel design, host-device memory management, and why GPUs are so much faster at parallel computation (thousands of simple cores vs a few complex cores).

**Hints:**
- You can't use OpenSSL on the GPU. Implement SHA256 in pure CUDA (the algorithm is public, about 100 lines of kernel code)
- Upload candidates in batches (e.g., 1 million at a time) to amortize the host-to-device transfer cost
- Use `cudaMemcpyAsync` with streams for overlapping computation and transfer
- Start with SHA256 only. Getting one algorithm working on GPU is a significant accomplishment
- This could be its own standalone advanced project in the repository

## Expert Challenge

### 9. Distributed Cracking Over the Network

Split the keyspace across multiple machines. One coordinator assigns work ranges; workers hash and report back.

**What to build:** A coordinator that accepts connections from worker nodes, assigns keyspace ranges, collects results, and handles worker failures (reassign their range to another worker).

**What you'll learn:** Distributed systems fundamentals: work distribution, heartbeating, fault tolerance, and the coordinator pattern. This is the same architecture that large-scale password cracking operations use.

**Hints:**
- Use TCP sockets or gRPC for communication
- The coordinator divides the total keyspace into chunks and assigns them on request
- Workers send periodic heartbeats with their progress. If a worker goes silent, the coordinator reassigns its chunk
- Think about what happens if two workers claim to crack the same hash (the coordinator should handle duplicate results gracefully)
- This pairs well with Challenge 8 (each worker could be GPU-accelerated)

## Performance Challenges

### 10. Benchmark Suite

How fast is the tool actually? Compare different hash algorithms, threading configurations, and attack modes.

**What to build:** A benchmark mode (`--benchmark`) that runs standardized tests and reports results:
```
SHA256 dictionary (10K words):  2.4M h/s
SHA256 brute force (6 chars):   2.1M h/s
MD5 dictionary (10K words):     3.8M h/s
SHA512 dictionary (10K words):  1.9M h/s
Threads: 1=600K  2=1.2M  4=2.3M  8=2.4M
```

**What you'll learn:** Microbenchmarking methodology, why results vary between runs, and where the actual bottlenecks are (hint: it's OpenSSL, not your code).

**Hints:**
- Use `std::chrono::steady_clock` for timing
- Run each benchmark multiple times and report median, not mean
- Pin threads to specific cores with `pthread_setaffinity_np` for consistent results
- Compare your numbers to hashcat's benchmarks to see the CPU vs GPU difference

## Getting Help

If you get stuck on any challenge:

1. Read the relevant source code. The architecture is designed so each component is understandable in isolation
2. Write a failing test first. If you can describe the expected behavior in a test, the implementation becomes clearer
3. Start small. Get the simplest possible version working, then add complexity
4. Check hashcat's documentation for real-world precedent. Most of these challenges are simplified versions of features that production cracking tools already implement
