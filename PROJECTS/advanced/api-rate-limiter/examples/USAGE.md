<!--
ⒸAngelaMos | 2026
USAGE.md
-->

# Using fastapi-420 as a Library

Reference guide for integrating `fastapi-420` into your own FastAPI project.
For security theory and architecture deep-dives, see the [learn modules](../learn/).

## Installation

```bash
uv add fastapi-420
```

Requires Python 3.12+. Dependencies (`fastapi`, `pydantic`, `pydantic-settings`, `redis`, `pyjwt`) are pulled in automatically.

## Minimal Setup

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi_420 import RateLimiter, RateLimiterSettings, set_global_limiter

settings = RateLimiterSettings()
limiter = RateLimiter(settings=settings)

@asynccontextmanager
async def lifespan(app: FastAPI):
    await limiter.init()
    set_global_limiter(limiter)
    yield
    await limiter.close()

app = FastAPI(lifespan=lifespan)

@app.get("/items")
@limiter.limit("60/minute")
async def list_items(request: Request):
    return {"items": []}
```

`set_global_limiter` registers the instance so dependency injection (`RateLimitDep`, `ScopedRateLimiter`) can find it without passing the limiter around manually.

## Three Integration Patterns

### 1. Middleware (Global)

Applies a blanket limit to every route. Health/metrics endpoints are excluded by default.

```python
from fastapi_420 import RateLimiter, RateLimiterSettings
from fastapi_420.middleware import RateLimitMiddleware

limiter = RateLimiter(RateLimiterSettings())

app.add_middleware(
    RateLimitMiddleware,
    limiter=limiter,
    default_limit="200/minute",
    exclude_paths=["/internal/debug"],
    exclude_patterns=[r"^/admin/.*"],
    path_limits={
        "/api/upload": "10/minute",
        "/auth/login": "5/minute",
    },
)
```

There is also `SlowDownMiddleware` which adds progressive delays instead of hard-blocking:

```python
from fastapi_420.middleware import SlowDownMiddleware

app.add_middleware(
    SlowDownMiddleware,
    limiter=limiter,
    threshold_limit="50/minute",
    max_delay_seconds=5.0,
    delay_increment=0.5,
)
```

### 2. Decorator (Per-Route)

Requires `request: Request` in the function signature so the limiter can extract client fingerprints.

```python
@app.get("/search")
@limiter.limit("30/minute", "500/hour")
async def search(request: Request, q: str):
    return {"results": [], "query": q}
```

Multiple rules stack. The most restrictive one that triggers wins.

### 3. Dependency Injection

**Inline with `RateLimitDep`:**

```python
from fastapi import Depends
from fastapi_420 import RateLimitDep

@app.get("/settings", dependencies=[Depends(RateLimitDep("30/minute"))])
async def get_settings():
    return {"theme": "dark"}
```

**Access the result object:**

```python
from typing import Annotated
from fastapi_420 import RateLimitDep, RateLimitResult

@app.get("/data")
async def get_data(
    result: Annotated[RateLimitResult, Depends(RateLimitDep("100/minute"))],
):
    return {"remaining": result.remaining, "reset_in": result.reset_after}
```

**Default limits with `require_rate_limit`:**

```python
from fastapi_420 import require_rate_limit

@app.get("/default-limited")
async def default_limited(
    result: Annotated[RateLimitResult, Depends(require_rate_limit)],
):
    return {"remaining": result.remaining}
```

This uses whatever `DEFAULT_LIMITS` is set to in your `RateLimiterSettings`.

## Scoped Rate Limiters

Group endpoints under a shared limiter with per-endpoint overrides.

```python
from fastapi_420 import ScopedRateLimiter

auth_limiter = ScopedRateLimiter(
    prefix="/auth",
    default_rules=["5/minute", "20/hour"],
    endpoint_rules={
        "POST:/auth/login": ["3/minute", "10/hour"],
        "POST:/auth/register": ["2/minute", "5/hour"],
    },
)

@app.post("/auth/login", dependencies=[Depends(auth_limiter)])
async def login(username: str, password: str):
    return {"token": "..."}

@app.post("/auth/register", dependencies=[Depends(auth_limiter)])
async def register(username: str, password: str):
    return {"user_id": 1}
```

Endpoint rule keys use the format `METHOD:/path`. If no specific rule matches, `default_rules` applies.

## Configuration

### RateLimiterSettings

All settings are [Pydantic Settings](https://docs.pydantic.dev/latest/concepts/pydantic_settings/) and can be set via environment variables with the `RATELIMIT_` prefix.

```python
from fastapi_420 import (
    RateLimiterSettings,
    StorageSettings,
    FingerprintSettings,
)
from fastapi_420.types import Algorithm, FingerprintLevel

