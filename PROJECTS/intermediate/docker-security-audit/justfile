# =============================================================================
# AngelaMos | 2026
# Justfile - Docker Security Audit (docksec)
# =============================================================================

set dotenv-load
set export
set shell := ["bash", "-uc"]
set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

project := file_name(justfile_directory())
version := `git describe --tags --always 2>/dev/null || echo "dev"`
commit := `git rev-parse --short HEAD 2>/dev/null || echo "none"`
build_date := `date -u +"%Y-%m-%dT%H:%M:%SZ"`
module := "github.com/CarterPerez-dev/docksec"
binary := "docksec"

ldflags := "-s -w -X main.version=" + version + " -X main.commit=" + commit + " -X main.buildDate=" + build_date

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
    go build -trimpath -ldflags "{{ldflags}}" -o bin/{{binary}} ./cmd/docksec

[group('build')]
build-all: build-linux build-darwin build-windows

[group('build')]
build-linux:
    GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "{{ldflags}}" -o bin/{{binary}}-linux-amd64 ./cmd/docksec
    GOOS=linux GOARCH=arm64 go build -trimpath -ldflags "{{ldflags}}" -o bin/{{binary}}-linux-arm64 ./cmd/docksec

[group('build')]
build-darwin:
    GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags "{{ldflags}}" -o bin/{{binary}}-darwin-amd64 ./cmd/docksec
    GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "{{ldflags}}" -o bin/{{binary}}-darwin-arm64 ./cmd/docksec

[group('build')]
build-windows:
    GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "{{ldflags}}" -o bin/{{binary}}-windows-amd64.exe ./cmd/docksec

[group('build')]
install:
    go install -trimpath -ldflags "{{ldflags}}" ./cmd/docksec

# =============================================================================
# Linting and Formatting
# =============================================================================

[group('lint')]
format:
    @which golines > /dev/null || (echo "Run 'just tools' first" && exit 1)
    golines . -w --max-len=80 --reformat-tags --shorten-comments --formatter=gofumpt

[group('lint')]
imports:
    @which gci > /dev/null || (echo "Run 'just tools' first" && exit 1)
    gci write . --skip-generated -s standard -s default -s "prefix({{module}})"

[group('lint')]
golangci-lint *ARGS:
    @which golangci-lint > /dev/null || (echo "Run 'just tools' first" && exit 1)
    golangci-lint run ./... {{ARGS}}

[group('lint')]
lint: format imports golangci-lint

# =============================================================================
# Go Toolchain
# =============================================================================

[group('go')]
fmt:
    go fmt ./...

[group('go')]
vet:
    go vet ./...

[group('go')]
tidy:
    go mod tidy

# =============================================================================
# Testing
# =============================================================================

[group('test')]
test *ARGS:
    go test -v -race -cover ./... {{ARGS}}

[group('test')]
test-short:
    go test -v -short ./...

[group('test')]
test-cov:
    go test -v -race -coverprofile=coverage.out ./...
    go tool cover -html=coverage.out -o coverage.html

# =============================================================================
# CI / Quality
# =============================================================================

[group('ci')]
ci: lint test

[group('ci')]
check: format imports golangci-lint

[group('ci')]
verify: fmt vet golangci-lint test

# =============================================================================
# Docker
# =============================================================================

[group('docker')]
docker-build:
    docker build -t {{binary}}:{{version}} -t {{binary}}:latest .

[group('docker')]
docker-run:
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock {{binary}}:latest scan

# =============================================================================
# Run
# =============================================================================

[group('run')]
run *ARGS:
    go run ./cmd/docksec {{ARGS}}

[group('run')]
run-scan:
    go run ./cmd/docksec scan

# =============================================================================
# Setup
# =============================================================================

[group('setup')]
tools:
    @echo "Installing formatting and linting tools..."
    go install github.com/segmentio/golines@latest
    go install mvdan.cc/gofumpt@latest
    go install github.com/daixiang0/gci@latest
    curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh | sh -s -- -b $(go env GOPATH)/bin v2.7.2
    @echo "Tools installed successfully"

# =============================================================================
# Utilities
# =============================================================================

[group('util')]
info:
    @echo "Project: {{project}}"
    @echo "Version: {{version}}"
    @echo "Commit: {{commit}}"
    @echo "OS: {{os()}} ({{arch()}})"

[group('util')]
clean:
    -rm -rf bin/
    go clean -cache -testcache
    -rm -f coverage.out coverage.html
    @echo "Build artifacts and caches cleaned"

[group('util')]
[confirm("Remove all build artifacts and caches?")]
nuke:
    @echo "Nuking everything..."
    -rm -rf bin/
    go clean -cache -testcache
    -rm -f coverage.out coverage.html
    @echo "Nuke complete!"
