# SIEM Dashboard

## What This Is

A full stack Security Information and Event Management (SIEM) platform that ingests log events from multiple source types, normalizes them into a common schema, classifies severity using pattern matching, and runs a real time correlation engine to generate alerts. It includes a React dashboard for monitoring, investigation, and attack scenario playback.

The backend is Flask with MongoDB for persistence and Redis Streams for real time event delivery. The frontend is React with TypeScript, Zustand for state, and Server-Sent Events for live updates.

## Why This Matters

Every organization with more than a handful of servers needs centralized log monitoring. Without it, you're blind to attacks until the damage is done. Commercial SIEMs like Splunk or Microsoft Sentinel cost tens of thousands per year, and most security teams still struggle with alert fatigue, missed correlations, and slow investigation workflows.

Building a SIEM from scratch teaches you how these systems actually work under the hood. You'll understand why correlation rules matter, how event normalization prevents data silos, and why real time streaming is critical for incident response.

**Real world scenarios where this applies:**
- A SOC analyst needs to correlate 20 failed SSH logins from one IP with a successful login 30 seconds later. That's a brute force followed by compromise, and the correlation engine in this project detects exactly that pattern.
- An incident responder pivots from a suspicious source IP to find all related events across firewall, auth, and endpoint logs. The pivot API (`/v1/logs/pivot`) enables this workflow.
- A security team wants to test detection rules against historical data before deploying them. The rule test endpoint (`/v1/rules/<id>/test`) replays events through a rule without creating real alerts.

## What You'll Learn

This project teaches you how SIEM systems process, correlate, and surface security events. By building it yourself, you'll understand:

**Security Concepts:**
- Log normalization across different source formats (firewall, IDS, auth, endpoint, DNS, proxy). Each source type has different fields and the normalizer in `app/engine/normalizer.py` maps them to a common schema.
- Severity classification using regex pattern matching against known attack indicators like "brute force", "lateral movement", and "data exfiltration".
- Correlation rule evaluation with sliding windows, including threshold counting, ordered sequence detection, and distinct-value aggregation.
- Alert lifecycle management from initial detection through acknowledgment, investigation, resolution, or false positive classification.

**Technical Skills:**
- Building a Flask application factory with MongoEngine, Redis, and structured error handling
- Implementing JWT authentication with Argon2id password hashing and timing safe verification to prevent user enumeration
- Using Redis Streams with consumer groups for reliable event delivery and Server-Sent Events for real time browser updates
- Writing a threaded correlation engine that evaluates rules against a continuous event stream
- Building a React frontend with Zustand state management, TanStack Query for data fetching, and SSE integration

**Tools and Techniques:**
- Docker Compose for local development with MongoDB, Redis, Nginx, Flask, and Vite running together
- YAML-based attack scenario playbooks that simulate real MITRE ATT&CK techniques like brute force (T1110.001) and DNS tunneling (T1048.003)
- Pydantic schemas for request validation with automatic error formatting
- MongoDB aggregation pipelines for timeline bucketing, severity breakdowns, and top source analysis

## Prerequisites

Before starting, you should understand:

**Required knowledge:**
- Python basics including classes, decorators, and type hints. You'll see decorators like `@endpoint(roles=ADMIN)` and `@_register(SourceType.FIREWALL)` throughout the codebase.
- Basic understanding of REST APIs and HTTP. The backend exposes around 30 endpoints under `/v1/`.
- Familiarity with JSON and basic database concepts. MongoDB stores documents as JSON-like structures and you'll work with MongoEngine's ORM.

**Tools you'll need:**
- Docker and Docker Compose, to run the full stack locally
- Python 3.14+ (the project uses modern type hints like `str | None`)
- Node.js 24+ and pnpm for the frontend
- A tool for making HTTP requests (curl, httpie, or Postman) to test the API directly

**Helpful but not required:**
- Experience with MongoDB queries and aggregation pipelines
- Familiarity with Redis data structures, particularly Streams
- Basic React and TypeScript knowledge for understanding the frontend

## Quick Start

Get the project running locally:

```bash
# Navigate to the project
cd PROJECTS/intermediate/siem-dashboard

# Start development environment
docker compose -f dev.compose.yml up --build

# The app will be available at http://localhost:8431
# Backend API is at http://localhost:8431/api/v1/
# Direct backend access at http://localhost:5113
# Direct frontend dev server at http://localhost:3959
```

Create an admin account:

```bash
docker exec -it siem-backend-dev flask admin create \
  --username admin \
  --email admin@example.com
```

Expected output: `Admin account 'admin' created successfully.`

Test the API:

```bash
# Register a regular user
curl -X POST http://localhost:8431/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"analyst1","email":"analyst@test.com","password":"testpass123"}'

# Ingest a test log event
curl -X POST http://localhost:8431/api/v1/logs/ingest \
  -H "Content-Type: application/json" \
  -d '{"source_type":"auth","event_type":"login_failure","source_ip":"10.0.0.1","username":"root"}'
```

