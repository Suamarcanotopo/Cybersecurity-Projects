# System Architecture

How the SIEM dashboard is designed, why each component exists, and how data moves through the system.

## High Level Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        Browser                                │
│  React 19 + TypeScript + Zustand + TanStack Query            │
│  SSE Listeners (EventSource)                                  │
└──────────────┬────────────────────────────┬──────────────────┘
               │ HTTP/JSON                  │ SSE
               ▼                            ▼
┌──────────────────────────────────────────────────────────────┐
│                     Nginx Reverse Proxy                       │
│  Rate limiting · Gzip · Static assets · SSE passthrough      │
│  proxy_buffering off (for /stream endpoints)                 │
└──────────────┬────────────────────────────┬──────────────────┘
               │                            │
               ▼                            ▼
┌──────────────────────────────────────────────────────────────┐
│                     Flask Backend                             │
│                                                               │
│  ┌─────────┐  ┌──────────────┐  ┌────────────────────┐      │
│  │ Routes  │→ │ Controllers  │→ │ Engine             │      │
│  │ (auth,  │  │ (validation, │  │ (normalizer,       │      │
│  │  logs,  │  │  business    │  │  severity,         │      │
│  │  alerts │  │  logic)      │  │  correlation)      │      │
│  │  rules) │  │              │  │                    │      │
│  └─────────┘  └──────────────┘  └────────────────────┘      │
│                                                               │
│  ┌──────────────────────┐  ┌──────────────────────────┐      │
│  │ Scenario Runner      │  │ Correlation Engine        │      │
│  │ (daemon threads,     │  │ (daemon thread,           │      │
│  │  playbook playback)  │  │  XREADGROUP consumer)     │      │
│  └──────────────────────┘  └──────────────────────────┘      │
└──────────┬──────────────────────────┬────────────────────────┘
           │                          │
           ▼                          ▼
┌────────────────────┐    ┌────────────────────┐
│    MongoDB 8.0     │    │   Redis 7 Alpine   │
│                    │    │                    │
│  log_events        │    │  siem:logs stream  │
│  alerts            │    │  siem:alerts stream│
│  correlation_rules │    │  rate limit keys   │
│  users             │    │                    │
│  scenario_runs     │    │                    │
└────────────────────┘    └────────────────────┘
```

### Component Breakdown

**Nginx Reverse Proxy**
Sits in front of everything. Handles TLS termination in production, rate limiting at the edge (`limit_req_zone` in `conf/nginx/nginx.conf:34-36`), gzip compression, and static asset caching. The critical detail is the SSE passthrough configuration. Regular API endpoints use buffered proxying, but `/stream` endpoints need `proxy_buffering off` and a 3600s read timeout (`conf/nginx/prod.nginx:30-43`). Without this, Nginx buffers SSE events and the browser gets nothing until the buffer fills.

**Flask Backend**
Application factory pattern in `backend/app/__init__.py`. Creates the Flask app, wires up MongoDB and Redis connections, registers blueprints, initializes rate limiting, creates Redis consumer groups, cleans up orphaned scenario runs, and starts the correlation engine. That startup order matters. The consumer groups must exist before the correlation engine tries to read from them.

**MongoDB**
Primary data store for all persistent documents. MongoEngine ODM maps Python classes to collections. Five main collections: `log_events`, `alerts`, `correlation_rules`, `users`, `scenario_runs`. Each has specific indexes defined in the model `meta` dict for query performance.

**Redis**
Two roles. First, it powers the streaming pipeline. Two Redis Streams (`siem:logs` and `siem:alerts`) handle the pub/sub fanout between log ingestion, the correlation engine, and SSE endpoints. Second, it backs the rate limiter (`flask-limiter` uses Redis as its storage backend via the `REDIS_URL` config).

**React Frontend**
Single page app with React 19, TypeScript, and a clean separation between data fetching (TanStack Query hooks in `frontend/src/api/hooks/`) and UI state (Zustand stores in `frontend/src/core/stores/`). Real time updates come through two SSE connections managed by `useLogStream` and `useAlertStream` hooks.

## Data Flow

### Log Ingestion Pipeline

This is the core pipeline. Every log event, whether from the scenario runner or an external POST, follows the same path:

```
1. Raw event arrives
   POST /v1/logs/ingest  (or ScenarioRunner._emit_event)
   │
