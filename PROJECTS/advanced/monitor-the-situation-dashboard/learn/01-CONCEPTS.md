<!--
©AngelaMos | 2026
01-CONCEPTS.md
-->

# Concepts

Before walking through code, you need to understand the security and operations theory the dashboard is built around. Skip this if you already know what EPSS percentile means, what a BGP hijack actually is, and why a SOC analyst with one screen needs a different feed mix than one with eight.

## Situational Awareness as a Discipline

The military origin of "situational awareness" (Endsley, 1995) breaks the term into three levels:

1. **Perception** — what is happening right now in the environment.
2. **Comprehension** — what those raw observations mean together.
3. **Projection** — what is likely to happen next.

Most security dashboards stop at level 1. They show alerts, traffic graphs, and CVE counts. A useful dashboard has to make level 2 cheap (visual fusion across feeds) and at least nudge toward level 3 (KEV diffs, EPSS climbing curves, ransomware leak posts that historically precede public breach disclosure by 3-7 days).

The eleven feeds in this project are chosen so that no single page-of-screen view requires the operator to mentally cross-reference. The globe spatializes ASN-bound data (outages, hijacks, scan sources) on the same surface as physical events (earthquakes, ISS, ransomware victims by country). The CVE panel shows EPSS bars next to KEV badges so "should I care?" is a visual decision, not a database query.

## The Eleven Feeds

| Feed | What it measures | Update cadence | Latency budget |
|---|---|---|---|
| DShield (SANS Internet Storm Center) | Top scanning source ASNs and target ports | 1h | 5 min |
| Cloudflare Radar — outages | Country-level connectivity drops with ASN attribution | 5 min | 30 sec |
| Cloudflare Radar — BGP hijacks | MOAS prefix anomalies with confidence scoring | 5 min | 30 sec |
| NVD CVE 2.0 | Newly published or modified CVEs | 2h | 30 min |
| FIRST EPSS | Exploit prediction percentile per CVE | 2h | hours |
| CISA KEV | Officially "exploited in the wild" catalog | 1h | hours |
| ransomware.live | Ransomware leak-site victim posts | 15m | minutes |
| Coinbase WS | BTC/ETH spot ticks | persistent | sub-second |
| USGS GeoJSON | Global earthquakes M2.5+ | 1m | 30 sec |
| NOAA SWPC | Kp index, Bz GSM, X-ray flux, solar wind speed/density | 1m / 3h | minutes |
| Wikipedia ITN + GDELT | World news headlines and event-tone spikes | 5m / 15m | minutes |
| ISS position + passes | Subsatellite point and TLE | 10s / 24h | seconds |

The cadence column is what the operator sees. The latency budget is how long the system can lag the source before the data is wrong enough to misinform a decision. Coinbase has a sub-second budget because BTC moves; KEV has hours because adding to KEV is itself a slow process. **Building a dashboard means matching every panel's freshness indicator to the right budget**, not just polling everything as fast as possible.

## EPSS vs CVSS, and Why It Matters

CVSS (Common Vulnerability Scoring System) gives a 0-10 severity number. CVSS is a *risk model* in the worst sense: a static rubric scored once at disclosure that asks "if exploited, how bad?" It does not answer "will it be exploited?"

EPSS (Exploit Prediction Scoring System, run by FIRST.org) answers the second question. It produces, for every CVE in NVD, a probability between 0 and 1 that the CVE will be exploited in the next 30 days, plus a percentile against the rest of the population. The model is updated daily based on observed exploitation telemetry.

The practical numbers:

- About 6% of all published CVEs ever get exploited in the wild.
- An EPSS percentile above ~95 is a useful triage threshold for "look at this today".
- KEV catalog membership is binary, hand-curated, and lags EPSS. KEV is the most expensive evidence (a CVE made it onto KEV because real attacks were observed) and EPSS is the cheapest forward-looking signal.

The CVE panel in this dashboard uses EPSS percentile as the primary sort key, with a KEV badge as a secondary visual marker. CVSS is shown but de-emphasized.

**Real example**: CVE-2017-5638 (Apache Struts, Equifax breach). CVSS 10.0. EPSS at disclosure was 0.97. KEV listed it eventually. By the time a CVSS-only dashboard would have moved it to "critical" attention, EPSS already said "this will be exploited within 30 days at 97% probability."

## CISA KEV and Why a Diff Matters

The CISA Known Exploited Vulnerabilities catalog is a hand-maintained list of CVEs CISA has observed being exploited against US federal systems or in widespread campaigns. Each entry includes a `dateAdded` and a `dueDate` (when federal civilian agencies must patch).

The catalog is small (~1000 entries) and grows by 1-10 per week. The interesting signal is not the snapshot, it is the **diff**. When a CVE is *added* to KEV today, it means CISA just confirmed in-the-wild exploitation that did not have public visibility yesterday. That diff is among the loudest single signals an enterprise defender can subscribe to.