settings = RateLimiterSettings(
    ENABLED=True,
    ALGORITHM=Algorithm.SLIDING_WINDOW,
    DEFAULT_LIMIT="100/minute",
    DEFAULT_LIMITS=["100/minute", "1000/hour"],
    FAIL_OPEN=True,
    KEY_PREFIX="myapp",
    INCLUDE_HEADERS=True,
    LOG_VIOLATIONS=True,
    ENVIRONMENT="production",
    storage=StorageSettings(
        REDIS_URL="redis://localhost:6379/0",
        REDIS_MAX_CONNECTIONS=100,
        FALLBACK_TO_MEMORY=True,
        MEMORY_MAX_KEYS=100_000,
    ),
    fingerprint=FingerprintSettings(
        LEVEL=FingerprintLevel.NORMAL,
        TRUST_X_FORWARDED_FOR=True,
        TRUSTED_PROXIES=["10.0.0.0/8"],
    ),
)
```

### Environment Variables

Instead of passing values in code, set them in your environment or `.env` file:

```bash
RATELIMIT_ENABLED=true
RATELIMIT_ALGORITHM=sliding_window
RATELIMIT_DEFAULT_LIMIT=100/minute
RATELIMIT_KEY_PREFIX=myapp
RATELIMIT_FAIL_OPEN=true
RATELIMIT_ENVIRONMENT=production

RATELIMIT_REDIS_URL=redis://localhost:6379/0
RATELIMIT_REDIS_MAX_CONNECTIONS=100
RATELIMIT_FALLBACK_TO_MEMORY=true

RATELIMIT_FP_LEVEL=normal
RATELIMIT_FP_TRUST_X_FORWARDED_FOR=true
```

Then just use `RateLimiterSettings()` with no arguments and it picks up everything from the environment.

### Algorithms

| Algorithm | Best For | Trade-off |
|-----------|----------|-----------|
| `SLIDING_WINDOW` | General use (default) | 99.997% accurate, slightly more memory |
| `TOKEN_BUCKET` | Burst-tolerant APIs | Allows short bursts up to capacity |
| `FIXED_WINDOW` | Simple counting | Boundary burst problem at window edges |

```python
from fastapi_420.types import Algorithm

settings = RateLimiterSettings(ALGORITHM=Algorithm.TOKEN_BUCKET)
```

All three algorithms use atomic Lua scripts when backed by Redis, so they are safe under concurrent load.

### Fingerprint Levels

Controls how aggressively clients are identified:

| Level | Components | Use Case |
|-------|-----------|----------|
| `RELAXED` | IP + auth token (if present) | Public APIs, mobile apps |
| `NORMAL` | IP + User-Agent + auth token | General web applications |
| `STRICT` | IP + UA + Accept headers + header order + TLS + geo | Anti-abuse, financial APIs |

### Rate Limit Rule Format

Rules follow the pattern `count/unit`:

```
"100/minute"    "1000/hour"    "10000/day"    "5/second"
```

Accepted units: `second`, `seconds`, `sec`, `s`, `minute`, `minutes`, `min`, `m`, `hour`, `hours`, `hr`, `h`, `day`, `days`, `d`.

## Redis Setup

For production, run Redis alongside your app. The `examples/docker-compose.yml` in this directory provides a ready-to-use setup:

```bash
docker compose -f examples/docker-compose.yml up -d
```

If Redis is unavailable and `FALLBACK_TO_MEMORY=True` (default), the limiter automatically falls back to in-memory storage. If `FAIL_OPEN=True` (default), requests are allowed through when both storage backends fail.

## Error Handling

When a client exceeds their limit, the limiter raises `EnhanceYourCalm` (HTTP 420). The response looks like:

```json
{
    "message": "Enhance your calm",
    "detail": "Rate limit exceeded. Take a breather.",
    "limit_info": {
        "RateLimit-Limit": "100",
        "RateLimit-Remaining": "0",
        "RateLimit-Reset": "45",
        "Retry-After": "45"
    }
}
```

Response headers (`RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`, `Retry-After`) follow the IETF draft standard and are included when `INCLUDE_HEADERS=True`.

To customize the rejection message:

```python
settings = RateLimiterSettings(
    HTTP_420_MESSAGE="Slow down there",
    HTTP_420_DETAIL="You've exceeded your rate limit. Wait and try again.",
)
```

## Custom Key Functions

Override the default fingerprinting with your own key extraction logic:

```python
def key_by_api_key(request: Request) -> str:
    return request.headers.get("X-API-Key", "anonymous")

@app.get("/partner/data")
@limiter.limit("1000/hour", key_func=key_by_api_key)
async def partner_data(request: Request):
    return {"data": "..."}
```

This also works with `RateLimitDep`:

```python
dep = RateLimitDep("500/hour", key_func=key_by_api_key)

@app.get("/partner/info", dependencies=[Depends(dep)])
async def partner_info():
    return {"info": "..."}
```

## Full Working Example

See [`app.py`](app.py) in this directory for a complete FastAPI application demonstrating all three integration patterns with tiered limits across auth, public, and user endpoint groups.

Run it:

```bash
docker compose up -d
uv run python examples/app.py
```