2. Normalize (app/engine/normalizer.py)
   │  Dispatches to source_type-specific normalizer
   │  Extracts common fields, preserves raw payload
   │
3. Classify severity (app/engine/severity.py)
   │  Event type lookup → regex pattern matching → default to info
   │
4. Persist to MongoDB (app/models/LogEvent.py)
   │  LogEvent.create_event() → document saved with all fields
   │
5. Publish to Redis Stream (app/core/streaming.py)
   │  XADD siem:logs {payload: JSON}
   │  Maxlen ~10000 (approximate trim)
   │
   ├──→ 6a. Correlation Engine reads via XREADGROUP
   │    │   Evaluates all enabled rules against event
   │    │   If rule fires → create Alert → XADD siem:alerts
   │    │   ACK message after processing
   │    │
   │    └──→ SSE /v1/alerts/stream (browser picks up new alerts)
   │
   └──→ 6b. SSE /v1/logs/stream
        │   XREAD with blocking, yields to EventSource
        └── Browser pushes to Zustand StreamStore
```

The important thing here is that steps 4 and 5 happen atomically from the controller's perspective. The event is persisted before it hits the stream. If Redis is down, the event is still in MongoDB. If MongoDB is down, nothing gets published because `create_event()` would throw first.

### Alert Lifecycle

Alerts have a state machine with five statuses:

```
new → acknowledged → investigating → resolved
                                   → false_positive
```

When the correlation engine fires a rule (`app/engine/correlation.py:_process_event`), it calls `Alert.create_from_rule()` which both saves the alert to MongoDB and publishes it to the `siem:alerts` Redis Stream. The alert document references the matched event IDs so analysts can drill into what triggered the alert.

Status transitions happen through `PATCH /v1/alerts/<id>/status` and are tracked with timestamps. The `acknowledged_by` field records which analyst claimed the alert, and `resolved_at` marks closure time.

### Authentication Flow

```
Register/Login
    │
    ▼
POST /v1/auth/register  or  POST /v1/auth/login
    │                           │
    ▼                           ▼
hash_password()            verify_password_timing_safe()
(Argon2id)                 (constant time, dummy hash for missing users)
    │                           │
    ▼                           ▼
User.create_user()          Validate credentials
    │                           │
    └───────┬───────────────────┘
            ▼
    create_access_token()
    JWT with sub=user_id, username, role, exp
            │
            ▼
    Return {access_token, token_type: "bearer"}
            │
            ▼
    Frontend stores in Zustand (persisted to localStorage)
    Axios interceptor attaches to every request
```

Each subsequent request hits the `endpoint()` decorator which extracts the Bearer token, decodes the JWT, loads the user from MongoDB, and attaches it to Flask's `g.current_user`. The decorator also handles role gating. Pass `roles=["admin"]` and non-admins get a 403.

## Design Patterns

### Application Factory

**Where it lives:** `backend/app/__init__.py`

The `create_app()` function builds the Flask app from scratch every time it's called. This isn't just a Flask convention. It solves real problems: test isolation (each test gets a fresh app), configuration flexibility (swap `.env` files between dev/prod), and import order issues (extensions initialize after app config is set).

The initialization order is deliberate:

1. Config loading (from env vars via Pydantic)
2. CORS setup
3. MongoDB and Redis connections
4. Error handlers
5. Rate limiter
6. Blueprint registration
7. Consumer group creation
8. Orphan scenario cleanup
9. Correlation engine start

If you move step 7 after step 9, the correlation engine will crash trying to read from a consumer group that doesn't exist yet.

### Decorator Stack Pattern

**Where it lives:** `backend/app/core/decorators/`

Every route handler uses the same decorator stack: `@endpoint` → `@S` → `@R`. This is a composable pipeline:

```python
# backend/app/routes/logs.py:32-39
@logs_bp.post("/ingest")
@endpoint(auth_required=False)
@S(LogIngestRequest)
@R(status=201)
def ingest_log() -> Any:
    return log_ctrl.ingest_log()
