# Implementation Walkthrough

This document walks through the actual code, explaining how each component works and why it's built the way it is.

## The Unified Hasher

The four hash algorithms (MD5, SHA1, SHA256, SHA512) all use the same OpenSSL EVP API. The only differences are which digest function to call and the output length. Instead of duplicating the implementation four times, a single template handles all of them:

```cpp
template <auto Algorithm, auto Name, std::size_t DigestLen>
class EVPHasher {
public:
    std::string hash(std::string_view input) const;
    static constexpr std::string_view name() { return Name; }
    static constexpr std::size_t digest_length() { return DigestLen; }
};
```

Each concrete hasher is just a type alias:

```cpp
using MD5Hasher    = EVPHasher<EVP_md5, "MD5", 32>;
using SHA256Hasher = EVPHasher<EVP_sha256, "SHA256", 64>;
```

The template parameters are resolved at compile time, so the compiler generates four separate `hash()` implementations, each hardcoded to its specific digest function. Same performance as hand-written code, zero duplication.

### The Hot Path: Hash Computation

The `hash()` method is the most performance-critical function in the codebase. Every candidate password passes through it. The implementation uses OpenSSL's EVP interface with RAII cleanup:

```cpp
std::string EVPHasher::hash(std::string_view input) const {
    auto ctx = std::unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)>(
        EVP_MD_CTX_new(), EVP_MD_CTX_free);

    if (!ctx
        || !EVP_DigestInit_ex(ctx.get(), Algorithm(), nullptr)
        || !EVP_DigestUpdate(ctx.get(), input.data(), input.size())
        || !EVP_DigestFinal_ex(ctx.get(), digest.data(), &len)) {
        return "";
    }

    // Convert digest bytes to hex string
}
```

The `unique_ptr` with a custom deleter (`EVP_MD_CTX_free`) ensures the context is freed even if something fails. The chained `if` checks every OpenSSL return value. Returning empty string on failure is the correct fail-safe: an empty string will never match a valid target hash, so a cracking run degrades gracefully instead of producing wrong results.

### Hex Encoding with a Lookup Table

The naive approach uses `std::ostringstream` with `std::hex` and `std::setw(2)`. That creates a heap-allocated stream object for every single hash. At millions of hashes per second, that's millions of unnecessary allocations.

Instead, a precomputed lookup table converts each byte to two hex characters with zero allocation:

```cpp
static constexpr std::array<std::array<char, 2>, 256> HEX_TABLE = [] {
    std::array<std::array<char, 2>, 256> t{};
    constexpr char digits[] = "0123456789abcdef";
    for (int i = 0; i < 256; ++i) {
        t[i] = {digits[i >> 4], digits[i & 0xF]};
    }
    return t;
}();
```

The table is computed at compile time (`constexpr` lambda). For each byte value 0-255, it stores the two hex characters. The high nibble (`i >> 4`) becomes the first character, the low nibble (`i & 0xF`) becomes the second. Byte `0xAB` maps to `{'a', 'b'}`.

Converting the full digest is a tight loop:

```cpp
std::string hex(len * 2, '\0');
for (unsigned int i = 0; i < len; ++i) {
    hex[i * 2]     = HEX_TABLE[digest[i]][0];
    hex[i * 2 + 1] = HEX_TABLE[digest[i]][1];
}
```

One allocation for the output string (size known upfront), two array lookups per byte. This is the same approach hashcat uses.

## Hash Auto-Detection

`HashDetector::detect()` identifies the hash algorithm from the hex string:

```cpp
std::expected<HashType, CrackError> HashDetector::detect(std::string_view hash) {
    // Validate all characters are hexadecimal
    if (!std::ranges::all_of(hash, is_hex)) {
        return std::unexpected(CrackError::InvalidHash);
    }

    // Match length to algorithm
    switch (hash.size()) {
        case config::MD5_HEX_LENGTH:    return HashType::MD5;
        case config::SHA1_HEX_LENGTH:   return HashType::SHA1;
        case config::SHA256_HEX_LENGTH: return HashType::SHA256;
        case config::SHA512_HEX_LENGTH: return HashType::SHA512;
        default: return std::unexpected(CrackError::InvalidHash);
    }
}
```

This works because each algorithm produces a unique digest length. MD5 is always 32 hex characters, SHA1 is always 40, SHA256 is 64, SHA512 is 128. The hex validation catches typos and non-hash input before the cracking run wastes time.

## Dictionary Attack with mmap

### Memory Mapping the File

Instead of reading the wordlist line by line with `std::ifstream` (which copies data from kernel space to user space on every read), we map the entire file into the process address space:

```cpp
auto* mapped = static_cast<const char*>(
    mmap(nullptr, file_size, PROT_READ, MAP_PRIVATE, fd, 0));
madvise(mapped, file_size, MADV_SEQUENTIAL);
```

