# =============================================================================
# AngelaMos | 2026
# Justfile - Credential Rotation Enforcer (cre)
# =============================================================================

set export
set shell         := ["bash", "-uc"]
set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

project        := file_name(justfile_directory())
version        := `git describe --tags --always 2>/dev/null || echo "dev"`
binary         := "bin/cre"
db_default     := "sqlite:cre.db"
test_db_url    := "postgres://cre_test:cre_test@localhost:5432/cre_test"

# =============================================================================
# Default
# =============================================================================

default:
    @just --list --unsorted

# =============================================================================
# Build
# =============================================================================

[group('build')]
build:
    shards build cre --release --no-debug

[group('build')]
build-dev:
    shards build cre

[group('build')]
deps:
    shards install

[group('build')]
clean:
    rm -rf bin lib .shards .crystal coverage tmp

[group('build')]
rebuild: clean deps build

# =============================================================================
# Run (cre lifecycle)
# =============================================================================

[group('run')]
run db=db_default:
    shards build cre && {{binary}} run --db={{db}}

[group('run')]
watch db=db_default:
    shards build cre && {{binary}} watch --db={{db}}

[group('run')]
check db=":memory:":
    shards build cre && {{binary}} check --db={{db}}

[group('run')]
rotate ID db=db_default:
    shards build cre && {{binary}} rotate {{ID}} --db={{db}}

[group('run')]
audit-verify db=db_default:
    shards build cre && {{binary}} audit verify --db={{db}}

[group('run')]
policy-list:
    shards build cre && {{binary}} policy list

[group('run')]
policy-show name:
    shards build cre && {{binary}} policy show {{name}}

[group('run')]
export framework="soc2" out="evidence.zip" db=db_default:
    shards build cre && {{binary}} export --framework={{framework}} --out={{out}} --db={{db}}

# =============================================================================
# Demos (Tier 1 / Tier 2 / Tier 3)
# =============================================================================

[group('demo')]
demo:
    shards build cre && {{binary}} demo

[group('demo')]
tui-demo seconds="8":
    shards build cre && {{binary}} tui-demo --seconds={{seconds}}

[group('demo')]
demo-full:
    docker compose -f docker/docker-compose.yml up -d
    @echo "Waiting for services to be healthy..."
    @sleep 8
    shards build cre
    @echo ""
    @echo "Stack up. Daemon will run against Postgres on port 6022."
    @echo "Press Ctrl+C to stop the daemon, then 'just demo-full-down' to tear down the stack."
    @echo ""
    DATABASE_URL=postgres://cre:cre@localhost:6022/cre \
      AWS_ENDPOINT=http://localhost:45666 \
      VAULT_ADDR=http://localhost:18201 \
      GITHUB_API_BASE=http://localhost:7115 \
      {{binary}} run --db=postgres://cre:cre@localhost:6022/cre

[group('demo')]
demo-full-down:
    docker compose -f docker/docker-compose.yml down -v

[group('demo')]
demo-full-logs:
    docker compose -f docker/docker-compose.yml logs -f --tail=50

[group('demo')]
demo-full-status:
    docker compose -f docker/docker-compose.yml ps

# =============================================================================
# Test
# =============================================================================

[group('test')]
test:
    crystal spec --order=random

[group('test')]
test-unit:
    crystal spec spec/unit --order=random

[group('test')]
test-integration:
    DATABASE_URL={{test_db_url}} crystal spec spec/integration --order=random

[group('test')]
test-watch:
    @echo "Watching spec/ for changes..."
    @while true; do \
      inotifywait -qre close_write src/ spec/ 2>/dev/null && crystal spec --order=random; \
    done

[group('test')]
coverage:
    @echo "Coverage requires kcov. Skipping if not installed."
    kcov --include-path=src coverage/ ./bin/cre || true

# =============================================================================
# Quality (format / lint)
# =============================================================================

[group('quality')]
format:
    crystal tool format

[group('quality')]
format-check:
    crystal tool format --check

[group('quality')]
lint:
    @if [ -x ./bin/ameba ]; then \
      ./bin/ameba; \
    else \
      echo "ameba not installed (requires libpcre3-dev on Debian 13+); skipping lint"; \
    fi

[group('quality')]
check-all: format-check lint test

[group('quality')]
ci: check-all

# =============================================================================
# Database (Tier 2 helpers)
# =============================================================================

[group('db')]
db-up:
    docker run -d --rm --name cre-pg -e POSTGRES_USER=cre_test -e POSTGRES_PASSWORD=cre_test -e POSTGRES_DB=cre_test -p 5432:5432 postgres:16

[group('db')]
db-down:
    docker stop cre-pg 2>/dev/null || true

[group('db')]
db-shell:
    docker exec -it cre-pg psql -U cre_test cre_test

# =============================================================================
# Utility
# =============================================================================

[group('util')]
version:
    @echo "{{project}} {{version}}"

[group('util')]
loc:
    @echo "Source LOC:"
    @find src -name "*.cr" -exec wc -l {} \; | awk '{total+=$1} END{print "  " total}'
    @echo "Spec LOC:"
    @find spec -name "*.cr" -exec wc -l {} \; | awk '{total+=$1} END{print "  " total}'
    @echo "Spec files: $(find spec -name '*_spec.cr' | wc -l)"

[group('util')]
binary-info:
    @ls -la {{binary}} 2>/dev/null || echo "binary not built; run 'just build'"
    @file {{binary}} 2>/dev/null || true
