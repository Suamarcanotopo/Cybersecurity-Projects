<!--
©AngelaMos | 2026
04-CHALLENGES.md
-->

# Challenges

You have a working dashboard. The interesting question is what to add to it. This file is a graded list of extensions, from "evening project" to "you should publish a blog post about it". Each entry includes a hint and a real-world reason it would matter.

## Easy

These take a few hours each. The goal is to build muscle memory for the collector + topic + frontend store wiring.

### Add an additional vendor advisory feed

Pick one of: Microsoft Security Response Center (MSRC), Cisco PSIRT, Red Hat Security Advisories, Project Zero. Each publishes RSS or JSON.

**Hint**: copy the `kev` collector layout. You need a `Fetcher` that does HTTP+parse, a `Repository` for upsert, a new topic constant, and a frontend store. The MSRC CVRF feed is a good first pick because it ships JSON, not custom XML.

**Why it matters**: NVD is consistently 1-7 days behind vendor disclosure. A direct vendor advisory feed is the single highest-leverage upgrade you can make for a defensive dashboard.

### Add a Tor exit node feed

The `tornull/exit-list` (or `dan.me.uk/torlist`) publishes the current Tor exit node list. Wire it up as a feed; on the frontend, paint Tor exits with a different color when they appear in the DShield top-IPs panel.

**Hint**: the simplest implementation is a 30-minute poller into a Redis set. The DShield enricher then does an `SISMEMBER` per IP at enrichment time and stamps `is_tor: true` on the payload.

**Why it matters**: Tor exit IPs scanning your edge are categorically different from compromised home routers scanning your edge. Visual differentiation is faster than a tooltip.

### Persist alert fire history with a UI page

The schema and `RecordFire` already exist (see `internal/alerts/repository.go`). What is missing is a `/v1/alerts/history` endpoint and a settings-page table.

**Hint**: model the endpoint after `/v1/intel/cve/search` for pagination, sort, and filter shape. Frontend route is already in the settings page tree (`pages/settings/Alerts.tsx` or similar).

**Why it matters**: when an alert fires and the user did not see it, the first question is "did it actually go to Slack?" The history page answers that without a database round trip.

### Add a "test alert" button

For each configured channel, render a button that posts to `/v1/notifications/channels/:id/test`. The endpoint sends a fixed `"This is a test alert from monitor-the-situation"` message via the channel's notifier.

**Hint**: this is a one-route endpoint plus a one-button frontend change. The work is the wiring, not the logic. Reuse `notifSender.Send(...)` directly.

**Why it matters**: the most common "alerts don't work" support question is actually "I configured the webhook wrong". A test button shifts that left.

## Medium

These are weekend projects. They require touching the bus, the storage layer, or both.

### Add MITRE ATT&CK technique tagging to ransomware victims

