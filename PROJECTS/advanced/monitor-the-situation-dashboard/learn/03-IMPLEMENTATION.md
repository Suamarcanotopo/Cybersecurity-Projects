<!--
©AngelaMos | 2026
03-IMPLEMENTATION.md
-->

# Implementation

This is the code-level walkthrough. It is organized by concern, not by file. We follow the path of one event from external API to a pixel on the globe, then loop back to cover the cross-cutting code.

All snippets are excerpts from the actual code. Snippets are intentionally not annotated with line numbers — formatting and small refactors invalidate line numbers in days, and the package + function name is enough to find any block again with `grep`.

## The Event Type

Everything in the system funnels through `events.Event`. It is deliberately tiny.

```go
// internal/events/event.go
package events

import "time"

type Event struct {
    Topic     Topic     `json:"topic"`
    Timestamp time.Time `json:"timestamp"`
    Source    string    `json:"source"`
    Payload   any       `json:"payload"`
}
```

`Payload any` is the interesting choice. We could have made it a sealed union of typed payloads, one per topic. We chose not to. The reasons:

- **Heterogeneous payload shapes.** A KEV add is a single CVE ID with a date. A DShield snapshot is a fused blob from three endpoints. A Coinbase tick is a price plus volume. Forcing them into one Go type tree adds zero runtime safety because the consumers (snapshot store, ws hub, alerts engine) all immediately re-marshal to JSON.
- **The bus is the only typed boundary on the producer side.** Every collector packs its own payload as `json.RawMessage` before emitting, so the JSON shape is committed at the collector. Subscribers pay one `json.Unmarshal` if they need fields.

The trade is real: a typo in a payload field name in a collector will not be caught at compile time. We mitigate with golden-file tests under each collector's `testdata/` directory.

## The Topic Enum

```go
// internal/events/topic.go
type Topic string

const (
    TopicHeartbeat        Topic = "heartbeat"
    TopicScanFirehose     Topic = "scan_firehose"
    TopicInternetOutage   Topic = "internet_outage"
    TopicBGPHijack        Topic = "bgp_hijack"
    TopicCVENew           Topic = "cve_new"
    TopicCVEUpdated       Topic = "cve_updated"
    TopicEPSS             Topic = "epss"
    TopicKEVAdded         Topic = "kev_added"
    TopicRansomwareVictim Topic = "ransomware_victim"
    TopicCoinbasePrice    Topic = "coinbase_price"
    TopicEarthquake       Topic = "earthquake"
    TopicSpaceWeather     Topic = "space_weather"
    TopicWikipediaITN     Topic = "wiki_itn"
    TopicGDELTSpike       Topic = "gdelt_spike"
    TopicISSPosition      Topic = "iss_position"
    TopicCollectorState   Topic = "collector_state"
)

func (t Topic) IsValid() bool { ... }
func AllTopics() []Topic       { ... }
```

`IsValid` is used by the WebSocket handler to whitelist `?topics=` query parameters. `AllTopics` is the default fallback when a client connects without specifying topics. Adding a feed means adding one constant here, one case in `IsValid`, and one entry in `AllTopics`. Then a collector emits with the new topic and the WS layer picks it up automatically.

## The Bus

`internal/bus/bus.go` is the spine.

```go
type Bus struct {
    ch          chan events.Event
    persister   Persister
    broadcaster Broadcaster
    logger      *slog.Logger
    dropped     atomic.Uint64

    subsMu      sync.RWMutex
    subscribers []chan events.Event
    subDropped  atomic.Uint64
}

func (b *Bus) Emit(ev events.Event) {
    select {
    case b.ch <- ev:
    default:
        b.dropped.Add(1)
        b.logger.Warn("event bus full, dropped", "topic", ev.Topic, "source", ev.Source)
    }
}
```

`Emit` is the producer-side API. The `select` with a `default` makes it non-blocking — if the buffer is full, we drop and increment the counter rather than block the calling collector goroutine.

The drain side, in `Run`, is the consumer:

```go
func (b *Bus) Run(ctx context.Context) error {
    defer b.closeSubscribers()
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case ev := <-b.ch:
            if b.persister != nil {
                if err := b.persister.Save(ctx, ev); err != nil {
                    b.logger.Error("persist event failed", "err", err, "topic", ev.Topic)
                }
            }
            if b.broadcaster != nil {
                payload, err := json.Marshal(ev.Payload)
                if err != nil {
                    b.logger.Error("marshal payload failed", "err", err, "topic", ev.Topic)
                    continue
                }
                b.broadcaster.Broadcast(string(ev.Topic), payload)
            }
            b.fanout(ev)
        }
    }
}
```

