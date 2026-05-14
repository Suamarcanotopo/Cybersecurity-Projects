# Core Security Concepts

This document explains the security concepts you'll encounter while building this project. These are not just definitions. We'll dig into why they matter and how they actually work.

## Rate Limiting Fundamentals

### What It Is

Rate limiting controls how many requests a client can make to an API within a time window. Instead of accepting unlimited traffic, you define rules like "100 requests per minute" or "5 login attempts per hour." When a client exceeds the limit, you reject their requests with HTTP 429 (Too Many Requests) or in this project's case, HTTP 420 (Enhance Your Calm).

The core mechanism is a counter. For each client, track how many requests they've made in the current time window. Increment on each request. If the count exceeds the limit, reject the request. Reset the counter when the window expires.

### Why It Matters

In September 2022, Uber suffered a complete breach because an attacker brute-forced MFA codes on an employee account. The attacker made hundreds of attempts until they guessed correctly. No rate limiting on the MFA endpoint meant unlimited guesses. With a 5-attempt limit, the attack would have failed immediately.

Rate limiting prevents:
- **Resource exhaustion** - One client consuming all your server capacity
- **Cost runaway** - If you pay per API call to third parties, unlimited requests = unlimited bills
- **Service degradation** - Slow clients hogging connections, starving fast clients

Without rate limiting, a single `while True: requests.get()` loop can take down your entire API.

### How It Works

The simplest implementation uses a counter and timestamp:
```python
# Naive approach (don't use this)
counters = {}

def check_rate_limit(client_id, limit, window_seconds):
    now = time.time()
    
    if client_id not in counters:
        counters[client_id] = {"count": 0, "window_start": now}
    
    client_data = counters[client_id]
    
    # Reset if window expired
    if now - client_data["window_start"] > window_seconds:
        client_data["count"] = 0
        client_data["window_start"] = now
    
    # Check limit
    if client_data["count"] >= limit:
        return False  # Rate limited
    
    client_data["count"] += 1
    return True  # Allowed
```

This has race conditions. Two concurrent requests can both read `count=99`, both increment to 100, and both get allowed when the limit is 100. You need atomic operations, which is why this project uses Redis Lua scripts (`src/fastapi_420/storage/lua/sliding_window.lua:1-32`).

### Common Attacks

1. **Distributed rate limit bypass** - Attacker uses 1000 IP addresses to make 99 requests each (under your 100/minute limit). Total: 99,000 requests/minute. Defense: Add a global endpoint limit in addition to per-user limits. See `src/fastapi_420/defense/layers.py:128-169`.

2. **Boundary exploitation** - With fixed windows, if the window resets at :00, an attacker makes 100 requests at :59 and 100 at :01. That's 200 requests in 2 seconds, bypassing your "100/minute" limit. Defense: Use sliding windows instead. See concept below.

3. **Header spoofing** - Attacker rotates `User-Agent` headers to appear as different clients. Defense: Fingerprint multiple attributes (IP + UA + Auth). See `src/fastapi_420/fingerprinting/composite.py:46-95`.

### Defense Strategies

This project implements layered defense:

**Layer 1: Per-user per-endpoint** - Strict limits for individual clients. Stops single-user abuse.
**Layer 2: Per-endpoint global** - Prevents one endpoint from being overwhelmed by distributed attacks.
**Layer 3: Global circuit breaker** - Protects entire API when under large-scale DDoS.

Check happens at `src/fastapi_420/defense/layers.py:47-84`. All three layers must pass for a request to succeed.

## Algorithm Comparison

### Sliding Window Counter

**What it is:**
Approximates a true sliding window using two fixed windows. Interpolates between the current and previous window based on elapsed time within the current window. Achieves 99.997% accuracy with O(1) memory per client.

The formula (from `src/fastapi_420/storage/lua/sliding_window.lua:18-19`):
```lua
weighted_count = previous_count * (1 - elapsed_ratio) + current_count
```

If you're 30 seconds into a 60-second window, `elapsed_ratio = 0.5`. Previous window gets 50% weight, current gets 100%.

**Why it matters:**
Recommended default for production because it eliminates the boundary burst problem while using minimal memory. True sliding windows require storing every request timestamp, consuming O(n) memory where n is the limit. This uses O(1) memory (just two counters) regardless of limit size.

