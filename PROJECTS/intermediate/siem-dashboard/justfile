# ©AngelaMos | 2026
# justfile

set dotenv-load
set export
set shell := ["bash", "-uc"]
set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

project := file_name(justfile_directory())
version := `git describe --tags --always 2>/dev/null || echo "dev"`

# =============================================================================
# Default
# =============================================================================

default:
    @just --list --unsorted

# =============================================================================
# Development
# =============================================================================

[group("dev")]
dev-up *ARGS:
    docker compose -f dev.compose.yml up {{ARGS}}

[group("dev")]
dev *ARGS:
    docker compose -f dev.compose.yml up -d {{ARGS}}

[group("dev")]
dev-down *ARGS:
    docker compose -f dev.compose.yml down {{ARGS}}

[group("dev")]
dev-stop:
    docker compose -f dev.compose.yml stop

[group("dev")]
dev-restart:
    docker compose -f dev.compose.yml restart

[group("dev")]
dev-build *ARGS:
    docker compose -f dev.compose.yml up -d --build {{ARGS}}

[group("dev")]
dev-logs:
    docker compose -f dev.compose.yml logs -f

[group("dev")]
dev-logs-backend:
    docker logs -f ${APP_NAME:-siem}-backend-dev --tail 100

[group("dev")]
dev-logs-frontend:
    docker logs -f ${APP_NAME:-siem}-frontend-dev --tail 100

[group("dev")]
dev-logs-mongo:
    docker logs -f ${APP_NAME:-siem}-mongo-dev --tail 100

# =============================================================================
# Production
# =============================================================================

[group("prod")]
prod-up *ARGS:
    docker compose up {{ARGS}}

[group("prod")]
prod *ARGS:
    docker compose up -d {{ARGS}}

[group("prod")]
prod-down *ARGS:
    docker compose down {{ARGS}}

[group("prod")]
prod-build *ARGS:
    docker compose up -d --build {{ARGS}}

[group("prod")]
prod-logs:
    docker compose logs -f

# =============================================================================
# Production + Cloudflare Tunnel
# =============================================================================

[group("tunnel")]
tunnel-up *ARGS:
    docker compose -f compose.yml -f cloudflared.compose.yml up {{ARGS}}

[group("tunnel")]
tunnel-start *ARGS:
    docker compose -f compose.yml -f cloudflared.compose.yml up -d {{ARGS}}

[group("tunnel")]
tunnel-down *ARGS:
    docker compose -f compose.yml -f cloudflared.compose.yml down {{ARGS}}

[group("tunnel")]
tunnel-logs:
    docker compose -f compose.yml -f cloudflared.compose.yml logs -f cloudflared

# =============================================================================
# Backend
# =============================================================================

[group("backend")]
create-admin *ARGS:
    docker exec -it ${APP_NAME:-siem}-backend-dev flask admin create {{ARGS}}

[group("backend")]
shell:
    docker exec -it ${APP_NAME:-siem}-backend-dev bash

[group("backend")]
flask-shell:
    docker exec -it ${APP_NAME:-siem}-backend-dev flask shell

[group("backend")]
test *ARGS:
    docker exec ${APP_NAME:-siem}-backend-dev pytest {{ARGS}}

[group("backend")]
lint:
    docker exec ${APP_NAME:-siem}-backend-dev ruff check app/

[group("backend")]
typecheck:
    docker exec ${APP_NAME:-siem}-backend-dev mypy app/