## Project Structure

```
siem-dashboard/
├── backend/
│   ├── app/
│   │   ├── __init__.py           # Flask app factory
│   │   ├── config.py             # Pydantic settings (60+ config values)
│   │   ├── extensions.py         # MongoDB and Redis initialization
│   │   ├── cli.py                # Flask CLI for admin management
│   │   ├── core/
│   │   │   ├── auth.py           # JWT + Argon2id authentication
│   │   │   ├── streaming.py      # Redis Streams + SSE generator
│   │   │   ├── errors.py         # Error hierarchy and handlers
│   │   │   ├── rate_limiting.py  # Flask-Limiter setup
│   │   │   ├── serialization.py  # MongoEngine to JSON conversion
│   │   │   └── decorators/       # @endpoint, @S, @R composable decorators
│   │   ├── engine/
│   │   │   ├── normalizer.py     # Multi-format log normalizer
│   │   │   ├── severity.py       # Pattern-based severity classifier
│   │   │   └── correlation.py    # Sliding window correlation engine
│   │   ├── models/               # MongoEngine documents (User, LogEvent, Alert, etc.)
│   │   ├── routes/               # Flask blueprints for each resource
│   │   ├── controllers/          # Business logic handlers
│   │   ├── schemas/              # Pydantic request/response schemas
│   │   └── scenarios/
│   │       ├── playbook.py       # YAML playbook parser
│   │       ├── runner.py         # Threaded scenario executor
│   │       └── playbooks/        # Attack scenario YAML files
│   ├── pyproject.toml            # Python dependencies and tool config
│   └── wsgi.py                   # Gunicorn entry point
├── frontend/
│   ├── src/
│   │   ├── api/hooks/            # TanStack Query hooks for each resource
│   │   ├── api/types/            # Zod schemas and TypeScript types
│   │   ├── core/app/             # Shell layout, routing, protected routes
│   │   ├── core/lib/             # Axios client, error handling, query config
│   │   ├── core/stores/          # Zustand stores (auth, stream, UI)
│   │   ├── core/charts/          # visx chart theme and color constants
│   │   ├── routes/               # Page components (lazy loaded)
│   │   └── config.ts             # API endpoints, query keys, constants
│   └── package.json
├── conf/
│   ├── docker/                   # Dockerfiles for dev and prod
│   └── nginx/                    # Nginx configs for proxying and SSE
├── compose.yml                   # Production Docker Compose
└── dev.compose.yml               # Development Docker Compose
```

## Next Steps

1. **Understand the concepts** - Read [01-CONCEPTS.md](./01-CONCEPTS.md) to learn about log correlation, event normalization, and SIEM architecture principles
2. **Study the architecture** - Read [02-ARCHITECTURE.md](./02-ARCHITECTURE.md) to see how the backend engine, streaming layer, and frontend connect
3. **Walk through the code** - Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for a detailed walkthrough of the correlation engine, normalizer, and streaming pipeline
4. **Extend the project** - Read [04-CHALLENGES.md](./04-CHALLENGES.md) for ideas like adding Sigma rule support, building a threat intelligence feed, or implementing SOAR playbooks

## Common Issues

**Backend container keeps restarting**
```
siem-backend-dev | Connection refused: mongodb://mongo:27017/siem
```
Solution: MongoDB takes 10-30 seconds to initialize. The healthcheck in `dev.compose.yml` has a `start_period: 30s` but sometimes this isn't enough on slower machines. Wait and check `docker compose logs mongo`.

**SSE streams disconnect immediately**
The Nginx config at `conf/nginx/dev.nginx` has special handling for SSE endpoints. If you see instant disconnects, verify the regex location block `location ~ ^/api(/v1/(logs|alerts)/stream.*)` is matching your request. The SSE endpoints need `proxy_buffering off` and long read timeouts.

**Redis Stream errors on startup**
```
BUSYGROUP Consumer Group name already exists
```
This is normal. The `ensure_consumer_group()` function in `app/core/streaming.py` wraps the creation in `contextlib.suppress(Exception)` because it's idempotent. The consumer group already exists from a previous run.

**Rate limiting blocks development requests**
Auth endpoints are limited to 10 requests per minute (`RATELIMIT_AUTH` in `config.py`). General endpoints allow 200 per minute. If you're hammering the login endpoint during testing, wait a minute or temporarily increase the limit in your `.env` file.

## Related Projects

If you found this interesting, check out:
- **API Rate Limiter** (advanced) - Deep dive into the rate limiting algorithms this project uses via Flask-Limiter, including sliding window and token bucket strategies
- **Network Traffic Analyzer** - Packet-level analysis using Scapy, complementing the higher level log analysis this SIEM performs
- **Docker Security Auditor** - Container security scanning that could feed events into this SIEM's ingestion pipeline