```

`@endpoint` handles JWT extraction, user loading, role enforcement, and error boundaries. `@S` (Schema) validates request data with Pydantic and stores the result on `g.validated`. `@R` (Response) auto-serializes the return value into JSON with the right status code.

The decorators execute outside-in: endpoint runs first (auth check), then S (validation), then the function body, then R (serialization). If auth fails, validation never runs. If validation fails, the controller never executes. This fail-fast approach keeps controller code clean.

**Trade-offs:**
The decorator stack is concise but can be confusing to debug. Stack traces go through multiple wrapper layers. If you add a new decorator, ordering matters and gets it wrong silently.

### Registry Pattern for Normalizers

**Where it lives:** `backend/app/engine/normalizer.py`

Each source type (firewall, IDS, auth, endpoint, DNS, proxy, generic) has its own normalizer function registered via the `@_register` decorator:

```python
# backend/app/engine/normalizer.py:16-22
def _register(source_type: SourceType) -> Callable[[NormalizerFn], NormalizerFn]:
    def decorator(fn: NormalizerFn) -> NormalizerFn:
        NORMALIZERS[source_type.value] = fn
        return fn
    return decorator
```

The `normalize()` dispatcher looks up the right function from the `NORMALIZERS` dict and falls back to `_normalize_generic` for unknown types. Adding a new source type means writing one function and adding the decorator. No switch statements, no if/elif chains, no modification of the dispatch logic.

### Thread-safe State with Locks

**Where it lives:** `backend/app/engine/correlation.py` (`CorrelationState` class)

The correlation engine runs on a daemon thread but shares state structures (sliding windows, cooldown timestamps) that could be accessed during rule testing from the main Flask thread. Every method on `CorrelationState` acquires `self._lock` before touching `_windows` or `_cooldowns`. This prevents data races but means the correlation engine can't process two events in parallel. For the throughput this project targets, that's fine.

## Layer Separation

```
┌────────────────────────────────────────────────────┐
│    Routes Layer (app/routes/)                       │
│    HTTP concerns only: URL mapping, rate limits     │
│    Does NOT: query databases, process data          │
└───────────────────────┬────────────────────────────┘
                        ▼
┌────────────────────────────────────────────────────┐
│    Controller Layer (app/controllers/)               │
│    Business logic: orchestrate models and engine    │
│    Does NOT: parse requests, format responses       │
└───────────────────────┬────────────────────────────┘
                        ▼
┌────────────────────────────────────────────────────┐
│    Model Layer (app/models/)                         │
│    Data access: MongoEngine documents, queries      │
│    Does NOT: know about HTTP, Flask request/response│
└───────────────────────┬────────────────────────────┘
                        ▼
┌────────────────────────────────────────────────────┐
│    Engine Layer (app/engine/)                        │
│    Domain logic: normalization, severity, correlation│
│    Does NOT: persist data, know about Flask          │
└────────────────────────────────────────────────────┘
```

### What Lives Where

**Routes** (`app/routes/`): Blueprint definitions, URL patterns, decorator stacks. Each route function is a thin wrapper that calls the corresponding controller function. Routes import from controllers and schemas, never from models directly.

**Controllers** (`app/controllers/`): Business logic coordination. The controller for log ingestion (`log_ctrl.ingest_log`) calls the normalizer, the severity classifier, the model's `create_event`, and the streaming publisher. Controllers access `g.validated` for input and `g.current_user` for auth context.

**Models** (`app/models/`): MongoEngine document definitions with query methods. `BaseDocument` provides shared functionality like `get_by_id`, `paginate`, and auto-updating `updated_at` timestamps. Models can call other models (Alert references LogEvent) but never import from routes or controllers.

**Engine** (`app/engine/`): Pure domain logic. The normalizer, severity classifier, and correlation engine live here. The correlation engine is the only component that reaches into both the streaming layer (to read events) and the model layer (to create alerts). This is a pragmatic trade-off to keep the daemon thread self-contained.

## Data Models

### LogEvent

```python
# backend/app/models/LogEvent.py
class LogEvent(BaseDocument):
    meta = {
        "collection": "log_events",
        "ordering": ["-timestamp"],
        "indexes": [
            "timestamp", "source_type", "severity",
            "source_ip", "dest_ip", "username",
            "hostname", "event_type", "scenario_run_id",
        ],
    }
    timestamp       = DateTimeField()
    source_type     = StringField(required=True)   # firewall, ids, auth, etc.
    source_ip       = StringField()
    dest_ip         = StringField()
    source_port     = IntField()
    dest_port       = IntField()
    severity        = StringField(default="info")
    event_type      = StringField()                # login_failure, port_scan, etc.
    raw             = DictField()                  # original payload, untouched
    normalized      = DictField()                  # source-type-specific fields
    hostname        = StringField()
    username        = StringField()
    scenario_run_id = ObjectIdField()              # links to ScenarioRun if simulated
