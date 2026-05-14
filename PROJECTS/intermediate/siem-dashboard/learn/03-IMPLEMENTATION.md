# Implementation Walkthrough

This document walks through the actual code in the SIEM dashboard, file by file. We'll trace how a log event enters the system, gets normalized, classified, published to a stream, correlated against rules, and surfaced as an alert in the browser. Each section references real files, real functions, and explains why the code is structured the way it is.

If you haven't read [02-ARCHITECTURE.md](./02-ARCHITECTURE.md) yet, do that first. This document assumes you understand the high level component layout and data flow.

## Application Bootstrap

### The Factory Pattern

`app/__init__.py` contains `create_app()`, the Flask application factory. This function builds the entire backend in a specific order that matters.

```python
def create_app() -> Flask:
    app = Flask(__name__)
    config = get_settings()
    app.config.from_mapping(config.flask_config())

    # 1. Extensions first (database + cache connections)
    init_extensions(app)

    # 2. Error handlers before anything that might raise
    register_error_handlers(app)

    # 3. Rate limiter needs app context
    init_rate_limiter(app)

    # 4. Blueprints register routes
    register_blueprints(app)

    # 5. Streaming infrastructure
    ensure_consumer_group()

    # 6. Clean up orphaned scenario runs from previous crashes
    cleanup_orphaned_runs()

    # 7. Start correlation engine last (needs everything else ready)
    start_correlation_engine(app)

    return app
```

The ordering is deliberate. You can't register error handlers after blueprints start throwing errors. You can't start the correlation engine before MongoDB and Redis connections exist. And you need consumer groups created before the correlation engine tries to read from them.