The order matters. Persist first so the snapshot is correct for any browser that connects between this event and the next. Broadcast second so live consumers see the event right after persistence. Fan out to channel subscribers (alerts engine) last because they may evaluate slow CEL predicates.

`fanout` is the second drop site:

```go
func (b *Bus) fanout(ev events.Event) {
    b.subsMu.RLock()
    subs := b.subscribers
    b.subsMu.RUnlock()
    for _, ch := range subs {
        select {
        case ch <- ev:
        default:
            b.subDropped.Add(1)
        }
    }
}
```

A slow alerts engine cannot back up the bus. It just loses alert evaluations, which is logged and visible via `SubscriberDroppedCount()` for ops monitoring.

## A Walking Tour of One Collector

Every collector has the same skeleton: poll, fetch, persist row(s), emit event(s), record state. We will use CVE because it is the most representative — pollable HTTP, dependent on a second API (EPSS), with both upsert and per-row event emission.

### CVE Collector — The Tick

```go
// internal/collectors/cve/collector.go
func (c *Collector) tick(ctx context.Context) {
    end := time.Now().UTC()
    start := end.Add(-c.cfg.Window)

    resp, err := c.cfg.NVD.Fetch(ctx, start, end)
    if err != nil {
        c.logger.Warn("nvd fetch", "err", err)
        c.cfg.State.RecordError(ctx, Name, err.Error())
        return
    }
```

Note the structure: a window of `[end - Window, end]`, not "everything". CVE feeds are append-mostly but can re-publish modifications, so a 2-hour window with a 2-hour poll interval gives a 1-window overlap that catches late modifications without re-processing the whole history.

```go
    ids := make([]string, 0, len(resp.Vulnerabilities))
    rows := make([]Row, 0, len(resp.Vulnerabilities))
    for _, v := range resp.Vulnerabilities {
        score, severity := v.PrimarySeverity()
        raw, _ := json.Marshal(v)
        rows = append(rows, Row{
            CveID:        v.CVE.ID,
            Published:    v.CVE.Published.Time,
            LastModified: v.CVE.LastModified.Time,
            Severity:     severity,
            CVSS:         score,
            Payload:      raw,
        })
        ids = append(ids, v.CVE.ID)
    }

    scores, err := c.cfg.EPSS.LookupBatch(ctx, ids)
```

Two API calls per tick: NVD for the CVE bodies, EPSS for the scores. We do them sequentially because EPSS is keyed on the CVE IDs the NVD call just returned. The EPSS error is logged but does not abort the tick — a CVE without an EPSS score is still useful, just not as well prioritized.

```go
    for _, row := range rows {
        if err := c.cfg.Repo.Upsert(ctx, row); err != nil { ... }
        if s, ok := scores[row.CveID]; ok {
            _ = c.cfg.Repo.UpdateEPSS(ctx, row.CveID, s.Score, s.Percentile)
            row.EPSSScore = &s.Score
            row.EPSSPercentile = &s.Percentile
        }
        body, _ := json.Marshal(row)
        c.cfg.Emitter.Emit(events.Event{
            Topic:     events.TopicCVENew,
            Timestamp: end,
            Source:    Name,
            Payload:   json.RawMessage(body),
        })
    }
    c.cfg.State.RecordSuccess(ctx, Name, emitted)
}
```

Persist-then-emit, per row. We emit `TopicCVENew` for every row in the window, even ones that were already in the table. The reason: a CVE's EPSS score can change without the CVE itself changing, and the frontend should reflect that. We could split into `cve_new` vs `cve_updated` based on insert vs update, but the consumers do not need that distinction yet.

`RecordSuccess` writes one row to `collector_state` so `/v1/admin/health` and the freshness ribbon on the frontend can both see "CVE collector ran 12 minutes ago, processed 47 rows".

### DShield — Multi-Endpoint Fusion

DShield is the cleanest example of the "fuse multiple upstream endpoints into one event" pattern.