The KEV collector polls the catalog, computes the new-since-last-poll set, and emits one `kev_added` event per new CVE. The frontend renders a banner and the alert engine optionally fires Telegram/Discord/Slack notifications.

## BGP Hijacks and Route Leaks

The internet routes traffic by trusting that ASNs (Autonomous Systems, the entities that run networks) honestly announce which IP prefixes they own. They do not all do this honestly.

A **BGP hijack** is when an ASN announces a prefix it does not own. Two flavors:

- **Origin hijack (MOAS, Multiple Origin AS)**: two ASNs both announce the same prefix. Cloudflare Radar's confidence scoring fuses this with prefix-validation history.
- **Path manipulation**: AS announces a more specific prefix or a shorter path so traffic prefers it. This is how the 2018 Amazon Route 53 hijack stole MyEtherWallet credentials.

A **route leak** is similar but accidental: a misconfigured router announces customer routes to peers they should not have been propagated to.

The Radar BGP endpoint returns hijack candidates with: `started_at`, `duration_sec`, `confidence` (0-100), `hijacker_asn`, `victim_asns`, `prefixes`. The collector filters by configured `MinConfidence` (default 60) before persisting and emitting. The globe panel renders hijack regions on the great-circle path between hijacker and victim ASN geolocations.

**Real incidents to read up on**:

- April 2018, AS10297 (eNet) hijacked Route 53 prefixes for two hours, redirected MyEtherWallet, stole ~$150k of ETH.
- June 2024, AS267613 (Eletel) hijacked Orange España prefixes, took the operator partly offline.
- April 2010, China Telecom (AS23724) accidentally announced 50,000 prefixes worldwide for ~18 minutes ("the great Chinese internet diversion").

## Mass-Scan Firehose

DShield, run by SANS Internet Storm Center, aggregates firewall logs from thousands of voluntary submitters. They publish:

- Top reporting sources (which IPs scanned the most submitters in the last 24h).
- Top targeted ports (which TCP/UDP ports got hit hardest).
- Country-level scan distribution.

This is the only feed in the system that gives a global, attacker-side view of "what is being scanned right now". It is *not* an attack feed in the IDS sense; it is the noise floor of the internet. The signal is in the *delta*: when port 7547 (TR-069 / CWMP) jumps to the top of the table, you are likely watching the next Mirai-class IoT botnet ramp up. When port 8728 (MikroTik Winbox) jumps, you are watching MikroTik routers get exploited again.

The DShield collector merges three endpoints (top sources, top ports, country distribution) into a single snapshot blob and emits it as `scan_firehose`.

## Snapshot vs Stream — The Two-Phase Protocol

The dashboard speaks two protocols that have to coexist:

1. **REST snapshot** — a fresh browser asks `GET /v1/snapshot` and gets the latest state of every topic in one JSON blob. Sourced from Redis, populated continuously by the bus.
2. **WebSocket stream** — same browser opens `/v1/ws?topics=cve_new,kev_added,...` and receives events as they happen.

The two have to be sequenced correctly or the browser sees impossible state. If the snapshot lags the stream by even a second, you can get a `cve_updated` event for a CVE the snapshot does not know about. The frontend handles this with a buffer:

- WS opens. Frontend buffers all messages.
- Snapshot REST returns. Frontend hydrates state.
- Frontend calls `setReady()` on the WS handle. Buffered messages flush into the same state.
- Subsequent messages flow live.

This is a classic snapshot+stream pattern (used by Kafka Connect, the Linux kernel, Postgres logical replication). Getting it wrong is the most common cause of "data is missing" bugs in real-time UIs.

## Why an In-Process Bus Instead of Kafka or NATS

A common reflex is "real-time fan-out → broker". For this scale (eleven producers, dozens of WS subscribers, single box) a broker is overkill. The cost calculus:

| Option | Pros | Cons at this scale |
|---|---|---|
| Kafka | Durable, horizontally scalable, replayable | Multi-node operational cost, persistent volumes, ACL system, Zookeeper/KRaft, full week of ops setup |
| NATS | Lighter than Kafka, simpler ops | Still a separate process, still a separate auth surface, still adds a network hop |
| Redis Pub/Sub | Already running Redis | Lossy, no backpressure model, no persistence, blocks on slow subscriber |
| In-process channel | Zero ops, lossy by design (drop-on-full), one-binary deploy | Cannot scale beyond one process |

The dashboard does not need to scale beyond one process. Eleven collectors at the cadences listed above produce well under 100 events/sec peak. A buffered Go channel with size 512 is more than enough. **The "constraint" of single-binary is actually the feature** — operations becomes `docker compose up` and a Justfile.

If you ever do need to scale (e.g., rendering this for a multi-tenant SOC product), you replace the bus with NATS JetStream and keep the rest. Collectors and the frontend do not change.

## Slow-Consumer Handling