A common mistake when building Flask apps: initializing things at module import time instead of inside the factory. That breaks testing (you can't create multiple app instances with different configs) and it breaks Gunicorn (the fork model means each worker needs its own connections). Everything here happens inside `create_app()`, which means each Gunicorn worker gets its own setup.

### Configuration

`app/config.py` uses Pydantic's `BaseSettings` to load configuration from environment variables with sensible defaults. The settings class has around 60 values covering everything from MongoDB URIs to correlation engine tuning.

```python
class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Core
    SECRET_KEY: str = "change-me-in-production"
    DEBUG: bool = False

    # MongoDB
    MONGODB_HOST: str = "mongodb://mongo:27017/siem"

    # Redis
    REDIS_URL: str = "redis://redis:6379/0"

    # Correlation
    CORRELATION_COOLDOWN_SECONDS: int = 300
    STREAM_READ_COUNT: int = 10
    STREAM_BLOCK_MS: int = 2000

    # Rate limiting
    RATELIMIT_DEFAULT: str = "200 per minute"
    RATELIMIT_AUTH: str = "10 per minute"
```

The `flask_config()` method on Settings translates these into Flask's config format. Notice the `SECRET_KEY` default. That string is intentionally obvious so nobody accidentally ships it to production. Pydantic will override it from the environment or `.env` file automatically.

The `get_settings()` function uses `@lru_cache` to create a singleton. This means the settings are parsed once (with all the Pydantic validation) and then reused. Without the cache, every access to settings would re-parse environment variables and re-validate.

### Extensions

`app/extensions.py` initializes MongoEngine and Redis as module-level singletons:

```python
db = MongoEngine()
redis_client: Redis | None = None

def init_extensions(app: Flask) -> None:
    db.init_app(app)

    global redis_client
    redis_client = Redis.from_url(
        app.config["REDIS_URL"],
        decode_responses=True,
    )
```

MongoEngine uses Flask's `init_app` pattern (lazy initialization). Redis is simpler: just create a connection from the URL. The `decode_responses=True` parameter means Redis returns Python strings instead of bytes. This matters everywhere downstream because you'll be JSON-serializing Redis data and `bytes` objects don't serialize cleanly.

## Log Ingestion Pipeline

This is the core pipeline. A raw event enters via HTTP POST, gets transformed, stored, published, correlated, and potentially triggers an alert. Let's trace the full path.

### Step 1: HTTP Entry Point

`app/routes/log_routes.py` defines the ingestion endpoint:

```python
@bp.post("/ingest")
@S(body=LogIngestSchema)
@R(status_code=201)
def ingest_log(body: LogIngestSchema):
    return log_ctrl.ingest_event(body)
```

Three decorators, each with a specific job. `@S(body=LogIngestSchema)` validates the request body against a Pydantic schema. `@R(status_code=201)` serializes the return value and sets the response code. The route itself is just one line of business logic delegation.

Note this endpoint has no `@endpoint()` decorator, which means it's unauthenticated. This is intentional. In a real deployment, log sources (firewalls, servers, agents) send events to the SIEM without user credentials. They'd authenticate via API keys or network-level controls, but for this project the ingestion endpoint is open.

### Step 2: Schema Validation

`app/schemas/log_schemas.py` defines what a valid ingestion request looks like:

```python
class LogIngestSchema(BaseModel):
    source_type: SourceType
    event_type: str
    timestamp: datetime | None = None
    source_ip: str | None = None
    source_port: int | None = None
    dest_ip: str | None = None
    dest_port: int | None = None
    protocol: str | None = None
    username: str | None = None
    hostname: str | None = None
    message: str | None = None
    # ... additional optional fields per source type
```

`SourceType` is a string enum: `firewall`, `ids`, `auth`, `endpoint`, `dns`, `proxy`, `generic`. Pydantic validates the enum value automatically. If you POST `"source_type": "foo"`, you get a 422 with a clear error message before any business logic runs.

Most fields are optional because different source types provide different data. A firewall log has `source_ip` and `dest_ip` but no `username`. An auth log has `username` but might not have `dest_ip`. The normalizer handles making sense of whatever fields are present.

### Step 3: Controller Logic

`app/controllers/log_ctrl.py` orchestrates the ingestion:

```python
def ingest_event(body: LogIngestSchema) -> dict:
    raw = body.model_dump(exclude_none=True)

    # Normalize: common fields + source-specific extraction
    normalized_data = normalize(raw)

    # Classify severity based on event type and content
    severity = classify_severity(raw)

    # Build and save the document
    event = LogEvent(
        source_type=raw["source_type"],
        event_type=raw["event_type"],
        severity=severity,
        timestamp=raw.get("timestamp", datetime.utcnow()),
        source_ip=raw.get("source_ip"),
        dest_ip=raw.get("dest_ip"),
        # ... remaining fields
        raw=raw,
        normalized=normalized_data,
    )
    event.save()

    # Publish to Redis Stream for real-time consumers
    publish_log_event(event)

    return serialize_document(event)
```

Three operations happen in sequence: normalize, classify, persist. Then the event is published to the Redis Stream asynchronously. The `raw` dict is preserved on the document alongside the `normalized` dict. This dual storage is important for forensics, as covered in [01-CONCEPTS.md](./01-CONCEPTS.md).

The controller calls `model_dump(exclude_none=True)` on the Pydantic schema to strip out fields that weren't provided. This prevents storing a bunch of `null` values in MongoDB and keeps the raw payload clean.

### Step 4: Normalization

`app/engine/normalizer.py` transforms raw events into a consistent structure. The registry pattern here is worth studying:

```python
NORMALIZERS: dict[str, Callable] = {}

def _register(source_type: SourceType):
    """Decorator to register a normalizer function for a source type."""
    def decorator(fn: Callable) -> Callable:
        NORMALIZERS[source_type.value] = fn
        return fn
    return decorator
```

Each source type gets its own normalizer function:

```python
@_register(SourceType.FIREWALL)
def _normalize_firewall(data: dict) -> dict:
    return {
        "action": data.get("action"),
        "protocol": data.get("protocol"),
        "bytes_sent": data.get("bytes_sent", 0),
        "bytes_received": data.get("bytes_received", 0),
    }

@_register(SourceType.AUTH)
def _normalize_auth(data: dict) -> dict:
    return {
        "auth_method": data.get("auth_method"),
        "result": data.get("result"),
        "failure_reason": data.get("failure_reason"),
    }

@_register(SourceType.DNS)
def _normalize_dns(data: dict) -> dict:
    return {
        "query": data.get("query"),
        "query_type": data.get("query_type"),
        "response_code": data.get("response_code"),
    }
```

The dispatch function ties it together:

```python
def normalize(data: dict) -> dict:
    source_type = data.get("source_type", "generic")
    normalizer = NORMALIZERS.get(source_type, NORMALIZERS["generic"])
    return normalizer(data)
```

This pattern makes adding new log sources trivial. Write a function, slap the `@_register` decorator on it, and you're done. No switch statements, no if/elif chains, no modification to existing code. The dispatcher looks up the function from the dict and calls it.

One thing to note: if a source type isn't recognized, it falls back to the `generic` normalizer, which just grabs the `message` field. This is a design choice. Failing silently on unknown source types means the system keeps ingesting even if it encounters something unexpected. In production you'd want to log a warning, but dropping events is worse than storing them with minimal normalization.

### Step 5: Severity Classification

`app/engine/severity.py` assigns a severity level to each event. It uses a two tier approach:

```python
HIGH_SEVERITY_EVENT_TYPES = frozenset({
    "privilege_escalation", "data_exfiltration",
    "c2_communication", "reverse_shell",
})

MEDIUM_SEVERITY_EVENT_TYPES = frozenset({
    "login_failure", "port_scan",
    "firewall_deny", "ids_alert",
})

CRITICAL_PATTERNS = [
    re.compile(r"privilege.?escalat", re.IGNORECASE),
    re.compile(r"ransomware", re.IGNORECASE),
    re.compile(r"c2.?beacon", re.IGNORECASE),
    re.compile(r"data.?exfil", re.IGNORECASE),
]

HIGH_PATTERNS = [
    re.compile(r"brute.?force", re.IGNORECASE),
    re.compile(r"lateral.?movement", re.IGNORECASE),
    re.compile(r"reverse.?shell", re.IGNORECASE),
    re.compile(r"credential.?dump", re.IGNORECASE),
]
```

The `classify_severity()` function checks the event type first (fast O(1) frozen set lookup), then falls through to regex matching on concatenated text fields:

```python
def classify_severity(data: dict) -> str:
    event_type = data.get("event_type", "")

    # Fast path: check event type directly
    if event_type in HIGH_SEVERITY_EVENT_TYPES:
        return "high"
    if event_type in MEDIUM_SEVERITY_EVENT_TYPES:
        return "medium"

    # Slow path: regex against content
    searchable = _build_searchable_text(data)

    for pattern in CRITICAL_PATTERNS:
        if pattern.search(searchable):
            return "critical"
    for pattern in HIGH_PATTERNS:
        if pattern.search(searchable):
            return "high"
    # ... medium and low patterns

    return "info"  # Default
```

The `_build_searchable_text()` helper concatenates `event_type`, `message`, and relevant normalized fields (like `signature_name` from IDS events or `command_line` from endpoint events) into a single string. This means a PowerShell command line containing "lateral movement" gets classified as high severity even if the event_type is just "process_execution".

The frozen sets are important. Python's `in` operator on a frozenset is O(1) average case. The regex patterns are compiled once at module load time, not on every classification call. These are small optimizations, but when you're classifying thousands of events per second they add up.

The default return of `"info"` is deliberate. Most events in a production environment are routine. Classifying unknowns as high severity would create alert fatigue and train analysts to ignore alerts.

### Step 6: Publishing to Redis Stream

`app/core/streaming.py` handles the Redis Streams integration:

```python
def publish_log_event(event: LogEvent) -> str | None:
    """Publish a log event to the Redis log stream."""
    try:
        data = {
            "id": str(event.id),
            "source_type": event.source_type,
            "event_type": event.event_type,
            "severity": event.severity,
            "source_ip": event.source_ip or "",
            "dest_ip": event.dest_ip or "",
            "username": event.username or "",
            "hostname": event.hostname or "",
            "timestamp": event.timestamp.isoformat(),
        }
        stream_id = redis_client.xadd(
            STREAM_LOGS,
            data,
            maxlen=STREAM_MAXLEN,
            approximate=True,
        )
        return stream_id
    except Exception:
        logger.exception("Failed to publish log event")
        return None
```

Several things to note here:

The `maxlen` parameter with `approximate=True` keeps the stream from growing without bound. Redis doesn't trim to exactly 10000 entries. Instead it trims in bulk when the stream exceeds the limit, which is more efficient than exact trimming. The stream might temporarily hold 10500 entries before Redis trims it back down.

The `None` values get converted to empty strings because Redis Stream fields can't store `None`. Downstream consumers need to handle empty strings as missing values.

The `try/except` with `return None` means a Redis failure doesn't crash the ingestion pipeline. The event is already persisted in MongoDB at this point. Losing the stream publish is acceptable. The event won't trigger real-time correlation or show up in the SSE feed until it's re-processed, but it won't be lost.

### Step 7: Consumer Group Setup

Before the correlation engine can read from the stream, consumer groups need to exist:

```python
def ensure_consumer_group() -> None:
    """Create consumer groups if they don't exist."""
    with contextlib.suppress(Exception):
        redis_client.xgroup_create(
            STREAM_LOGS,
            CONSUMER_GROUP,
            id="0",
            mkstream=True,
        )
    with contextlib.suppress(Exception):
        redis_client.xgroup_create(
            STREAM_ALERTS,
            CONSUMER_GROUP,
            id="0",
            mkstream=True,
        )
```

The `contextlib.suppress(Exception)` handles the case where the consumer group already exists (Redis throws `BUSYGROUP`). This makes the function idempotent, safe to call on every startup. The `mkstream=True` parameter creates the stream itself if it doesn't exist. The `id="0"` means the consumer group starts reading from the beginning of the stream.

## Correlation Engine

This is the most complex part of the backend. The engine runs in a background thread, consuming events from Redis and evaluating them against correlation rules.

### Engine Lifecycle

`app/engine/correlation.py` defines the `CorrelationEngine` class:

```python
class CorrelationEngine:
    def __init__(self, app: Flask):
        self.app = app
        self.state = CorrelationState()
        self._thread: threading.Thread | None = None
        self._stop_event = threading.Event()

    def start(self) -> None:
        self._thread = threading.Thread(
            target=self._run,
            daemon=True,
            name="correlation-engine",
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=5)
```

The engine starts as a daemon thread. Daemon threads are killed when the main process exits, so there's no risk of orphaned engine threads keeping the process alive. The `_stop_event` provides a clean shutdown path: the `_run()` loop checks it on every iteration.

### The Main Loop

```python
def _run(self) -> None:
    with self.app.app_context():
        while not self._stop_event.is_set():
            try:
                messages = redis_client.xreadgroup(
                    groupname=CONSUMER_GROUP,
                    consumername=CONSUMER_NAME,
                    streams={STREAM_LOGS: ">"},
                    count=STREAM_READ_COUNT,
                    block=STREAM_BLOCK_MS,
                )
                if messages:
                    for stream_name, entries in messages:
                        for entry_id, data in entries:
                            self._process_event(data, entry_id)
                            redis_client.xack(
                                STREAM_LOGS,
                                CONSUMER_GROUP,
                                entry_id,
                            )
            except Exception:
                logger.exception("Correlation engine error")
                time.sleep(1)
```

Let's break this down:

`self.app.app_context()` pushes a Flask application context. Without this, the thread can't access MongoEngine (which is tied to Flask's app context) or the config. This is a common Flask gotcha with background threads.