```go
// internal/collectors/dshield/collector.go
snaps, err := c.cfg.Fetcher.FetchAll(ctx) // hits 3 endpoints concurrently

merged := map[string]json.RawMessage{"ts": tsRaw}
for _, s := range snaps {
    payload := s.Payload
    if s.Kind == KindTopIPs {
        payload = c.enrichSources(ctx, payload)
    }
    _ = c.cfg.Persister.PutSnapshot(ctx, now, s.Kind, payload)
    merged[s.Kind] = payload
}

body, _ := json.Marshal(merged)
c.cfg.Emitter.Emit(events.Event{
    Topic:     events.TopicScanFirehose,
    Timestamp: now,
    Source:    Name,
    Payload:   json.RawMessage(body),
})
```

The merged JSON has shape `{ts, top_ips, top_ports, country_dist}`. The frontend's `DShieldPanel` consumes the merged blob in one render pass. The Postgres persistence is per-kind so we can query "show me top IPs from 2026-04-01" without parsing a fused blob.

The `enrichSources` step is optional and runs only if an `Enricher` is configured (AbuseIPDB + GreyNoise). It iterates the top-IPs list, looks up each IP, and returns enriched rows with country code, classification, and threat actor name. If the lookup fails or the enricher is nil, it falls through to the original payload.

### Coinbase — Persistent WebSocket

Coinbase is the only collector that does not poll. The decomposition into multiple files reflects how messy real WebSocket clients get:

- `client.go` — raw connection, `ReadFrame`, `WriteFrame`.
- `readloop.go` — frame loop with sequencer reset on snapshot frames.
- `aggregator.go` — tick-to-minute-bar OHLC.
- `reconnect.go` — exponential backoff on disconnect.
- `sequencer.go` — gap detection on `sequence_num`.
- `collector.go` — orchestration.

The aggregator is the most interesting:

```go
// internal/collectors/coinbase/aggregator.go
func (a *Aggregator) Push(t Tick) (*MinuteBar, MinuteBar) {
    minute := t.TS.UTC().Truncate(time.Minute)
    cur, exists := a.open[t.Symbol]

    if !exists {
        cur = MinuteBar{Symbol: t.Symbol, Minute: minute, Open: t.Price, High: t.Price, Low: t.Price, Close: t.Price, Volume24hAtClose: t.Volume24h}
        a.open[t.Symbol] = cur
        return nil, cur
    }

    if minute.After(cur.Minute) {
        closed := cur
        cur = MinuteBar{...}  // start new minute
        a.open[t.Symbol] = cur
        return &closed, cur
    }

    // same minute, update OHLC
    if t.Price.GreaterThan(cur.High) { cur.High = t.Price }
    if t.Price.LessThan(cur.Low)     { cur.Low  = t.Price }
    cur.Close = t.Price
    cur.Volume24hAtClose = t.Volume24h
    a.open[t.Symbol] = cur
    return nil, cur
}
```

Returns `(closed, current)`. When a tick crosses a minute boundary, the previous minute is returned as `closed` and the collector persists it to `btc_eth_minute`. The current minute is always returned for live display.

This is also why the minute volume column was renamed in migration `0005`: the original column was called `volume` and we documented "per-minute volume", but the Coinbase ticker channel only gives 24-hour rolling volume, not per-trade size. The rename to `volume_24h_at_close` makes the actual semantic visible in the schema.

### ISS — Two Cadences, Client-Side Propagation

```go
// cmd/api/main.go
coll := iss.NewCollector(iss.CollectorConfig{
    PositionInterval: cfg.Collectors.ISS.PositionInterval,  // 10s
    TLEInterval:      cfg.Collectors.ISS.TLEInterval,       // 24h
    Fetcher:          iss.NewClient(iss.ClientConfig{}),
    TLEStore:         iss.NewTLEStore(redis.Client),
    ...
})
```

