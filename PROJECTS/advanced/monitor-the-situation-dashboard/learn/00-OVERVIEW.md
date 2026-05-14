<!--
©AngelaMos | 2026
00-OVERVIEW.md
-->

# Monitor the Situation Dashboard

## What This Is

A real-time situational awareness dashboard that fuses eleven live intelligence feeds (mass-scan firehose, BGP hijacks, internet outages, fresh CVEs with EPSS scoring, CISA KEV diff, ransomware victim leak posts, M2.5+ earthquakes, NOAA space weather, ISS orbital track, Wikipedia ITN, GDELT spikes, plus BTC/ETH ticks) into a single SOC view. A single Go binary runs every collector as an `errgroup` goroutine, feeds events through an in-process bus, and fans them out to browsers over WebSocket.

The phrase "monitoring the situation" started as a Twitter/X meme in mid-2025. This is the build that actually monitors the situation.

## Why This Matters

Most "dashboards" you see are static Grafana charts pointed at one Prometheus job. Real situational awareness, the kind a SOC actually uses, requires fusing wildly different feeds at wildly different cadences and presenting them coherently to a human under stress. That is hard.

A few real incidents this kind of dashboard would have caught minutes earlier than reading Twitter:

- **June 2024 Cloudflare BGP hijack** by Eletel (AS267613) for Orange España traffic. CF Radar published the hijack confidence score within minutes. A dashboard polling that endpoint surfaces it before the news cycle catches up.
- **Log4Shell, December 2021 (CVE-2021-44228)**. EPSS hit 0.97 within hours of disclosure, KEV listing followed shortly after. A CVE velocity panel weighted by EPSS and KEV diff is exactly how you spot "this one matters" in a flood of CVEs.
- **2024 CrowdStrike outage**. Cloudflare Radar's outage feed flagged abnormal connectivity dips per ASN before anyone identified the root cause. An operator with the outage panel open sees something is wrong before they know what.

The point of this project is to teach how live data infrastructure for security operations actually gets built: the collector pattern, the bus pattern, WebSocket fan-out, and how to keep all of that observable and correct at three orders of magnitude of cadence variation (sub-second to daily).

## What You'll Learn

**Security and operations theory**

