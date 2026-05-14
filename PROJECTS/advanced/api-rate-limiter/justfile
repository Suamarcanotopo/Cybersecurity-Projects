# =============================================================================
# AngelaMos | 2026
# Justfile - API Rate Limiter (fastapi-420)
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
    ruff check src/ tests/ {{ARGS}}

[group('lint')]
ruff-fix:
    ruff check src/ tests/ --fix
    ruff format src/ tests/

[group('lint')]
ruff-format:
    ruff format src/ tests/

[group('lint')]
pylint *ARGS:
    pylint src/fastapi_420 {{ARGS}}

[group('lint')]
lint: ruff pylint

# =============================================================================
# Type Checking
# =============================================================================

[group('types')]
mypy *ARGS:
    mypy src/ {{ARGS}}

[group('types')]
ty *ARGS:
    ty check {{ARGS}}

[group('types')]
typecheck: mypy

# =============================================================================
# Testing
# =============================================================================

[group('test')]
pytest *ARGS:
    pytest tests/ {{ARGS}}

[group('test')]
test: pytest

[group('test')]
test-cov:
    pytest tests/ --cov=src/fastapi_420 --cov-report=term-missing --cov-report=html

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
    @echo "Setting up development environment..."
    uv sync --all-extras
    @echo "Setup complete!"

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
    -rm -f .coverage
    -rm -rf dist
    -rm -rf build
    @echo "Cache directories cleaned"

[group('util')]
[confirm("Remove all build artifacts and virtual environment?")]
nuke:
    @echo "Nuking everything..."
    -rm -rf .mypy_cache
    -rm -rf .pytest_cache
    -rm -rf .ruff_cache
    -rm -rf htmlcov
    -rm -f .coverage
    -rm -rf dist
    -rm -rf build
    -rm -rf .venv
    @echo "Nuke complete!"