`xreadgroup` with `">"` reads only new, undelivered messages. The `block=STREAM_BLOCK_MS` (default 2000ms) makes this a blocking call. The thread sleeps for up to 2 seconds waiting for new events instead of busy-polling. When events arrive, it wakes up immediately.

`count=STREAM_READ_COUNT` (default 10) limits how many events are read per call. This controls batch size. Reading 10 events at a time means the engine processes in small batches, which keeps per-event latency low while amortizing the Redis call overhead.

After processing each event, `xack` acknowledges it. This tells Redis the event was successfully handled and doesn't need redelivery. If the engine crashes before acknowledging, Redis will redeliver the event on the next startup. This gives you at-least-once processing semantics.

The `except Exception` with a 1-second sleep prevents a tight error loop. If Redis goes down, the engine logs the error and waits a second before retrying instead of hammering the dead connection.

### Rule Loading and Caching

```python
def _get_rules(self) -> list:
    """Load enabled rules with caching."""
    now = time.time()
    if now - self._rules_cache_time > RULES_CACHE_TTL:
        self._rules_cache = list(
            CorrelationRule.objects(enabled=True)
        )
        self._rules_cache_time = now
    return self._rules_cache
```

Rules are cached for 30 seconds (`RULES_CACHE_TTL`). Without caching, every event would trigger a MongoDB query for all enabled rules. With 100 events per second and 20 rules, that's 100 database queries per second just for rule loading. The cache reduces this to one query every 30 seconds.

