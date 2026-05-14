# API Rate Limiter (fastapi-420)

## What This Is

A production-ready rate limiting library for FastAPI that implements three battle-tested algorithms (sliding window, token bucket, fixed window) with Redis or in-memory storage, advanced client fingerprinting, and a three-layer defense system that scales from per-user limits to global DDoS protection.

## Why This Matters

On February 28, 2018, GitHub experienced a 1.35 Tbps DDoS attack, the largest recorded at the time. The attack lasted only 10 minutes because their rate limiting and traffic filtering systems kicked in. Without proper rate limiting, even legitimate traffic spikes can take down APIs. When the iPhone 15 launched, Apple's activation servers struggled under load from millions of simultaneous requests. Rate limiting isn't just about security, it's about availability.

**Real world scenarios where this applies:**
- **Preventing credential stuffing** - In 2019, Dunkin' Donuts suffered a credential stuffing attack where attackers made millions of login attempts using stolen credentials. Rate limiting login endpoints to 3-5 attempts per minute blocks this attack pattern completely.
- **API cost control** - If you're calling expensive third-party APIs or running ML inference, a single misbehaving client can cost you thousands of dollars in a few hours. Rate limits protect your budget.
- **Fair resource distribution** - In 2020, scalpers used bots to buy all the PS5 inventory within seconds of release. E-commerce sites now use rate limiting on checkout endpoints to give real customers a fair chance.

## What You'll Learn

This project teaches you how production rate limiting actually works. By building it yourself, you'll understand:

**Security Concepts:**
- **Three-layer defense architecture** - Why you need per-user limits (stop individual abuse), per-endpoint limits (prevent endpoint-specific attacks), and global limits (DDoS protection). One layer isn't enough. The 2016 Dyn DNS attack bypassed per-user limits by using millions of IoT devices.
- **Client fingerprinting** - How to identify clients reliably when IPs aren't unique (NAT, proxies, mobile networks). You'll learn why fingerprinting just IP addresses is broken, especially for IPv6 where users control entire /64 blocks (18 quintillion addresses).
- **Algorithm tradeoffs** - Why sliding window is recommended for production (accurate with constant memory), when token bucket makes sense (burst tolerance), and why fixed window has a boundary problem that attackers exploit.

**Technical Skills:**
- **Atomic operations with Lua scripts** - Rate limiting requires atomic read-modify-write operations. You'll see how Redis Lua scripts (stored in `src/fastapi_420/storage/lua/`) guarantee correctness even under heavy concurrent load.
- **ASGI middleware integration** - How to hook into FastAPI's request lifecycle at `src/fastapi_420/middleware.py:37-106` to apply rate limits globally without modifying every endpoint.
- **Async Python patterns** - Managing concurrent requests with asyncio locks (`src/fastapi_420/storage/memory.py:44`), background cleanup tasks, and graceful shutdown.

**Tools and Techniques:**
- **Redis for distributed systems** - The in-memory storage at `src/fastapi_420/storage/memory.py` works for single instances, but production systems need Redis (`src/fastapi_420/storage/redis_backend.py`) to share state across multiple servers.
- **Pydantic settings validation** - The config system at `src/fastapi_420/config.py:120-164` validates environment variables at startup, failing fast if misconfigured instead of causing runtime errors.
- **Testing rate limiters** - The test suite shows patterns for testing time-dependent code using explicit timestamps (`tests/test_algorithms.py:143`) rather than sleeping in tests.

## Prerequisites

Before starting, you should understand:

**Required knowledge:**
- **Python async/await** - The entire codebase is async. You need to know the difference between `async def` and `def`, when to use `await`, and what `asyncio.create_task()` does.
- **FastAPI basics** - Understand middleware, dependency injection with `Depends()`, and how request/response flow works. If you haven't built a FastAPI app before, do that first.
- **HTTP headers** - Know what `X-Forwarded-For`, `User-Agent`, and `Authorization` headers are for. The fingerprinting system relies heavily on header analysis.

**Tools you'll need:**
- **Python 3.12+** - Uses new type hints like `list[str]` instead of `List[str]`
- **Redis (optional)** - For production use. Install with Docker: `docker run -d -p 6379:6379 redis:7-alpine`
- **httpx or curl** - For testing API endpoints