The ISS collector polls `wheretheiss.at` every 10s for the live position (this is the source the dashboard's "current ISS pin" uses). It also polls CelesTrak every 24 hours for the TLE (Two-Line Element set), caches it in Redis, and emits it.

The frontend has `frontend/src/lib/sgp4.ts` (or equivalent) that propagates the cached TLE on each animation frame to draw the orbital track. So the visible orbit is computed client-side from a 24-hour-old TLE; only the "current pin" is server-pushed every 10s.

This is a good example of **moving compute to the client** when the algorithm is well-defined and the data input is small. SGP4 is ~200 lines of math; pushing the propagated position over WebSocket every animation frame would saturate the network for no benefit.

## The WebSocket Hub

`internal/ws/hub.go`:

```go
const (
    defaultSubscriberBuf = 256
    defaultPingInterval  = 30 * time.Second
    defaultPingTimeout   = 10 * time.Second
    defaultWriteTimeout  = 5 * time.Second
    defaultMaxSubs       = 5000
)

func (h *Hub) Broadcast(topic events.Topic, payload []byte) {
    env, err := EncodeEnvelope(string(topic), payload)
    if err != nil {
        h.logger.Error("encode envelope", "err", err, "topic", topic)
        return
    }
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

The lock spans the whole iteration. This is fine because the iteration is fast (just a non-blocking channel send per sub) and the lock serializes against `add`/`remove`, which are the only other writers to `h.subs`. The connection close happens in a separate goroutine to avoid holding the lock through any I/O.

The slow-consumer comment in the constant block is worth quoting in full because it is the kind of thing you only learn by getting it wrong:

> Per-connection outbound buffer. Must absorb peak event rate × browser stutter window: heartbeat (5s) + coinbase (~8/s peak) + ISS (10s) + occasional bursts of CVE/KEV/ransomware. 16 is too small — a single browser GC pause fills it and triggers slow-consumer close, which the user sees as "NO SIGNAL".

### Serve Loop

```go
// internal/ws/hub.go
func (h *Hub) Serve(ctx context.Context, c *cdrws.Conn, topics []events.Topic) error {
    sub := newSubscriber(topics, h.bufSize, func() {
        _ = c.Close(cdrws.StatusPolicyViolation, "slow consumer")
    })
    if !h.add(sub) {
        _ = c.Close(cdrws.StatusTryAgainLater, "server at capacity")
        return ErrAtCapacity
    }
    defer h.remove(sub)

    connCtx, cancelRead := context.WithCancel(ctx)
    defer cancelRead()
    go func() {
        for {
            if _, _, err := c.Read(connCtx); err != nil {
                cancelRead()
                return
            }
        }
    }()
    pingT := time.NewTicker(h.pingInterval)
    defer pingT.Stop()

    for {
        select {
        case msg := <-sub.msgs:
            wctx, cancel := context.WithTimeout(connCtx, h.writeTimeout)
            err := c.Write(wctx, cdrws.MessageText, msg)
            cancel()
            if err != nil { return err }
        case <-pingT.C:
            pctx, cancel := context.WithTimeout(connCtx, h.pingTimeout)
            err := c.Ping(pctx)
            cancel()
            if err != nil { return err }
        case <-connCtx.Done():
            _ = c.Close(cdrws.StatusNormalClosure, "")
            return connCtx.Err()
        }
    }
}
```

The dedicated read goroutine is the post-mortem of a real bug. The `coder/websocket` library has a helper `c.CloseRead(ctx)` that auto-closes the connection on any received frame. We used it. The frontend's `setReady()` sends `{"op":"init"}` after snapshot hydration. That message tripped `CloseRead`'s "received unexpected data" path, killing the connection with `StatusPolicyViolation`. The user saw a reconnect loop.

The fix: drain client→server messages explicitly with `c.Read(connCtx)` and discard them. Connection stays alive; ping/pong frames still get handled by the library.

### Envelope

```go
// internal/ws/envelope.go
func EncodeEnvelope(channel string, payload []byte) ([]byte, error) {
    var buf bytes.Buffer
    buf.WriteString(`{"ch":`)
    chRaw, _ := json.Marshal(channel)
    buf.Write(chRaw)
    buf.WriteString(`,"data":`)
    if len(payload) == 0 {
        buf.WriteString("null")
    } else {
        buf.Write(payload)
    }
    buf.WriteString(`,"ts":`)
    tsRaw, _ := json.Marshal(time.Now().UTC().Format(time.RFC3339Nano))
    buf.Write(tsRaw)
    buf.WriteByte('}')
    return buf.Bytes(), nil
}
```

Built by hand, not via `json.Marshal` of a struct. Reason: the `data` field is already-encoded JSON. Marshalling a struct with `Data json.RawMessage` works but goes through a generic encoder path. Concatenation is faster and avoids re-allocating for the largest field. At ~50k events/min peak, this matters.

## The Snapshot Store

```go
// internal/snapshot/store.go
const (
    keyPrefix       = "state:"
    keyHashPrice    = "state:coinbase_price"
    scanCount       = 100
    wrongTypeMarker = "WRONGTYPE"
)

func (s *Store) PutLatest(ctx context.Context, topic events.Topic, payload json.RawMessage) error {
    return s.rdb.Set(ctx, keyPrefix+string(topic), []byte(payload), 0).Err()
}

func (s *Store) MergeSymbolMap(ctx context.Context, topic events.Topic, payload json.RawMessage) error {
    var tick struct{ Symbol string `json:"symbol"` }
    if err := json.Unmarshal(payload, &tick); err != nil || tick.Symbol == "" {
        return fmt.Errorf("coinbase merge: no symbol in payload")
    }
    key := keyPrefix + string(topic)
    err := s.rdb.HSet(ctx, key, tick.Symbol, []byte(payload)).Err()
    if err == nil { return nil }
    if !isWrongType(err) { return fmt.Errorf("redis hset %s/%s: %w", topic, tick.Symbol, err) }
    if delErr := s.rdb.Del(ctx, key).Err(); delErr != nil { ... }
    // retry as hash
    return s.rdb.HSet(ctx, key, tick.Symbol, []byte(payload)).Err()
}
```

`MergeSymbolMap` has a self-healing migration path: if the key exists as a string (legacy format) and `HSet` fails with `WRONGTYPE`, we delete and retry as a hash. This means a developer who upgraded mid-tick does not have to manually `redis-cli del`.

`GetAll` uses `SCAN` rather than `KEYS`. `KEYS *` is O(n) blocking on the Redis main thread; `SCAN` is incremental. For a snapshot store with ~16 keys this is overkill, but the habit is the right one — `KEYS` in any production code path is a foot-gun.

```go
func (s *Store) readKey(ctx context.Context, key string) (json.RawMessage, error) {
    t, _ := s.rdb.Type(ctx, key).Result()
    switch t {
    case "string":
        v, err := s.rdb.Get(ctx, key).Bytes()
        return json.RawMessage(v), err
    case "hash":
        fields, _ := s.rdb.HGetAll(ctx, key).Result()
        m := make(map[string]json.RawMessage, len(fields))
        for k, v := range fields {
            m[k] = json.RawMessage(v)
        }
        return json.Marshal(m)
    }
    return nil, fmt.Errorf("unsupported redis type %q for key %s", t, key)
}
```

Type-aware deserialization. The snapshot HTTP handler is dumb — `core.OK(w, all)` and a no-cache header — because all the work happens in the store.

## The Alert Engine

`internal/alerts/engine.go` is the most complex part of the system because it has to compile predicates, refresh them, and dispatch with cooldowns and parallel delivery.

### Compile and Refresh

```go
func (e *Engine) reload(ctx context.Context) error {
    all, _ := e.repo.ListAll(ctx)
    indexed := make(map[string][]compiledRule, len(all))
    for _, r := range all {
        prog, err := e.compile(r.Predicate)
        if err != nil {
            e.logger.Warn("alerts: skipping rule with bad predicate",
                "rule_id", r.ID, "topic", r.Topic, "err", err)
            continue
        }
        indexed[r.Topic] = append(indexed[r.Topic], compiledRule{rule: r, program: prog})
    }
    e.rulesByTopic.Store(&indexed)
    return nil
}
```

`atomic.Pointer[map[string][]compiledRule]` gives a lock-free read path. The map itself is never mutated after `Store`; reload always builds a fresh map and swaps the pointer. Readers grab the pointer once and operate on a stable map.

Compile errors do not fail the whole reload — a single bad rule predicate is logged and skipped. This matters: the rule UI lets users author predicates, and one user typing `event.severity = "high"` (assignment instead of comparison) should not silently break alerts for everyone.

### Evaluate

```go
func (e *Engine) Evaluate(ctx context.Context, ev events.Event) {
    idx := e.rulesByTopic.Load()
    if idx == nil { return }
    rules, ok := (*idx)[string(ev.Topic)]
    if !ok || len(rules) == 0 { return }

    payload, err := normalizePayload(ev.Payload)
    if err != nil {
        e.logger.Warn("alerts: payload normalize failed", ...)
        return
    }

    for _, cr := range rules {
        if !cr.rule.Enabled { continue }
        match, err := evalPredicate(cr.program, payload)
        if err != nil { ... continue }
        if !match { continue }
        e.fire(ctx, cr.rule, ev, payload)
    }
}
```

`normalizePayload` handles the `any` type discipline. The bus carries `Payload any`; CEL needs a `map[string]any` for field access. The function tries the cheap path (already a map), then `json.RawMessage` (unmarshal once), then full round-trip via `json.Marshal`+`Unmarshal`. The bulk of events come in as `json.RawMessage` because that is what the collectors produce.

### Fire

```go
func (e *Engine) fire(ctx context.Context, rule Rule, ev events.Event, payload map[string]any) {
    channels, _ := e.loader.LoadChannels(ctx, rule.UserID)
    cooldown := time.Duration(rule.CooldownSec) * time.Second
    message := formatMessage(rule, ev, payload)

    var wg sync.WaitGroup
    var mu sync.Mutex
    delivered := []string{}
    deliveryErrs := map[string]string{}

    for _, ch := range channels {
        ch := ch
        key := fmt.Sprintf("alert_cooldown:%s:%s:%s", rule.ID, ch.Type, ch.ID)
        ok, _ := e.cooldowns.TryAcquire(ctx, key, cooldown)
        if !ok { continue }
        wg.Add(1)
        go func() {
            defer wg.Done()
            err := e.notifier.SendAlert(ctx, ch, message)
            mu.Lock(); defer mu.Unlock()
            if err != nil {
                deliveryErrs[ch.ID] = err.Error()
                return
            }
            delivered = append(delivered, ch.ID)
        }()
    }
    wg.Wait()

    body, _ := json.Marshal(payload)
    errBody, _ := json.Marshal(deliveryErrs)
    _ = e.repo.RecordFire(ctx, HistoryRow{
        RuleID: rule.ID, UserID: rule.UserID,
        FiredAt: time.Now().UTC(),
        Payload: body,
        DeliveredTo: delivered,
        DeliveryErrors: errBody,
    })
}
```

Three things worth pointing at:

- **Per-channel cooldown via Redis `SET NX EX`**. The `RedisCooldown.TryAcquire` is a single round-trip and the TTL ensures the key auto-cleans.
- **Parallel delivery**. Telegram is slow (2-5s for a botless rate-limited send), Slack is fast (~200ms). Sequential delivery would pace everything to the slowest. We dispatch all channels concurrently, then `wg.Wait` for all to return.
- **Fire history is recorded once per rule firing, not per channel**. `delivered` lists which channels succeeded; `deliveryErrs` maps channel ID to error text. That makes the UI's "alert history" page useful for debugging integration failures.

## Webhook Encryption

```go
// internal/notifications/crypto.go
func (e *Encryptor) Encrypt(plaintext []byte) (ciphertext, nonce []byte, err error) {
    block, _ := aes.NewCipher(e.key)
    gcm, _ := cipher.NewGCM(block)
    nonce = make([]byte, gcm.NonceSize())
    if _, err := io.ReadFull(rand.Reader, nonce); err != nil { ... }
    ciphertext = gcm.Seal(nil, nonce, plaintext, nil)
    return ciphertext, nonce, nil
}
```

Standard library AES-256-GCM. The key is base64-decoded from `NOTIFICATION_ENCRYPTION_KEY` and validated to be exactly 32 bytes at startup:

```go
func NewEncryptor(b64Key string) (*Encryptor, error) {
    key, _ := base64.StdEncoding.DecodeString(b64Key)
    if len(key) != 32 {
        return nil, fmt.Errorf("encryption key must be 32 bytes, got %d", len(key))
    }
    return &Encryptor{key: key}, nil
}
```

If `NewEncryptor` returns an error, the entire alert engine is disabled for the lifetime of the process — `bridge` and `notifBridge` stay nil, so `notifBridge != nil` checks in `cmd/api/main.go` skip the engine setup. This is **fail-closed** behaviour: misconfiguration disables the feature rather than running it with broken/no encryption.

## Frontend Wiring

### The WebSocket Driver

`frontend/src/api/ws.ts`:

```ts
export function createDashboardWS(opts: CreateDashboardWSOpts): DashboardWS {
  const backoff = opts.backoff ?? DEFAULT_BACKOFF
  const onEvent = opts.onEvent ?? (() => undefined)

  let driver: WSDriver | null = null
  let ready = false
  let opened = false
  let closed = false
  let buffer: WSEvent[] = []
  let nextDelay = backoff.initialMs
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null

  function attach() {
    if (closed) return
    const d = opts.driver()
    driver = d
    opened = false
    d.onOpen = () => {
      nextDelay = backoff.initialMs
      opened = true
      sendInitIfReady()
    }
    d.onMessage = (data) => {
      let parsed: WSEvent
      try { parsed = JSON.parse(data) as WSEvent } catch { return }
      if (ready) onEvent(parsed)
      else buffer.push(parsed)
    }
    d.onClose = () => {
      driver = null
      opened = false
      if (closed) return
      const delay = nextDelay
      nextDelay = Math.min(nextDelay * 2, backoff.maxMs)
      reconnectTimer = setTimeout(attach, delay)
    }
  }
  return {
    connect() { attach() },
    setReady() {
      ready = true
      sendInitIfReady()
      const flush = buffer
      buffer = []
      for (const ev of flush) onEvent(ev)
    },
    disconnect() { ... },
  }
}
```

The factory takes a `driver` thunk so tests can inject a fake. `browserDriver` is the production implementation that wraps the platform `WebSocket`. The buffer-flush in `setReady` is the snapshot+stream handshake on the client side.

Reconnect uses exponential backoff with `nextDelay * 2` capped at `maxMs` (default 30s). On a clean open, `nextDelay` resets so a reconnect after long uptime starts at 1s again.

### Store Routing

The `App` boot sequence (paraphrased):

1. Mount providers (TanStack Query client, Zustand stores already global).
2. Open the WebSocket via `createDashboardWS`. Hand it an `onEvent` that dispatches by `ev.ch` into the right store.
3. Fetch `/v1/snapshot`. On success, hydrate every store from the response.
4. Call `ws.setReady()`. Buffered events flush through `onEvent` into the now-hydrated stores.

Stores are flat by topic. For example, `stores/cve.ts` holds the recent CVE list and exposes a setter (`upsertCVE`) that the WS dispatcher calls. Components subscribe via `useCVEStore(state => state.list)` so a Coinbase tick does not re-render the CVE panel.

### The Globe

`frontend/src/pages/globe/Globe.tsx` is the big consumer. It subscribes to the `globeEvents` store, which is a fan-in of the topic-specific stores: outages, BGP hijacks, earthquakes, ransomware victims, mass-scan ASN dots, ISS position. The globe component listens, computes the layer mutations, and applies them in a `requestAnimationFrame` batch.

The TLE-driven ISS orbit track is propagated client-side. Every animation frame, the SGP4 propagator advances the satellite's mean anomaly and emits a (lat, lon) the globe layer renders as a polyline. The TLE itself comes from the snapshot or a `iss_position` event with a `tle` field; the position pin (separate from the orbit track) comes from the `wheretheiss.at` 10-second poll.

## Common Pitfalls

A short list of mistakes we made and you might too.

**Forgetting to register a topic in `IsValid`/`AllTopics`.** Adding a topic constant is not enough. The WebSocket handler validates `?topics=` against `IsValid`, and the default fallback uses `AllTopics`. Miss either and your new topic silently never reaches the browser.

**Putting expensive work in `Bus.Run`.** The drain loop is single-goroutine. If you add a synchronous DB write before the broadcast, you cap the entire system's broadcast rate at the DB write rate. Move expensive work into a subscriber channel or the persister implementation.

**Using `c.CloseRead` on `coder/websocket`.** It looks helpful. It closes the connection on any received frame, including the client `init` op the dashboard uses. Either drain reads explicitly or design a strict server-push protocol with close-on-receive semantics — pick one.

**Not validating the encryption key length at startup.** AES-256 silently accepts a 16-byte key as AES-128 if you do not check. The `NewEncryptor` constructor must enforce `len(key) == 32`.

**Returning `*MinuteBar` from the aggregator and forgetting to nil-check.** The `Push` return signature `(*MinuteBar, MinuteBar)` puts the closed bar behind a pointer. Persisting `*closed` without a nil check is the most common bug we caught in code review on the Coinbase package.

**B-tree on time columns at scale.** Tempting because it's the default. For tens of millions of append-mostly rows, BRIN is dozens of times smaller and just as fast for range scans. If you use B-tree on `occurred_at`, your index is bigger than the table within months.

**Keying alert cooldowns globally instead of per-channel.** A user with Telegram and Slack rules on the same predicate wants an independent cooldown on each. Keying on `rule_id` alone causes the channel that fires first to mute the other.

## Where To Go Next

Continue to [04-CHALLENGES.md](04-CHALLENGES.md) for extension ideas, harder feature work, and deployment hardening.