**Implementation:**
See `src/fastapi_420/algorithms/sliding_window.py:31-43`. The algorithm delegates to storage backends that handle the weighted calculation atomically.

### Token Bucket

**What it is:**
Imagine a bucket that holds tokens. Each request consumes one token. Tokens refill at a constant rate. If the bucket is empty, requests are rejected. The bucket has a maximum capacity, allowing bursts up to that size.

Implementation at `src/fastapi_420/storage/lua/token_bucket.lua:17-26`:
```lua
local elapsed = now - last_refill
local tokens_to_add = elapsed * refill_rate
tokens = math.min(capacity, tokens + tokens_to_add)
```

**When to use it:**
APIs that handle file uploads, image processing, or other bursty workloads. A client might be idle for minutes then suddenly upload 10 files. Token bucket allows the burst (if capacity=10) while enforcing average rate over time.

**Tradeoff:**
More complex to reason about than fixed/sliding windows. Clients must understand both the burst capacity and refill rate. Documentation becomes harder: "You can make 100 requests immediately, then 1.67 requests per second thereafter" vs simple "100 per minute."

### Fixed Window

**What it is:**
Divide time into fixed windows (00:00-00:59, 01:00-01:59). Count requests in the current window. Reset counter when window expires.

Implementation at `src/fastapi_420/storage/lua/fixed_window.lua:13-16`:
```lua
local current_window = math.floor(now / window_seconds)
local window_key = key .. ":" .. current_window
local count = redis.call('GET', window_key) or 0
```

**Boundary burst problem:**
At 12:00:59, client makes 100 requests (limit reached).
At 12:01:00, window resets. Client makes 100 more requests.
Result: 200 requests in 2 seconds, violating the intended "100/minute" limit by 100%.

This is exploitable. An attacker who knows your window boundaries can double their effective rate.

**When to use it:**
Only if you need absolute simplicity and can tolerate boundary bursts. For example, internal admin tools where precision doesn't matter.

## Client Fingerprinting

### What It Is

Identifying who is making a request. Sounds simple: just use the IP address. But it's not that simple.

**Problem 1: NAT and proxies**
An office building might have 500 employees sharing one public IP via NAT. If you rate limit by IP, all 500 people share the same limit. One person's API abuse blocks everyone.

**Problem 2: IPv6 /64 blocks**
Users control entire /64 IPv6 prefixes (18 quintillion addresses). An attacker can rotate through millions of IPs without limitation. The solution at `src/fastapi_420/fingerprinting/ip.py:89-107` normalizes IPv6 addresses to their /64 prefix, treating all IPs in a block as one identity.

**Problem 3: Mobile networks**
Mobile carriers use carrier-grade NAT (CGNAT). Your IP changes every few minutes as you move between cell towers. IP-based rate limiting breaks legitimate mobile users.

### Why It Matters

In 2020, Nike's SNKRS app suffered from bot attacks during limited sneaker releases. Bots used residential proxy networks (real IP addresses from home users) to bypass IP-based limits. Nike's rate limiting was ineffective because each bot request came from a different, legitimate-looking IP.

The solution is composite fingerprinting. Combine multiple attributes:
- IP address (normalized for IPv6)
- User-Agent string
- Accept-Language and Accept-Encoding headers
- TLS fingerprint (JA3)
- Authentication token
- Geographic ASN

See `src/fastapi_420/fingerprinting/composite.py:96-163` for how these combine into a unique fingerprint.

### How It Works

The `CompositeFingerprinter` has three preset levels:

**Relaxed**: IP + Auth only
Best for: Internal APIs where users authenticate and IPs are stable.

**Normal** (default): IP + User-Agent + Auth
Best for: Most public APIs. Balances accuracy with false positive rate.

**Strict**: All attributes including headers hash, TLS fingerprint, geo
Best for: High-security APIs where you can tolerate some legitimate users being fingerprinted differently across sessions.

Example fingerprint from `src/fastapi_420/fingerprinting/composite.py:96-125`:
```
Normal level: "192.168.1.1:Mozilla/5.0...:user_abc123"
Strict level: "192.168.1.1:Mozilla/5.0...:en-US:gzip:8a3bc9:user_abc123:ja3_hash:AS15169"
```

### Common Pitfalls