The tradeoff: when you create or modify a rule, it takes up to 30 seconds to take effect. For a SIEM, this is fine. Detection rules aren't time-critical to deploy. If you needed sub-second rule updates, you'd use a Redis pub/sub channel to notify the engine of changes.

### Event Processing

```python
def _process_event(self, data: dict, entry_id: str) -> None:
    rules = self._get_rules()
    for rule in rules:
        try:
            evaluator = EVALUATORS.get(rule.rule_type)
            if evaluator and self._event_matches_rule(data, rule):
                fired = evaluator(rule, data, self.state)
                if fired:
                    self._create_alert(rule, data, fired)
        except Exception:
            logger.exception(f"Error evaluating rule {rule.id}")
```

For each event, the engine iterates over all enabled rules. First it checks whether the event is relevant to the rule (does the `event_type` match? does the `source_type` match?). Then it calls the appropriate evaluator based on rule type.

The `EVALUATORS` dict maps rule types to functions:

```python
EVALUATORS = {
    "threshold": _evaluate_threshold,
    "sequence": _evaluate_sequence,
    "aggregation": _evaluate_aggregation,
}
```

This is the same registry pattern used in the normalizer. Adding a new rule type means writing an evaluator function and adding one entry to this dict.

### Threshold Evaluation

The threshold evaluator counts matching events per group key within a time window:

```python
def _evaluate_threshold(
    rule: CorrelationRule,
    data: dict,
    state: CorrelationState,
) -> list[str] | None:
    conditions = rule.conditions
    group_key = data.get(conditions.get("group_by", "source_ip"), "")
    window = conditions.get("window_seconds", 300)
    threshold = conditions.get("threshold", 10)

    # Add event to sliding window
    state.add_event(rule.id, group_key, data, window)

    # Check if threshold exceeded
    count = state.get_count(rule.id, group_key)
    if count >= threshold:
        if not state.in_cooldown(rule.id, group_key):
            state.set_cooldown(rule.id, group_key)
            return state.get_event_ids(rule.id, group_key)

    return None
```

The sliding window is maintained by `CorrelationState`. When we add an event, expired entries (older than `window_seconds`) are pruned. The count reflects only events within the current window.

The cooldown check is critical. Without it, once the threshold is exceeded, every subsequent event would fire the rule again. A 10-minute brute force attack with threshold 10 and window 300 would generate hundreds of alerts without cooldown. With the default 300-second cooldown, it generates at most 2 alerts (one at the threshold, potentially another after the cooldown expires if the attack continues).

### Sequence Evaluation

Sequence rules are more complex. They track ordered sets of event types:

```python
def _evaluate_sequence(
    rule: CorrelationRule,
    data: dict,
    state: CorrelationState,
) -> list[str] | None:
    conditions = rule.conditions
    steps = conditions.get("steps", [])
    group_key = data.get(conditions.get("group_by", "source_ip"), "")
    window = conditions.get("window_seconds", 300)

    event_type = data.get("event_type", "")

    # Find which step this event matches
    for i, step in enumerate(steps):
        if event_type == step.get("event_type"):
            state.add_sequence_event(
                rule.id, group_key, i, data, window
            )
            break

    # Check if all steps are satisfied in order
    if state.sequence_complete(rule.id, group_key, steps):
        if not state.in_cooldown(rule.id, group_key):
            state.set_cooldown(rule.id, group_key)
            return state.get_sequence_event_ids(rule.id, group_key)

    return None
```

A sequence rule with steps `[login_failure (count >= 5), login_success]` means: within the window, we need at least 5 `login_failure` events from the same group key, followed by at least one `login_success`. The `sequence_complete()` method checks both the ordering and the per-step count requirements.

This models real attack patterns. Brute force followed by compromise isn't just "both happened." It's "failures happened first, then success." A sequence rule respects that ordering.

### Aggregation Evaluation

Aggregation rules count distinct values:

```python
def _evaluate_aggregation(
    rule: CorrelationRule,
    data: dict,
    state: CorrelationState,
) -> list[str] | None:
    conditions = rule.conditions
    group_key = data.get(conditions.get("group_by", "source_ip"), "")
    agg_field = conditions.get("aggregation_field", "dest_ip")
    window = conditions.get("window_seconds", 60)
    threshold = conditions.get("threshold", 20)

    agg_value = data.get(agg_field, "")
    state.add_aggregation_event(
        rule.id, group_key, agg_value, data, window
    )

    distinct_count = state.get_distinct_count(rule.id, group_key)
    if distinct_count >= threshold:
        if not state.in_cooldown(rule.id, group_key):
            state.set_cooldown(rule.id, group_key)
            return state.get_aggregation_event_ids(rule.id, group_key)

    return None
```

The classic use case: port scanning detection. One source IP connects to 20+ distinct destination IPs in a minute. The aggregation state tracks which destination IPs have been seen (using a set for O(1) membership checks) and fires when the set exceeds the threshold.

### Thread-Safe State

`CorrelationState` uses threading locks because it's accessed from the correlation engine thread while the main thread might be reading state for debugging or testing:

