<!--
©AngelaMos | 2026
02-ARCHITECTURE.md
-->

# Architecture

This document covers the runtime shape of the system: how a single Go process orchestrates eleven heterogeneous data feeds, how events get from a collector goroutine to a browser, and how state survives a restart.

## High-Level Picture

```
┌──────────────────────────────────────────────────────────────────────┐
│  External feeds (HTTP / WS, varying cadences)                        │
│  DShield · CF Radar · NVD · EPSS · KEV · ransomware.live · Coinbase  │
│  · USGS · NOAA SWPC · Wikipedia · GDELT · CelesTrak · wheretheiss    │
└───┬──────────────────────────────────────────────────────────────────┘
    │
    │   ▼ each collector is one errgroup goroutine
    ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│  collector   │  │  collector   │  │  collector   │  │  collector   │
│  (cve)       │  │  (kev)       │  │  (cfradar)   │  │  …           │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │                 │
       │  Emit(events.Event{Topic, Source, Timestamp, Payload})
       ▼                 ▼                 ▼                 ▼
       ╔═══════════════════════════════════════════════════════╗
       ║          bus.Bus  (buffered channel, 512)             ║
       ║                                                       ║
       ║   1. Persister.Save(ev)  → snapshot store (Redis)     ║
       ║   2. Broadcaster.Broadcast(topic, payload) → ws.Hub   ║
       ║   3. fanout(ev) → channel subscribers (alerts engine) ║
       ╚═══════════════════════════════════════════════════════╝
                         │              │              │
                         ▼              ▼              ▼
                    ┌─────────┐   ┌──────────┐   ┌─────────────┐
                    │ Redis   │   │ ws.Hub   │   │ alerts.     │
                    │ snapshot│   │ per-conn │   │ Dispatcher  │
                    │ store   │   │ buf 256  │   │ (CEL eval)  │
                    └─────┬───┘   └────┬─────┘   └──────┬──────┘
                          │            │                │
                          ▼            ▼                ▼
                    GET /v1/snapshot   /v1/ws        Telegram /
                    (REST hydrate)     (WS stream)   Discord / Slack

  Append-mostly Postgres tables (BRIN indexed) live alongside Redis
  for historical queries via /v1/intel/* REST endpoints (CVE search,
  KEV list, hijack timeline, ransomware victims, earthquakes).
```

The bus is the spine. Everything else is either a producer (collector), a consumer (snapshot store, ws hub, alerts dispatcher), or a query path that bypasses the bus entirely (the historical Postgres queries served by the `intel` package).

## The Single-Binary Decision

The whole backend is `cmd/api/main.go` running one binary. There is no scheduler, no separate worker, no message broker. This is intentional and load-bearing.

The orchestration is a single `errgroup.Group`:

```go
collectorGroup, collectorCtx := errgroup.WithContext(ctx)
collectorGroup.Go(func() error { return eventBus.Run(collectorCtx) })
collectorGroup.Go(func() error { return beat.Run(collectorCtx) })

if cfg.Collectors.DShield.Enabled {
    coll := dshield.NewCollector(dshield.CollectorConfig{...})
    collectorGroup.Go(func() error { return coll.Run(collectorCtx) })
}
// ... ten more collectors ...
```

`errgroup.WithContext` gives you two guarantees:

1. **Shared cancellation**. If any goroutine returns an error, every other goroutine's context is cancelled. One collector exploding does not silently leave the others running on a half-broken process.
2. **Wait-for-all teardown**. `collectorGroup.Wait()` blocks until every goroutine has actually returned. Combined with a `signal.NotifyContext(SIGINT, SIGTERM)` parent context and a 5-second drain delay before the HTTP server stops, every event in flight has a chance to be persisted and broadcast before the process exits.

The cost of this design: you cannot horizontally scale a single user's view across multiple processes (there is no shared bus). The benefit: zero distributed-systems failure modes for ~99% of deployments. **If you ever want multi-process, you replace `bus.Bus` with NATS JetStream and keep everything else.**

## The Event Bus

`bus.Bus` is a buffered Go channel with three downstream effects per event. The shape:

```go
type Bus struct {
    ch          chan events.Event   // size 512
    persister   Persister           // redis snapshot store
    broadcaster Broadcaster         // ws hub
    subscribers []chan events.Event // alerts dispatcher etc
}

func (b *Bus) Emit(ev events.Event) {
    select {
    case b.ch <- ev:
    default:
        b.dropped.Add(1)
        b.logger.Warn("event bus full, dropped", ...)
    }
}
```

Three things are non-obvious here:

