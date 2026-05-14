#!/usr/bin/env bash
# ©AngelaMos | 2026
# install.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

PROJECT="fwrule"
INSTALL_DIR="${HOME}/.local/bin"

echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
  ┌─────────────────────────────────────────┐
  │  FWRULE Installer                       │
  │  Firewall Rule Engine for iptables/nft  │
  └─────────────────────────────────────────┘
BANNER
echo -e "${NC}"

check_v() {
    if command -v v &> /dev/null; then
        V_VERSION=$(v version 2>/dev/null || echo "unknown")
        success "V compiler found: ${V_VERSION}"
        return 0
    fi
    return 1
}

install_v() {
    info "V compiler not found. Installing from source..."

    if ! command -v git &> /dev/null; then
        fail "git is required to install V. Please install git first."
    fi

    if ! command -v make &> /dev/null; then
        fail "make is required to install V. Please install build tools first."
    fi

    V_DIR="${HOME}/.local/share/vlang"

    if [[ -d "${V_DIR}" ]]; then
        info "Updating existing V installation..."
        cd "${V_DIR}"
        git pull --quiet
    else
        info "Cloning V repository..."
        git clone --depth 1 https://github.com/vlang/v "${V_DIR}"
        cd "${V_DIR}"
    fi

    info "Building V compiler..."
    make --quiet

    mkdir -p "${INSTALL_DIR}"
    ln -sf "${V_DIR}/v" "${INSTALL_DIR}/v"
    success "V compiler installed to ${INSTALL_DIR}/v"

    if ! echo "$PATH" | grep -q "${INSTALL_DIR}"; then
        warn "${INSTALL_DIR} is not in your PATH"

        SHELL_NAME=$(basename "${SHELL:-bash}")
        case "${SHELL_NAME}" in
            zsh)  RC_FILE="${HOME}/.zshrc" ;;
            fish) RC_FILE="${HOME}/.config/fish/config.fish" ;;
            *)    RC_FILE="${HOME}/.bashrc" ;;
        esac

        if [[ "${SHELL_NAME}" == "fish" ]]; then
            PATH_LINE="fish_add_path ${INSTALL_DIR}"
        else
            PATH_LINE="export PATH=\"${INSTALL_DIR}:\$PATH\""
        fi

        if [[ -f "${RC_FILE}" ]] && grep -q "${INSTALL_DIR}" "${RC_FILE}" 2>/dev/null; then
            info "PATH entry already in ${RC_FILE}"
        else
            echo "${PATH_LINE}" >> "${RC_FILE}"
            success "Added ${INSTALL_DIR} to PATH in ${RC_FILE}"
            warn "Run 'source ${RC_FILE}' or restart your shell"
        fi

        export PATH="${INSTALL_DIR}:${PATH}"
    fi
}

build_project() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "${SCRIPT_DIR}"

    info "Building ${PROJECT}..."
    mkdir -p bin/

    v -prod -o "bin/${PROJECT}" src/
    success "Built bin/${PROJECT}"

    BINARY_SIZE=$(ls -lh "bin/${PROJECT}" | awk '{print $5}')
    info "Binary size: ${BINARY_SIZE}"
}

install_binary() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    mkdir -p "${INSTALL_DIR}"
    cp "${SCRIPT_DIR}/bin/${PROJECT}" "${INSTALL_DIR}/${PROJECT}"
    chmod +x "${INSTALL_DIR}/${PROJECT}"
    success "Installed ${PROJECT} to ${INSTALL_DIR}/${PROJECT}"
}

verify_install() {
    if command -v "${PROJECT}" &> /dev/null; then
        VERSION=$("${PROJECT}" version 2>/dev/null || echo "unknown")
        success "Verification passed: ${VERSION}"
    else
        warn "Binary installed but not found in PATH"
        info "Run: ${INSTALL_DIR}/${PROJECT} version"
    fi
}

if ! check_v; then
    install_v
fi

build_project
install_binary
verify_install

echo ""
echo -e "${GREEN}${BOLD}Installation complete!${NC}"
echo ""
echo -e "${BOLD}Usage:${NC}"
echo "  ${PROJECT} load rules.txt"
echo "  ${PROJECT} analyze /etc/iptables.rules"
echo "  ${PROJECT} harden -s ssh,http,https -f nftables"
echo "  ${PROJECT} export rules.txt -f nftables"
echo "  ${PROJECT} diff old.rules new.rules"
echo ""
echo -e "${BOLD}Run tests:${NC}"
echo "  just test"
echo ""