**Mistake 1: Trusting X-Forwarded-For blindly**
```python
# Bad
client_ip = request.headers.get("X-Forwarded-For").split(",")[0]

# Good - from src/fastapi_420/fingerprinting/ip.py:61-81
def _parse_x_forwarded_for(self, header, request):
    ips = [ip.strip() for ip in header.split(",")]
    
    # Walk backwards, stop at first untrusted IP
    for ip in reversed(ips):
        if ip not in self.trusted_proxies:
            return ip
    
    return ips[0]  # All IPs are trusted proxies
```

Anyone can send an `X-Forwarded-For` header. If you don't validate it against trusted proxy IPs, attackers can spoof their identity.

**Mistake 2: Hashing the entire User-Agent**
User-Agent changes with browser updates. `Mozilla/5.0 (Version 120.0)` becomes `Mozilla/5.0 (Version 121.0)` next month. If you hash the full string, legitimate users appear as new clients after every browser update, bypassing limits.

Better: Extract just the browser and platform, ignore version: `Mozilla/5.0 (Windows)` instead of full string.

## Circuit Breakers

### What It Is

A circuit breaker monitors system load and automatically switches between states:

**Closed** (normal): All requests allowed, circuit monitors error rate
**Open** (emergency): Reject most requests immediately, bypass rate limit checks
**Half-open** (recovery): Allow limited traffic to test if system recovered

Implementation at `src/fastapi_420/defense/circuit_breaker.py:35-57`:
```python
async def check(self, storage):
    now = time.time()
    
    if self._state.is_open:
        if now - self._state.last_failure_time >= self.recovery_time:
            await self._enter_half_open()
            return True  # Allow request to test recovery
        return False  # Circuit still open
    
    request_count = await self._get_request_count(storage)
    
    if request_count >= self.threshold:
        await self._trip(now)  # Open the circuit
        return False
```

### Why It Matters

During a DDoS attack, your rate limiter itself becomes a bottleneck. Checking limits requires database queries (Redis lookups). If you're getting 1 million requests/second, that's 1 million Redis queries/second. Redis will fall over.

The circuit breaker says: "We're under attack. Stop checking individual limits. Just reject everything except authenticated users." This reduces load on Redis from 1 million queries/second to near zero, allowing the system to survive.

The February 2020 AWS outage in US-East-1 was partially caused by cascading failures when one service couldn't handle load, causing other services to retry repeatedly, making the problem worse. Circuit breakers prevent retry storms.

### Defense Modes

Configured at `src/fastapi_420/config.py:85-94`, the circuit breaker supports different strategies:

**Adaptive**: Allow authenticated users, block anonymous
Use when: Most attacks come from unauthenticated bots

**Lockdown**: Block almost everything, allow only known-good clients
Use when: Under severe attack, acceptable to block some legitimate traffic temporarily

**Challenge**: Return CAPTCHA challenges instead of hard blocks
Not implemented in base project but shown in challenges section

**Disabled**: No circuit breaker
Use when: You have dedicated DDoS protection in front (Cloudflare, Akamai)

## HTTP 420 "Enhance Your Calm"

This project uses HTTP 420 instead of the standard 429 (Too Many Requests). Why?

HTTP 420 was originally used by Twitter's API in 2010-2015 with the text "Enhance Your Calm" when clients hit rate limits. It's not an official status code (IANA-registered codes stop at 418), but it's become a semi-standard for rate limiting in the API community.

Benefits:
- Immediately recognizable to developers familiar with Twitter's API
- The message "Enhance Your Calm" is more friendly than "Too Many Requests"
- Easy to filter in logs: `grep "420" access.log`

The implementation at `src/fastapi_420/exceptions.py:40-68` includes proper headers:
```python
HTTP/1.1 420 Enhance Your Calm
RateLimit-Limit: 100
RateLimit-Remaining: 0
RateLimit-Reset: 45
Retry-After: 45
```

These headers follow the IETF draft standard for rate limit headers, making them compatible with client libraries that understand 429 responses.

## Industry Standards and Frameworks

### OWASP Top 10

This project addresses:
- **A01:2021 - Broken Access Control** - Rate limiting prevents brute force authentication attacks. Without limits on `/login`, attackers can try millions of password combinations.
- **A04:2021 - Insecure Design** - Implementing proper rate limiting from the start is secure design. Adding it later is harder and often incomplete.
- **A05:2021 - Security Misconfiguration** - The config validation at `src/fastapi_420/config.py:165-179` ensures rate limits are actually enabled and properly configured before startup.

