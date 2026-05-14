# =============================================================================
# AngelaMos | 2026
# Justfile - Aenebris (Haskell Reverse Proxy)
# =============================================================================

set export
set shell        := ["bash", "-uc"]
set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

project        := file_name(justfile_directory())
version        := `git describe --tags --always 2>/dev/null || echo "dev"`
default_config := "examples/config.yaml"
log_file       := "aenebris.log"
backend_log    := "backend.log"

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
    stack build

[group('build')]
build-fast:
    stack build --fast

[group('build')]
build-watch:
    stack build --fast --file-watch

[group('build')]
build-pedantic:
    stack build --pedantic

[group('build')]
deps:
    stack build --only-dependencies

[group('build')]
install:
    stack install

[group('build')]
ghci *ARGS:
    stack ghci {{ARGS}}

# =============================================================================
# Run (Proxy Lifecycle)
# =============================================================================

[group('run')]
run config=default_config:
    stack run -- {{config}}

[group('run')]
run-bg config=default_config:
    @echo "Starting Aenebris with {{config}}..."
    @nohup stack run -- {{config}} > {{log_file}} 2>&1 &
    @sleep 2
    @echo "PID: $(pgrep -f '[a]enebris examples' | head -1)"
    @echo "Use 'just logs' to follow output, 'just stop' to halt"

[group('run')]
https:
    stack run -- examples/config-https.yaml

[group('run')]
sni:
    stack run -- examples/config-sni.yaml

[group('run')]
lb:
    stack run -- examples/config-loadbalancing.yaml

[group('run')]
advanced:
    stack run -- examples/config-advanced.yaml

[group('run')]
ws-sse:
    stack run -- examples/websockets/config_ws_sse.yaml

[group('run')]
stop:
    @pkill -f '[a]enebris examples' && echo "Proxy stopped" || echo "Proxy not running"

[group('run')]
restart config=default_config:
    @just stop
    @sleep 1
    @just run-bg {{config}}

[group('run')]
logs:
    tail -f {{log_file}}

[group('run')]
status:
    @pgrep -af '[a]enebris examples' || echo "Proxy not running"

# =============================================================================
# Backends (Python Test Servers)
# =============================================================================

[group('backend')]
backend:
    python3 examples/test_backend.py

[group('backend')]
backend-bg:
    @nohup python3 examples/test_backend.py > {{backend_log}} 2>&1 &
    @sleep 1
    @echo "Backend on :8000 (PID: $(pgrep -f '[t]est_backend.py' | head -1))"

[group('backend')]
backends:
    @bash examples/start_backends.sh

[group('backend')]
ws-server:
    python3 examples/websockets/ws_echo_server.py

[group('backend')]
sse-server:
    python3 examples/websockets/sse_server.py

[group('backend')]
kill-backends:
    -@pkill -f '[t]est_backend\.py'
    -@pkill -f '[t]est_backend_multi\.py'
    -@pkill -f '[w]s_echo_server\.py'
    -@pkill -f '[s]se_server\.py'
    @echo "Test backends stopped"

[group('backend')]
kill-all:
    @just stop
    @just kill-backends

# =============================================================================
# Tests (HSpec + Integration)
# =============================================================================

[group('test')]
test *ARGS:
    stack test {{ARGS}}

[group('test')]
test-fast:
    stack test --fast

[group('test')]
test-watch:
    stack test --fast --file-watch

[group('test')]
test-match PATTERN:
    stack test --test-arguments='--match="{{PATTERN}}"'

[group('test')]
test-cov:
    stack test --coverage

[group('test')]
test-list:
    stack test --test-arguments='--dry-run'

[group('test')]
test-config:
    @just test-match "Config"

[group('test')]
test-lb:
    @just test-match "LoadBalancer"

[group('test')]
test-backend-unit:
    @just test-match "Backend"

[group('test')]
test-security:
    @just test-match "Security headers"

[group('test')]
test-redirect:
    @just test-match "HTTPS redirect"

[group('test')]
test-ratelimit:
    @just test-match "RateLimit"

[group('test')]
test-ddos:
    stack test --test-arguments='--match="EarlyData" --match="IPJail" --match="MemoryShed" --match="ConnLimit"'

[group('test')]
test-ja4h:
    @just test-match "JA4H fingerprint"

[group('test')]
test-waf:
    @just test-match "WAF"

[group('test')]
test-honeypot:
    @just test-match "Honeypot"

[group('test')]
test-geo:
    @just test-match "Geo/ASN"

[group('test')]
test-ml:
    stack test --test-arguments='--match="ML.Features" --match="ML.Model"'

[group('test')]
ws-test host='localhost' port='8081':
    python3 examples/websockets/test_client.py {{host}} {{port}}

# =============================================================================
# TLS / Certificates
# =============================================================================

[group('tls')]
gen-certs:
    bash examples/generate-test-certs.sh

[group('tls')]
clean-certs:
    -rm -rf examples/certs
    @echo "Test certs removed (regenerate with 'just gen-certs')"

[group('tls')]
tls-headers:
    curl -kI https://localhost:8443/

[group('tls')]
tls13:
    openssl s_client -connect localhost:8443 -tls1_3 < /dev/null 2>&1 | grep -E "Protocol|Cipher"

[group('tls')]
sni-curl domain='api.localhost':
    curl -k -H "Host: {{domain}}" -v https://localhost:8443/

# =============================================================================
# CI / Quality
# =============================================================================

[group('ci')]
ci: build test

[group('ci')]
check: build

# =============================================================================
# Setup
# =============================================================================

[group('setup')]
setup:
    @echo "First-time setup: building deps + generating test certs..."
    stack build --only-dependencies
    bash examples/generate-test-certs.sh
    @echo "Setup complete - try 'just backends' then 'just run'"

# =============================================================================
# Utilities
# =============================================================================

[group('util')]
info:
    @echo "Project:  {{project}}"
    @echo "Version:  {{version}}"
    @echo "OS:       {{os()}} ({{arch()}})"
    @stack --version 2>/dev/null || true
    @ghc --version   2>/dev/null || true

[group('util')]
clean:
    stack clean
    -rm -f {{log_file}} {{backend_log}} nohup.out
    -rm -f /tmp/backend-8000.log /tmp/backend-8001.log /tmp/backend-8002.log
    @echo "Build artifacts and logs cleaned"

[group('util')]
[confirm("Remove .stack-work, dist-newstyle, certs, and all logs?")]
nuke:
    -stack purge
    -rm -rf .stack-work dist-newstyle
    -rm -rf examples/certs
    -rm -f {{log_file}} {{backend_log}} nohup.out
    -rm -f /tmp/backend-*.log
    @echo "Nuke complete"
