# ©AngelaMos | 2026
# Justfile
# =============================================================================

set dotenv-load
set export
set shell := ["bash", "-uc"]

project := file_name(justfile_directory())
version := `git describe --tags --always 2>/dev/null || echo "dev"`

# =============================================================================
# Default
# =============================================================================

default:
    @just --list --unsorted

# =============================================================================
# Run
# =============================================================================

[group('run')]
run *ARGS:
    uv run b64tool {{ARGS}}

[group('run')]
encode DATA *ARGS:
    uv run b64tool encode "{{DATA}}" {{ARGS}}

[group('run')]
decode DATA *ARGS:
    uv run b64tool decode "{{DATA}}" {{ARGS}}

[group('run')]
detect DATA:
    uv run b64tool detect "{{DATA}}"

[group('run')]
peel DATA:
    uv run b64tool peel "{{DATA}}"

[group('run')]
chain DATA STEPS:
    uv run b64tool chain "{{DATA}}" --steps {{STEPS}}

# =============================================================================
# Linting and Formatting
# =============================================================================

[group('lint')]
ruff *ARGS:
    uv run ruff check src/ tests/ {{ARGS}}

[group('lint')]
ruff-fix:
    uv run ruff check src/ tests/ --fix
    uv run ruff format src/ tests/

[group('lint')]
ruff-format:
    uv run ruff format src/ tests/

[group('lint')]
lint: ruff

# =============================================================================
# Type Checking
# =============================================================================

[group('types')]
mypy *ARGS:
    uv run mypy src/ {{ARGS}}

[group('types')]
typecheck: mypy

# =============================================================================
# Testing
# =============================================================================

[group('test')]
test *ARGS:
    uv run pytest {{ARGS}}

[group('test')]
test-cov:
    uv run pytest --cov=base64_tool --cov-report=term-missing --cov-report=html

# =============================================================================
# CI / Quality
# =============================================================================

[group('ci')]
ci: lint typecheck test

[group('ci')]
check: ruff mypy

# =============================================================================
# Setup
# =============================================================================

[group('setup')]
setup:
    uv sync --all-extras

[group('setup')]
install:
    uv sync

[group('setup')]
install-dev:
    uv sync --all-extras

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
    -rm -rf .mypy_cache
    -rm -rf .pytest_cache
    -rm -rf .ruff_cache
    -rm -rf htmlcov
    -rm -rf .coverage
    -rm -rf dist
    -rm -rf *.egg-info
    @echo "Cache directories cleaned"