- **`Emit` is non-blocking**. A backed-up bus drops events instead of stalling collectors. This is the right choice when collectors are time-sensitive (Coinbase, USGS) and would rather miss a tick than fall behind real time.
- **One goroutine drains the channel**. The `Run` loop pulls events off the buffer, persists, broadcasts, and fans out, in that order. If persistence is slow, broadcast lags. This is acceptable because the snapshot is the source of truth for late-joining clients.
- **Subscribers are separate from broadcast**. The alerts engine subscribes through `Bus.Subscribe()` which returns a 256-buffered channel. Slow alert evaluation does not back up the bus; events are dropped at the subscriber boundary instead.

The bus is the only place the system tolerates lossiness. Below the bus (Postgres writes inside collector repositories) is durable. Above the bus (snapshot store) is eventually consistent with last-write-wins semantics — a dropped event simply means the next event for that topic overwrites the lost one a few seconds later.

## The Collector Pattern

Every collector implements roughly:

```go
type CollectorConfig struct {
    Interval  time.Duration
    Fetcher   Fetcher       // calls the upstream API
    Repo      Repository    // persists historical rows
    Emitter   Emitter       // bus.Emit
    State     StateRecorder // health/freshness tracking
    Logger    *slog.Logger
}

func (c *Collector) Run(ctx context.Context) error {
    ticker := time.NewTicker(c.cfg.Interval)
    defer ticker.Stop()
    c.tick(ctx)             // immediate first poll
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-ticker.C:
            c.tick(ctx)
        }
    }
}
```

The `tick` body is upstream-specific but the structure is the same: fetch, persist to its own table, emit a single event. The fetcher, repository, emitter, and state recorder are interfaces — every collector ships with a fake of each so the unit tests do not need network or database.

Some collectors are weirder than others:

- **DShield** merges three endpoints into one snapshot. Optional `Enricher` enriches the top-IPs blob with country code from AbuseIPDB and classification from GreyNoise.
- **Coinbase** is a persistent WebSocket, not a poller. The `coinbase` package decomposes into `client` (raw WS), `readloop` (frame-by-frame read with sequencer), `aggregator` (tick → minute bar), `reconnect` (exponential backoff), and `collector` (orchestration).
- **ISS** has two cadences: `PositionInterval` (10s) for live position via `wheretheiss.at`, and `TLEInterval` (24h) to refresh the orbital element set from CelesTrak. The cached TLE is propagated client-side between polls so the globe is not blocked on the network.
- **SWPC** has both a fast (1m) and slow (3h) cadence. Kp index updates every 3h; magnetometer Bz updates every minute. One collector handles both.

Every collector reports via `state.RecordSuccess` or `state.RecordError` on each tick. The `collector_state` table is the source of truth for the `/v1/admin/health` endpoint, which lights up red panels when a feed has not refreshed within its expected window.

## The Snapshot Store

A new browser must show useful state immediately, before any WebSocket events arrive. The snapshot store solves that.

`snapshot.Store` is a thin Redis wrapper. The persister side, attached to the bus, calls `Save` for every event:

```go
func (s StorePersister) Save(ctx context.Context, ev events.Event) error {
    raw, _ := json.Marshal(ev.Payload)
    if ev.Topic == events.TopicCoinbasePrice {
        return s.Store.MergeSymbolMap(ctx, ev.Topic, raw)
    }
    return s.Store.PutLatest(ctx, ev.Topic, raw)
}
```

For most topics, "latest" is one Redis key (`state:cve_new`, `state:kev_added`, etc.) with the raw JSON payload. For Coinbase, where there are multiple symbols, the topic is a Redis hash with one field per symbol so a BTC tick does not stomp on the latest ETH tick.

The serve side, behind `GET /v1/snapshot`, scans `state:*` and returns one merged JSON document. The frontend hydrates everything in one round trip, then catches up via WebSocket.

The store does **not** persist historical data. Postgres does. The store is a cold-start cache, not the system of record. If Redis is wiped, the dashboard reboots cold for ~2 hours (until the slowest collector cycles) but loses no durable data.

## The WebSocket Hub

`ws.Hub` is a fan-out router with bounded per-subscriber buffers and aggressive slow-consumer eviction.

```go
const (
    defaultSubscriberBuf = 256
    defaultPingInterval  = 30 * time.Second
    defaultMaxSubs       = 5000
)

func (h *Hub) Broadcast(topic events.Topic, payload []byte) {
    env, _ := EncodeEnvelope(string(topic), payload)
    h.mu.Lock()
    defer h.mu.Unlock()
    for sub := range h.subs {
        if _, ok := sub.topics[topic]; !ok {
            continue
        }
        select {
        case sub.msgs <- env:
        default:
            go sub.closeSlow()
        }
    }
}
```