After this call, `mapped` is a pointer to the file's contents in memory. Reading a word is just pointer arithmetic. The `MADV_SEQUENTIAL` hint tells the kernel to prefetch pages ahead of the current read position since we're scanning linearly.

### Thread Partitioning

For N threads, the file is split into N ranges by counting newlines:

```cpp
std::size_t lines_per_thread = total_lines / total_threads;
std::size_t my_start_line = thread_index * lines_per_thread + ...;
```

Each thread walks forward through the file to find the byte offset of its starting line, then scans its range independently. No shared cursor, no locks, no coordination between threads during the cracking loop.

### Reading Words

The `next()` method scans from the current offset to the next newline:

```cpp
std::expected<std::string, AttackComplete> DictionaryAttack::next() {
    while (current_offset_ < end_offset_) {
        // Find newline
        while (line_end < end_offset_ && file_.data()[line_end] != '\n') {
            ++line_end;
        }

        // Strip \r for Windows line endings
        if (word_end > line_start && file_.data()[word_end - 1] == '\r') {
            --word_end;
        }

        // Skip empty lines (iterative, not recursive)
        if (word_end > line_start) {
            return std::string(file_.data() + line_start, word_end - line_start);
        }
    }
    return std::unexpected(AttackComplete{});
}
```

Empty lines are skipped iteratively. An earlier version used recursion (`return next()`), but a wordlist with many consecutive empty lines could theoretically overflow the stack.

## Brute Force Keyspace Generation

### Computing the Total Keyspace

For a charset of size C and max length L:

```cpp
std::size_t compute_keyspace(std::size_t charset_size, std::size_t max_length) {
    std::size_t total = 0;
    std::size_t power = 1;
    for (std::size_t len = 1; len <= max_length; ++len) {
        power *= charset_size;
        total += power;
    }
    return total;
}
```

This computes `C + C^2 + C^3 + ... + C^L`. For lowercase letters (C=26) and L=4, that's 26 + 676 + 17576 + 456976 = 475,254.

### Index-to-Candidate Conversion

Each candidate has a unique flat index in the range `[0, total)`. Converting an index to a string is like converting a number to a variable-length base:

```cpp
std::string index_to_candidate(std::size_t index) const {
    // Determine which length bucket this index falls in
    std::size_t cumulative = 0;
    std::size_t power = base;
    std::size_t length = 1;
    while (cumulative + power <= index && length < max_length_) {
        cumulative += power;
        ++length;
        power *= base;
    }

    // Convert the offset within that bucket to characters
    std::size_t offset = index - cumulative;
    std::string result(length, charset_[0]);
    for (std::size_t i = length; i > 0; --i) {
        result[i - 1] = charset_[offset % base];
        offset /= base;
    }
    return result;
}
```

This is the same algorithm as converting a decimal number to base-N, except the "digits" are characters from the charset. Index 0 maps to the first single-character string, and the indices increase through all single-character strings, then all two-character strings, and so on.

## Rule-Based Mutations with std::generator

### Individual Rules

Each rule is a coroutine that yields mutations lazily:

```cpp
std::generator<std::string> RuleSet::leet_speak(std::string_view word) {
    std::string result(word);
    for (auto& c : result) {
        auto lower = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        for (auto [from, to] : LEET_MAP) {
            if (lower == from) { c = to; break; }
        }
    }
    co_yield std::move(result);
}
```

The `co_yield` keyword suspends the function and returns the value. When the caller asks for the next value, execution resumes where it left off. For simple rules like leet speak, there's only one yield. For append_digits, there are 1000 yields (one per digit 0-999).

### Composing Rules

`apply_all()` delegates to each rule using `std::ranges::elements_of`:

```cpp
std::generator<std::string> RuleSet::apply_all(std::string_view word) {
    co_yield std::ranges::elements_of(capitalize_first(word));
    co_yield std::ranges::elements_of(uppercase_all(word));
    co_yield std::ranges::elements_of(leet_speak(word));
    co_yield std::ranges::elements_of(append_digits(word));
    co_yield std::ranges::elements_of(prepend_digits(word));
    co_yield std::ranges::elements_of(reverse(word));
    co_yield std::ranges::elements_of(toggle_case(word));
}
```

`elements_of` is a C++23 feature for delegating to sub-generators. Without it, you'd write `for (auto&& s : sub_gen) { co_yield std::move(s); }` for each rule, which is verbose and has O(depth) overhead per element.

### The Leet Map

The substitution table uses a constexpr array instead of `std::unordered_map`:

```cpp
static constexpr std::array<std::pair<char, char>, 6> LEET_MAP = {{
    {'a', '@'}, {'e', '3'}, {'i', '1'},
    {'o', '0'}, {'s', '$'}, {'t', '7'}
}};
```

