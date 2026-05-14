# Extension Challenges

You've built the base project. Now make it yours by extending it with new features.

These challenges are ordered by difficulty. Start with the easier ones to build confidence, then tackle the harder ones when you want to dive deeper.

## Easy Challenges

### Challenge 1: Add Custom Rate Limit Headers

**What to build:**
Add custom headers to rate limit responses beyond the standard RateLimit-* headers. Include headers like X-RateLimit-Policy (which rule was hit) and X-RateLimit-Scope (user/endpoint/global).

**Why it's useful:**
Debugging and client-side logic. Clients can see exactly which limit they hit and adjust behavior accordingly. If they hit the per-endpoint limit vs per-user limit, they know whether to slow down across all endpoints or just the current one.

**What you'll learn:**
- Modifying the RateLimitResult data structure
- Adding information to HTTP responses via middleware
- Debugging rate limiting behavior

**Hints:**
- Look at `src/fastapi_420/types.py:66-92` where RateLimitResult is defined. Add new fields for policy name and scope.
- Modify the `headers` property at lines 84-92 to include your new headers.
- Test it by making requests and checking response headers: `curl -i localhost:8000/api/test`

**Test it works:**
```bash
curl -i http://localhost:8000/api/test
# Should see:
# RateLimit-Limit: 100
# RateLimit-Remaining: 99
# X-RateLimit-Policy: default
# X-RateLimit-Scope: user
```

### Challenge 2: Add Endpoint-Specific Limits via Decorator

**What to build:**
Create a decorator that applies different limits to different endpoints without using middleware configuration. Allow developers to write `@rate_limit("10/minute", "100/hour")` directly on route functions.

**Why it's useful:**
More explicit than middleware configuration. Developers see limits directly in code next to the endpoint. Easier to maintain because limits live with the code they protect.

**What you'll learn:**
- Python decorators with parameters
- Preserving function metadata with functools.wraps
- Integrating with FastAPI's dependency injection system

**Hints:**
- Study the existing decorator at `src/fastapi_420/limiter.py:143-177`
- The challenge is making it work without passing request explicitly. Use FastAPI's Depends() to inject request.
- Don't forget to call `functools.wraps(func)` to preserve the original function's name and docstring.

**Test it works:**
```python
@app.get("/custom")
@rate_limit("5/minute")
async def custom_endpoint():
    return {"limited": True}

# Make 5 requests, should work
# 6th request should return HTTP 420
```

### Challenge 3: Add Redis Key Prefix Per Environment

**What to build:**
Automatically prefix Redis keys with environment name (dev/staging/prod) so different environments can share a Redis instance without key collisions.

**Why it's useful:**
Cost savings. Instead of running 3 separate Redis instances, run one with namespaced keys. Development keys don't interfere with production keys.

**What you'll learn:**
- Redis key design patterns
- Environment-based configuration
- Key namespacing strategies

**Hints:**
- Modify `RateLimitKey.build()` at `src/fastapi_420/types.py:354-362` to include environment prefix
- Get environment from settings: `self._settings.ENVIRONMENT`
- Result should be: `dev:ratelimit:v1:user:...` instead of `ratelimit:v1:user:...`

**Test it works:**
```bash
# Set environment
export RATELIMIT_ENVIRONMENT=staging

# Start app, make requests
# Check Redis keys
redis-cli keys "*"
# Should see: staging:ratelimit:v1:user:...
```

## Intermediate Challenges

### Challenge 4: Implement Request Cost Weighting

**What to build:**
Allow different requests to consume different amounts of rate limit "budget." A simple GET might cost 1 point, while an expensive report generation costs 10 points. Clients with 100 points/minute can make 100 simple requests or 10 expensive ones.

**Real world application:**
OpenAI's API uses this pattern. Different models cost different amounts of "tokens." GPT-4 is more expensive than GPT-3.5. Same concept applies to APIs where some endpoints are computationally expensive.