A WebSocket subscriber that stops reading is a denial-of-service risk to every other subscriber. If the hub blocks on the slow client's `Write`, latency for everyone goes up. If the hub buffers unbounded, memory grows until OOM.

The pattern in this project: **bounded per-subscriber buffer, drop+disconnect on overflow**. The hub gives each subscriber a 256-message channel. On send, the hub does a non-blocking select. If the channel is full, the hub asynchronously closes the connection with `StatusPolicyViolation: slow consumer`. The client reconnects, gets a fresh snapshot from REST, and continues.

256 is not arbitrary. Heartbeat fires every 5s, Coinbase peaks ~8 ticks/sec, ISS every 10s. A buffer that only holds 16 messages fills during a single browser GC pause and triggers a reconnect loop. 256 absorbs typical jitter without papering over genuinely-stuck clients.

## Time-Series Storage with BRIN

The dashboard's tables are append-mostly: events arrive monotonically by `occurred_at`, and queries almost always filter by a recent time range. This is the workload BRIN (Block Range Index) was built for.

A BRIN index stores per-block-range summaries (min/max of the indexed column) instead of per-row entries. For a column that is naturally correlated with physical row order (which `occurred_at` is, because rows arrive in time order), BRIN is **dozens to hundreds of times smaller than B-tree** with comparable scan-range performance.

Trade-off: BRIN is great for `WHERE ts > now() - interval '24h'` and useless for `WHERE id = ?`. The migrations in this project use B-tree on primary keys and BRIN on time columns:

```sql
CREATE INDEX idx_quakes_time_brin ON earthquakes USING BRIN (occurred_at);
CREATE INDEX idx_quakes_mag       ON earthquakes (mag DESC, occurred_at DESC);
```

The first index serves "show me earthquakes in the last hour". The second serves "show me the strongest earthquakes from the last week".

You should reach for BRIN before considering native partitioning. Partitioning solves problems BRIN does not (per-partition retention via `DROP PARTITION`, parallel pruning), but adds operational complexity. For this dataset size — measured in tens of millions of rows over months, not billions — BRIN alone holds up.

## Auth: ES256 with Auto-Rotated Keys

JWT signing has two viable shapes for a public-facing dashboard:

- **HS256** (HMAC SHA-256, symmetric). Simple. Same secret signs and verifies. Anything with the secret can mint tokens.
- **ES256** (ECDSA P-256, asymmetric). Private key signs. Public key verifies. You can publish the public key freely (JWKS endpoint) so other services can verify without holding the signing secret.

This project uses ES256 (Ed25519 in some legacy notes — the actual implementation is P-256 ECDSA per RFC 7518). The reasons:

- The dashboard exposes `/.well-known/jwks.json`, so a future microservice could verify dashboard tokens without trusting the dashboard's filesystem.
- Private key rotation only requires updating the signer; verifiers fetch the new JWKS automatically.
- Argon2id password hashes plus ES256 tokens means a database leak alone does not let an attacker mint admin sessions.

The bootstrap code generates the keypair if missing (see `ensureJWTKeys` in `cmd/api/main.go`). For real deployments you mount the keys from a secret store, but the auto-generation makes dev frictionless.

## Webhook Secret Encryption

Configurable alerts (Slack, Discord, Telegram) require storing webhook URLs and bot tokens. These are credentials. A compromised database without encryption gives the attacker every alerted user's webhook, which they can immediately use to spam, phish, or push malicious links into the user's communication channels.

The `notifications` package wraps user-supplied webhook configs with AES-256-GCM. The encryption key is a 32-byte value loaded from `NOTIFICATION_ENCRYPTION_KEY`. Encryption produces `(ciphertext, nonce)`; both are stored, neither is logged. Decryption happens on demand at alert-fire time and the plaintext never persists.

If the env var is not set, the entire alert engine is disabled with a logged warning. **Failing closed** is the correct security posture here: it is better to have no alerts than to have plaintext webhook credentials in your database.

## Testing Your Understanding

Before moving to architecture, you should be able to answer:

1. Why is EPSS percentile a better triage signal than CVSS for an operator's first 30 minutes of attention?
2. What is the difference between an origin BGP hijack (MOAS) and a path manipulation hijack? Which one would a confidence-scored Radar feed catch more reliably?
3. Why does the system buffer WebSocket messages on the client until the snapshot REST returns, instead of just connecting and rendering as events arrive?
4. What is the actual scale ceiling of an in-process Go channel bus, and at what point would you switch to NATS or Kafka?
5. Why is BRIN the right choice for `occurred_at` columns and the wrong choice for primary key columns?
6. What goes wrong if `NOTIFICATION_ENCRYPTION_KEY` is set to a 16-byte value instead of 32?
7. Why does the dashboard close slow WebSocket consumers instead of buffering more aggressively?

If any of these are unclear, re-read the relevant section. If they all make sense, continue to [02-ARCHITECTURE.md](02-ARCHITECTURE.md).
