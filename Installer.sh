#!/usr/bin/env bash
#
# RavenEye Installer
#
# Installs external tools RavenEye.sh depends on:
#
#   Base:
#     curl, wget, jq, git, unzip, build tools, libpcap, Python
#
#   Go:
#     subfinder, httpx, dnsx, naabu, katana
#     assetfinder, anew, subfaster
#
#   Other:
#     findomain
#     waymore
#     paramspider
#
# Supported platforms:
#   - Debian / Ubuntu / Kali / Mint
#   - Arch / Manjaro / EndeavourOS / BlackArch
#   - Fedora
#   - RHEL / Rocky / AlmaLinux / CentOS
#   - openSUSE
#   - Alpine
#   - macOS (Intel + Apple Silicon)
#
# Requirements:
#   - Run as normal user with sudo available, OR as root
#   - macOS requires Homebrew for automatic package installation
#
# Usage:
#   chmod +x Installer.sh
#   ./Installer.sh
#

set -euo pipefail

RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'

ok()   { printf '%b\n' "${GREEN}[+]${RESET} $1"; }
info() { printf '%b\n' "${CYAN}[*]${RESET} $1"; }
warn() { printf '%b\n' "${YELLOW}[!]${RESET} $1"; }
fail() { printf '%b\n' "${RED}[-]${RESET} $1"; }

# ──────────────────────────────────────────────────────────────
# GLOBALS
# ──────────────────────────────────────────────────────────────

MIN_GO_MAJOR=1
MIN_GO_MINOR=24

GOBIN_DIR="${HOME}/go/bin"
PYTHON_VENV="${HOME}/.raveneye-venv"

OS=""
DISTRO=""
PKG_MANAGER=""

# ──────────────────────────────────────────────────────────────
# SUDO
# ──────────────────────────────────────────────────────────────

if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
else
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        fail "This installer needs root or sudo."
        fail "Install sudo or re-run this script as root."
        exit 1
    fi
fi

# ──────────────────────────────────────────────────────────────
# OS DETECTION
#
# FIX: detect_os was failing because:
#   1. sourcing /etc/os-release under set -euo pipefail could abort
#      if any variable assignment in that file triggered an error.
#   2. The DISTRO re-assignment inside the ID_LIKE case used the
#      wrong ${DISTRO:-...} form — it would never overwrite a
#      non-empty DISTRO, so the ID_LIKE normalization was a no-op.
#   3. On systems where ID_LIKE is unset the ${ID_LIKE:-} expansion
#      inside a case pattern still caused issues with some shells.
# ──────────────────────────────────────────────────────────────

detect_os() {
    case "$(uname -s)" in
        Darwin)  OS="macos"   ;;
        Linux)   OS="linux"   ;;
        FreeBSD) OS="freebsd" ;;
        OpenBSD) OS="openbsd" ;;
        NetBSD)  OS="netbsd"  ;;
        *)       OS="unknown" ;;
    esac

    if [[ "$OS" == "linux" ]] && [[ -r /etc/os-release ]]; then
        # Read each key we need explicitly instead of sourcing the whole
        # file — avoids set -e aborting on any exotic assignment in that
        # file, and keeps our own namespace clean.
        local os_id=""
        local os_id_like=""

        while IFS='=' read -r key value; do
            # Strip surrounding quotes from the value
            value="${value%\"}"
            value="${value#\"}"
            value="${value%\'}"
            value="${value#\'}"

            case "$key" in
                ID)      os_id="$value"      ;;
                ID_LIKE) os_id_like="$value" ;;
            esac
        done < /etc/os-release

        DISTRO="${os_id:-unknown}"

        # Normalise family so callers can match broad families.
        # We overwrite DISTRO only when the raw ID doesn't already
        # reflect the family (e.g. kali → keep kali, mint → keep mint,
        # but raspbian → debian because ID_LIKE=debian).
        if [[ -n "$os_id_like" ]]; then
            case "$os_id_like" in
                *debian*)
                    # Keep the specific distro name; just record the family
                    # via a separate variable if you ever need it.
                    ;;
                *arch*)
                    ;;
                *rhel* | *fedora*)
                    ;;
            esac
        fi
    fi
}