```python
class CorrelationState:
    def __init__(self):
        self._lock = threading.Lock()
        self._windows: dict[str, dict[str, list]] = {}
        self._cooldowns: dict[str, dict[str, float]] = {}

    def add_event(self, rule_id, group_key, data, window_seconds):
        with self._lock:
            key = f"{rule_id}:{group_key}"
            now = time.time()

            if key not in self._windows:
                self._windows[key] = []

            # Prune expired
            cutoff = now - window_seconds
            self._windows[key] = [
                e for e in self._windows[key]
                if e["timestamp"] > cutoff
            ]

            # Add new
            self._windows[key].append({
                "timestamp": now,
                "event_id": data.get("id"),
                "data": data,
            })
```

The lock is coarse-grained: one lock for the entire state object. This is simpler than per-key locking and plenty fast for single-threaded consumption. If you needed to scale to multiple correlation engine threads, you'd want finer-grained locking or a lock-free concurrent data structure.

The sliding window prunes on every insertion. Old entries beyond `window_seconds` are filtered out. This keeps memory bounded. Without pruning, the state would grow linearly with event volume and never shrink.

### Alert Creation

When a rule fires, the engine creates an Alert document:

```python
def _create_alert(self, rule, data, event_ids):
    with self.app.app_context():
        alert = Alert.create_from_rule(
            rule=rule,
            matched_event_ids=event_ids,
            trigger_event=data,
        )

        # Publish to alert stream
        publish_alert(alert)
```

`Alert.create_from_rule()` is a class method on the Alert model that builds and saves the document, copying the rule's `mitre_tactic`, `mitre_technique`, severity, and description. The `matched_event_ids` field stores references to the LogEvent documents that triggered the rule. This lets analysts drill down from an alert to the raw events.

After saving, the alert is published to the `siem:alerts` Redis Stream. The frontend's SSE connection picks this up and shows a notification in the browser.

## Authentication System

### Password Hashing

`app/core/auth.py` implements the auth layer:

```python
from pwdlib import PasswordHash
from pwdlib.hashers.argon2 import Argon2Hasher

_hasher = PasswordHash((Argon2Hasher(),))

DUMMY_HASH = _hasher.hash("dummy-password-for-timing")

def hash_password(password: str) -> str:
    return _hasher.hash(password)

def verify_password_timing_safe(password: str, hash: str | None) -> bool:
    """Verify password with constant-time behavior."""
    if hash is None:
        # User doesn't exist - still do the work
        _hasher.verify(password, DUMMY_HASH)
        return False
    return _hasher.verify(password, hash)
```