```

Nine indexes cover the query patterns used by the log viewer, pivot searches, and dashboard aggregations. The `raw` field preserves the original event exactly as submitted. The `normalized` field holds source-type-specific fields extracted by the normalizer. This dual storage means you can always go back to the original data if the normalizer had a bug.

### Alert

```python
# backend/app/models/Alert.py
class Alert(BaseDocument):
    rule_id             = ObjectIdField(required=True)
    rule_name           = StringField(required=True)
    severity            = StringField(required=True)
    title               = StringField(required=True)   # "{rule_name} [{group_value}]"
    matched_event_ids   = ListField(ObjectIdField())   # references to LogEvent docs
    matched_event_count = IntField(default=0)
    group_value         = StringField()                # the IP, username, etc. that grouped
    status              = StringField(default="new")
    mitre_tactic        = StringField()
    mitre_technique     = StringField()
    acknowledged_by     = StringField()
    acknowledged_at     = DateTimeField()
    resolved_at         = DateTimeField()
```

Alerts link back to both the rule that generated them (`rule_id`) and the specific events that matched (`matched_event_ids`). The `get_with_events()` method loads the referenced LogEvent documents for the alert detail view. This is a manual join since MongoDB doesn't do relational joins, but the list of IDs is bounded by the correlation window size, so it's never thousands of documents.

### CorrelationRule

```python
# backend/app/models/CorrelationRule.py
class CorrelationRule(BaseDocument):
    name         = StringField(required=True, unique=True)
    rule_type    = StringField(required=True)   # threshold, sequence, aggregation
    conditions   = DictField(required=True)     # type-specific config
    severity     = StringField(required=True)
    enabled      = BooleanField(default=True)
    mitre_tactic    = StringField()
    mitre_technique = StringField()
```

The `conditions` field is a flexible dict whose shape depends on `rule_type`. For threshold rules it contains `event_filter`, `threshold`, `window_seconds`, and `group_by`. For sequence rules it has `steps` (an ordered list of event filters). For aggregation rules it adds `aggregation_field` for counting distinct values. Validation of these shapes happens in the Pydantic schemas (`backend/app/schemas/rule.py:60-82`) using a `@model_validator` that dispatches to the correct condition schema based on `rule_type`.

## Security Architecture

### Threat Model

What the platform defends against:

1. **Credential stuffing on the login endpoint.** Rate limiting at both Nginx (3r/s for auth endpoints) and Flask (10/minute via `flask-limiter`) makes brute force impractical. The `verify_password_timing_safe` function prevents username enumeration through timing differences.

2. **Unauthorized access to SIEM data.** JWT-based authentication on every API endpoint (except `/v1/logs/ingest` and public auth routes). Role-based access control gates admin operations. The `endpoint()` decorator enforces this uniformly.

3. **Privilege escalation via role manipulation.** The `update_role` controller in `admin_ctrl.py:36-43` checks `User.count_admins()` before allowing demotion. You can't demote the last admin. Admins also can't deactivate or delete their own accounts.

4. **SSE token leakage.** SSE connections can't use the Authorization header (browser limitation with EventSource), so tokens go in the query string. The `extract_bearer_token()` function in `app/core/auth.py:97-102` checks the header first, then falls back to `request.args.get("token")`. This is a known trade-off. The token appears in server access logs but is transmitted over HTTPS.

What's out of scope:
Network-level attacks (handled by infrastructure), database injection (MongoEngine parameterizes queries), XSS (React escapes by default, plus security headers from Nginx).

### Defense in Depth

```
Nginx Layer
├── Rate limiting (10r/s API, 3r/s auth)
├── Connection limits (50 per IP in prod)
├── Security headers (X-Frame-Options, X-Content-Type-Options, etc.)
└── Request size limits (10MB max body)
    │
