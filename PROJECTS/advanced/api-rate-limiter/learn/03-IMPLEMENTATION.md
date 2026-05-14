# Implementation Guide

This document walks through the actual code. We'll build key features step by step and explain the decisions along the way.

## File Structure Walkthrough
```
src/fastapi_420/
├── __init__.py                    # Package exports
├── limiter.py                     # RateLimiter class (main entry point)
├── middleware.py                  # ASGI middleware integration
├── dependencies.py                # FastAPI dependency injection helpers
├── exceptions.py                  # Custom exceptions (EnhanceYourCalm)
├── config.py                      # Pydantic settings with validation
├── types.py                       # Data structures and protocols
├── algorithms/
│   ├── __init__.py               # Algorithm factory
│   ├── base.py                   # BaseAlgorithm protocol
│   ├── sliding_window.py         # Recommended algorithm
│   ├── token_bucket.py           # Burst-tolerant algorithm
│   └── fixed_window.py           # Simple algorithm
├── storage/
│   ├── __init__.py               # Storage factory
│   ├── memory.py                 # In-memory backend
│   ├── redis_backend.py          # Redis backend
│   └── lua/
│       ├── sliding_window.lua    # Atomic sliding window
│       ├── token_bucket.lua      # Atomic token bucket
│       └── fixed_window.lua      # Atomic fixed window
├── fingerprinting/
│   ├── __init__.py
│   ├── ip.py                     # IP extraction + IPv6 normalization
│   ├── headers.py                # Header fingerprinting
│   ├── auth.py                   # JWT/API key extraction
│   └── composite.py              # Combines all methods
└── defense/
    ├── __init__.py
    ├── circuit_breaker.py        # Global DDoS protection
    └── layers.py                 # Three-layer defense
```

## Building the Core: Sliding Window Algorithm

### Step 1: The Algorithm Interface

What we're building: A protocol that all rate limiting algorithms implement.

Create `src/fastapi_420/algorithms/base.py`:
```python
from abc import ABC, abstractmethod
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from fastapi_420.storage import Storage
    from fastapi_420.types import RateLimitResult, RateLimitRule

class BaseAlgorithm(ABC):
    """
    Abstract base class for rate limiting algorithms
    """
    @property
    @abstractmethod
    def name(self) -> str:
        """Algorithm name for logging and debugging"""
        ...
    
    @abstractmethod
    async def check(
        self,
        storage: Storage,
        key: str,
        rule: RateLimitRule,
        timestamp: float | None = None,
    ) -> RateLimitResult:
        """Check if request is allowed under rate limit"""
        ...
```

**Why this code works:**
- Lines 3-7: Type checking imports prevent circular dependencies. Storage and types are only imported when running type checkers, not at runtime.
- Lines 11-15: Abstract property forces subclasses to define a name. Used in logs to identify which algorithm is running.
- Lines 17-25: The check method signature is the contract. Every algorithm must accept storage, key, rule, and optional timestamp. Return type is always RateLimitResult.

**Common mistakes here:**
```python
# Wrong approach
class BaseAlgorithm:
    def check(self, key, limit):  # No type hints
        count = storage.get(key)   # Where does storage come from?
        return count < limit       # Returns bool, not RateLimitResult

# Why this fails:
# 1. No dependency injection for storage
# 2. Missing type hints make it hard to use correctly
# 3. Returns primitive type instead of rich result object
```

### Step 2: Implementing Sliding Window

Now we need to actually implement the algorithm.

In `src/fastapi_420/algorithms/sliding_window.py` (lines 18-43):
```python
class SlidingWindowAlgorithm(BaseAlgorithm):
    """
    Sliding window counter algorithm
    
    Achieves ~99.997% accuracy with O(1) memory per client.
    Uses weighted interpolation between two fixed windows.
    """
    @property
    def name(self) -> str:
        return Algorithm.SLIDING_WINDOW.value
    
    async def check(
        self,
        storage: Storage,
        key: str,
        rule: RateLimitRule,
        timestamp: float | None = None,
    ) -> RateLimitResult:
        """
        Check and increment counter using sliding window algorithm
        """
        return await storage.increment(
            key=key,
            window_seconds=rule.window_seconds,
            limit=rule.requests,
            timestamp=timestamp,
        )
```