detect_package_manager() {
    if [[ "$OS" == "macos" ]]; then
        if command -v brew >/dev/null 2>&1; then
            PKG_MANAGER="brew"
        else
            PKG_MANAGER=""
        fi
        return
    fi

    if [[ "$OS" != "linux" ]]; then
        PKG_MANAGER=""
        return
    fi

    if   command -v apt-get >/dev/null 2>&1; then PKG_MANAGER="apt"
    elif command -v pacman  >/dev/null 2>&1; then PKG_MANAGER="pacman"
    elif command -v dnf     >/dev/null 2>&1; then PKG_MANAGER="dnf"
    elif command -v yum     >/dev/null 2>&1; then PKG_MANAGER="yum"
    elif command -v zypper  >/dev/null 2>&1; then PKG_MANAGER="zypper"
    elif command -v apk     >/dev/null 2>&1; then PKG_MANAGER="apk"
    else PKG_MANAGER=""
    fi
}

detect_os
detect_package_manager

# ──────────────────────────────────────────────────────────────
# EARLY PLATFORM CHECKS
# (moved before the display block so fail() is always defined)
# ──────────────────────────────────────────────────────────────

if [[ "$OS" == "macos" ]] && ! command -v brew >/dev/null 2>&1; then
    fail "Homebrew is required for automatic macOS dependency installation."
    fail "Install Homebrew from: https://brew.sh/"
    fail "Then re-run this installer."
    exit 1
fi

if [[ "$OS" == "unknown" ]]; then
    fail "Unsupported operating system: $(uname -s)"
    exit 1
fi

if [[ "$OS" != "macos" && "$OS" != "linux" ]]; then
    fail "This installer currently supports Linux and macOS."
    fail "Detected: $OS"
    exit 1
fi

if [[ -z "$PKG_MANAGER" ]]; then
    fail "No supported package manager detected."
    exit 1
fi

# ──────────────────────────────────────────────────────────────
# DISPLAY PLATFORM
# ──────────────────────────────────────────────────────────────

printf '\n%b\n' "${CYAN}${BOLD}=== RavenEye Installer ===${RESET}"
printf '\n'

info "Detected OS:      ${OS}"
[[ -n "$DISTRO"      ]] && info "Detected distro:  ${DISTRO}"
[[ -n "$PKG_MANAGER" ]] && info "Package manager:  ${PKG_MANAGER}"

# ──────────────────────────────────────────────────────────────
# PROFILE / PATH HELPERS
# ──────────────────────────────────────────────────────────────

get_shell_profile() {
    local shell_name
    shell_name="$(basename "${SHELL:-bash}")"

    case "$shell_name" in
        zsh)  echo "${HOME}/.zshrc" ;;
        bash)
            if [[ "$OS" == "macos" ]]; then
                echo "${HOME}/.bash_profile"
            else
                echo "${HOME}/.bashrc"
            fi
            ;;
        fish) echo "${HOME}/.config/fish/config.fish" ;;
        *)    echo "${HOME}/.profile" ;;
    esac
}

PROFILE="$(get_shell_profile)"

add_path_line() {
    local path_to_add="$1"
    local line="export PATH=\"\$PATH:${path_to_add}\""

    [[ ! -f "$PROFILE" ]] && touch "$PROFILE"

    if ! grep -Fq "$path_to_add" "$PROFILE" 2>/dev/null; then
        printf '\n# RavenEye\n%s\n' "$line" >> "$PROFILE"
    fi

    export PATH="$PATH:$path_to_add"
}

# ──────────────────────────────────────────────────────────────
# VERSION COMPARISON
# (avoids GNU-only sort -V; works on macOS/BSD)
# ──────────────────────────────────────────────────────────────

go_version_ok() {
    local version="$1"
    local major minor

    major="${version%%.*}"
    minor="${version#*.}"
    minor="${minor%%.*}"

    [[ "$major" =~ ^[0-9]+$ ]] || return 1
    [[ "$minor" =~ ^[0-9]+$ ]] || return 1

    if   (( major >  MIN_GO_MAJOR )); then return 0
    elif (( major == MIN_GO_MAJOR && minor >= MIN_GO_MINOR )); then return 0
    else return 1
    fi
}

# ──────────────────────────────────────────────────────────────
# PACKAGE INSTALLATION
# ──────────────────────────────────────────────────────────────