Flask Layer
├── flask-limiter (moving window, 200/min default, 10/min auth)
├── Pydantic validation (all inputs validated before processing)
├── JWT verification (expiry, required claims)
└── Role enforcement (decorator-based RBAC)
    │
Application Layer
├── Argon2id password hashing
├── Constant-time password verification
├── Last-admin protection
└── Self-action prevention (can't deactivate your own account)
```

## Storage Strategy

### MongoDB: Persistent State

All documents that need to survive restarts. Log events, alerts, correlation rules, users, scenario runs. MongoEngine provides the ODM layer with type coercion and validation.

The `BaseDocument` class (`app/models/Base.py`) adds `created_at` and `updated_at` to every document and overrides `save()` to auto-update the timestamp. The `paginate()` class method provides consistent offset-based pagination across all collections.

Index strategy: every field used in a filter or sort gets an index. LogEvent has nine indexes, which is aggressive but appropriate for a query-heavy dashboard. Write performance takes a small hit, but reads (which dominate in a SIEM) stay fast.

### Redis: Ephemeral Streams and Rate Limits

Two Redis Streams with approximate maxlen of 10,000 entries each. The streams are ephemeral. Restarting Redis loses unprocessed messages, but since events are persisted in MongoDB first, the only impact is that the correlation engine might miss some events during the restart window. For a learning project, this is an acceptable trade-off. Production SIEMs would use persistent queues.

Rate limit counters also live in Redis. The `moving-window` strategy in `flask-limiter` stores sliding window counters keyed by client IP.

## Configuration

### Environment Variables

All configuration flows through `backend/app/config.py` using Pydantic Settings:

```python
class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
    )
    MONGO_URI: str = "mongodb://mongo:27017/siem"
    REDIS_URL: str = "redis://redis:6379/0"
    SECRET_KEY: str = "change-me-in-production"
    JWT_EXPIRATION_HOURS: int = 24
    CORRELATION_COOLDOWN_SECONDS: int = 300
    RATELIMIT_DEFAULT: str = "200/minute"
    RATELIMIT_AUTH: str = "10/minute"
    # ... ~40 more settings with defaults
```

Every setting has a sensible default, so the project works out of the box with just `docker compose up`. But the defaults are explicitly not secure for production. The `SECRET_KEY` default is `"change-me-in-production"` and Redis has no password in dev mode.

### Development vs Production

**Development** (`dev.compose.yml`): Hot reload on both frontend and backend. No Nginx auth rate limiting. Redis without a password. MongoDB port exposed on host. Frontend runs as a Vite dev server with HMR.

**Production** (`compose.yml`): Gunicorn with 4 workers. Frontend pre-built and served as static files from Nginx. Redis requires `REDIS_PASSWORD`. Nginx adds security headers, connection limits, and aggressive caching for static assets. Docker resource limits are set (backend gets 2 CPUs, 1GB RAM).

## Performance Considerations

### Bottlenecks

**Correlation engine is single-threaded.** The `CorrelationEngine._run()` loop processes events sequentially. Under heavy load (hundreds of events per second), the consumer group will accumulate a backlog. The `STREAM_READ_COUNT` setting (default 10) and `STREAM_BLOCK_MS` (default 2000) control the batch size and blocking behavior.

**MongoDB aggregations for the dashboard.** The `timeline_aggregation`, `severity_breakdown`, and `top_sources` methods all run aggregation pipelines. With millions of log events, these become slow. The `$dateTrunc` grouping in the timeline pipeline is particularly expensive without a compound index on `(timestamp, severity)`.

**SSE connections hold threads.** Each SSE client holds a Gunicorn worker thread open for the entire connection duration. With 4 workers and 3 SSE clients, only 1 worker is available for regular API requests. Production would need either more workers or an async SSE solution.

### Optimizations Already Present

**Rule caching.** The correlation engine caches enabled rules for `CORRELATION_RULE_CACHE_SECONDS` (default 30s) to avoid hitting MongoDB on every event. See `CorrelationEngine._get_rules()`.

**Approximate stream trimming.** `XADD` with `approximate=True` lets Redis trim the stream lazily rather than on every write. Slightly exceeds the 10,000 maxlen but avoids the per-write trim overhead.

**Sliding window cleanup.** `CorrelationState.get_window()` evicts expired entries every time a window is read, keeping memory bounded without a separate cleanup thread.

## Deployment Architecture

### Docker Compose Topology

```
                   ┌──────────┐
        :8431 ────→│  Nginx   │
                   └────┬─────┘
                        │
              ┌─────────┴─────────┐
              │                   │
         ┌────▼────┐        ┌────▼────┐
         │ Backend │        │ Static  │
         │ (Flask) │        │ (built  │
         │ :5000   │        │  React) │
         └────┬────┘        └─────────┘
              │
     ┌────────┴────────┐
     │                 │