**What you'll learn:**
- Extending rate limiting beyond simple request counting
- Designing flexible APIs that account for resource consumption
- Balancing simplicity with power

**Implementation approach:**

1. **Add cost parameter to check method**
   - Files to create: None (modify existing)
   - Files to modify: `src/fastapi_420/limiter.py:181`, `src/fastapi_420/algorithms/base.py:26`

2. **Multiply counter by cost**
   - Hook into storage increment operations
   - Pass cost to Lua scripts
   - Update sliding window algorithm to handle weighted counts

3. **Test edge cases:**
   - What if cost=0? (Free requests)
   - What if cost=1000 but limit is 100? (Single request exhausts limit)
   - What if cost is negative? (Should reject as invalid)

**Hints:**
- Start by adding an optional `cost: int = 1` parameter to `limiter.check()`
- In the Lua script, change `redis.call('INCR', current_key)` to `redis.call('INCRBY', current_key, cost)`
- For testing, create endpoints with different costs: `/cheap` (cost=1), `/expensive` (cost=10)

**Extra credit:**
Make cost configurable per endpoint via decorator: `@limiter.limit("100/minute", cost=5)`

### Challenge 5: Add CAPTCHA Challenge for Suspicious Clients

**What to build:**
When a client hits rate limits repeatedly, instead of blocking them completely, return a CAPTCHA challenge. If they solve it, allow the request through. Track CAPTCHA success rate per client.

**Real world application:**
Cloudflare's "I'm Under Attack" mode works this way. Suspicious traffic gets CAPTCHA challenges instead of hard blocks. Reduces false positives (blocking legitimate users) while still stopping bots.

**What you'll learn:**
- Integrating third-party services (hCaptcha, reCAPTCHA)
- Progressive enforcement strategies
- Balancing security with user experience

**Implementation approach:**

1. **Track violation count per client**
   - Add counter: "violations:{identifier}" in Redis
   - Increment on rate limit exceeded
   - Reset on successful CAPTCHA

2. **Return CAPTCHA challenge instead of 420**
   - When violations > threshold (e.g., 3), return HTTP 429 with CAPTCHA challenge
   - Response body includes CAPTCHA site key
   - Client solves CAPTCHA, submits solution token

3. **Validate CAPTCHA solution**
   - New endpoint: POST /verify-captcha
   - Validate token with CAPTCHA API
   - If valid, grant temporary bypass (store token in Redis with expiration)

4. **Bypass rate limit with valid CAPTCHA**
   - Check for CAPTCHA bypass token in fingerprint extraction
   - If present and valid, skip rate limit check

**Hints:**
- Use hCaptcha (simpler API than reCAPTCHA)
- Store bypass tokens with 5-minute expiration
- Track CAPTCHA solve rate: `captcha_solved / captcha_presented`

**Testing:**
Can't easily test CAPTCHA in automated tests. Instead:
1. Create mock CAPTCHA verifier that always returns true
2. Inject mock in test environment
3. In production, use real hCaptcha API

### Challenge 6: Implement Geolocation-Based Rate Limits

**What to build:**
Apply different rate limits based on client geographic location. Stricter limits for regions with high bot activity (e.g., limit clients from certain countries to 10/minute vs 100/minute for domestic traffic).

**Real world application:**
E-commerce sites often see bot traffic primarily from certain regions. Applying regional limits reduces fraud without impacting legitimate international customers.

**What you'll learn:**
- IP geolocation databases (MaxMind GeoIP2)
- Policy-based rate limiting
- Geographic discrimination considerations (be careful with this)

**Implementation approach:**

1. **Add geolocation lookup**
   - Library: `geoip2` with MaxMind database
   - On fingerprint extraction, lookup IP address
   - Add country code to FingerprintData

2. **Define geo-based policies**
   - Config: `GEO_LIMITS = {"US": "100/minute", "CN": "10/minute", "default": "50/minute"}`
   - Load from environment or config file