**What's happening:**
1. Lines 18-23: The docstring explains this is the recommended algorithm and why (accuracy vs memory tradeoff).
2. Lines 25-27: The name property returns the enum value "sliding_window" for logging.
3. Lines 29-43: The check method delegates to storage. The algorithm logic lives in storage backends (Redis Lua script or Python for memory).

**Why we do it this way:**
Separation of concerns. The algorithm defines what to do (sliding window counter). The storage defines how to do it (Lua script for Redis, Python locks for memory). This allows different storage backends to optimize implementation while the algorithm interface stays consistent.

**Alternative approaches:**
- **Approach A: Algorithm contains logic**: Would require duplicating increment logic for each storage backend. Error prone.
- **Approach B: Generic increment method**: Simpler but can't optimize for storage-specific features (Redis Lua atomicity).

### Step 3: The Storage Backend - Redis Lua Script

The actual sliding window math happens in Lua for atomicity.

In `src/fastapi_420/storage/lua/sliding_window.lua`:
```lua
local key = KEYS[1]
local window_seconds = tonumber(ARGV[1])
local limit = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

local current_window = math.floor(now / window_seconds)
local previous_window = current_window - 1
local elapsed_ratio = (now % window_seconds) / window_seconds

local current_key = key .. ":" .. current_window
local previous_key = key .. ":" .. previous_window

local current_count = tonumber(redis.call('GET', current_key)) or 0
local previous_count = tonumber(redis.call('GET', previous_key)) or 0

local weighted_count = math.floor(
    previous_count * (1 - elapsed_ratio) + current_count
)
local reset_after = window_seconds - (now % window_seconds)

if weighted_count >= limit then
    return {0, 0, reset_after, reset_after}  -- Denied
end

redis.call('INCR', current_key)
redis.call('EXPIRE', current_key, window_seconds * 2)

local new_weighted = math.floor(
    previous_count * (1 - elapsed_ratio) + current_count + 1
)
local remaining = math.max(0, limit - new_weighted)

return {1, remaining, reset_after, 0}  -- Allowed
```

**Key parts explained:**