┌────▼────┐     ┌──────▼─────┐
│ MongoDB │     │   Redis    │
│  :27017 │     │   :6379    │
└─────────┘     └────────────┘
```

Two Docker networks isolate traffic. The `frontend` network connects Nginx to the backend. The `backend` network connects the backend to MongoDB and Redis. MongoDB and Redis are not directly accessible from the frontend network.

Resource limits in production:
- Nginx: 1 CPU, 256MB RAM
- Backend: 2 CPUs, 1GB RAM
- MongoDB: 1 CPU, 512MB RAM
- Redis: 0.5 CPU, 256MB RAM

### Health Checks

Every service has a health check. The backend exposes `/health` which returns `"1"` (defined in `app/__init__.py`). MongoDB uses `mongosh --eval "db.adminCommand('ping')"`. Redis uses `redis-cli ping`. Nginx depends on the backend being healthy before it starts accepting traffic.

## Design Decisions

### MongoDB over PostgreSQL

MongoDB was chosen because log events are semi-structured. Different source types have different fields (firewall events have `action` and `protocol`, DNS events have `query` and `query_type`). Storing this in a relational schema would mean either a wide sparse table or a separate table per source type. MongoDB's flexible documents with the `DictField` for `raw` and `normalized` handle this naturally.

Trade-off: no transactional joins. The alert detail view requires a manual lookup of matched events by ID. With PostgreSQL, this would be a single JOIN query.

### Redis Streams over Kafka or RabbitMQ

Redis Streams provide enough pub/sub for this use case without adding another infrastructure dependency. The consumer group semantics (`XREADGROUP`, `XACK`) give exactly-once processing for the correlation engine. SSE endpoints use plain `XREAD` (no consumer group) since they're just tailing the stream for display.

Trade-off: no persistence guarantees, no multi-node replication, limited backpressure. A production SIEM would need something more robust.

### JWT over Sessions

Stateless auth means the backend doesn't need to store sessions in Redis or MongoDB. Each request carries its own proof of identity. The frontend stores the token in Zustand (persisted to localStorage via the `persist` middleware in `frontend/src/core/stores/auth.store.ts`).

Trade-off: you can't invalidate a JWT before it expires. If a user's account is deactivated, they can still make requests until the token's `exp` claim passes. The `endpoint()` decorator mitigates this by loading the user from MongoDB on every request and checking `is_active`.

### Pydantic for Request Validation

Every endpoint validates input through Pydantic schemas via the `@S` decorator. This catches bad data at the boundary before it reaches controller logic. The correlation rule schemas are particularly interesting. The `RuleCreateRequest` uses a `@model_validator` to dispatch condition validation based on `rule_type`, so threshold rules validate differently from sequence rules.

Trade-off: Pydantic adds import time and a layer of indirection. Simple endpoints that just take an ID don't need validation but still go through the decorator stack.

## Error Handling Strategy

### Error Hierarchy

```python
# backend/app/core/errors.py
AppError (500)
├── NotFoundError (404)
├── ValidationError (422, includes field-level details)
├── AuthenticationError (401)
├── ForbiddenError (403)
└── ConflictError (409)
```

All custom errors extend `AppError`, which carries a `status_code` and `message`. The `register_error_handlers()` function in `errors.py` attaches a single Flask error handler for `AppError` that serializes any subclass into a consistent JSON response: `{"error": "ErrorClassName", "message": "..."}`.

The `endpoint()` decorator adds a catch-all for unexpected exceptions. If a controller raises something that isn't an `AppError`, the decorator logs the traceback via structlog and returns a generic 500. This prevents stack traces from leaking to the client.

### Frontend Error Handling

The frontend mirrors this with `ApiError` in `frontend/src/core/lib/errors.ts`. The Axios response interceptor transforms HTTP errors into typed `ApiError` instances with codes like `AUTHENTICATION_ERROR`, `VALIDATION_ERROR`, etc. The React Query cache has global error handlers that show toast notifications for background query failures.

## Extensibility

### Adding a New Log Source Type

1. Add the source type to `SourceType` enum in `backend/app/models/LogEvent.py`
2. Write a normalizer function in `backend/app/engine/normalizer.py`:

```python
@_register(SourceType.YOUR_NEW_TYPE)
def _normalize_your_type(raw: dict[str, Any]) -> dict[str, Any]:
    return {
        "your_field": raw.get("your_field"),
        # ... extract source-specific fields
    }