### MITRE ATT&CK

Relevant techniques this project defects or prevents:
- **T1110.001** - Password Guessing: Rate limiting login endpoints stops brute force attacks
- **T1110.003** - Password Spraying: Per-user limits prevent trying common passwords across many accounts
- **T1498** - Network Denial of Service: Circuit breaker and global limits mitigate application-layer DDoS
- **T1496** - Resource Hijacking: Prevents abuse of compute-heavy endpoints (ML inference, rendering)

### CWE

Common weakness enumerations covered:
- **CWE-770** - Allocation of Resources Without Limits: The entire purpose of this project
- **CWE-307** - Improper Restriction of Excessive Authentication Attempts: Solved by rate limiting auth endpoints
- **CWE-799** - Improper Control of Interaction Frequency: Broad category, rate limiting is the mitigation

## Real World Examples

### Case Study 1: GitHub's Approach

GitHub's API uses a sophisticated rate limiting system described in their docs. For authenticated users: 5000 requests/hour. For OAuth apps: varies by scope. For unauthenticated requests: 60/hour per IP.

Key lesson: Different limits for different authentication levels. The implementation in `examples/app.py:42-70` shows this pattern:
```python
auth_limiter = ScopedRateLimiter(
    endpoint_rules={
        "POST:/auth/login": ["3/minute", "10/hour"],      # Strict
        "POST:/auth/register": ["2/minute", "5/hour"],    # Very strict
    }
)

user_limiter = ScopedRateLimiter(
    default_rules=["60/minute", "500/hour"],              # Relaxed for authenticated
)
```

### Case Study 2: The 2016 Dyn DDoS Attack

On October 21, 2016, a massive DDoS attack took down major sites including Twitter, Netflix, Reddit. The attack used the Mirai botnet (millions of compromised IoT devices) to flood Dyn's DNS servers.

Traditional per-IP rate limiting failed because:
1. Traffic came from millions of unique IPs (distributed attack)
2. Each individual IP stayed under limits
3. The aggregate exceeded capacity by 100x

Defense required: Global endpoint limits + circuit breakers. When total traffic to `/dns-query` exceeded threshold, the circuit breaker should have rejected most requests immediately instead of trying to process them all.

This project's three-layer defense (`src/fastapi_420/defense/layers.py:47-84`) addresses this exact scenario. Layer 1 (per-user) won't help. Layer 2 (per-endpoint global) starts blocking when endpoint traffic exceeds `ENDPOINT_LIMIT_MULTIPLIER` (default 10x user limit). Layer 3 (circuit breaker) provides last-resort protection.

## Testing Your Understanding

Before moving to architecture, make sure you can answer:

1. You have a 100/minute fixed window limit. At 12:00:30, a client has made 50 requests. At what time does their counter reset? Can they make 100 more requests at 12:00:59?

2. Your API serves both mobile and desktop users. Mobile users share IPs due to carrier NAT. How do you implement rate limiting that doesn't unfairly penalize mobile users? What attributes do you fingerprint?

3. An attacker controls a /64 IPv6 block (18 quintillion addresses). You're rate limiting by IP. How many requests can they make before hitting your 100/minute limit? How do you fix this?

If these questions feel unclear, re-read the relevant sections. The implementation will make more sense once these fundamentals click.

## Further Reading

**Essential:**
- [IETF Rate Limit Headers Draft](https://datatracker.ietf.org/doc/draft-ietf-httpapi-ratelimit-headers/) - Standard for RateLimit-* headers this project implements
- [Redis Lua Scripting](https://redis.io/docs/interact/programmability/eval-intro/) - How atomic operations work

**Deep dives:**
- [Generic Cell Rate Algorithm](https://en.wikipedia.org/wiki/Generic_cell_rate_algorithm) - The telecom algorithm that inspired token bucket
- [Stripe's Rate Limiting](https://stripe.com/blog/rate-limiters) - How a major API company thinks about rate limiting

**Historical context:**
- [Twitter's API History](https://developer.twitter.com/en/docs/rate-limits) - Origin of HTTP 420 status code