- **Threat intel feed economics**: which feeds actually cost money (NVD API key throttling, AbuseIPDB lookups), which are free but fragile (DShield scraping), which are commercial but worth it (Cloudflare Radar). What latency budget each one has.
- **EPSS vs CVSS**: why "Critical CVSS 9.8" is not the same as "this will be exploited tomorrow" and why EPSS percentile is the correct prioritization signal for an operator's first 30 minutes of attention.
- **CISA KEV**: what Known Exploited Vulnerabilities actually means, why a KEV diff alert is the loudest single signal a practitioner can subscribe to, and how it correlates (or doesn't) with EPSS.
- **BGP hijacks vs route leaks**: how MOAS (multiple origin AS) detection works, why confidence scoring exists, and what an ASN really represents on the global routing table.
- **Why coordinate transforms matter**: ISS position needs SGP4 propagation from a TLE, not a polling endpoint, because the polling endpoint is `wheretheiss.at` and the TLE source is CelesTrak, and they update at different cadences. Mixing them naively gives you teleporting satellites.

**Distributed systems patterns**

- **In-process event bus** as a pragmatic alternative to Kafka or NATS when your scale is "one box, eleven producers, one fan-out". The single-binary architecture is a feature, not a constraint.
- **Backpressure and lossy fan-out**: when to drop events, when to block the producer, and why slow WebSocket subscribers must never block collector goroutines.
- **Snapshot-then-stream protocol**: how a connecting browser gets the current world state via REST and then transitions cleanly to WebSocket without missing or double-counting events.
- **BRIN indexes for append-mostly time-series in Postgres**, and why you reach for them before partitioning.
- **Single-binary `errgroup` orchestration**: how to start eleven heterogeneous workers, propagate cancellation, and clean up on `SIGTERM` without writing a process supervisor.

**Auth and crypto**

- **JWT with auto-rotated Ed25519 (ES256)**: why asymmetric signing belongs in front of any public dashboard, how `JWKS` exposure works, and why it lets you change keys without reissuing every active token.
- **AES-256-GCM at rest** for webhook secrets so a database leak does not become a Discord/Slack/Telegram pwn of every alerted user.
- **Argon2id** for password hashing instead of bcrypt, with the parameter tuning rationale.

**Frontend telemetry**

- A 3D MapLibre globe with per-country outage shading, ASN dot density for mass-scan sources, ransomware victim markers, earthquake epicenters, and a live ISS track propagated on the client.
- TanStack Query v5 + Zustand for the snapshot/stream split: REST for cold start, WebSocket pushes into the same store, components subscribe to selectors.

## Prerequisites

**You should be comfortable with:**

- **Go** — goroutines, channels, contexts, `errgroup`, the `context.Context` cancellation model. If you have never written `select { case <-ctx.Done(): ... }` you will be lost.
- **PostgreSQL basics** — `CREATE INDEX`, `EXPLAIN`, JSONB columns. Not advanced query planning, just enough to read a migration.
- **HTTP and WebSocket fundamentals** — how a WS upgrade handshake works, what ping/pong frames are for, what backpressure means.
- **TypeScript and React** — hooks, state management. You do not need MapLibre or D3 expertise; the project uses them but the patterns are explained.

**Nice to have but not required:**

- BGP and ASN intuition (CIDR, prefix length, "what is AS15169"). Read the [Cloudflare Radar BGP docs](https://developers.cloudflare.com/radar/) if you want a primer.
- SGP4/TLE astrodynamics for the ISS panel (the project uses `joshuaferrara/go-satellite` so you do not have to implement it).
- CEL (Common Expression Language) for the alert rule predicates. The Google `cel-go` README is the right starting point.

**Tools:**

- Go 1.25+
- Node 20+ and `pnpm`
- Docker and Docker Compose
- `just` ([install](https://github.com/casey/just)) — every recipe is in the `Justfile`
- Optional: an NVD API key (raises CVE poll budget from 5 req/30s to 50 req/30s) and a Cloudflare API token (`CF_RADAR_TOKEN`) for the Radar feeds.

## Quick Start

```bash
cd PROJECTS/advanced/monitor-the-situation-dashboard

# Optional: fill in API keys (nothing is required to boot)
cp .env.example .env

# Bring up postgres, redis, backend, frontend in dev mode
just dev-up

# In another shell, run migrations
just migrate
```

Visit `http://localhost:8432`. You should see the globe initialize, then panels populate one by one as their first poll cycle returns. The heartbeat panel shows green within five seconds.

If you see a `NO SIGNAL` ribbon, the WebSocket failed. Check `just logs backend` — the most common cause is `notifications: encryption key not set`, which disables the alert engine but not the dashboard itself.

## Expected Output

Within about a minute of `just dev-up`:

- **Globe panel** rotating, with the ISS track drawn in a polar orbit. Earthquake dots appear as USGS publishes them (typically 5-30 per hour worldwide above M2.5).
- **CVE velocity panel** populated with the last two hours of NVD entries, sorted by EPSS. Several rows tagged `KEV` if any made the catalog recently.
- **DShield panel** showing top scanning ASNs. If you waited the full hour for the first poll, the panel shows the top 10 sources for mass scanning by report volume.
- **BTC/ETH panels** ticking live (Coinbase has the lowest cadence in the system, sub-second).
- **Outage panel** quiet most days. Cloudflare Radar surfaces something interesting roughly weekly.

## Where To Go Next

This file is the orientation. The actual learning material is split across:

| File | Focus | Read time |
|---|---|---|
| [01-CONCEPTS.md](01-CONCEPTS.md) | Threat intel theory: EPSS, KEV, BGP hijacks, mass-scan firehoses, situational awareness as a discipline | 20 min |
| [02-ARCHITECTURE.md](02-ARCHITECTURE.md) | Single-binary collector pipeline, event bus, snapshot store, WebSocket fan-out, BRIN time-series storage | 30 min |
| [03-IMPLEMENTATION.md](03-IMPLEMENTATION.md) | Code walkthrough across collectors, bus, ws, alerts engine, snapshot REST, frontend store wiring | 45 min |
| [04-CHALLENGES.md](04-CHALLENGES.md) | Extension ideas, extra feeds to wire in, alert engine improvements, deployment hardening | 15 min |

Read in order if this is your first encounter with the project. Skip to `03-IMPLEMENTATION` if you have already deployed similar systems and want to compare patterns.