Six entries. A linear scan over 6 elements is faster than computing a hash, looking up a bucket, and dereferencing a node pointer. The `unordered_map` would also heap-allocate at construction time, which the constexpr array avoids entirely.

## The Engine Template

The Engine wires everything together. It's a static template function in a header because it must be instantiated for each hasher/attack combination:

```cpp
template <Hasher H, AttackStrategy A>
auto Engine::crack(const CrackConfig& cfg)
    -> std::expected<CrackResult, CrackError>
```

### Worker Lambda

Each thread runs a lambda that creates its own attack partition, its own hasher instance, and loops until it finds a match or runs out of candidates:

```cpp
pool.run([&](unsigned tid, unsigned total, SharedState& state) {
    H hasher;
    auto attack = create_attack();  // partitioned for this thread

    std::size_t local_count = 0;
    while (!state.found.load(std::memory_order_relaxed)) {
        auto candidate = attack->next();
        if (!candidate.has_value()) { break; }

        std::string to_hash = *candidate;
        // Apply salt if configured...

        if (hasher.hash(to_hash) == cfg.target_hash) {
            state.tested_count.fetch_add(local_count, std::memory_order_relaxed);
            state.set_result(std::move(*candidate));
            break;
        }

        ++local_count;
        if ((local_count & 0x3FF) == 0) {
            state.tested_count.fetch_add(local_count, std::memory_order_relaxed);
            local_count = 0;
        }
    }
    state.tested_count.fetch_add(local_count, std::memory_order_relaxed);
});
```

Key details:
- `relaxed` memory ordering on the `found` flag is intentional. We don't need immediate visibility. If one thread sets `found` and another thread runs for a few extra iterations before seeing it, that's fine. The cost of stronger ordering (memory fences on every iteration) is not worth the guarantee of stopping instantly
- The local counter batches atomic updates every 1024 iterations (`& 0x3FF` is a bitmask check, faster than modulo). The final `fetch_add` after the loop flushes any remaining count

## CLI Dispatch

The main function uses a template lambda to dispatch based on hash type without runtime polymorphism:

```cpp
template <Hasher H>
static auto dispatch_attack(const CrackConfig& cfg)
    -> std::expected<CrackResult, CrackError> {
    if (cfg.bruteforce) return Engine::crack<H, BruteForceAttack>(cfg);
    if (cfg.use_rules) return Engine::crack<H, RuleAttack>(cfg);
    return Engine::crack<H, DictionaryAttack>(cfg);
}

static auto dispatch_hasher(HashType type, const CrackConfig& cfg)
    -> std::expected<CrackResult, CrackError> {
    switch (type) {
        case HashType::MD5:    return dispatch_attack<MD5Hasher>(cfg);
        case HashType::SHA1:   return dispatch_attack<SHA1Hasher>(cfg);
        case HashType::SHA256: return dispatch_attack<SHA256Hasher>(cfg);
        case HashType::SHA512: return dispatch_attack<SHA512Hasher>(cfg);
    }
    return std::unexpected(CrackError::UnsupportedAlgorithm);
}
```

The `switch` is the only point where a runtime decision is made. Each case instantiates the Engine template with a concrete hasher type. From that point forward, everything is resolved at compile time.

## Testing Strategy

The test suite has 38 tests organized by component:

**Hasher tests** verify against NIST known-answer vectors. If `SHA256Hasher::hash("password")` doesn't produce exactly `5e884898da28...`, the implementation is wrong. These are the most important tests because a subtle hashing bug would make the entire tool silently fail.

**HashDetector tests** verify type detection (length-based) and input validation (non-hex rejection).

**DictionaryAttack tests** verify word reading, thread partitioning (two threads together read all words), total count, and file-not-found error handling.

**BruteForceAttack tests** verify keyspace math, candidate generation completeness (all combinations produced), and thread partitioning (no duplicates, no gaps).

**RuleSet tests** verify each mutation rule against expected output. The `AllRulesProduceMutations` test confirms the total count exceeds 2000 (7 rules applied to "password", with append_digits and prepend_digits each producing 1000).

**Engine tests** are integration tests. `CracksSHA256WithDictionary` runs the full pipeline with 2 threads and verifies it finds "password". `CracksWithSalt` verifies salt prepending works end to end.

## Common Pitfalls

**Forgetting to flush the local counter**: If a thread finds the password and breaks without flushing `local_count`, the final tested count will be wrong. The `fetch_add` after the loop handles this.

**Comparing hashes with different case**: SHA256 might produce uppercase hex on some platforms. Our hex encoder always produces lowercase, and the target hash is used as-is from the CLI. If someone pastes an uppercase hash, it won't match. A real production tool would normalize both to lowercase.

**mmap and file truncation**: If the wordlist file is modified while the tool is running, the behavior is undefined. `MAP_PRIVATE` helps (we get a copy-on-write snapshot), but for a tool that processes a file once and exits, this is not a practical concern.