```

3. Optionally add severity patterns in `backend/app/engine/severity.py`

That's it. The registry pattern means no other code changes are needed. The ingest endpoint, SSE streaming, correlation engine, and frontend log viewer all work with any source type.

### Adding a New Correlation Rule Type

1. Add the type to `RuleType` enum in `backend/app/models/CorrelationRule.py`
2. Add a Pydantic conditions schema in `backend/app/schemas/rule.py`
3. Write the evaluator function in `backend/app/engine/correlation.py`:

```python
def _evaluate_your_type(rule, event_data, state, rule_id, group_key):
    # Your evaluation logic
    # Return EvaluationResult if fired, None otherwise
```

4. Register it in the `evaluators` dict inside `evaluate_rule()`

### Adding a New API Endpoint

1. Create or update a schema in `backend/app/schemas/`
2. Write the controller function in `backend/app/controllers/`
3. Add the route in `backend/app/routes/` with the decorator stack
4. Add the frontend hook in `frontend/src/api/hooks/`
5. Add the endpoint path to `frontend/src/config.ts`

## Limitations

**No horizontal scaling.** The correlation engine uses in-memory state (`CorrelationState`). Running multiple backend instances means each instance has its own sliding windows and cooldowns. Events would be split across instances via the consumer group, but the state wouldn't be shared. Fixing this would require moving correlation state to Redis.

**No event deduplication.** If the same event is ingested twice (network retry, for example), it gets stored twice and may trigger correlation rules twice. A production system would hash the raw event and check for duplicates before persisting.

**No log retention policy.** Events accumulate in MongoDB forever. The dashboard aggregations will slow down as the collection grows. A TTL index on `timestamp` or a periodic cleanup job would fix this.

**Single consumer for correlation.** The `CONSUMER_NAME` is hardcoded to `"engine-1"`. Adding more consumers would require partitioning logic to prevent duplicate alert generation.

## Key Files Reference

Backend core:
- `backend/app/__init__.py` - Application factory, startup sequence
- `backend/app/config.py` - All settings via Pydantic
- `backend/app/core/auth.py` - JWT and password operations
- `backend/app/core/streaming.py` - Redis Streams pub/sub and SSE
- `backend/app/core/decorators/` - endpoint, S, R decorator stack
- `backend/app/engine/correlation.py` - Correlation engine and rule evaluation
- `backend/app/engine/normalizer.py` - Log normalization registry
- `backend/app/engine/severity.py` - Severity classification
- `backend/app/scenarios/runner.py` - Scenario playback threads

Frontend core:
- `frontend/src/config.ts` - API endpoints, query keys, routes
- `frontend/src/core/lib/api.ts` - Axios client with interceptors
- `frontend/src/core/stores/auth.store.ts` - Auth state with persistence
- `frontend/src/core/stores/stream.store.ts` - SSE event buffer
- `frontend/src/api/hooks/useEventStream.ts` - SSE connection management

Infrastructure:
- `dev.compose.yml` - Development Docker setup
- `compose.yml` - Production Docker setup
- `conf/nginx/nginx.conf` - Nginx main config with rate limits
- `conf/nginx/prod.nginx` - Production server block with SSE passthrough

## Next Steps

Now that you understand the architecture:
1. Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for a code-level walkthrough
2. Try modifying the normalizer to add a new source type and see the registry pattern in action