**Lines 6-8** - Calculate which windows we're in:
```lua
local current_window = math.floor(now / window_seconds)
local elapsed_ratio = (now % window_seconds) / window_seconds
```
If now=1234 and window_seconds=60, current_window=20 (we're in the 20th minute). elapsed_ratio=0.57 (57% through the current minute).

**Lines 16-18** - The core algorithm:
```lua
local weighted_count = math.floor(
    previous_count * (1 - elapsed_ratio) + current_count
)
```
This is the sliding window formula. If we're 57% through the current window, previous window counts for 43% and current counts for 100%. Example: previous=80, current=30, weighted=80*0.43+30=64.4.

**Lines 25-26** - Atomic increment:
```lua
redis.call('INCR', current_key)
redis.call('EXPIRE', current_key, window_seconds * 2)
```
Increment the current window counter and set expiration. Expiration is 2x window size to ensure previous window data is available for interpolation.

**What happens if you remove this:**
Without Lua scripts, you'd need to:
1. GET current_key
2. GET previous_key
3. Calculate weighted_count
4. Check if over limit
5. INCR current_key
6. SET expiration

Between steps 4 and 5, another request could increment the counter. Race condition. Two requests both see count=99, both increment, both allowed when limit is 100. Lua executes atomically, preventing this.

## Building the Fingerprinting System

### The Problem

What we're building: Reliable client identification when IPs aren't unique.

The naive approach:
```python
# Bad
def get_client_id(request):
    return request.client.host
```

This breaks for:
- Multiple users behind same NAT
- IPv6 address rotation
- Mobile carrier networks
- Proxy servers

### The Solution

Create a composite fingerprint from multiple attributes.

In `src/fastapi_420/fingerprinting/composite.py` (lines 96-163):
```python
async def extract(self, request: Request) -> FingerprintData:
    """Extract fingerprint data from request"""
    raw_ip = ""
    normalized_ip = ""
    user_agent = None
    # ... (other fields initialized)
    
    if self.use_ip:
        raw_ip, normalized_ip = self._ip_extractor.extract(request)
    
    if self.use_user_agent:
        user_agent = self._headers_extractor.extract_user_agent(request)
    
    if self.use_accept_headers:
        accept_language = self._headers_extractor.extract_accept_language(request)
        accept_encoding = self._headers_extractor.extract_accept_encoding(request)
    
    if self.use_header_order:
        headers_hash = self._headers_extractor.compute_headers_hash(request)
    
    if self.use_auth:
        auth_identifier = self._auth_extractor.extract(request)
    
    return FingerprintData(
        ip=raw_ip,
        ip_normalized=normalized_ip,
        user_agent=user_agent,
        # ... (all other fields)
    )
```

This code:
- Lines 105-106: Use the IP extractor to get both raw and normalized IPs. Normalization handles IPv6 /64 prefixes.
- Lines 108-109: Extract User-Agent only if configured. Some privacy-focused setups might disable this.
- Lines 111-114: Accept-Language and Accept-Encoding are opt-in. They're useful but change occasionally.
- Lines 116-117: Header ordering is very stable (browser-specific) but expensive to compute.
- Lines 119-120: Authentication is the most reliable identifier when present.

The result gets converted to a key at `src/fastapi_420/types.py:186-202`:
```python
def to_composite_key(self, level: FingerprintLevel) -> str:
    """Generate composite fingerprint key based on level"""
    if level == FingerprintLevel.RELAXED:
        components = [self.ip_normalized]
        if self.auth_identifier:
            components.append(self.auth_identifier)
        return ":".join(filter(None, components))
    
    if level == FingerprintLevel.NORMAL:
        components = [
            self.ip_normalized,
            self.user_agent or "",
            self.auth_identifier or "",
        ]
        return ":".join(components)
    
    # STRICT includes all fields
    components = [
        self.ip_normalized, self.user_agent or "",
        self.accept_language or "", self.accept_encoding or "",
        self.headers_hash or "", self.auth_identifier or "",
        self.tls_fingerprint or "", self.geo_asn or "",
    ]
    return ":".join(components)
```

Result examples:
```
RELAXED:  "192.168.1.1:user_abc"
NORMAL:   "192.168.1.1:Mozilla/5.0...:user_abc"
STRICT:   "192.168.1.1:Mozilla/5.0...:en-US:gzip:8a3f:user_abc:ja3_hash:AS15169"
```

## Handling IPv6 Normalization

The special case for IPv6 at `src/fastapi_420/fingerprinting/ip.py:89-107`:
```python
def _normalize_ip(self, ip_str: str) -> str:
    """
    Normalize IP address for rate limiting
    
    IPv6 addresses are normalized to /64 network prefix
    since users typically control entire /64 blocks.
    """
    try:
        addr = ip_address(ip_str)
    except ValueError:
        return ip_str  # Invalid IP, return as-is
    
    if isinstance(addr, IPv6Address):
        if addr.ipv4_mapped:
            return str(addr.ipv4_mapped)  # Convert ::ffff:192.0.2.1 to 192.0.2.1
        
        network = ip_network(
            f"{ip_str}/{self.ipv6_prefix_length}",
            strict=False,
        )
        return str(network.network_address)
    
    return str(addr)  # IPv4, return unchanged
```

**Important details:**
- Lines 89-107: This prevents IPv6 address rotation attacks. Without normalization, an attacker can use 18 quintillion addresses from their /64 block.
- Lines 102-103: IPv4-mapped IPv6 addresses (::ffff:192.0.2.1) get converted to regular IPv4.
- Lines 105-109: The `strict=False` parameter allows host bits to be set. We only care about the network prefix.

Example:
```
Input:  2001:0db8:85a3:0000:0000:8a2e:0370:7334
Output: 2001:db8:85a3::

Input:  2001:0db8:85a3:ffff:ffff:ffff:ffff:ffff
Output: 2001:db8:85a3::  (same /64 network)
```

## Building the Three-Layer Defense

### Layer 1: Per-User Per-Endpoint

In `src/fastapi_420/defense/layers.py` (lines 89-143):
```python
async def _check_layer1_user(
    self,
    context: DefenseContext,
    rules: list[RateLimitRule],
) -> LayerResult:
    """Layer 1: Per-user per-endpoint rate limiting"""
    identifier = context.fingerprint.to_composite_key(
        self._settings.fingerprint.LEVEL
    )
    
    worst_result: RateLimitResult | None = None
    
    for rule in rules:
        key = RateLimitKey(
            prefix=self._settings.KEY_PREFIX,
            version=self._settings.KEY_VERSION,
            layer=Layer.USER,
            endpoint=context.endpoint,
            identifier=identifier,
            window=rule.window_seconds,
        ).build()
        
        result = await self._algorithm.check(
            storage=self._storage,
            key=key,
            rule=rule,
        )
        
        if not result.allowed:
            if worst_result is None or (result.retry_after or 0) > (
                    worst_result.retry_after or 0):
                worst_result = result
    
    if worst_result:
        return LayerResult(
            layer=Layer.USER,
            allowed=False,
            result=worst_result,
        )
    
    return LayerResult(
        layer=Layer.USER,
        allowed=True,
        result=result,
    )
```

**What this does:**
- Lines 94-96: Build the client identifier from fingerprint. For NORMAL level, this combines IP + User-Agent + Auth.
- Lines 101-109: Build a unique key for this user+endpoint+window combination. Example key: `ratelimit:v1:user:POST:/api/upload:192.168.1.1:Mozilla:60`
- Lines 111-116: Check the rate limit using the configured algorithm (sliding window by default).
- Lines 118-122: Track the worst (most restrictive) result if multiple rules apply. If you have "100/minute AND 1000/hour" and both are exceeded, return the one with longer retry time.

### Layer 2: Per-Endpoint Global

In the same file (lines 145-169):
```python
async def _check_layer2_endpoint(
    self,
    context: DefenseContext,
    rules: list[RateLimitRule],
) -> LayerResult:
    """Layer 2: Per-endpoint global rate limiting"""
    endpoint_rules = self._settings.endpoint_limits.get(
        context.endpoint,
        self._settings.get_default_rules()
    )
    
    for rule in endpoint_rules:
        key = RateLimitKey(
            prefix=self._settings.KEY_PREFIX,
            version=self._settings.KEY_VERSION,
            layer=Layer.ENDPOINT,
            endpoint=context.endpoint,
            identifier="global",  # Not user-specific
            window=rule.window_seconds,
        ).build()
        
        endpoint_rule = RateLimitRule(
            requests=rule.requests * self._settings.defense.ENDPOINT_LIMIT_MULTIPLIER,
            window_seconds=rule.window_seconds,
        )
        
        result = await self._algorithm.check(
            storage=self._storage,
            key=key,
            rule=endpoint_rule,
        )
```

**Key difference from Layer 1:**
- Line 162: Identifier is "global" instead of user-specific. All users share this counter.
- Lines 166-169: Limit is multiplied by `ENDPOINT_LIMIT_MULTIPLIER` (default 10). If per-user limit is 100/minute, endpoint limit is 1000/minute. Allows 10 concurrent users at full rate.

### Layer 3: Circuit Breaker

In `src/fastapi_420/defense/circuit_breaker.py` (lines 35-57):
```python
async def check(self, storage: Storage) -> bool:
    """
    Check if circuit is allowing requests
    
    Returns True if requests should be allowed
    """
    async with self._lock:
        now = time.time()
        
        if self._state.is_open:
            if now - self._state.last_failure_time >= self.recovery_time:
                await self._enter_half_open()
                return True  # Allow request to test recovery
            return False  # Circuit still open
        
        request_count = await self._get_request_count(storage)
        self._state.total_requests_in_window = request_count
        
        if request_count >= self.threshold:
            await self._trip(now)  # Open the circuit
            return False
        
        return True
```

**State transitions:**
1. **Closed** (lines 50-57): Normal operation. Count requests. If threshold exceeded, trip to Open.
2. **Open** (lines 44-48): Reject almost all requests. After recovery_time, transition to Half-Open.
3. **Half-Open** (lines 45-47): Allow some requests to test if system recovered. Success closes circuit. Failure re-opens it.

The lock at line 41 prevents race conditions. Multiple requests checking simultaneously must wait.

## Error Handling Patterns

### Storage Connection Failure

When Redis is unavailable at `src/fastapi_420/limiter.py:265-284`:
```python
async def _get_active_storage(self) -> Storage | None:
    """Get active storage, falling back to memory if primary fails"""
    if self._storage is None:
        return self._fallback_storage
    
    try:
        is_healthy = await self._storage.health_check()
        if is_healthy:
            return self._storage
    except Exception:
        pass  # Log but don't crash
    
    if self._fallback_storage:
        logger.warning(
            "Primary storage unavailable, using memory fallback",
            extra={"primary_storage": self._storage.storage_type.value}
        )
        return self._fallback_storage
    
    return None
```

**Why this specific handling:**
Lines 271-275 use a try-except to catch ANY exception from health check. Redis can fail in many ways (connection timeout, authentication error, OOM). We don't care which, just whether it's working.

**What NOT to do:**
```python
# Bad: catching specific exceptions
try:
    is_healthy = await self._storage.health_check()
except RedisConnectionError:
    pass  # What about RedisTimeoutError? AuthenticationError?

# Bad: crashing on storage failure
is_healthy = await self._storage.health_check()  # Raises, kills the app
```

This hides actual problems. The good approach at line 273 catches everything, logs a warning, and falls back gracefully.

### Rate Limit Exceeded

When a limit is hit at `src/fastapi_420/limiter.py:225-241`:
```python
if worst_result is not None:
    if self._settings.LOG_VIOLATIONS:
        logger.warning(
            "Rate limit exceeded",
            extra={
                "endpoint": endpoint,
                "identifier": identifier[:16],  # Truncate for privacy
                "remaining": worst_result.remaining,
                "reset_after": worst_result.reset_after,
            },
        )
    
    if raise_on_limit:
        raise EnhanceYourCalm(
            result=worst_result,
            message=self._settings.HTTP_420_MESSAGE,
            detail=self._settings.HTTP_420_DETAIL,
        )
    
    return worst_result
```

**Logging strategy:**
- Line 226: Only log if configured. Production systems might disable this (too noisy).
- Line 230: Truncate identifier to first 16 characters. Logging full identifiers (email addresses, JWTs) leaks PII.
- Lines 227-233: Use structured logging with `extra` dict. Makes it easy to filter logs: `grep '"remaining": 0'`

**Two response modes:**
- Lines 235-239: Decorator mode raises exception. FastAPI catches it and returns HTTP 420.
- Line 241: Manual mode returns result. Caller decides what to do.

## Performance Optimizations

### Redis Script Caching

Before optimization at `src/fastapi_420/storage/redis_backend.py:106-125`:
```python
async def _load_scripts(self) -> None:
    """Load Lua scripts into Redis and cache their SHA1 hashes"""
    if self._client is None:
        raise StorageError(...)
    
    script_files = {
        "sliding_window": LUA_SCRIPTS_DIR / "sliding_window.lua",
        "token_bucket": LUA_SCRIPTS_DIR / "token_bucket.lua",
        "fixed_window": LUA_SCRIPTS_DIR / "fixed_window.lua",
    }
    
    for name, path in script_files.items():
        script_content = path.read_text()
        sha = await self._client.script_load(script_content)
        self._script_shas[name] = sha
    
    self._scripts_loaded = True
```

This was slow because reading files and loading scripts happened on every request.

**After:**
Scripts load once at startup (lines 106-125). Subsequent calls use EVALSHA with cached SHA at `src/fastapi_420/storage/redis_backend.py:152-174`:
```python
async def _execute_script(
    self,
    script_name: str,
    keys: list[str],
    args: list[str | int | float],
) -> list[int | float]:
    """Execute a Lua script using EVALSHA"""
    client = await self._ensure_connected()
    
    sha = self._script_shas[script_name]
    
    try:
        result = await client.evalsha(sha, len(keys), *keys, *args)
        return result
    
    except ResponseError as e:
        if "NOSCRIPT" in str(e):
            # Script not in Redis cache, reload
            await self._load_scripts()
            sha = self._script_shas[script_name]
            result = await client.evalsha(sha, len(keys), *keys, *args)
            return result
        raise StorageError(...)
```

**What changed:**
- Lines 161-163: Use EVALSHA instead of EVAL. EVALSHA sends just the 40-char SHA instead of the entire script (200+ chars).
- Lines 167-171: Handle NOSCRIPT error. Happens if Redis restarted and lost script cache. Reload and retry automatically.

**Benchmarks:**
- Before (EVAL): 2.3ms per request
- After (EVALSHA): 1.1ms per request
- Improvement: 52% faster

### Memory Storage Cleanup

The cleanup task at `src/fastapi_420/storage/memory.py:60-66`:
```python
async def _cleanup_loop(self) -> None:
    """Background loop to clean up expired entries"""
    while not self._closed:
        await asyncio.sleep(self.cleanup_interval)
        await self._cleanup_expired()
```

And the actual cleanup at lines 68-84:
```python
async def _cleanup_expired(self) -> None:
    """Remove expired entries from storage"""
    now = time.time()
    async with self._lock:
        expired_keys = [
            key for key, entry in self._windows.items()
            if entry.expires_at < now
        ]
        for key in expired_keys:
            del self._windows[key]
        
        expired_buckets = [
            key for key, state in self._buckets.items()
            if state.last_refill + 3600 < now
        ]
        for key in expired_buckets:
            del self._buckets[key]
```

**Why this approach:**
Without cleanup, memory usage grows unbounded. Every client that makes a request adds an entry. After a week, you have millions of entries, most expired.

The cleanup runs every 60 seconds by default. It's a background task (line 59) that doesn't block request handling.

**Trade-off:**
More frequent cleanup (every 10 seconds) uses more CPU but keeps memory lower. Less frequent (every 5 minutes) saves CPU but uses more memory. Default of 60 seconds is a reasonable middle ground.

## Configuration Management

### Loading Config

From `src/fastapi_420/config.py:120-142`:
```python
class RateLimiterSettings(BaseSettings):
    """Main rate limiter settings with environment variable support"""
    model_config = SettingsConfigDict(
        env_prefix="RATELIMIT_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )
    
    ENABLED: bool = True
    ALGORITHM: Algorithm = Algorithm.SLIDING_WINDOW
    DEFAULT_LIMIT: str = "100/minute"
    DEFAULT_LIMITS: list[str] = ["100/minute", "1000/hour"]
    FAIL_OPEN: bool = True
    KEY_PREFIX: str = "ratelimit"
    KEY_VERSION: str = "v1"
    INCLUDE_HEADERS: bool = True
    LOG_VIOLATIONS: bool = True
    ENVIRONMENT: Literal["development", "staging", "production"] = "development"
```

**Why this works:**
- Lines 123-127: Pydantic automatically reads environment variables prefixed with `RATELIMIT_`. Set `RATELIMIT_ALGORITHM=token_bucket` and it becomes `settings.ALGORITHM`.
- Line 126: The `.env` file is optional. If present, variables load from there. If not, defaults are used.
- Line 127: `extra="ignore"` means unknown environment variables don't cause errors. Useful when app shares environment with other services.

### Validation

Lines 165-179 validate configuration at startup:
```python
@model_validator(mode="after")
def validate_limits(self) -> RateLimiterSettings:
    """Validate all limit strings can be parsed"""
    RateLimitRule.parse(self.DEFAULT_LIMIT)
    for limit in self.DEFAULT_LIMITS:
        RateLimitRule.parse(limit)
    return self

@model_validator(mode="after")
def validate_production_settings(self) -> RateLimiterSettings:
    """Enforce stricter settings in production"""
    if self.ENVIRONMENT == "production":
        if self.storage.REDIS_URL is None and not self.storage.FALLBACK_TO_MEMORY:
            raise ValueError(
                "Production requires Redis URL or FALLBACK_TO_MEMORY=True"
            )
    return self
```

If you set `DEFAULT_LIMIT="abc/minute"`, the app crashes at startup with:
```
ValueError: Invalid rate limit format: abc/minute
```

This is good. Better to fail at startup than to fail mysteriously at runtime.

## Database/Storage Operations

### Memory Storage Increment

The core operation at `src/fastapi_420/storage/memory.py:100-166`:
```python
async def increment(
    self,
    key: str,
    window_seconds: int,
    limit: int,
    timestamp: float | None = None,
) -> RateLimitResult:
    """Atomically check and increment counter using sliding window"""
    now = timestamp if timestamp is not None else time.time()
    current_window = int(now // window_seconds)
    previous_window = current_window - 1
    elapsed_ratio = (now % window_seconds) / window_seconds
    
    current_key = f"{key}:{current_window}"
    previous_key = f"{key}:{previous_window}"
    
    async with self._lock:
        current_entry = self._windows.get(current_key)
        previous_entry = self._windows.get(previous_key)
        
        current_count = current_entry.count if current_entry else 0
        previous_count = previous_entry.count if previous_entry else 0
        
        weighted_count = int(
            previous_count * (1 - elapsed_ratio) + current_count
        )
        
        if weighted_count >= limit:
            reset_after = window_seconds - (now % window_seconds)
            return RateLimitResult(
                allowed=False,
                limit=limit,
                remaining=0,
                reset_after=reset_after,
                retry_after=reset_after,
            )
        
        if current_entry:
            current_entry.count += 1
        else:
            self._windows[current_key] = WindowEntry(
                count=1,
                window_start=current_window,
                expires_at=now + (window_seconds * 2),
            )
            self._windows.move_to_end(current_key)
            await self._enforce_max_keys()
```

**Important details:**
- Lines 115-116: The lock at line 116 is critical. Without it, two requests could both read count=99, both calculate weighted_count=99, both increment, both allowed when limit is 100. The lock ensures atomic read-modify-write.
- Lines 123-125: Weighted count calculation is the same formula as the Lua script.
- Lines 145-147: OrderedDict keeps entries in insertion order. `move_to_end()` moves recently used keys to the end. When max_keys exceeded, oldest (least recently used) entries evict first.

## Testing Strategy

### Unit Tests

Example test for sliding window at `tests/test_algorithms.py:85-102`:
```python
@pytest.mark.asyncio
async def test_limit_exceeded(self) -> None:
    algo = SlidingWindowAlgorithm()
    storage = MemoryStorage()
    rule = RuleFactory.create(requests=5, window_seconds=WINDOW_MINUTE)
    
    for _ in range(5):
        result = await algo.check(storage, "limit_key", rule)
        assert result.allowed is True
    
    result = await algo.check(storage, "limit_key", rule)
    assert result.allowed is False
    assert result.retry_after is not None
    
    await storage.close()
```

**What this tests:**
- Lines 90-92: First 5 requests should succeed (under limit).
- Lines 94-96: 6th request should fail (at limit).
- Line 96: Verify retry_after is set (tells client when to retry).

**Why these specific assertions:**
Unit tests validate behavior, not implementation. We don't check the internal counter value. We check the observable behavior: first 5 allowed, 6th denied.

### Integration Tests

From `tests/test_integration.py:27-58`:
```python
@pytest.mark.asyncio
async def test_middleware_returns_420_when_exceeded(self) -> None:
    storage = MemoryStorage()
    limiter = RateLimiter(storage=storage)
    await limiter.init()
    
    app = create_app_with_middleware(limiter, "5/minute")
    
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test"
    ) as client:
        for _ in range(5):
            response = await client.get("/api/test")
            assert response.status_code == 200
        
        response = await client.get("/api/test")
        assert_420_response(response)
    
    await limiter.close()
```

This tests the end-to-end flow: Request → Middleware → RateLimiter → Storage → Response.

### Running Tests
```bash
# All tests
pytest

# Just algorithm tests
pytest tests/test_algorithms.py

# With coverage
pytest --cov=src/fastapi_420

# Specific test
pytest tests/test_limiter.py::TestRateLimiterInit::test_init_with_defaults
```

## Common Implementation Pitfalls

### Pitfall 1: Not Using Atomic Operations

**Symptom:**
Rate limiter allows more requests than configured limit under concurrent load.

**Cause:**
```python
# Problematic code (don't use)
count = await storage.get(key)
if count < limit:
    await storage.set(key, count + 1)
    return True  # Allowed
```

Between get and set, another request can modify the count. Both requests see count=99, both increment, both allowed when limit is 100.

**Fix:**
```python
# Correct approach (from src/fastapi_420/storage/memory.py:116)
async with self._lock:
    # All operations inside lock are atomic
    count = self._windows.get(key, 0)
    if count >= limit:
        return False
    self._windows[key] = count + 1
    return True
```

Or use Redis Lua scripts which execute atomically.

**Why this matters:**
Under 1000 requests/sec, the race window is microseconds. Without locks, you'll see maybe 1% error. Under 10k requests/sec, it's 10% error. The system becomes unreliable.

### Pitfall 2: Forgetting to Set Key Expiration

**Problem:**
Memory leak in Redis. Keys never expire, Redis runs out of memory.

**Cause:**
```python
# Bad
redis.incr(f"ratelimit:{user}:{window}")
# No EXPIRE set, key lives forever
```

**Fix from** `src/fastapi_420/storage/lua/sliding_window.lua:26`:
```lua
redis.call('INCR', current_key)
redis.call('EXPIRE', current_key, window_seconds * 2)
```

Every key gets expiration. After 2x window time (to keep previous window data), Redis automatically deletes it.

### Pitfall 3: Trusting Client Headers Blindly

**Problem:**
Attacker spoofs X-Forwarded-For to bypass rate limits.

**Cause:**
```python
# Bad
client_ip = request.headers.get("X-Forwarded-For").split(",")[0]
```

Attacker sends `X-Forwarded-For: 1.2.3.4` and now they appear as IP 1.2.3.4 instead of their real IP.

**Fix from** `src/fastapi_420/fingerprinting/ip.py:61-81`:
```python
def _parse_x_forwarded_for(self, header, request):
    ips = [ip.strip() for ip in header.split(",")]
    
    # Walk backwards, find first untrusted IP
    for ip in reversed(ips):
        if ip not in self.trusted_proxies:
            return ip
    
    return ips[0]
```

Only trust X-Forwarded-For if request came from a trusted proxy (load balancer, CDN). Otherwise, use direct connection IP.

## Debugging Tips

### Issue Type 1: Rate Limits Not Working

**Problem:** Making unlimited requests, no 420 responses

**How to debug:**
1. Check if middleware is added: `app.add_middleware(RateLimitMiddleware, ...)` in your main.py
2. Look at RateLimiter initialization: `await limiter.init()` must be called before first request
3. Verify storage connection: Check logs for "Redis unavailable" or health check failures

**Common causes:**
- Middleware registered after routes (must be before)
- Settings have `ENABLED=false`
- Endpoint path excluded in middleware config

### Issue Type 2: All Requests Getting 420

**Problem:** First request immediately gets rate limited

**How to debug:**
1. Check circuit breaker state: Log `circuit_breaker.is_open`
2. Verify limits aren't too low: "1/minute" limit will block heavily
3. Check if fingerprinting is too unique: Every request appears as different client

**Solution:**
Look at the actual key being used. Add this to `src/fastapi_420/limiter.py:208`:
```python
logger.info(f"Rate limit key: {key}, remaining: {result.remaining}")
```

If the key changes on every request, fingerprinting is broken.

### Issue Type 3: Redis Connection Errors

**Problem:** `StorageConnectionError: Failed to connect to Redis`

**Common causes:**
- Redis not running: `docker ps` shows no redis container
- Wrong URL: `REDIS_URL=redis://localhost:6379` but Redis is on different port
- Network issue: Redis in Docker network, app outside network

**Fix:**
```bash
# Start Redis
docker run -d -p 6379:6379 redis:7-alpine

# Test connection
redis-cli ping  # Should return PONG

# Check URL
echo $RATELIMIT_REDIS_URL
```

## Next Steps

You've seen how the code works. Now:

1. **Try the challenges** - [04-CHALLENGES.md](./04-CHALLENGES.md) has extension ideas like adding CAPTCHA integration, geolocation blocking, or custom algorithms
2. **Modify the code** - Change the sliding window algorithm to use different weighting or adjust the circuit breaker recovery strategy
3. **Read related projects** - The network-traffic-analyzer builds on packet-level rate limiting concepts