ransomware.live posts include the threat actor name. Map actor names to known ATT&CK technique sets (CISA publishes mappings; so does MITRE's ATT&CK Navigator). Store the technique IDs on the ransomware row and surface them as small badges on the panel.

**Hint**: the mapping itself is data, not code. Build a `actor_tactics.yaml` and load it at startup. The collector enriches the payload before persistence and emit. Bonus: when a previously-unmapped actor appears, log a warning so you remember to extend the mapping.

**Why it matters**: knowing that REvil uses T1486 (Data Encrypted for Impact) and T1078 (Valid Accounts) tells a defender what to check when REvil shows up in the wild. Names are not actionable; techniques are.

### Add a "follow-the-money" Bitcoin ransomware tracker

When a ransomware victim post includes a wallet address (some leak posts do), look it up against Chainalysis-style public sources or use blockchair's API for transaction history. Render the wallet's recent inbound transfers as a sparkline.

**Hint**: this is the only feed in the project that has an unbounded fan-out (one wallet → many tx history calls), so put it behind a per-wallet cache with a long TTL. Do not re-fetch on every page render.

**Why it matters**: ransomware payment flows are public information on the blockchain. Surfacing them next to the victim post is unique to the dashboard's "fuse signals" thesis.

### Replace the in-process bus with NATS JetStream

Keep the same `Bus` interface (`Emit`, `Subscribe`, `Run`). Swap the implementation from a Go channel to NATS JetStream. Now the dashboard can run multiple instances behind a load balancer.

**Hint**: JetStream's per-stream subjects map cleanly to topics. Use a durable consumer per backend instance for the alerts dispatcher, and pull-based subscription for the WebSocket hub broadcast. Keep persistence of the snapshot in Redis, not JetStream — Redis stays as the read-side cache.

**Why it matters**: the natural next step when one operator becomes a small team. The architecture chapter promised this would be a one-component replacement; the challenge is to actually verify that.

### Add OpenTelemetry traces across the bus

`core.NewTelemetry` already initializes the OTel tracer. Wire trace context through `Bus.Emit` so a single CVE event can be traced from NVD fetch → upsert → bus → snapshot → ws broadcast → frontend ack.

**Hint**: add a `context.Context` parameter to `Emit` (today it does not take one). Inject the span context into the event payload as a `traceparent` header. The persister and broadcaster pick it up. Frontend logs a `console.debug` with the trace ID so you can correlate in Tempo or Honeycomb.

**Why it matters**: when one panel is "stale" and another is fresh, distributed tracing tells you which collector is slow. Without traces, you read logs and guess.

### Migrate from polling to NVD's CVE 2.0 event stream when it lands

NVD has been promising an event-driven feed for years. When it ships (or if it has by the time you read this), replacing the 2-hour CVE poll with a streaming subscription cuts dashboard latency on new CVEs from "up to two hours" to "seconds". The collector layout is already prepared for this — `coinbase` is the streaming reference implementation.

**Hint**: model on `internal/collectors/coinbase/`. The hardest part is gap recovery on reconnect, which `sequencer.go` shows.

**Why it matters**: if you build dashboards for a SOC, latency is a feature. The team using your tool will notice.

## Hard

These are blog-post-grade projects. Each is a multi-week investment.

### Add a YARA-based malware feed via Malshare or VirusTotal Hunting

Malshare publishes a daily feed of new malware hashes. VirusTotal Hunting has live YARA matches. Wire either in, persist matches with the YARA rule that matched, and surface "this rule fired N times in the last 24h" on a new panel.

**Hint**: VT Hunting requires a paid API key. Start with Malshare. The frontend panel can be a sparkline per rule plus a click-through to the latest matched hash.

**Why it matters**: connecting a YARA hit to a CVE diff to a KEV entry to a ransomware leak is the dashboard's whole pitch. This adds the file-side signal to the network-side and patch-side ones already there.

### Build a "what just changed?" diff replay

Right now every panel shows current state. Add a time-machine slider: drag back, the dashboard reconstructs every panel as of that moment.

**Hint**: this is what BRIN was built for. Every panel store needs an `at(t time.Time)` query against the historical Postgres tables. The frontend needs to disconnect the WebSocket, render from the historical query, and reconnect when the user releases the slider. Watch out for the Coinbase panel — minute bars are sparse compared to ticks; you have to choose which to show.

**Why it matters**: post-incident review on "what was the dashboard showing 30 minutes before the incident page" is the scariest question to leave unanswered.

### Add MOAS hijack detection from a public BGP collector (not Cloudflare)

CF Radar's hijack detection is closed-source. RIPE's RIS Live (`ris-live.ripe.net`) is a free public BGP feed at firehose volume. Implement your own MOAS detector from the raw stream: maintain a sliding window of `(prefix, origin_as)` observations, alert when a prefix has two distinct origin ASNs simultaneously.

**Hint**: this is at least a week of work. Start by writing a `client.go` that subscribes to RIS Live's WebSocket. Keep observations in a bounded LRU. Tune confidence by AS-relationships (sibling ASNs are not hijacks, peers might be).

**Why it matters**: building a hijack detector from raw BGP data is the canonical "you understand internet routing now" project. CF Radar is convenient; RIS Live is educational.

### Multi-tenant SaaS-ify the dashboard

Right now there is one user (the operator). Turn it into a hosted SaaS where each customer gets isolated alert rules, channel configs, and rate-limit budgets. Same data feeds (the world is the world), per-tenant alert state.

**Hint**: the `users` table and `auth` package are already most of the way there. The hard part is data partitioning: alert rules and channels are per-tenant; CVE/KEV/ransomware data is shared. The frontend has to gate admin pages by org membership. Stripe billing is its own thing. Plan for at least a month.

**Why it matters**: this is the path from "personal project" to "actual product". Doing it well teaches multi-tenancy patterns that apply to every B2B SaaS.

### Add a WebGL flow visualization on top of the globe

Today the globe shows discrete events: dots, hijack arcs, ISS pin. Add a WebGL particle system that flows along the BGP arcs continuously, with intensity proportional to detected hijack confidence. Then, when an outage is active, render the country in pulsing red with rate proportional to the affected ASN count.

**Hint**: MapLibre's custom layers API supports raw WebGL passes. Look at deck.gl's TripsLayer and ArcLayer for reference. Particle counts get expensive fast — cap at ~5000 active particles per frame.

**Why it matters**: this is what makes a screenshot of the dashboard go viral. Pretty matters when a tool's audience is operators who stare at it for 8 hours a day.

## Deployment Hardening

Real production deployments need these. The current Justfile gets you 80% there.

### Run the backend behind a non-Cloudflare proxy as well

`cloudflared.compose.yml` covers Cloudflare Tunnel. Add an alternate `compose.traefik.yml` and `compose.nginx-direct.yml` for self-hosted edge. The configs differ in TLS termination, header forwarding, and WebSocket upgrade rules.

**Hint**: the `TrustedProxyHops` config is the key knob. Cloudflare adds known CF-Connecting-IP headers; Traefik adds `X-Forwarded-For`. Get the trusted hop count right per setup or your rate limits and WS-per-IP caps run on the proxy IP, not the client IP.

### Add a Postgres read replica for `/v1/intel/*`

The historical query endpoints are read-heavy and tolerant of seconds-of-lag. Point a `pgx` read pool at a streaming replica; route `intel.Handler` reads to it.

**Hint**: this is one new pool in `core` and one config knob. The collectors keep writing to the primary. Only `intel/handler.go` reads need re-pointing.

### Add Prometheus metrics for the bus and hub

`Bus.DroppedCount`, `Bus.SubscriberDroppedCount`, `Hub.SubscriberCount` are already exposed in code but only logged. Wire them to a `prometheus.GaugeFunc`. Add latency histograms on collector ticks via `core.Telemetry`.

**Hint**: Otel already exports to Prometheus if you set the exporter to `prometheus`. The work is naming the metrics consistently and writing the alerting rules (e.g., page on `bus_dropped_total` rate > 0 for 5m).

### Dependabot, Renovate, and supply-chain pinning

The Go module file already pins by checksum. Add `.github/dependabot.yml` for Go and pnpm. Lock the docker base images by digest, not tag. Fail CI when `go mod download -x` reports any unverified module.

**Hint**: the `bug-bounty-platform` project in this repo has a CI hardening setup worth copying.

### Build SBOMs and attest provenance

`syft` produces SBOMs. `slsa-github-generator` produces SLSA provenance. Add a release workflow that emits both, signs the binary with `cosign`, and pushes signed images to GHCR with attestation.

**Hint**: the SBOM is one `syft packages dir:.` invocation. The provenance is a GitHub-actions reusable workflow. The hard part is shipping `cosign verify` into the deploy pipeline so unsigned images cannot deploy.

## Connections to Other Projects in This Repo

A few extension ideas that pull in code from sibling projects:

- **Honeypot-network** publishes attacker IPs. Pipe them in as a 13th feed and color the DShield panel rows that overlap.
- **API rate limiter** — its sliding-window store would be a drop-in upgrade for the per-IP WebSocket connection cap.
- **Bug bounty platform** — when a CVE on the dashboard maps to an in-scope program, surface the program link on the CVE row.
- **AI threat detection** — wire its anomaly score on attacker IPs into the DShield enricher so high-anomaly IPs render with a different glyph.

## Final Note

The dashboard is not "done". It is an opinionated foundation. Every extension on this list has been sketched, and a few prototyped, in the lifetime of the project. None of them require ripping the architecture apart, because the architecture was specifically chosen to keep the producer-bus-consumer separation clean.

If you build something interesting on top of it, send a PR or open an issue. Especially the hard category — the goal is for this codebase to be the cleanest reference implementation of "real-time security operations dashboard" anyone has published.