Things to notice:

- **Per-subscriber topic filter**. The connecting client sends `?topics=cve_new,kev_added,...` and the hub only sends matching topics. A panel that does not need Coinbase ticks does not pay for them.
- **Non-blocking send**. If the subscriber's 256-message channel is full, the hub does not wait. It schedules a `closeSlow()` goroutine that closes the connection with `StatusPolicyViolation`.
- **Heartbeat pings every 30s**. The browser's reconnect logic uses missing pongs as the disconnect signal; this is faster and more reliable than waiting for TCP RST.
- **Capacity limit**. `MaxSubscribers: 5000` (configurable) protects against connection-flood DoS. Over capacity, new connections get `StatusTryAgainLater`.

The envelope format is intentionally minimal:

```json
{"ch":"cve_new","data":{...},"ts":"2026-05-08T18:30:12.123456789Z"}
```

`ch` is the topic, `data` is the raw payload, `ts` is the server-side timestamp at fan-out. No protocol versioning, no auth in-band — auth is on the upgrade handshake.

## The Snapshot+Stream Handshake

The frontend's `createDashboardWS` factory implements the buffer-then-flush pattern:

```ts
return {
  connect() { attach() },
  setReady() {
    ready = true
    sendInitIfReady()
    const flush = buffer
    buffer = []
    for (const ev of flush) onEvent(ev)
  },
  ...
}
```

The lifecycle:

1. App boots. `connect()` opens the WebSocket. `ready = false`. Incoming messages go into `buffer`.
2. App fetches `GET /v1/snapshot` via TanStack Query. Response hydrates Zustand stores.
3. App calls `setReady()`. The buffered messages are replayed through `onEvent`. `ready = true`. Subsequent messages flow live.

The protocol's only client→server message is `{"op":"init"}`, sent by `setReady()`. The server-side hub reads and discards client messages — the protocol is server-push only — but the previous code closed the connection with `StatusPolicyViolation` on receiving any data frame, which turned every client `init` into a forced reconnect. The current `Serve` loop reads-and-discards in a separate goroutine to keep the connection alive.

This handshake is the single most error-prone part of the system. The unit tests in `frontend/src/api/ws.test.ts` and the backend's `ws/hub_test.go` exist specifically because we got it wrong twice during development.

## Storage: Redis + Postgres

The split is deliberate.

**Redis** holds:

- The snapshot store (`state:*`) — one key per topic, last-write-wins.
- TLE for ISS — small JSON, refreshed daily, read continuously.
- Rate limit counters — sliding window per IP/user.
- Alert engine cooldowns — per (rule, channel) `SET NX EX` keys.
- Auth session tokens (refresh token rotation).

**Postgres** holds everything that needs to be queryable historically: CVEs, KEV entries, earthquakes, ransomware victims, BTC/ETH ticks and minute bars, outage events, BGP hijacks, DShield snapshots, world events, alert rule definitions, alert fire history, user accounts, notification channel configs.

Redis is the hot path. Postgres is the cold path. The two never depend on each other for correctness; if Redis is down, the dashboard has no live state but the `intel` REST endpoints (`/v1/intel/cve/search`, `/v1/intel/kev/list`, etc.) still work against Postgres directly.

The Postgres schema uses BRIN on every time column and B-tree on primary keys plus a few selective indexes (severity+lastmod for CVE, mag+occurred for earthquakes, confidence+detected for hijacks). All payload columns are `jsonb` because schemas evolve faster than migrations.

## The Alert Engine

The alert engine is an in-process consumer subscribed to the bus. Per event, it looks up rules indexed by topic, evaluates each rule's CEL predicate against the payload, and if matching, dispatches to the user's configured channels.

Indexed by topic so the hot path is `O(rules-for-this-topic)` not `O(all-rules)`:

```go
e.rulesByTopic.Store(&indexed)  // atomic.Pointer[map[string][]compiledRule]
```

The pointer swap means rule reloads (every 30s) are lock-free for the eval path. Refresh just compiles every rule's CEL predicate into a `cel.Program` and atomically swaps the index.

Cooldowns are per `(rule, channel)`:

```go
key := fmt.Sprintf("alert_cooldown:%s:%s:%s", rule.ID, ch.Type, ch.ID)
ok, err := e.cooldowns.TryAcquire(ctx, key, cooldown)
```