3. **Apply policy at rate limit check**
   - In LayeredDefense, check client's country code
   - Select appropriate limit from GEO_LIMITS
   - Fall back to default if country not configured

4. **Monitor and adjust**
   - Log rate limit violations by country
   - Dashboard showing requests/violations per region

**Hints:**
- MaxMind GeoLite2 database is free but requires registration
- Cache geo lookups (IP to country mapping doesn't change frequently)
- Consider privacy implications. Logging IP addresses with country codes might be PII in some jurisdictions.

**Ethical considerations:**
Geo-based limiting can be discriminatory. Only use it for legitimate security purposes. Document why certain regions have stricter limits. Consider offering CAPTCHA challenge instead of hard blocking.

## Advanced Challenges

### Challenge 7: Build a Rate Limit Dashboard

**What to build:**
Web dashboard showing real-time rate limiting stats. Metrics include requests/sec, top violators, circuit breaker status, algorithm performance. Built with FastAPI + htmx or React.

**Why this is hard:**
Requires collecting metrics without impacting rate limiting performance. Need efficient aggregation of high-frequency events. Must handle dashboard queries without slowing down rate limit checks.

**What you'll learn:**
- High-performance metrics collection
- Time-series data aggregation
- Building admin dashboards
- WebSocket or Server-Sent Events for real-time updates

**Architecture changes needed:**
```
┌─────────────────┐
│  Rate Limiter   │
│  (existing)     │
└────────┬────────┘
         │
         ├─ Check limit (fast path)
         │
         └─ Emit metrics (async, non-blocking)
                  ↓
         ┌────────────────┐
         │ Metrics Buffer │
         │ (in-memory)    │
         └────────┬───────┘
                  │
         Batch write every 5 seconds
                  ↓
         ┌────────────────┐
         │ Redis TimeSeries│
         │ or InfluxDB     │
         └────────┬───────┘
                  │
                  ↓
         ┌────────────────┐
         │   Dashboard    │
         │   (FastAPI)    │
         └────────────────┘
```

**Implementation steps:**

**Phase 1: Metrics Collection** (3-5 hours)
- Add metrics emitter to rate limiter
- Batch metrics in memory buffer
- Flush to Redis every 5 seconds
- Metrics: requests_total, violations_total, latency_histogram

**Phase 2: Aggregation** (3-5 hours)
- Create background task to aggregate 5-second metrics into 1-minute/1-hour/1-day buckets
- Store in Redis sorted sets: `ZADD metrics:requests:minute:{timestamp} {count} {endpoint}`
- Retention: Keep 5-second data for 10 minutes, 1-minute data for 24 hours, 1-hour data for 30 days

**Phase 3: Dashboard Backend** (4-6 hours)
- FastAPI endpoints:
  - `GET /api/metrics/summary` - Current state (last minute stats)
  - `GET /api/metrics/timeseries?metric=requests&window=1h` - Historical data
  - `GET /api/metrics/top-violators?limit=10` - Clients with most violations
- WebSocket endpoint: `/ws/metrics` - Real-time updates

**Phase 4: Dashboard Frontend** (6-8 hours)
- Chart.js or Recharts for time-series graphs
- Auto-refresh every 5 seconds
- Cards showing: Total requests, Rate limit violations, Circuit breaker status, Top endpoints
- Table of recent violations with client fingerprint (truncated), endpoint, timestamp

**Gotchas:**
- **Don't block rate limit checks**: Metrics collection must be async. Use `asyncio.create_task()` to fire-and-forget.
- **Buffer overflow**: If metrics buffer grows too large (million events), drop oldest or sample.
- **Redis memory**: Time-series data grows fast. Set expiration policies.

**Success criteria:**
Your implementation should:
- [ ] Collect metrics without adding >5ms latency to rate limit checks
- [ ] Display requests/sec updated every 5 seconds
- [ ] Show top 10 rate limit violators with endpoint breakdown
- [ ] Visualize circuit breaker state transitions
- [ ] Handle 10k requests/sec without overloading dashboard backend

### Challenge 8: Implement Distributed Circuit Breaker

**What to build:**
Circuit breaker that shares state across multiple API servers using Redis. When one server trips the circuit, all servers immediately enter the same state. Current implementation is per-process only.

**Estimated time:**
2-3 days for full implementation with testing

**Prerequisites:**
You should have completed Challenge 4 (request cost weighting) and Challenge 7 (dashboard) first because understanding metrics is crucial for distributed coordination.

**What you'll learn:**
- Distributed systems coordination
- Redis pub/sub for event propagation
- Eventually consistent state management
- Handling network partitions and race conditions

**Planning this feature:**

Before you code, think through:
- **Consensus**: How do servers agree on circuit state? (Redis as single source of truth)
- **Propagation delay**: Server A trips circuit, how long until Server B knows? (Pub/sub gives ~100ms)
- **Failure modes**: What if Redis connection fails? (Fall back to local circuit breaker)
- **Race conditions**: Multiple servers trying to trip circuit simultaneously (Use Redis SET NX)

**High level architecture:**
```
┌──────────────┐       ┌──────────────┐       ┌──────────────┐
│  Server 1    │       │  Server 2    │       │  Server 3    │
│  Circuit     │       │  Circuit     │       │  Circuit     │
│  Breaker     │       │  Breaker     │       │  Breaker     │
└──────┬───────┘       └──────┬───────┘       └──────┬───────┘
       │                      │                      │
       └──────────────────────┼──────────────────────┘
                              │
                   ┌──────────▼───────────┐
                   │      Redis           │
                   │  Circuit State:      │
                   │  - is_open           │
                   │  - trip_time         │
                   │  - request_count     │
                   │                      │
                   │  Pub/Sub Channel:    │
                   │  circuit:events      │
                   └──────────────────────┘
```

**Implementation phases:**

**Phase 1: Shared State** (6-8 hours)
- Store circuit state in Redis hash: `circuit:state`
- Fields: is_open (0/1), last_trip_time, failure_count, request_count
- Each server reads state before checking thresholds
- Use Redis TTL to auto-reset after recovery_time

**Phase 2: Atomic Tripping** (4-6 hours)
- Use Lua script for atomic trip operation:
```lua
  local current_count = redis.call('GET', 'circuit:requests')
  if current_count >= threshold then
      redis.call('HSET', 'circuit:state', 'is_open', '1')
      redis.call('HSET', 'circuit:state', 'trip_time', now)
      redis.call('PUBLISH', 'circuit:events', 'TRIPPED')
      return 1
  end
  return 0
```
- Only one server successfully trips, others see is_open=1 immediately

**Phase 3: Event Propagation** (5-7 hours)
- Subscribe to Redis pub/sub channel: `circuit:events`
- Events: TRIPPED, HALF_OPEN, CLOSED
- Background task listens for events, updates local cache
- Local cache reduces Redis reads (check local first, Redis if stale)

**Phase 4: Graceful Degradation** (4-6 hours)
- If Redis connection fails, fall back to local circuit breaker
- Log warning: "Distributed circuit breaker unavailable, using local"
- When Redis reconnects, sync local state with distributed state
- Handle case where local circuit is open but distributed is closed (trust distributed)

**Known challenges:**

1. **Clock Skew**
   - Problem: Servers have slightly different clocks. Server A thinks circuit should close at 12:00:30, Server B thinks 12:00:31.
   - Hint: Use Redis TIME command to get server time, not local time. Or use TTL-based expiration instead of timestamp comparison.

2. **Network Partition**
   - Problem: Server C can't reach Redis, falls back to local circuit. Local circuit trips at lower threshold, blocks legitimate traffic.
   - Hint: Add "confidence" metric. If Redis connection is flaky, increase thresholds or disable circuit entirely (fail-open).

3. **Thundering Herd**
   - Problem: Circuit opens, 100 servers all try to enter half-open state simultaneously after recovery_time.
   - Hint: Randomize recovery time: `recovery_time ± random(0, 5)` so servers stagger their retry attempts.

**Success criteria:**
Your implementation should:
- [ ] Trip circuit across all servers within 500ms of threshold exceeded
- [ ] Sync state even if a server restarts (reads from Redis on startup)
- [ ] Gracefully handle Redis connection failure (fall back to local)
- [ ] Support manual circuit state changes via Redis CLI: `HSET circuit:state is_open 1`
- [ ] Pass load test: 10 servers, 100k requests/sec, circuit trips correctly across all

### Challenge 9: Build Custom Algorithm - Generic Cell Rate Algorithm (GCRA)

**What to build:**
Implement the GCRA algorithm used by ATM networks and some high-performance rate limiters. More precise than token bucket, allows bursting within a defined "cell delay variation tolerance."

**Estimated time:**
3-4 days including research, implementation, and thorough testing

**Prerequisites:**
Strong understanding of token bucket and sliding window algorithms. Read the GCRA spec before starting.

**What you'll learn:**
- Telecoms network algorithms
- Sub-second precision rate limiting
- Continuous vs discrete time modeling
- Algorithm correctness proofs

**How GCRA works:**

GCRA tracks "Theoretical Arrival Time" (TAT). Each request should arrive no earlier than TAT. If request arrives at time T:
```
if T >= TAT:
    TAT = max(TAT, T) + 1/rate
    ALLOW
else:
    DENY
```

With burst tolerance, allow requests that arrive up to `limit` time units early:
```
if T >= TAT - limit:
    TAT = max(TAT, T) + 1/rate
    ALLOW
else:
    DENY
```

**Implementation:**

1. **Create algorithm file**: `src/fastapi_420/algorithms/gcra.py`
2. **Define state**: Store TAT in Redis/memory
3. **Implement check method**:
```python
   async def check(self, storage, key, rule, timestamp=None):
       now = timestamp or time.time()
       rate = rule.requests / rule.window_seconds  # requests per second
       limit = rule.requests  # burst tolerance
       
       tat = await storage.get_gcra_state(key)
       if tat is None:
           tat = now
       
       if now >= tat - limit / rate:
           # Allow
           new_tat = max(tat, now) + 1/rate
           await storage.set_gcra_state(key, new_tat, ttl=rule.window_seconds)
           remaining = calculate_remaining(new_tat, now, rate, limit)
           return RateLimitResult(allowed=True, remaining=remaining, ...)
       else:
           # Deny
           return RateLimitResult(allowed=False, retry_after=tat - now, ...)
```

4. **Add storage methods**: `get_gcra_state()` and `set_gcra_state()` to storage backends
5. **Write comprehensive tests**: Edge cases like clock adjustments, very high rates, fractional rates

**Testing strategy:**
```python
# Test burst tolerance
rule = RateLimitRule(requests=10, window_seconds=10)  # 1 req/sec, burst of 10
algo = GCRAAlgorithm()

# Should allow 10 immediate requests
for i in range(10):
    assert algo.check(storage, "test", rule, timestamp=0).allowed

# 11th should deny
assert not algo.check(storage, "test", rule, timestamp=0).allowed

# After 1 second, should allow 1 more
assert algo.check(storage, "test", rule, timestamp=1.0).allowed
```

**Compare with token bucket:**
Both algorithms allow bursting, but GCRA is more precise. Token bucket updates in discrete increments (add X tokens every Y seconds). GCRA uses continuous time (TAT can be any float value).

## Mix and Match

Combine features for bigger projects:

**Project Idea 1: Full Rate Limiting Dashboard with Geo Limits**
- Combine Challenge 7 (Dashboard) + Challenge 6 (Geolocation)
- Add map visualization showing requests by country
- Admin panel to adjust geo limits in real-time
- Result: Production-ready rate limiting with geographic policies

**Project Idea 2: Cost-Weighted Limits with CAPTCHA Bypass**
- Combine Challenge 4 (Cost Weighting) + Challenge 5 (CAPTCHA)
- Expensive operations cost more points
- When points exhausted, offer CAPTCHA to get temporary boost
- Result: Flexible system that allows bursts with verification

## Real World Integration Challenges

### Integrate with Prometheus for Monitoring

**The goal:**
Export rate limiting metrics to Prometheus for visualization in Grafana. Track requests, violations, algorithm latency, storage health.

**What you'll need:**
- prometheus-client library
- Grafana dashboard JSON
- Understanding of metric types (counter, gauge, histogram)

**Implementation plan:**
1. Add prometheus_client to dependencies
2. Create metrics in `src/fastapi_420/metrics.py`:
```python
   from prometheus_client import Counter, Histogram
   
   requests_total = Counter(
       'ratelimit_requests_total',
       'Total requests checked',
       ['algorithm', 'allowed']
   )
   
   check_latency = Histogram(
       'ratelimit_check_duration_seconds',
       'Time to check rate limit'
   )
```
3. Instrument code: `requests_total.labels(algorithm='sliding_window', allowed='true').inc()`
4. Expose metrics endpoint: `@app.get("/metrics")` returns `prometheus_client.generate_latest()`
5. Configure Prometheus scrape config, point at `/metrics`

**Watch out for:**
- High cardinality labels (don't include user IDs in labels, use <10 unique values per label)
- Metric name conventions (use underscores, suffix with unit)
- Performance impact (prometheus_client is fast but not free, adds ~50μs per metric update)

### Deploy to Kubernetes

**The goal:**
Run the rate-limited API in Kubernetes with Redis, monitoring, and auto-scaling.

**What you'll learn:**
- Kubernetes deployments and services
- ConfigMaps and Secrets for configuration
- Horizontal Pod Autoscaler
- Redis deployment with persistence

**Steps:**

1. **Create Dockerfile** for API:
```dockerfile
   FROM python:3.12-slim
   WORKDIR /app
   COPY requirements.txt .
   RUN pip install -r requirements.txt
   COPY src/ ./src/
   CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0"]
```

2. **Kubernetes manifests**:
```yaml
   # redis-deployment.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: redis
   spec:
     replicas: 1
     template:
       spec:
         containers:
         - name: redis
           image: redis:7-alpine
           ports:
           - containerPort: 6379
   
   # api-deployment.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: api
   spec:
     replicas: 3
     template:
       spec:
         containers:
         - name: api
           image: your-api:latest
           env:
           - name: RATELIMIT_REDIS_URL
             value: "redis://redis:6379"
           ports:
           - containerPort: 8000
   
   # api-service.yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: api
   spec:
     selector:
       app: api
     ports:
     - port: 80
       targetPort: 8000
     type: LoadBalancer
```

3. **ConfigMap** for settings:
```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: ratelimit-config
   data:
     RATELIMIT_ALGORITHM: "sliding_window"
     RATELIMIT_DEFAULT_LIMIT: "100/minute"
     RATELIMIT_CIRCUIT_THRESHOLD: "10000"
```

4. **Horizontal Pod Autoscaler**:
```yaml
   apiVersion: autoscaling/v2
   kind: HorizontalPodAutoscaler
   metadata:
     name: api-hpa
   spec:
     scaleTargetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: api
     minReplicas: 3
     maxReplicas: 10
     metrics:
     - type: Resource
       resource:
         name: cpu
         target:
           type: Utilization
           averageUtilization: 70
```

**Production checklist:**
- [ ] Redis has persistent volume for data
- [ ] Secrets used for sensitive config (not ConfigMap)
- [ ] Resource limits set (CPU/memory)
- [ ] Liveness and readiness probes configured
- [ ] Logging goes to stdout (captured by Kubernetes)
- [ ] Metrics endpoint exposed for Prometheus scraping

## Performance Challenges

### Challenge: Handle 100k Requests/Second

**The goal:**
Optimize the rate limiter to handle 100k requests/sec on a single machine without falling over.

**Current bottleneck:**
At 10k req/sec, Redis network latency becomes limiting factor. Each request = 1 Redis call = 1ms round trip = max 1000 req/sec per connection.

**Optimization approaches:**

**Approach 1: Connection Pooling**
- How: Increase `REDIS_MAX_CONNECTIONS` from 100 to 1000
- Gain: 100x parallelism, can handle 100k req/sec
- Tradeoff: Redis connection overhead, more memory

**Approach 2: Local Caching with Eventual Consistency**
- How: Cache rate limit state in-memory for 100ms. Only sync with Redis every 100ms.
- Gain: Reduce Redis calls by 90%, max 10x improvement
- Tradeoff: Accuracy drops to ~95%. Two servers might allow 110/100 requests in a window.

**Approach 3: Batching**
- How: Accumulate requests for 10ms, send to Redis in single pipeline
- Gain: Reduce network overhead, ~5x improvement
- Tradeoff: 10ms added latency, complexity

**Benchmark it:**
```bash
# Load test with wrk
wrk -t12 -c400 -d30s http://localhost:8000/api/test

# Should see:
# Requests/sec: 100000
# Latency avg: 4ms
# Latency 99th: 15ms
```

Target metrics:
- **Throughput**: >100k requests/sec
- **Latency p50**: <5ms
- **Latency p99**: <20ms

### Challenge: Reduce Memory Usage by 90%

**The goal:**
Reduce memory consumption for 1 million active rate limit keys from ~100MB to ~10MB.

**Current usage:**
Each key stores:
- Python dict entry: 56 bytes
- WindowEntry: 24 bytes
- String key (~50 chars): 50 bytes
Total: ~130 bytes/key * 1M keys = 130MB

**Optimization areas:**

**Area 1: Use Redis instead of Memory**
- What's inefficient: Python objects have overhead
- How to fix: Store in Redis (more memory efficient)
- Savings: 70% reduction

**Area 2: Compress Keys**
- What's inefficient: Keys like "ratelimit:v1:user:POST:/api/endpoint:192.168.1.1:Mozilla...:60" are 100+ chars
- How to fix: Hash keys to 16-char hex strings
- Savings: 80% reduction in key size

**Area 3: Use Slots**
- What's inefficient: Python's `__dict__` attribute on dataclasses
- How to fix: Add `__slots__` to WindowEntry, RateLimitResult
- Savings: 30% reduction in object size

## Security Challenges

### Challenge: Add JWT-Based Rate Limit Tiers

**What to implement:**
Different rate limits based on JWT claims. Free tier: 10/minute. Paid tier: 100/minute. Enterprise: 1000/minute.

**Threat model:**
This protects against:
- Free tier abuse (creating many accounts to get more quota)
- Fair resource allocation (paying customers get what they paid for)

**Implementation:**

1. **Extract tier from JWT**:
```python
   # In auth extractor
   payload = jwt.decode(token, secret, algorithms=['HS256'])
   tier = payload.get('tier', 'free')  # free, paid, enterprise
```

2. **Add tier to fingerprint**:
```python
   # In FingerprintData
   tier: str | None = None
```

3. **Select limit based on tier**:
```python
   # In RateLimiter.check
   tier_limits = {
       'free': ['10/minute'],
       'paid': ['100/minute'],
       'enterprise': ['1000/minute'],
   }
   rules = [RateLimitRule.parse(l) for l in tier_limits.get(tier, tier_limits['free'])]
```

**Testing the security:**
- Try to forge JWT with tier=enterprise
- Should fail signature validation
- Try to create free account, abuse endpoint
- Should hit 10/minute limit
- Verify paid users can exceed free tier limits

### Challenge: Pass OWASP API Security Top 10

**The goal:**
Audit the rate limiter against OWASP API Security Top 10 and fix any gaps.

**Current gaps:**
- **API4:2023 - Unrestricted Resource Consumption**: Partially covered by rate limiting. Gap: No per-IP limits on unauthenticated endpoints.
- **API5:2023 - Broken Function Level Authorization**: Gap: Circuit breaker bypass doesn't check if "authenticated" user actually has permission.
- **API8:2023 - Security Misconfiguration**: Gap: No validation that production has Redis configured.

**Remediation:**

1. **Add per-IP limits for unauthenticated**:
```python
   if not fingerprint.auth_identifier:
       # Stricter limits for anonymous
       rules = [RateLimitRule.parse('10/minute')]
```

2. **Add permission check to circuit bypass**:
```python
   def _should_bypass_circuit(self, context):
       if not context.is_authenticated:
           return False
       # Check actual permissions, not just authentication
       return context.has_permission('circuit.bypass')
```

3. **Add production validation**:
```python
   @model_validator(mode='after')
   def validate_production(self):
       if self.ENVIRONMENT == 'production':
           if not self.storage.REDIS_URL:
               raise ValueError("Production requires Redis")
       return self
```

## Contribution Ideas

Finished a challenge? Share it back:

1. **Fork the repo**
2. **Implement your extension** in a feature branch: `git checkout -b feature/captcha-challenge`
3. **Document it** - Add to learn/ folder explaining how it works
4. **Submit a PR** with:
   - Your implementation
   - Tests proving it works
   - Documentation in learn/ folder
   - Example usage in examples/

Good extensions might get merged into the main project. Even if not merged, you'll have a portfolio piece showing real-world security engineering.

## Challenge Yourself Further

### Build Something New

Use the concepts you learned here to build:
- **API Gateway with rate limiting** - Reverse proxy that adds rate limiting to any backend API
- **Database query rate limiter** - Limit queries/second to prevent database overload
- **Distributed task queue throttler** - Rate limit background job execution

### Study Real Implementations

Compare your implementation to production tools:
- **Kong API Gateway** - Supports multiple rate limiting strategies, read their Lua plugin code
- **Cloudflare Workers** - Edge-based rate limiting, study their architecture blog posts
- **GitHub API** - Read their rate limiting docs, understand their tier system

Read their code, understand their tradeoffs, steal their good ideas.

### Write About It

Document your extensions:
- Blog post: "Adding Geolocation-Based Rate Limiting to FastAPI"
- Tutorial: "How I Built a Rate Limiting Dashboard in a Weekend"
- Comparison: "Sliding Window vs GCRA: Performance Benchmarks"

Teaching others is the best way to verify you understand it.

## Getting Help

Stuck on a challenge?

1. **Debug systematically**
   - What did you expect? (Specific behavior)
   - What actually happened? (Logs, errors, wrong output)
   - What's the smallest test case that reproduces it?

2. **Read the existing code**
   - Similar features already implemented? (Look at algorithms/ for patterns)
   - Tests showing how components work? (tests/test_*.py has examples)

3. **Search for similar problems**
   - GitHub issues on similar projects
   - Stack Overflow for specific errors
   - Redis/FastAPI docs for API questions

4. **Ask for help**
   - Open a GitHub discussion with:
     - Challenge you're working on
     - What you've tried
     - Specific error or unexpected behavior
     - Your hypothesis about what's wrong
   - Don't just paste errors. Explain your understanding.

## Challenge Completion

Track your progress:

- [ ] Easy Challenge 1: Custom headers
- [ ] Easy Challenge 2: Decorator syntax
- [ ] Easy Challenge 3: Environment prefixes
- [ ] Intermediate Challenge 4: Request cost weighting
- [ ] Intermediate Challenge 5: CAPTCHA integration
- [ ] Intermediate Challenge 6: Geolocation limits
- [ ] Advanced Challenge 7: Rate limit dashboard
- [ ] Advanced Challenge 8: Distributed circuit breaker
- [ ] Advanced Challenge 9: GCRA algorithm

Completed all of them? You've mastered rate limiting. Time to build something new or contribute back to the community.