install_packages() {
    local packages=("$@")

    case "$PKG_MANAGER" in
        apt)
            info "Installing packages with apt..."
            $SUDO apt-get update -qq
            $SUDO apt-get install -y -qq "${packages[@]}"
            ;;
        pacman)
            info "Installing packages with pacman..."
            $SUDO pacman -Sy --needed --noconfirm "${packages[@]}"
            ;;
        dnf)
            info "Installing packages with dnf..."
            $SUDO dnf install -y "${packages[@]}"
            ;;
        yum)
            info "Installing packages with yum..."
            $SUDO yum install -y "${packages[@]}"
            ;;
        zypper)
            info "Installing packages with zypper..."
            $SUDO zypper --non-interactive install "${packages[@]}"
            ;;
        apk)
            info "Installing packages with apk..."
            $SUDO apk add --no-cache "${packages[@]}"
            ;;
        brew)
            info "Installing packages with Homebrew..."
            brew update >/dev/null 2>&1 || true
            brew install "${packages[@]}"
            ;;
        *)
            fail "No supported package manager detected."
            fail "Supported: apt, pacman, dnf, yum, zypper, apk, brew."
            exit 1
            ;;
    esac
}

# ──────────────────────────────────────────────────────────────
# BASE PACKAGES
# ──────────────────────────────────────────────────────────────

install_base_packages() {
    info "Installing base dependencies..."

    case "$PKG_MANAGER" in
        apt)
            install_packages \
                curl wget git unzip jq \
                build-essential libpcap-dev ca-certificates \
                python3 python3-pip python3-venv
            ;;
        pacman)
            install_packages \
                curl wget git unzip jq \
                base-devel libpcap ca-certificates \
                python python-pip python-virtualenv
            ;;
        dnf | yum)
            install_packages \
                curl wget git unzip jq \
                gcc gcc-c++ make libpcap-devel ca-certificates \
                python3 python3-pip
            ;;
        zypper)
            install_packages \
                curl wget git unzip jq \
                gcc gcc-c++ make libpcap-devel ca-certificates \
                python3 python3-pip
            ;;
        apk)
            install_packages \
                curl wget git unzip jq \
                build-base libpcap-dev ca-certificates \
                python3 py3-pip python3-dev
            ;;
        brew)
            install_packages \
                curl wget git unzip jq libpcap python
            ;;
        *)
            fail "Cannot install base packages on this platform."
            exit 1
            ;;
    esac

    ok "Base packages installed."
}

install_base_packages

# ──────────────────────────────────────────────────────────────
# GO TOOLCHAIN
# ──────────────────────────────────────────────────────────────

install_go_from_official() {
    local arch goarch os_name
    local go_tag go_tarball go_url tmp_go

    arch="$(uname -m)"

    case "$arch" in
        x86_64 | amd64)          goarch="amd64"   ;;
        aarch64 | arm64)         goarch="arm64"   ;;
        armv7l)                  goarch="armv6l"  ;;
        *)
            fail "Unsupported CPU architecture for Go installation: $arch"
            exit 1
            ;;
    esac

    case "$OS" in
        linux) os_name="linux"  ;;
        macos) os_name="darwin" ;;
        *)
            fail "Unsupported OS for Go installation: $OS"
            exit 1
            ;;
    esac

    info "Fetching current Go release from go.dev..."

    go_tag="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"

    if [[ -z "$go_tag" ]]; then
        fail "Could not determine the latest Go release."
        fail "Install Go >= ${MIN_GO_MAJOR}.${MIN_GO_MINOR} manually."
        exit 1
    fi

    go_tarball="${go_tag}.${os_name}-${goarch}.tar.gz"
    go_url="https://go.dev/dl/${go_tarball}"

    tmp_go="$(mktemp -d)"
    trap 'rm -rf "$tmp_go"' RETURN

    info "Downloading ${go_tarball}..."
    curl -fsSL "$go_url" -o "$tmp_go/go.tar.gz"

    $SUDO rm -rf /usr/local/go
    $SUDO tar -C /usr/local -xzf "$tmp_go/go.tar.gz"

    add_path_line "/usr/local/go/bin"
    ok "Installed $(/usr/local/go/bin/go version)"
}