**Helpful but not required:**
- **Redis Lua scripting** - The project includes pre-written Lua scripts, but understanding them helps
- **OAuth/JWT basics** - The auth extractor (`src/fastapi_420/fingerprinting/auth.py`) can parse JWT tokens

## Quick Start

Get the project running locally:
```bash
# Clone and navigate
cd PROJECTS/advanced/api-rate-limiter

# Install dependencies
pip install -e . --break-system-packages

# Optional: Start Redis for production-like testing
docker compose -f examples/docker-compose.yml up -d

# Run the example app
python examples/app.py
```

Expected output: Server starts on http://0.0.0.0:8000 with multiple rate-limited endpoints. Try hitting the strict login endpoint:
```bash
# First 3 requests work
curl http://localhost:8000/auth/login -X POST -d "username=test&password=test"

# 4th request gets HTTP 420
curl -i http://localhost:8000/auth/login -X POST -d "username=test&password=test"
```

You'll see `HTTP/1.1 420 Enhance Your Calm` with `Retry-After` and `RateLimit-*` headers.

## Project Structure
```
api-rate-limiter/
├── src/fastapi_420/
│   ├── algorithms/           # Rate limiting algorithms
│   │   ├── sliding_window.py # Recommended default (99.997% accurate)
│   │   ├── token_bucket.py   # For burst tolerance
│   │   └── fixed_window.py   # Simple but has boundary issues
│   ├── storage/              # Storage backends
│   │   ├── memory.py         # In-memory (single instance)
│   │   ├── redis_backend.py  # Redis (distributed)
│   │   └── lua/              # Atomic Lua scripts
│   ├── fingerprinting/       # Client identification
│   │   ├── ip.py             # IP extraction with IPv6 /64 normalization
│   │   ├── headers.py        # User-Agent, Accept-* headers
│   │   ├── auth.py           # JWT, API keys, sessions
│   │   └── composite.py      # Combines all methods
│   ├── defense/              # Multi-layer protection
│   │   ├── layers.py         # User/Endpoint/Global limits
│   │   └── circuit_breaker.py# DDoS protection
│   ├── limiter.py            # Main RateLimiter class
│   ├── middleware.py         # ASGI middleware
│   ├── dependencies.py       # FastAPI dependency injection
│   ├── config.py             # Settings with Pydantic
│   └── types.py              # Data structures
├── examples/
│   └── app.py                # Full working example
└── tests/                    # Comprehensive test suite
```

## Next Steps

1. **Understand the concepts** - Read [01-CONCEPTS.md](./01-CONCEPTS.md) to learn rate limiting fundamentals, algorithm differences, and why fingerprinting matters
2. **Study the architecture** - Read [02-ARCHITECTURE.md](./02-ARCHITECTURE.md) to see the three-layer defense system and data flow
3. **Walk through the code** - Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for line-by-line implementation details
4. **Extend the project** - Read [04-CHALLENGES.md](./04-CHALLENGES.md) for ideas like adding geolocation blocking, CAPTCHA integration, or custom algorithms

## Common Issues

**"Redis connection failed" but I want to use memory storage**
```
REDIS_URL not set, fallback to memory storage enabled
```
Solution: This is fine for development. The `FALLBACK_TO_MEMORY=True` setting (default) automatically switches to in-memory storage when Redis is unavailable. For production, set `REDIS_URL` environment variable.

**"Rate limit not working for requests from different IPs"**
Solution: Check if you're behind a proxy. If using nginx or cloudflare, set `TRUST_X_FORWARDED_FOR=True` in your settings so the IP extractor reads `X-Forwarded-For` header instead of the proxy IP. See `src/fastapi_420/fingerprinting/ip.py:52-68` for proxy handling logic.

**"Getting HTTP 420 immediately on first request"**
Check the circuit breaker threshold. If `CIRCUIT_THRESHOLD` is too low (like 100) and you're load testing, the global circuit breaker might be triggering. See `src/fastapi_420/defense/circuit_breaker.py:45-55` for threshold logic.

## Related Projects

If you found this interesting, check out:
- **network-traffic-analyzer** - Builds on packet inspection to detect DDoS attacks before they hit your API
- **docker-security-audit** - Shows how to audit rate limiting configurations in containerized deployments
- **bug-bounty-platform** - Implements rate limiting for submission endpoints to prevent spam
