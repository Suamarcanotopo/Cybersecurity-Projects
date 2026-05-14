# =============================================================================
# AngelaMos | 2026
# Justfile - Encrypted P2P Chat
# =============================================================================

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
# Linting and Formatting
# =============================================================================

[group('lint')]
ruff *ARGS:
    ruff check backend/ {{ARGS}}

[group('lint')]
ruff-fix:
    ruff check backend/ --fix
    ruff format backend/

[group('lint')]
ruff-format:
    ruff format backend/

[group('lint')]
pylint *ARGS:
    pylint backend/app {{ARGS}}

[group('lint')]
lint: ruff pylint

# =============================================================================
# Frontend Linting
# =============================================================================

[group('frontend')]
eslint *ARGS:
    cd frontend && pnpm eslint . {{ARGS}}

[group('frontend')]
eslint-fix:
    cd frontend && pnpm eslint . --fix

[group('frontend')]
prettier *ARGS:
    cd frontend && pnpm prettier --check "src/**/*.{ts,tsx,css}" {{ARGS}}

[group('frontend')]
prettier-fix:
    cd frontend && pnpm prettier --write "src/**/*.{ts,tsx,css}"

[group('frontend')]
tsc *ARGS:
    cd frontend && pnpm tsc --noEmit {{ARGS}}

# =============================================================================
# Type Checking
# =============================================================================

[group('types')]
mypy *ARGS:
    mypy backend/app {{ARGS}}

[group('types')]
typecheck: mypy

# =============================================================================
# Testing
# =============================================================================

[group('test')]
pytest *ARGS:
    cd backend && uv run pytest {{ARGS}}

[group('test')]
test-frontend *ARGS:
    cd frontend && pnpm test {{ARGS}}

[group('test')]
test: pytest test-frontend

[group('test')]
test-cov:
    cd backend && uv run pytest --cov=app --cov-report=term-missing --cov-report=html

[group('dev')]
dev-reset:
    docker compose -f dev.compose.yml down -v
    @echo "Volumes wiped. Run 'just dev-up' to start fresh."

# =============================================================================
# CI / Quality
# =============================================================================

[group('ci')]
ci: lint typecheck test

[group('ci')]
check: ruff mypy

# =============================================================================
# Docker Compose (Production)
# =============================================================================

[group('docker')]
up *ARGS:
    docker compose up {{ARGS}}

[group('docker')]
start *ARGS:
    docker compose up -d {{ARGS}}

[group('docker')]
down *ARGS:
    docker compose down {{ARGS}}

[group('docker')]
stop:
    docker compose stop

[group('docker')]
build *ARGS:
    docker compose build {{ARGS}}

[group('docker')]
rebuild:
    docker compose build --no-cache

[group('docker')]
logs *SERVICE:
    docker compose logs -f {{SERVICE}}

[group('docker')]
ps:
    docker compose ps

[group('docker')]
shell service='backend':
    docker compose exec -it {{service}} /bin/bash

# =============================================================================
# Docker Compose (Dev)
# =============================================================================

[group('dev')]
dev-up *ARGS:
    docker compose -f dev.compose.yml up {{ARGS}}

[group('dev')]
dev-start *ARGS:
    docker compose -f dev.compose.yml up -d {{ARGS}}

[group('dev')]
dev-down *ARGS:
    docker compose -f dev.compose.yml down {{ARGS}}

[group('dev')]
dev-stop:
    docker compose -f dev.compose.yml stop

[group('dev')]
dev-build *ARGS:
    docker compose -f dev.compose.yml build {{ARGS}}

[group('dev')]
dev-rebuild:
    docker compose -f dev.compose.yml build --no-cache

[group('dev')]
dev-logs *SERVICE:
    docker compose -f dev.compose.yml logs -f {{SERVICE}}

[group('dev')]
dev-ps:
    docker compose -f dev.compose.yml ps

[group('dev')]
dev-shell service='backend':
    docker compose -f dev.compose.yml exec -it {{service}} /bin/bash

# =============================================================================
# Database (Docker)
# =============================================================================

[group('db')]
migrate *ARGS:
    docker compose exec backend alembic upgrade {{ARGS}}

[group('db')]
migration message:
    docker compose exec backend alembic revision --autogenerate -m "{{message}}"

[group('db')]
rollback:
    docker compose exec backend alembic downgrade -1

[group('db')]
db-history:
    docker compose exec backend alembic history --verbose

[group('db')]
db-current:
    docker compose exec backend alembic current

# =============================================================================
# Database (Local - no Docker)
# =============================================================================

[group('db-local')]
migrate-local *ARGS:
    cd backend && uv run alembic upgrade {{ARGS}}

[group('db-local')]
migration-local message:
    cd backend && uv run alembic revision --autogenerate -m "{{message}}"

[group('db-local')]
rollback-local:
    cd backend && uv run alembic downgrade -1

[group('db-local')]
db-history-local:
    cd backend && uv run alembic history --verbose

[group('db-local')]
db-current-local:
    cd backend && uv run alembic current

# =============================================================================
# Setup
# =============================================================================

[group('setup')]
setup: setup-backend setup-frontend env
    @echo "Setup complete!"

[group('setup')]
setup-backend:
    @echo "Setting up backend..."
    cd backend && uv sync
    @echo "Backend setup complete!"

[group('setup')]
setup-frontend:
    @echo "Setting up frontend..."
    cd frontend && pnpm install
    @echo "Frontend setup complete!"

[group('setup')]
env:
    @echo "Creating .env files..."
    @if [ ! -f .env ]; then cp .env.example .env; echo "Created root .env"; fi
    @if [ ! -f frontend/.env ]; then cp frontend/.env.example frontend/.env; echo "Created frontend/.env"; fi
    @echo ".env files created! Please update with your values."

# =============================================================================
# Utilities
# =============================================================================

[group('util')]
info:
    @echo "Project: {{project}}"
    @echo "Version: {{version}}"
    @echo "OS: {{os()}} ({{arch()}})"

[group('util')]
clean:
    -rm -rf backend/.mypy_cache
    -rm -rf backend/.pytest_cache
    -rm -rf backend/.ruff_cache
    -rm -rf backend/htmlcov
    -rm -rf backend/.coverage
    @echo "Cache directories cleaned"

[group('util')]
[confirm("Remove all containers, volumes, and build artifacts?")]
nuke:
    @echo "Nuking everything..."
    -docker compose -f dev.compose.yml down -v
    -docker compose down -v
    -rm -rf frontend/node_modules
    -rm -rf frontend/dist
    -rm -rf .venv
    -rm -rf backend/.venv
    -rm -rf backend/__pycache__
    -rm -rf backend/.pytest_cache
    -rm -rf backend/.mypy_cache
    -rm -rf backend/.ruff_cache
    @echo "Nuke complete!"