install_go() {
    local current_version=""

    if command -v go >/dev/null 2>&1; then
        current_version="$(
            go version |
            grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' |
            sed 's/^go//' |
            head -n1
        )"

        if [[ -n "$current_version" ]] && go_version_ok "$current_version"; then
            ok "Go ${current_version} already installed."
            return
        fi

        warn "Installed Go ${current_version:-unknown} is older than ${MIN_GO_MAJOR}.${MIN_GO_MINOR}."
    fi

    # Try the OS package manager first.
    case "$PKG_MANAGER" in
        brew)   brew install go >/dev/null 2>&1 || brew upgrade go >/dev/null 2>&1 || true ;;
        apt)    $SUDO apt-get install -y -qq golang-go >/dev/null 2>&1 || true ;;
        pacman) $SUDO pacman -S --needed --noconfirm go >/dev/null 2>&1 || true ;;
        dnf)    $SUDO dnf install -y golang >/dev/null 2>&1 || true ;;
        yum)    $SUDO yum install -y golang >/dev/null 2>&1 || true ;;
        zypper) $SUDO zypper --non-interactive install go >/dev/null 2>&1 || true ;;
        apk)    $SUDO apk add --no-cache go >/dev/null 2>&1 || true ;;
    esac

    hash -r 2>/dev/null || true

    if command -v go >/dev/null 2>&1; then
        current_version="$(
            go version |
            grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' |
            sed 's/^go//' |
            head -n1
        )"

        if [[ -n "$current_version" ]] && go_version_ok "$current_version"; then
            ok "Go ${current_version} installed."
            return
        fi
    fi

    # Package manager Go was too old — fall back to official archive.
    install_go_from_official
}

install_go

# ──────────────────────────────────────────────────────────────
# GOPATH / GOBIN
# ──────────────────────────────────────────────────────────────

mkdir -p "$GOBIN_DIR"
add_path_line "$GOBIN_DIR"
export PATH="$PATH:${GOBIN_DIR}"
hash -r 2>/dev/null || true

if ! command -v go >/dev/null 2>&1; then
    fail "Go is not available after installation."
    exit 1
fi

# ──────────────────────────────────────────────────────────────
# GO TOOLS
# ──────────────────────────────────────────────────────────────

info "Installing Go-based reconnaissance tools..."

# bin_exists checks GOBIN_DIR first (binaries installed by go install),
# then falls back to the full PATH.  This covers tools that were installed
# by a previous run even if the shell session is new.
bin_exists() {
    local bin="$1"
    [[ -x "${GOBIN_DIR}/${bin}" ]] || command -v "$bin" >/dev/null 2>&1
}

go_install() {
    local pkg="$1"
    local bin_name="$2"
    local log_file="/tmp/raveneye-goinstall-${bin_name}.log"

    printf '  %b%-14s%b' "$DIM" "$bin_name" "$RESET"

    if bin_exists "$bin_name"; then
        printf ' %bskip (already installed)%b\n' "$CYAN" "$RESET"
        return
    fi

    if go install "$pkg" >"$log_file" 2>&1; then
        printf ' %b✓%b\n' "$GREEN" "$RESET"
    else
        printf ' %b✗%b\n' "$RED" "$RESET"
        warn "Installation failed for ${bin_name}. See ${log_file}"
    fi
}

go_install "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest" "subfinder"
go_install "github.com/projectdiscovery/httpx/cmd/httpx@latest"            "httpx"
go_install "github.com/projectdiscovery/dnsx/cmd/dnsx@latest"              "dnsx"
go_install "github.com/projectdiscovery/naabu/v2/cmd/naabu@latest"         "naabu"
go_install "github.com/projectdiscovery/katana/cmd/katana@latest"          "katana"
go_install "github.com/tomnomnom/assetfinder@latest"                       "assetfinder"
go_install "github.com/tomnomnom/anew@latest"                              "anew"
go_install "github.com/melvinsh/subfaster/v2/cmd/subfaster@latest"         "subfaster"

ok "Go-based tools processed."

# ──────────────────────────────────────────────────────────────
# FINDOMAIN
# ──────────────────────────────────────────────────────────────