The `DUMMY_HASH` is computed once at module load time. When `hash` is `None` (user doesn't exist), the function still performs a full Argon2id verification against this dummy. The result is thrown away, but the time cost is the same. This prevents username enumeration via timing side channels.

Why `pwdlib` instead of `passlib`? `pwdlib` is a newer library with a cleaner API and better Argon2id defaults. The default parameters (memory cost, time cost, parallelism) match current OWASP recommendations without manual tuning.

### JWT Tokens

```python
def create_access_token(user: User) -> str:
    config = get_settings()
    now = datetime.utcnow()
    payload = {
        "sub": str(user.id),
        "username": user.username,
        "role": user.role,
        "iat": now,
        "exp": now + timedelta(hours=config.JWT_EXPIRY_HOURS),
    }
    return jwt.encode(payload, config.SECRET_KEY, algorithm="HS256")

def decode_access_token(token: str) -> dict:
    config = get_settings()
    return jwt.decode(token, config.SECRET_KEY, algorithms=["HS256"])
```

The JWT contains the user's ID, username, and role. This means the `@endpoint()` decorator can check authorization without a database query for most requests. The role is embedded in the token.

The tradeoff: you can't revoke a JWT before it expires. If you change a user's role or deactivate their account, the old token still works until expiry. The code mitigates this by loading the user from MongoDB on every authenticated request (in the `@endpoint` decorator) and checking `is_active`. This means a deactivated user gets blocked on the next request, not just at token expiry.

### The Endpoint Decorator

`app/core/decorators/endpoint.py` is the auth enforcement point:

```python
def endpoint(roles: str | tuple | None = None):
    def decorator(fn):
        @wraps(fn)
        def wrapper(*args, **kwargs):
            token = _extract_token(request)
            if token is None:
                raise AuthenticationError("Missing token")

            payload = decode_access_token(token)
            user = User.objects(id=payload["sub"]).first()

            if user is None or not user.is_active:
                raise AuthenticationError("Invalid or inactive user")

            if roles and user.role not in (
                roles if isinstance(roles, tuple) else (roles,)
            ):
                raise ForbiddenError("Insufficient permissions")

            g.current_user = user
            return fn(*args, **kwargs)
        return wrapper
    return decorator
```

`_extract_token()` pulls the JWT from the `Authorization: Bearer <token>` header. For SSE endpoints, it also checks query parameters because the browser's `EventSource` API doesn't support custom headers. This is noted in the architecture doc as a known tradeoff.

The decorator loads the full user from MongoDB on every request. This seems expensive, but it's necessary. The JWT could be stale (role changed, account deactivated). The database check ensures the current state is used for authorization decisions.

`g.current_user` stores the user on Flask's request-scoped `g` object. Any function downstream can access the authenticated user via `g.current_user` without passing it through parameters.

## The Decorator Stack

The project uses three composable decorators that form a pipeline: `@endpoint`, `@S`, and `@R`. Understanding how they compose is important.

### @S (Schema Validation)

`app/core/decorators/schema.py`:

```python
def S(body: type[BaseModel] | None = None,
      query: type[BaseModel] | None = None):
    def decorator(fn):
        @wraps(fn)
        def wrapper(*args, **kwargs):
            if body:
                try:
                    parsed = body.model_validate(request.get_json())
                except ValidationError as e:
                    raise AppValidationError(str(e))
                kwargs["body"] = parsed

            if query:
                try:
                    parsed = query.model_validate(request.args.to_dict())
                except ValidationError as e:
                    raise AppValidationError(str(e))
                kwargs["query"] = parsed

            return fn(*args, **kwargs)
        return wrapper
    return decorator
```

`@S` intercepts the request before the route function runs. It parses the request body and/or query parameters against Pydantic schemas. Validated data is injected as keyword arguments (`body=`, `query=`). If validation fails, it raises an `AppValidationError` that the error handler converts to a 422 response.

### @R (Response Serialization)

`app/core/decorators/response.py`:

```python
def R(status_code: int = 200):
    def decorator(fn):
        @wraps(fn)
        def wrapper(*args, **kwargs):
            result = fn(*args, **kwargs)
            if isinstance(result, Response):
                return result
            return jsonify(result), status_code
        return wrapper
    return decorator
```

`@R` wraps the return value in `jsonify()` and sets the status code. If the function returns a Flask `Response` directly (like for streaming), it passes through unchanged.

### Composition Order

When you see a route like:

```python
@bp.post("/")
@endpoint(roles=ADMIN)
@S(body=RuleCreateSchema)
@R(status_code=201)
def create_rule(body: RuleCreateSchema):
    return rule_ctrl.create(body)
```

The decorators execute from bottom to top (outermost first):
1. `@endpoint` checks auth and sets `g.current_user`
2. `@S` validates the request body
3. The route function runs
4. `@R` serializes the response

If auth fails, schema validation never runs. If validation fails, the route function never runs. Each decorator either passes control to the next one or short-circuits with an error.

## Streaming and SSE

### SSE Generator

`app/core/streaming.py` implements the Server-Sent Events generator:

```python
def sse_log_stream(last_id: str = "$"):
    """Generator that yields SSE events from the log stream."""
    while True:
        try:
            results = redis_client.xread(
                streams={STREAM_LOGS: last_id},
                count=10,
                block=STREAM_BLOCK_MS,
            )
            if results:
                for stream_name, entries in results:
                    for entry_id, data in entries:
                        last_id = entry_id
                        yield f"data: {json.dumps(data)}\n\n"
            else:
                # No events within block timeout - send keepalive
                yield ": keepalive\n\n"
        except GeneratorExit:
            break
        except Exception:
            logger.exception("SSE stream error")
            yield ": error\n\n"
            time.sleep(1)
```

Key details:

`xread` (not `xreadgroup`) is used for SSE. Consumer groups provide exactly-once delivery, which is appropriate for the correlation engine. But SSE clients are ephemeral browsers that come and go. If a browser disconnects and reconnects, it should get current events, not replayed old ones. `xread` with `$` starts from the latest event.

The keepalive comment (`: keepalive\n\n`) is an SSE comment (starts with `:`). The browser ignores it, but it keeps the HTTP connection alive. Without it, proxies and load balancers would time out the connection. Nginx's default `proxy_read_timeout` is 60 seconds. The Nginx config for this project sets it to 3600 seconds for SSE endpoints, but keepalives are still needed as a safety net.

`GeneratorExit` fires when the client disconnects. This is Python's way of telling the generator to clean up. Without catching it, the generator would log a spurious error on every client disconnect.

### SSE Route

```python
@bp.get("/stream")
@endpoint()
def stream_logs():
    token = request.args.get("token")  # SSE can't use headers
    return Response(
        sse_log_stream(),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",  # Nginx hint
        },
    )
```

The `X-Accel-Buffering: no` header tells Nginx to disable response buffering for this endpoint. Combined with `proxy_buffering off` in the Nginx config, this ensures events flow through to the browser immediately instead of being buffered.

## Scenario Playback System

### YAML Playbooks

The project includes attack scenario playbooks in `app/scenarios/playbooks/`. Each YAML file describes a sequence of events that simulate a real attack:

```yaml
# brute_force_lateral.yml
name: "Brute Force with Lateral Movement"
description: "SSH brute force followed by lateral movement"
mitre_techniques:
  - T1110.001
  - T1021.004
steps:
  - delay: 0
    event:
      source_type: auth
      event_type: login_failure
      source_ip: "203.0.113.50"
      username: root
      hostname: web-01
      auth_method: ssh_password
      failure_reason: invalid_password
  # ... 19 more login_failure events with varying usernames
  - delay: 2
    event:
      source_type: auth
      event_type: login_success
      source_ip: "203.0.113.50"
      username: admin
      hostname: web-01
      auth_method: ssh_password
  - delay: 5
    event:
      source_type: auth
      event_type: login_success
      source_ip: "10.0.1.10"  # Internal IP now
      username: admin
      hostname: db-01
      auth_method: ssh_key
```

The `delay` field (in seconds) spaces out events realistically. A real brute force doesn't happen in zero time. The delays let the correlation engine's sliding windows work correctly during playback.

### Playbook Parser

`app/scenarios/playbook.py` loads and validates these YAML files:

```python
def load_playbook(name: str) -> dict:
    playbook_dir = Path(__file__).parent / "playbooks"
    path = playbook_dir / f"{name}.yml"

    if not path.exists():
        raise NotFoundError(f"Playbook '{name}' not found")

    with open(path) as f:
        playbook = yaml.safe_load(f)

    # Validate structure
    if "steps" not in playbook:
        raise ValidationError("Playbook missing 'steps'")

    return playbook
```

`yaml.safe_load` is used instead of `yaml.load`. This is a security consideration. `yaml.load` can execute arbitrary Python code embedded in YAML (via `!!python/object` tags). `safe_load` rejects those. In a security tool, this matters more than most places.

### Threaded Runner

`app/scenarios/runner.py` executes playbooks in background threads:

```python
class ScenarioRunner:
    _active_runs: dict[str, threading.Thread] = {}

    @classmethod
    def start(cls, playbook_name: str, run_id: str, app: Flask) -> None:
        thread = threading.Thread(
            target=cls._execute,
            args=(playbook_name, run_id, app),
            daemon=True,
        )
        cls._active_runs[run_id] = thread
        thread.start()

    @classmethod
    def _execute(cls, playbook_name, run_id, app):
        with app.app_context():
            playbook = load_playbook(playbook_name)
            run = ScenarioRun.objects(id=run_id).first()

            try:
                run.update(status="running")
                for step in playbook["steps"]:
                    if run.reload().status == "cancelled":
                        break

                    delay = step.get("delay", 0)
                    if delay > 0:
                        time.sleep(delay)

                    # Ingest the event through the normal pipeline
                    event_data = step["event"]
                    event_data["scenario_run_id"] = run_id
                    _ingest_scenario_event(event_data)

                status = "cancelled" if run.reload().status == "cancelled" else "completed"
                run.update(status=status)
            except Exception as e:
                run.update(status="failed", error=str(e))
            finally:
                cls._active_runs.pop(run_id, None)
```

Events injected by scenarios go through the same ingestion pipeline as real events. They get normalized, classified, persisted, published to the stream, and correlated. The only difference is the `scenario_run_id` field, which tags them for later cleanup and filtering.

The `run.reload().status == "cancelled"` check on every step allows stopping a running scenario. When a user clicks "Cancel" in the UI, the status is updated in MongoDB, and the next loop iteration picks it up.

The `_active_runs` dict tracks running threads. The `cleanup_orphaned_runs()` function called during startup marks any runs with status "running" as "failed" since they were interrupted by a process restart.

## Frontend Integration

### SSE Hook

`src/api/hooks/useEventStream.ts` connects the browser to the SSE endpoints:

```typescript
export function useEventStream(
  endpoint: 'logs' | 'alerts',
  enabled: boolean = true
) {
  const { token } = useAuthStore();
  const addEvent = useStreamStore((s) => s.addEvent);
  const addAlert = useStreamStore((s) => s.addAlert);

  useEffect(() => {
    if (!enabled || !token) return;

    const url = `${API_BASE}/${endpoint}/stream?token=${token}`;
    const source = new EventSource(url);

    source.onmessage = (event) => {
      const data = JSON.parse(event.data);
      if (endpoint === 'logs') {
        addEvent(data);
      } else {
        addAlert(data);
      }
    };

    source.onerror = () => {
      source.close();
      // Reconnect after delay
      setTimeout(() => {
        // React will re-run the effect
      }, 3000);
    };

    return () => source.close();
  }, [token, endpoint, enabled]);
}
```

The token is passed as a query parameter because `EventSource` doesn't support custom headers. This is a well known limitation of the SSE API. The token is still transmitted over HTTPS (assuming production deployment), so it's encrypted in transit.

The reconnect logic is simple: close the connection and let React's `useEffect` cleanup/re-run cycle handle reconnection. In production you'd want exponential backoff, but for a learning project this is sufficient.

### Zustand Stores

`src/core/stores/stream.store.ts` manages real-time event state:

```typescript
interface StreamState {
  events: LogEvent[];
  alerts: Alert[];
  addEvent: (event: LogEvent) => void;
  addAlert: (alert: Alert) => void;
  clearEvents: () => void;
}

export const useStreamStore = create<StreamState>((set) => ({
  events: [],
  alerts: [],
  addEvent: (event) =>
    set((state) => ({
      events: [...state.events, event].slice(-100),
    })),
  addAlert: (alert) =>
    set((state) => ({
      alerts: [...state.alerts, alert].slice(-50),
    })),
  clearEvents: () => set({ events: [], alerts: [] }),
}));
```

The `.slice(-100)` caps the in-memory event buffer at 100 entries. Without this, a sustained event stream would grow the browser's memory without bound. The UI shows the latest 100 events in real time, and users can query the full history via the search API.

### Auth Store

`src/core/stores/auth.store.ts` handles authentication state with persistence:

```typescript
export const useAuthStore = create<AuthState>()(
  persist(
    (set) => ({
      token: null,
      user: null,
      login: (token, user) => set({ token, user }),
      logout: () => set({ token: null, user: null }),
    }),
    {
      name: 'siem-auth',
    }
  )
);
```

Zustand's `persist` middleware saves the token and user to `localStorage`. This means refreshing the page doesn't log you out. The Axios interceptor in `src/core/lib/api.ts` reads the token from this store and attaches it to every API request:

```typescript
api.interceptors.request.use((config) => {
  const { token } = useAuthStore.getState();
  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});
```

### TanStack Query Hooks

`src/api/hooks/` contains custom hooks for each API resource. The pattern is consistent:

```typescript
// useAlerts.ts
export function useAlerts(params?: AlertQueryParams) {
  return useQuery({
    queryKey: [QUERY_KEYS.ALERTS, params],
    queryFn: () => api.get('/alerts', { params }).then((r) => r.data),
  });
}

export function useUpdateAlertStatus() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id, status }: { id: string; status: string }) =>
      api.patch(`/alerts/${id}/status`, { status }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: [QUERY_KEYS.ALERTS] });
    },
  });
}
```

TanStack Query handles caching, deduplication, and background refetching. When an alert's status is updated, `invalidateQueries` forces a refresh of the alerts list. This keeps the UI consistent without manual state management.

## Dashboard Aggregations

The dashboard page shows summary visualizations: timeline, severity breakdown, and top sources. These are powered by MongoDB aggregation pipelines.

### Timeline Aggregation

`app/controllers/dashboard_ctrl.py`:

```python
def get_timeline(hours: int = 24, bucket_minutes: int = 15):
    cutoff = datetime.utcnow() - timedelta(hours=hours)

    pipeline = [
        {"$match": {"timestamp": {"$gte": cutoff}}},
        {"$group": {
            "_id": {
                "$dateTrunc": {
                    "date": "$timestamp",
                    "unit": "minute",
                    "binSize": bucket_minutes,
                }
            },
            "count": {"$sum": 1},
            "critical": {
                "$sum": {"$cond": [
                    {"$eq": ["$severity", "critical"]}, 1, 0
                ]}
            },
            "high": {
                "$sum": {"$cond": [
                    {"$eq": ["$severity", "high"]}, 1, 0
                ]}
            },
        }},
        {"$sort": {"_id": 1}},
    ]

    return list(LogEvent.objects.aggregate(pipeline))
```

`$dateTrunc` buckets timestamps into 15-minute intervals. Within each bucket, the pipeline counts total events and breaks them down by severity. The frontend renders this as a stacked area chart.

This query hits the `timestamp` index on `LogEvent`. Without that index, MongoDB would scan every document. With millions of events, that's the difference between milliseconds and minutes.

### Pivot Queries

The pivot API lets analysts investigate specific indicators:

```python
def pivot(field: str, value: str, limit: int = 100):
    """Find all events matching a specific field value."""
    valid_fields = {
        "source_ip", "dest_ip", "username",
        "hostname", "event_type", "source_type",
    }
    if field not in valid_fields:
        raise ValidationError(f"Invalid pivot field: {field}")

    return LogEvent.objects(**{field: value}).order_by(
        "-timestamp"
    ).limit(limit)
```

This is the investigation workflow. An analyst sees an alert, notes the `source_ip`, and pivots to find every event from that IP. The whitelist of valid fields prevents arbitrary field queries that could be slow or exploitable.

## Error Handling

### Error Hierarchy

`app/core/errors.py` defines a structured error hierarchy:

```python
class AppError(Exception):
    status_code = 500
    error_type = "AppError"

    def __init__(self, message: str):
        self.message = message
        super().__init__(message)

class NotFoundError(AppError):
    status_code = 404
    error_type = "NotFoundError"

class ValidationError(AppError):
    status_code = 422
    error_type = "ValidationError"

class AuthenticationError(AppError):
    status_code = 401
    error_type = "AuthenticationError"

class ForbiddenError(AppError):
    status_code = 403
    error_type = "ForbiddenError"

class ConflictError(AppError):
    status_code = 409
    error_type = "ConflictError"
```

A single Flask error handler catches all `AppError` subclasses:

```python
def register_error_handlers(app: Flask):
    @app.errorhandler(AppError)
    def handle_app_error(error: AppError):
        return jsonify({
            "error": error.error_type,
            "message": error.message,
        }), error.status_code
```

This gives you consistent JSON error responses across the entire API. No endpoint returns HTML errors. No endpoint returns different error formats. The frontend can rely on `response.data.error` and `response.data.message` being present for all error responses.

### Frontend Error Handling

`src/core/lib/api.ts` mirrors this on the client:

```typescript
class ApiError extends Error {
  constructor(
    public status: number,
    public error: string,
    message: string
  ) {
    super(message);
  }
}

api.interceptors.response.use(
  (response) => response,
  (error) => {
    if (error.response) {
      const { status, data } = error.response;
      throw new ApiError(status, data.error, data.message);
    }
    throw new ApiError(0, 'NetworkError', 'Connection failed');
  }
);
```

The Axios interceptor transforms HTTP errors into typed `ApiError` objects. React Query's global `onError` handler can then show toast notifications with the error message. A 401 triggers a logout. A 403 shows "Insufficient permissions." A 422 shows the validation error details.

## Common Debugging Scenarios

### "Events aren't showing up in real time"

Check these in order:
1. Is the SSE connection established? Open browser dev tools, Network tab, filter by EventStream. You should see a long-lived request to `/api/v1/logs/stream`.
2. Is the Nginx proxy buffering disabled? Check `proxy_buffering off` in the Nginx config for SSE endpoints.
3. Is Redis running? `docker compose exec redis redis-cli ping` should return `PONG`.
4. Are events being published? `docker compose exec redis redis-cli XLEN siem:logs` shows the stream length.

### "Correlation rules aren't firing"

1. Is the correlation engine thread running? Check backend logs for "Correlation engine started."
2. Is the rule enabled? `CorrelationRule.objects(enabled=True)` in a Flask shell.
3. Does the event match the rule? The `_event_matches_rule()` function checks `event_type` and `source_type` against the rule's conditions.
4. Is the rule in cooldown? After firing once, it won't fire again for `CORRELATION_COOLDOWN_SECONDS` (default 300).
5. Has the rule cache expired? Rules are cached for 30 seconds. New rules take up to 30 seconds to be evaluated.

### "Authentication errors on every request"

1. Check the JWT expiry. Default is 24 hours (`JWT_EXPIRY_HOURS` in config).
2. Check that `SECRET_KEY` is consistent across restarts. If the key changes, all existing tokens become invalid.
3. Check the `Authorization` header format. It must be `Bearer <token>`, not just the token.

## What's Next

Now that you understand how the code works, read [04-CHALLENGES.md](./04-CHALLENGES.md) for ideas on extending this project. The challenges range from adding new log source normalizers (beginner) to implementing Sigma rule support and SOAR playbooks (advanced).