`TryAcquire` is a Redis `SET NX EX`. A user with rules on Slack and Telegram for the same predicate has independent cooldown windows on each — important because Slack and Telegram have different rate limits and a single global cooldown would cause one to mute the other.

CEL was chosen over a custom DSL or Lua. Reasons: it is sandboxed by design (no syscalls, no I/O), has a tiny Go binary footprint, and predicate authoring is familiar to anyone who has used IAM conditions, Cloud Armor rules, or Envoy filters.

## Auth Pipeline

The auth flow is conventional ES256 JWT with auto-rotated keys:

```
1. POST /v1/auth/register
   → Argon2id(password) → users.password_hash
   → seed default alert rules

2. POST /v1/auth/login
   → verify Argon2id
   → mint access_token (15m, ES256, kid in header)
   → mint refresh_token (30d, opaque, stored in Redis)
   → set HttpOnly Secure cookies in production

3. Every authenticated request
   → middleware.Authenticator(verifier)
   → verifier checks ES256 signature + revocation list
   → ctx is populated with user identity

4. Public endpoints get a guest path
   → /v1/snapshot, /v1/ws, /v1/intel/* are read-only and unauthenticated
   → /v1/alerts/* and /v1/notifications/* require auth

5. Admin endpoints
   → middleware.RequireAdmin checks email vs cfg.App.AdminEmail
   → /v1/admin/db, /v1/admin/redis, /v1/admin/users
```

The signing key lives at `cfg.JWT.PrivateKeyPath`. If missing on boot, `ensureJWTKeys` generates a fresh ES256 keypair into `keys/`. The public side is exposed at `/.well-known/jwks.json` so any external service can verify dashboard tokens without trusting the dashboard's filesystem.

Refresh tokens are rotated on every use (Redis swap-and-set), so a leaked refresh token has at most one use before invalidation.

## Frontend State Architecture

Roughly the inverse of the backend:

- **TanStack Query v5** — REST. Owns the snapshot fetch, the `/v1/intel/*` historical queries, and any user-action mutations (create rule, delete channel).
- **Zustand stores** — live state. One store per topic family: `prices`, `ticker`, `cve`, `kev`, `bgpHijack`, `outage`, `earthquake`, `ransomware`, `freshness`, `globeEvents`, `heartbeat`, `audio`, `ui`.
- **Component selectors** — components subscribe to specific store slices via Zustand's selector pattern, so a CVE update does not re-render the BTC panel.

The WebSocket message handler is a single dispatch table that routes incoming `{ch, data}` envelopes into the right store. Adding a new feed on the backend requires adding one entry to this table and one new Zustand store.

The globe (`pages/globe/Globe.tsx`) is the heaviest component. It uses MapLibre for the projection and renders five distinct layer types: country choropleth (outages), great-circle paths (BGP hijacks), point clouds (DShield ASN dots, earthquake epicenters, ransomware markers), and an animated trail (ISS ground track). Layer updates are batched per animation frame because individually mutating MapLibre layers per WebSocket message is the fastest way to drop frame rate.

## Failure Modes the Architecture Survives

| Failure | Effect | Recovery |
|---|---|---|
| Single feed goes down (e.g., USGS 502) | That collector logs error, `RecordError`, dashboard shows stale-yellow on that panel. Other panels unaffected. | Next tick succeeds, freshness recovers. |
| Redis goes down | Snapshot returns empty, WS still works, intel endpoints still work. | Bus persister logs errors, drops nothing else. |
| Postgres goes down | Collectors that need to upsert log errors. Bus emit + WS still work. Intel REST returns 503. | Postgres reconnects, collectors resume on next tick. |
| Bus channel full | `Emit` drops the event, increments counter. Snapshot misses one update. | Next event for that topic overwrites in snapshot. |
| WS subscriber stalls | Hub closes them with `StatusPolicyViolation`. | Browser reconnects, gets fresh snapshot, continues. |
| Process killed mid-write | `errgroup.Wait()` blocks shutdown until in-flight work finishes (within `ShutdownTimeout`). | Restart picks up where it left off, no data loss for durable tables. |

The system is **not** designed to survive losing the host. There is no replication, no leader election, no quorum. It is a single-binary single-host dashboard. If you need HA, you put a second instance behind a load balancer with its own Postgres replica and accept that the two instances will see slightly different live states (because Coinbase WS ticks arrive at different moments). For the original use case — one operator, one screen, one box — that complexity is the wrong trade.

## Where To Go Next

Continue to [03-IMPLEMENTATION.md](03-IMPLEMENTATION.md) for the actual code walkthrough across collectors, bus, ws, alerts, snapshot, and frontend wiring.