install_findomain() {
    if bin_exists findomain; then
        ok "findomain already installed — skipping."
        return
    fi

    case "$PKG_MANAGER" in
        brew)
            info "Installing findomain with Homebrew..."
            if brew list findomain >/dev/null 2>&1; then
                ok "findomain already installed."
                return
            fi
            if brew install findomain >/dev/null 2>&1; then
                ok "findomain installed."
                return
            fi
            ;;
        pacman)
            info "Installing findomain with pacman..."
            if $SUDO pacman -S --needed --noconfirm findomain >/dev/null 2>&1; then
                ok "findomain installed."
                return
            fi
            ;;
    esac

    local arch asset tmp_fd url
    arch="$(uname -m)"

    case "${OS}:${arch}" in
        linux:x86_64 | linux:amd64)          asset="findomain-linux.zip"   ;;
        linux:aarch64 | linux:arm64)         asset="findomain-aarch64.zip" ;;
        linux:armv7l)                        asset="findomain-armv7.zip"   ;;
        macos:x86_64 | macos:amd64)          asset="findomain-osx.zip"     ;;
        macos:arm64 | macos:aarch64)         asset="findomain-osx.zip"     ;;
        *)
            warn "No known prebuilt findomain binary for ${OS}/${arch}. Skipping."
            return
            ;;
    esac

    tmp_fd="$(mktemp -d)"
    url="https://github.com/Findomain/Findomain/releases/latest/download/${asset}"

    info "Downloading findomain..."

    if curl -fsSL "$url" -o "$tmp_fd/findomain.zip"; then
        if unzip -q -o "$tmp_fd/findomain.zip" -d "$tmp_fd"; then
            local binary
            binary="$(
                find "$tmp_fd" -type f \
                    \( -name 'findomain' -o -name 'findomain.dms' \) \
                    -print -quit
            )"

            if [[ -n "$binary" ]]; then
                chmod +x "$binary"
                $SUDO install -m 0755 "$binary" /usr/local/bin/findomain
                ok "findomain installed to /usr/local/bin/findomain."
            else
                warn "findomain archive did not contain the expected binary."
            fi
        else
            warn "Could not extract findomain archive."
        fi
    else
        warn "Could not download findomain."
    fi

    rm -rf "$tmp_fd"
}

install_findomain

# ──────────────────────────────────────────────────────────────
# PYTHON ENVIRONMENT
# (uses a dedicated venv — no --break-system-packages needed)
# ──────────────────────────────────────────────────────────────

install_python_tools() {
    local python_bin

    if   command -v python3 >/dev/null 2>&1; then python_bin="python3"
    elif command -v python  >/dev/null 2>&1; then python_bin="python"
    else
        fail "Python 3 is required but was not found."
        exit 1
    fi

    info "Creating RavenEye Python virtual environment..."

    [[ ! -d "$PYTHON_VENV" ]] && "$python_bin" -m venv "$PYTHON_VENV"

    "$PYTHON_VENV/bin/python" -m pip install \
        --upgrade pip setuptools wheel >/dev/null

    if [[ -x "${PYTHON_VENV}/bin/waymore" ]] || command -v waymore >/dev/null 2>&1; then
        ok "waymore already installed — skipping."
    else
        info "Installing waymore..."
        "$PYTHON_VENV/bin/python" -m pip install --upgrade waymore >/dev/null
    fi

    if [[ -x "${PYTHON_VENV}/bin/paramspider" ]] || command -v paramspider >/dev/null 2>&1; then
        ok "paramspider already installed — skipping."
    else
        info "Installing ParamSpider from GitHub..."
        "$PYTHON_VENV/bin/python" -m pip install --upgrade \
            "git+https://github.com/devanshbatham/ParamSpider.git" >/dev/null
    fi

    add_path_line "${PYTHON_VENV}/bin"
    export PATH="${PYTHON_VENV}/bin:${PATH}"

    ok "Python tools processed."
}

install_python_tools

# ──────────────────────────────────────────────────────────────
# FINAL PATH REFRESH
# ──────────────────────────────────────────────────────────────

export PATH="${GOBIN_DIR}:${PYTHON_VENV}/bin:${PATH}"
hash -r 2>/dev/null || true

# ──────────────────────────────────────────────────────────────
# VERIFY
# ──────────────────────────────────────────────────────────────

printf '\n%b\n' "${CYAN}${BOLD}=== Verifying installation ===${RESET}"

TOOLS=(
    curl jq go
    subfinder httpx dnsx naabu katana
    assetfinder anew subfaster
    findomain waymore paramspider
)

FAILED=0

for tool in "${TOOLS[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf '  %b✓%b %-14s %s\n' \
            "$GREEN" "$RESET" "$tool" "$(command -v "$tool")"
    else
        printf '  %b✗%b %-14s %s\n' \
            "$RED" "$RESET" "$tool" "NOT FOUND"
        FAILED=1
    fi
done

printf '\n'

# ──────────────────────────────────────────────────────────────
# FINISH
# ──────────────────────────────────────────────────────────────

printf '\n'

if [[ "$FAILED" -ne 0 ]]; then
    warn "Some tools are missing. Open a new shell or run:"
    printf '    source "%s"\n\n' "$PROFILE"
    warn "Then run the installer again."
    exit 1
fi

warn "Open a new shell, or run:"
printf '    source "%s"\n\n' "$PROFILE"
ok "RavenEye installation completed successfully."
ok "Run:"
printf '    ./RavenEye.sh -t example.com -small\n\n'
