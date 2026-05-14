#!/usr/bin/env bash
# ©AngelaMos | 2026
# install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
red() { printf "\033[31m%s\033[0m\n" "$*"; }

bold "Credential Rotation Enforcer - install.sh"

# 1) Crystal
if ! command -v crystal >/dev/null 2>&1; then
  yellow "Crystal not found. Install instructions: https://crystal-lang.org/install/"
  yellow "Or, on Linux:"
  yellow "  curl -fsSL https://crystal-lang.org/install.sh | sudo bash"
  yellow "Or, on macOS:"
  yellow "  brew install crystal"
  exit 1
fi
crystal_version=$(crystal --version | head -1 | awk '{print $2}')
green "Crystal $crystal_version found"

# 2) System deps (libpcre2 for regex, libssl for crypto)
case "$(uname -s)" in
  Linux)
    if ! ldconfig -p 2>/dev/null | grep -q libpcre2-8; then
      yellow "libpcre2 not detected. On Debian/Ubuntu: sudo apt-get install -y libpcre2-dev"
      yellow "On Alpine: apk add pcre2-dev"
    fi
    ;;
  Darwin)
    : # macOS bundles what's needed
    ;;
esac

cd "$PROJECT_ROOT"

# 3) Shards
bold "Resolving shard dependencies..."
shards install
green "shards installed"

# 4) Build
bold "Building cre (release mode)..."
shards build cre --release
green "cre binary built at bin/cre ($(stat -c %s bin/cre 2>/dev/null || stat -f %z bin/cre) bytes)"

# 5) Optional install to PATH
if [ "${INSTALL_TO_PATH:-0}" = "1" ]; then
  bold "Installing to ${INSTALL_PREFIX}/bin/cre"
  if [ -w "${INSTALL_PREFIX}/bin" ]; then
    cp bin/cre "${INSTALL_PREFIX}/bin/cre"
  else
    sudo cp bin/cre "${INSTALL_PREFIX}/bin/cre"
  fi
  green "Installed: $(which cre)"
fi

bold ""
bold "Try the zero-deps demo:"
echo "  ./bin/cre demo"
bold ""
bold "Or start the daemon:"
echo "  ./bin/cre run --db=sqlite:cre.db"
bold ""
bold "See learn/00-OVERVIEW.md for the full walkthrough."
