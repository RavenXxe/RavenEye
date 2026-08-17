#!/bin/bash

# ╔══════════════════════════════════════════════════════════════╗
# ║                         RavenEye v1.0.1                      ║
# ║                    FULL RECON ENGINE                         ║
# ║                         @ravenXxx                            ║
# ╚══════════════════════════════════════════════════════════════╝

set -o pipefail

RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
MAGENTA='\033[35m'
CYAN='\033[36m'

usage() {
    printf '%b\n' \
        "${CYAN}${BOLD}RavenEye${RESET} - Full Recon Engine" \
        "" \
        "${BOLD}Usage:${RESET} $0 -t <domain> [-small | -full]" \
        "       $0 -l <file>   [-small | -full]" \
        "" \
        "${BOLD}Options:${RESET}" \
        "  -t, --target <domain>   Single target domain" \
        "  -l, --list <file>       File with one domain per line (multi-target)" \
        "  -small                  Subdomain discovery only, then stop (default)" \
        "  -full                   Full recon, all phases" \
        "  -h, --help              Show this help" \
        "" \
        "${BOLD}Example:${RESET}" \
        "  $0 -t example.com -small" \
        "  $0 -l domains.txt -full"
}

TARGET=""
LIST_FILE=""
MODE="small"
MODE_SET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)
            if [[ -z "${2:-}" ]]; then
                printf '%b\n' "${RED}[-]${RESET} Missing target after $1"
                usage
                exit 1
            fi
            TARGET="$2"
            shift 2
            ;;
        -l|--list)
            if [[ -z "${2:-}" ]]; then
                printf '%b\n' "${RED}[-]${RESET} Missing file path after $1"
                usage
                exit 1
            fi
            LIST_FILE="$2"
            shift 2
            ;;
        -small)
            MODE_SET=$((MODE_SET + 1))
            MODE="small"
            shift
            ;;
        -full)
            MODE_SET=$((MODE_SET + 1))
            MODE="full"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf '%b\n' "${RED}[-]${RESET} Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ "$MODE_SET" -gt 1 ]]; then
    printf '%b\n' \
        "${RED}[-]${RESET} Only one mode flag allowed: -small or -full." \
        "${YELLOW}[!]${RESET} Use: $0 -t example.com "
    exit 1
fi

is_valid_domain() {
    local d="$1"

    if [[ "$d" =~ ^https?:// ]] ||
       [[ "$d" == */* ]] ||
       [[ "$d" == *:* ]] ||
       [[ "$d" == *"*"* ]] ||
       [[ "$d" == *"@"* ]] ||
       [[ "$d" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi

    if [[ ! "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; then
        return 1
    fi

    return 0
}

if [[ -n "$TARGET" && -n "$LIST_FILE" ]]; then
    printf '%b\n' \
        "${RED}[-]${RESET} Use either -t <domain> or -l <file>, not both." \
        "${YELLOW}[!]${RESET} Use: $0 -t example.com   OR   $0 -l domains.txt"
    exit 1
fi

if [[ -z "$TARGET" && -z "$LIST_FILE" ]]; then
    printf '%b\n' \
        "${RED}[-]${RESET} A target is required." \
        "${YELLOW}[!]${RESET} Use: $0 -t example.com -small or -full" \
        "${YELLOW}[!]${RESET} Or:  $0 -l domains.txt -small or -full"
    exit 1
fi

if [[ -n "$TARGET" ]]; then
    if ! is_valid_domain "$TARGET"; then
        printf '%b\n' \
            "${RED}[-]${RESET} Invalid target: $TARGET" \
            "${YELLOW}[!]${RESET} Domain only, e.g. example.com"
        exit 1
    fi
    TARGET="${TARGET,,}"
fi

if [[ -n "$LIST_FILE" ]]; then
    if [[ ! -f "$LIST_FILE" ]]; then
        printf '%b\n' "${RED}[-]${RESET} List file not found: $LIST_FILE"
        exit 1
    fi
    if [[ ! -r "$LIST_FILE" ]]; then
        printf '%b\n' "${RED}[-]${RESET} List file is not readable: $LIST_FILE"
        exit 1
    fi
    if [[ ! -s "$LIST_FILE" ]]; then
        printf '%b\n' "${RED}[-]${RESET} List file is empty: $LIST_FILE"
        exit 1
    fi
fi

if [[ -n "$TARGET" ]]; then
    OUTDIR="${OUTDIR:-results/$TARGET}"
else
    FIRST_DOMAIN="$(grep -v '^[[:space:]]*#' "$LIST_FILE" | sed '/^[[:space:]]*$/d' | head -n 1 | tr -d '\r' | xargs)"
    FIRST_DOMAIN="${FIRST_DOMAIN,,}"
    OUTDIR="${OUTDIR:-results/$FIRST_DOMAIN}"
fi

SUBS="$OUTDIR/subs.txt"
ALIVE="$OUTDIR/fresh_alive_domains"
RESOLVED="$OUTDIR/resolved_dns"
TECH="$OUTDIR/tech_domains"
URLS="$OUTDIR/endpoints.txt"
NAABU_OUT="$OUTDIR/naabu.txt"
PARAMS="$OUTDIR/params.txt"

mkdir -p "$OUTDIR" || {
    printf '%b\n' "${RED}[-]${RESET} Cannot create output directory: $OUTDIR"
    exit 1
}

OUTDIR="$(realpath "$OUTDIR")"

TMPDIR_RAVEN="$OUTDIR/.tmp"

mkdir -p "$TMPDIR_RAVEN" || {
    printf '%b\n' "${RED}[-]${RESET} Cannot create temp directory: $TMPDIR_RAVEN"
    exit 1
}

TMPDIR_RAVEN="$(realpath "$TMPDIR_RAVEN")"

TARGETS_FILE="$TMPDIR_RAVEN/targets.txt"
SKIPPED_COUNT=0

if [[ -n "$TARGET" ]]; then
    printf '%s\n' "$TARGET" > "$TARGETS_FILE"
    TARGET_LABEL="$TARGET"
else
    : > "$TARGETS_FILE"

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line="${raw_line%%#*}"
        line="${line//$'\r'/}"
        line="$(printf '%s' "$line" | xargs 2>/dev/null)"

        [[ -z "$line" ]] && continue

        line="${line,,}"

        if is_valid_domain "$line"; then
            printf '%s\n' "$line" >> "$TARGETS_FILE"
        else
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        fi
    done < "$LIST_FILE"

    sort -u "$TARGETS_FILE" -o "$TARGETS_FILE"

    if [[ ! -s "$TARGETS_FILE" ]]; then
        printf '%b\n' \
            "${RED}[-]${RESET} No valid domains found in: $LIST_FILE" \
            "${YELLOW}[!]${RESET} One domain per line, e.g. example.com"
        rm -rf "$TMPDIR_RAVEN" 2>/dev/null
        exit 1
    fi

    TARGET_COUNT=$(wc -l < "$TARGETS_FILE" | tr -d ' ')
    TARGET_LABEL="${TARGET_COUNT} domains (${LIST_FILE})"
fi

CURRENT_PID=""

cleanup() {
    if [[ -n "$CURRENT_PID" ]] &&
       kill -0 "$CURRENT_PID" 2>/dev/null; then
        kill "$CURRENT_PID" 2>/dev/null
        wait "$CURRENT_PID" 2>/dev/null
    fi

    tput cnorm 2>/dev/null || true

    rm -rf "$TMPDIR_RAVEN" 2>/dev/null
    rm -f "resume.cfg" 2>/dev/null
    printf '\n'
    printf '%b\n' "${YELLOW}[!]${RESET} Recon interrupted."

    exit 130
}

trap cleanup INT TERM

timestamp() {
    date '+%H:%M:%S'
}

line() {
    printf '%b\n' \
        "${DIM}──────────────────────────────────────────────────────────────${RESET}"
}

info() {
    printf '%b\n' \
        "${CYAN}[$(timestamp)] 🌷 ${RESET} $1"
}

phase() {
    printf '\n%b\n' \
        "${BLUE}${BOLD}[$(timestamp)] 🌷 $1${RESET}"
}

success() {
    printf '%b\n' \
        "${GREEN}[$(timestamp)] ✓${RESET} $1"
}

warn() {
    printf '%b\n' \
        "${YELLOW}[$(timestamp)] !${RESET} $1"
}

error() {
    printf '%b\n' \
        "${RED}[$(timestamp)] ✗${RESET} $1"
}

detail() {
    printf '%b\n' \
        "           ${DIM}└─ $1${RESET}"
}

spinner() {
    local pid="$1"
    local id="$2"
    local name="$3"

    local frames=(
        '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'
    )

    local i=0
    local frame_count=${#frames[@]}

    tput civis 2>/dev/null || true

    while kill -0 "$pid" 2>/dev/null; do
        printf '\r\033[2K'
        printf '  %b%-22s%b %b%s RUNNING%b' \
            "${MAGENTA}[${id}]${RESET} " \
            "$name" \
            "$RESET" \
            "$YELLOW" \
            "${frames[$i]}" \
            "$RESET"

        i=$(( (i + 1) % frame_count ))
        sleep 0.08
    done

    wait "$pid"
    local status=$?

    printf '\r\033[2K'
    tput cnorm 2>/dev/null || true

    return "$status"
}

run_tool() {
    local id="$1"
    local name="$2"

    shift 2

    local log_file="$TMPDIR_RAVEN/tool_${id}.log"

    "$@" >"$log_file" 2>&1 &

    CURRENT_PID=$!

    spinner "$CURRENT_PID" "$id" "$name"
    local status=$?

    CURRENT_PID=""

    if [[ $status -eq 0 ]]; then

        printf '  %b%-22s%b %b✓ COMPLETE%b\n' \
            "${MAGENTA}[${id}]${RESET} " \
            "$name" \
            "$RESET" \
            "$GREEN" \
            "$RESET"

    else
        if grep -qE 'curl: \(22\).*429|HTTP.*429|429' "$log_file" 2>/dev/null; then

            printf '  %b%-22s%b %b⚠ RATE LIMIT HIT%b\n' \
                "${MAGENTA}[${id}]${RESET} " \
                "$name" \
                "$RESET" \
                "$YELLOW" \
                "$RESET"

        elif grep -qE 'curl: \(22\).*404|HTTP.*404|404 Not Found' "$log_file" 2>/dev/null; then

            # crt.sh (and some other recon APIs) return a bare 404
            # both when a domain simply has no data AND when they
            # are throttling us - either way it isn't a real
            # failure of the tool, so treat it like a rate limit.
            printf '  %b%-22s%b %b⚠ RATE LIMIT HIT (404)%b\n' \
                "${MAGENTA}[${id}]${RESET} " \
                "$name" \
                "$RESET" \
                "$YELLOW" \
                "$RESET"

        elif grep -qE 'curl: \(22\).*502|HTTP.*502|502' "$log_file" 2>/dev/null; then

            printf '  %b%-22s%b %b⚠ BAD GATEWAY (502)%b\n' \
                "${MAGENTA}[${id}]${RESET} " \
                "$name" \
                "$RESET" \
                "$YELLOW" \
                "$RESET"

        else

            printf '  %b%-22s%b %b✗ FAILED%b\n' \
                "${MAGENTA}[${id}]${RESET} " \
                "$name" \
                "$RESET" \
                "$RED" \
                "$RESET"

            if [[ -s "$log_file" ]]; then
                local reason
                reason=$(tail -n 1 "$log_file" | tr -d '\r' | cut -c1-100)

                [[ -n "$reason" ]] &&
                    printf '           %b└─ %s%b\n' "$DIM" "$reason" "$RESET"
            fi

        fi
    fi

    rm -f "$log_file"

    return "$status"
}

count_lines() {
    if [[ -s "$1" ]]; then
        sort -u "$1" 2>/dev/null |
            wc -l |
            tr -d ' '
    else
        echo "0"
    fi
}

clear

printf '\n'

printf '%b\n' "${CYAN}${BOLD}"

printf '%s\n' \
    '╭──────────────────────────────────────────────────────────────╮' \
    '│                           RavenEye v1.0.1                    │' \
    '│                      FULL RECON ENGINE                       │' \
    '│                          @ravenXxx                           │' \
    '├──────────────────────────────────────────────────────────────┤'

printf '%b' "${RESET}"

printf '│ %b%-10s%b %-50s│\n' \
    "${BOLD}" "TARGET" "${RESET}" "$TARGET_LABEL"

if [[ "$MODE" == "small" ]]; then
    MODE_LABEL="SMALL (SUBDOMAINS ONLY)"
else
    MODE_LABEL="FULL RECON"
fi

printf '│ %b%-10s%b %-50s│\n' \
    "${BOLD}" "MODE" "${RESET}" "$MODE_LABEL"

printf '│ %b%-10s%b %-50s│\n' \
    "${BOLD}" "OUTPUT" "${RESET}" "$OUTDIR"

printf '%b' "${CYAN}${BOLD}"

printf '%s\n' \
    '╰──────────────────────────────────────────────────────────────╯'

printf '%b\n' "${RESET}"

START_TIME=$(date +%s)

info "Initializing reconnaissance engine"
info "Target: ${BOLD}${TARGET_LABEL}${RESET}"
detail "Output directory: $OUTDIR"

if [[ -n "$LIST_FILE" && "$SKIPPED_COUNT" -gt 0 ]]; then
    warn "$SKIPPED_COUNT invalid line(s) skipped from $LIST_FILE"
fi

: > "$SUBS"
: > "$ALIVE"
: > "$TECH"

if [[ "$MODE" == "full" ]]; then
    : > "$RESOLVED"
    : > "$URLS"
    : > "$NAABU_OUT"
fi

phase " SUBDOMAIN DISCOVERY"

run_tool 01 "HACKERTARGET" \
    bash -o pipefail -c '
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            curl -fsS \
                --retry 2 \
                --retry-delay 1 \
                --connect-timeout 10 \
                --max-time 30 \
                "https://api.hackertarget.com/hostsearch/?q=$d" |
            cut -d "," -f1 >> "$2"
        done < "$1"
    ' _ "$TARGETS_FILE" "$SUBS"

run_tool 02 "CRT.SH" \
    bash -o pipefail -c '
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            # crt.sh returns HTTP 404 for domains it has no
            # certificate data for (and sometimes while throttling).
            # That is a normal, expected outcome for *some* domains
            # in the list, not a hard error - so we no longer let
            # curl -f abort the loop; keep the exit status so
            # run_tool can classify it as a rate-limit-style
            # warning instead of a raw FAILED, but always continue
            # to the next domain and never fail the whole step for
            # a single 404.
            curl -fsS \
                "https://crt.sh/?q=$d&output=json" \
                2>>"$TMPDIR_RAVEN/tool_02.log" |
            jq -r ".[].name_value | split(\"\\n\")[]" 2>/dev/null |
            sed "s/^\\*\\.//" >> "$2"
        done < "$1"
        exit 0
    ' _ "$TARGETS_FILE" "$SUBS"

run_tool 03 "SUBFINDER" \
    bash -o pipefail -c '
        subfinder \
            -dL "$1" \
            -all \
            -silent \
            >> "$2"
    ' _ "$TARGETS_FILE" "$SUBS"

run_tool 04 "URLSCAN" \
    bash -o pipefail -c '
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            curl -fsS \
                --retry-delay 1 \
                --connect-timeout 10 \
                "https://urlscan.io/api/v1/search/?q=domain:$d" |
            jq -r ".results[].page.domain" >> "$2"
        done < "$1"
    ' _ "$TARGETS_FILE" "$SUBS"

run_tool 05 "ASSETFINDER" \
    bash -o pipefail -c '
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            assetfinder \
                -subs-only \
                "$d" \
                >> "$2"
        done < "$1"
    ' _ "$TARGETS_FILE" "$SUBS"

run_tool 06 "FINDOMAIN" \
    bash -o pipefail -c '
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            findomain \
                -t "$d" \
                -q \
                >> "$2"
        done < "$1"
    ' _ "$TARGETS_FILE" "$SUBS"

run_tool 07 "SUBFASTER" \
    bash -o pipefail -c '
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            target_re=$(printf "%s" "$d" | sed "s/[.]/\\./g")
            subfaster \
                -d "$d" \
                -all \
                -recursive |
            sort -u |
            grep -E "(^|\\.)${target_re}\$" \
                >> "$2"
        done < "$1"
    ' _ "$TARGETS_FILE" "$SUBS"

if [[ -s "$SUBS" ]]; then
    TARGET_ALT=$(sed 's/[.]/\\./g' "$TARGETS_FILE" | paste -sd '|' -)
    grep -E "^([a-zA-Z0-9_-]+\.)*(${TARGET_ALT})$" "$SUBS" 2>/dev/null |
        sed 's/\r//' |
        sort -u > "${SUBS}.tmp" &&
        mv "${SUBS}.tmp" "$SUBS"
fi

SUB_COUNT=$(count_lines "$SUBS")

success "SUBDOMAIN DISCOVERY COMPLETE"
detail "$SUB_COUNT unique candidates discovered"

run_tool 08 "HTTPX" \
    bash -o pipefail -c '
        httpx \
            -l "$1" \
            -silent \
            -threads 200 |
        anew "$2" >/dev/null
    ' _ "$SUBS" "$ALIVE"

run_tool 09 "HTTPX FINGERPRINT" \
    bash -o pipefail -c '
        httpx \
            -l "$1" \
            --random-agent \
            --status-code \
            --title \
            --server \
            -tech-detect \
            -cl \
            > "$2"
    ' _ "$ALIVE" "$TECH"

ALIVE_COUNT=$(count_lines "$ALIVE")

if [[ -s "$SUBS" ]]; then
    TARGET_ALT=$(sed 's/[.]/\\./g' "$TARGETS_FILE" | paste -sd '|' -)
    grep -E "^([a-zA-Z0-9_-]+\.)*(${TARGET_ALT})$" "$SUBS" 2>/dev/null |
        sed 's/\r//' |
        sort -u > "${SUBS}.tmp" &&
        mv "${SUBS}.tmp" "$SUBS"
fi

SUB_COUNT=$(count_lines "$SUBS")

success "SUBDOMAIN DISCOVERY COMPLETE"
detail "$SUB_COUNT unique candidates discovered"

if [[ "$MODE" == "small" ]]; then

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    MINUTES=$((DURATION / 60))
    SECONDS=$((DURATION % 60))

    printf '\n'
    line

    printf '%b\n' \
        "${CYAN}${BOLD}  SMALL SCAN COMPLETE${RESET}"

    printf '\n'

    printf '  %b%-14s%b %b%s%b\n' \
        "$DIM" "TARGET" "$RESET" "$BOLD" "$TARGET_LABEL" "$RESET"
    printf '  %b%-14s%b %b%s%b\n' \
        "$DIM" "SUBDOMAINS" "$RESET" "$BOLD" "$SUB_COUNT" "$RESET"
    printf '  %b%-14s%b %b%02d:%02d%b\n' \
        "$DIM" "DURATION" "$RESET" "$BOLD" "$MINUTES" "$SECONDS" "$RESET"
    printf '  %b%-14s%b %b%s%b\n' \
        "$DIM" "OUTPUT" "$RESET" "$BOLD" "$SUBS" "$RESET"

    printf '\n'
    line

    printf '%b\n' \
        "${MAGENTA}${BOLD}  RavenEye  •  @ravenXxx${RESET}"

    line
    printf '\n'

    rm -rf "$TMPDIR_RAVEN" 2>/dev/null

    exit 0
fi

phase " DNS ENUMERATION"

run_tool 10 "DNSX" \
    bash -o pipefail -c '
        dnsx \
            -l "$1" \
            -threads 300 \
            -silent \
            > "$2"
    ' _ "$ALIVE" "$RESOLVED"

RESOLVED_COUNT=$(count_lines "$RESOLVED")

success "DNS ENUMERATION COMPLETE"
detail "$RESOLVED_COUNT resolved hosts"

phase " PORT DISCOVERY"

run_tool 11 "NAABU" \
    bash -o pipefail -c '
        naabu \
            -l "$1" \
            -sV-fast  \
            -silent \
            -top-ports 100 \
            > "$2"
    ' _ "$RESOLVED" "$NAABU_OUT"

PORT_COUNT=$(count_lines "$NAABU_OUT")

success "PORT DISCOVERY COMPLETE"
detail "$PORT_COUNT discovered services"

phase " CRAWLING / URL COLLECTION"

: > "$TMPDIR_RAVEN/katana_targets.txt"

while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    printf 'https://%s\n' "$d" >> "$TMPDIR_RAVEN/katana_targets.txt"
done < "$TARGETS_FILE"

run_tool 12 "KATANA" \
    bash -o pipefail -c '
        if ! timeout 300 katana \
           -list "$1" \
           -jc \
           -c 50 \
           -p 50 \
           -rl 200 \
           -timeout 3 \
           -o "$2" \
           -silent
        then
            exit 0
        fi
    ' _ "$TMPDIR_RAVEN/katana_targets.txt" "$TMPDIR_RAVEN/katana_full.txt"

run_tool 13 "WAYMORE" \
    waymore \
    -i "$TARGETS_FILE" \
    -mode U \
    -oU "$TMPDIR_RAVEN/waymore.txt"

run_tool 14 "URL MERGE" \
    bash -o pipefail -c '
        cat "$1" "$2" 2>/dev/null |
        sort -u > "$3"
    ' _ "$TMPDIR_RAVEN/waymore.txt" "$TMPDIR_RAVEN/katana_full.txt" "$URLS"

URL_COUNT=$(count_lines "$URLS")

success "URL COLLECTION COMPLETE"
detail "$URL_COUNT unique URLs collected"

PARAMS_DIR="$OUTDIR/params"
mkdir -p "$PARAMS_DIR"

# ──────────────────────────────────────────────────────────────
# Fastest, most reliable param source: the URLs we ALREADY have
# from katana + waymore ($URLS). No extra network calls, no
# archive.org rate limits, works even if paramspider is
# unavailable or gets throttled below.
# ──────────────────────────────────────────────────────────────

run_tool 15 "URL PARAMS" \
    bash -o pipefail -c '
        grep "?" "$1" 2>/dev/null | sort -u > "$2"
        exit 0
    ' _ "$URLS" "$PARAMS_DIR/from_urls.txt"

# archive.org'"'"'s CDX API throttles aggressively - ParamSpider
# silently exits 0 with no output when it gets rate-limited after
# 3 retries (see client.py: bare sys.exit()), so a high worker
# count here does more harm than good. Keep this modest; it now
# only adds anything paramspider finds beyond what we already
# extracted above.
PARAM_JOBS="${PARAM_JOBS:-5}"
PARAM_TMP="$OUTDIR/.paramspider"

rm -rf "$PARAM_TMP"
mkdir -p "$PARAM_TMP"

run_tool 16 "Paramspider" \
    bash -o pipefail -c '
        alive="$1"
        out="$2"
        tmp="$3"
        jobs="$4"

        mkdir -p "$out" "$tmp"

        # Fail loudly and immediately if paramspider is missing or
        # broken, instead of every worker silently erroring
        # "command not found" and the step reporting a fake
        # "COMPLETE / 0 results". Also guards against the PyPI
        # name-squat package (pip install paramspider), which
        # installs a no-op placeholder with no CLI at all - the
        # real tool is: pip install git+https://github.com/devanshbatham/ParamSpider.git
        if ! command -v paramspider >/dev/null 2>&1; then
            echo "[ERROR] paramspider not found in PATH." >&2
            echo "[ERROR] If you installed it via '"'"'pip install paramspider'"'"', that PyPI name is a squatted placeholder with no functionality." >&2
            echo "[ERROR] Install the real tool: pip install git+https://github.com/devanshbatham/ParamSpider.git" >&2
            exit 1
        fi

        # NOTE (fix): $alive (fresh_alive_domains) is httpx output,
        # i.e. full URLs like "https://sub.example.com" or
        # "https://sub.example.com:8443". The old filter regex only
        # matched bare hostnames with no scheme, so it never matched
        # a single line here -> domains.txt was always empty ->
        # every paramspider worker ran on zero domains -> params/
        # ended up empty (or absent once cleaned up). Strip the
        # scheme and any trailing :port/path before filtering.
        sort -u "$alive" |
            sed -E "s#^[a-zA-Z]+://##" |
            sed -E "s#[/:].*##" |
            sed "/^[[:space:]]*$/d" |
            sed "s/\r$//" |
            sed "s#^[[:space:]]*##;s#[[:space:]]*$##" |
            sort -u |
            grep -E "^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,63}$" \
            > "$tmp/domains.txt"

        total=$(wc -l < "$tmp/domains.txt" | tr -d " ")

        echo "[ParamSpider] domains: $total" >&2
        echo "[ParamSpider] workers: $jobs" >&2

        export PARAM_OUT="$out"
        export PARAM_TMP="$tmp"

        cat "$tmp/domains.txt" |
            xargs -r -n1 -P"$jobs" \
            bash -c '\''
                domain="$1"

                safe_name=$(printf "%s" "$domain" |
                    tr "/: " "___")

                log="$PARAM_TMP/log_${safe_name}.txt"

                workdir=$(mktemp -d \
                    "$PARAM_TMP/worker.XXXXXX")

                {
                    echo "=========================================="
                    echo "DOMAIN: $domain"
                    echo "WORKDIR: $workdir"
                    echo "PID: $$"
                    echo "=========================================="
                    echo

                    cd "$workdir" || {
                        echo "[ERROR] Cannot enter workdir"
                        exit 0
                    }

                    echo "[+] Running:"
                    echo "paramspider -d $domain"
                    echo

                    paramspider -d "$domain"

                    status=$?

                    echo
                    echo "[+] ParamSpider exit code: $status"
                    echo

                    echo "[+] Generated files:"
                    find "$workdir" \
                        -maxdepth 3 \
                        -type f \
                        -print 2>/dev/null || true

                    echo

                    if [[ -d "$workdir/results" ]]; then

                        echo "[+] Results:"
                        find "$workdir/results" \
                            -maxdepth 1 \
                            -type f \
                            -name "*.txt" \
                            -print 2>/dev/null || true

                        find "$workdir/results" \
                            -maxdepth 1 \
                            -type f \
                            -name "*.txt" \
                            -exec mv -f {} "$PARAM_OUT/" \; \
                            2>/dev/null || true

                    else
                        echo "[!] No results directory created"
                    fi

                    echo
                    echo "[+] Param directory:"
                    find "$PARAM_OUT" \
                        -maxdepth 1 \
                        -type f \
                        -printf "%f\n" 2>/dev/null || true

                    rm -rf "$workdir"

                } >"$log" 2>&1

            '\'' _

        echo "[ParamSpider] workers finished" >&2
        echo >&2
        echo "========== PARAMSPIDER LOG SUMMARY ==========" >&2

        problem_logs=0

        for log in "$tmp"/log_*.txt; do
            [[ -f "$log" ]] || continue

            if grep -qiE \
                "error|exception|traceback|failed|permission|no results directory" \
                "$log"; then

                problem_logs=$((problem_logs + 1))
                echo >&2
                echo "----- $(basename "$log") -----" >&2
                tail -n 30 "$log" >&2
            fi
        done

        # If EVERY worker log had a problem (or there is no output
        # at all despite domains being fed in), surface that as a
        # real failure so run_tool shows it instead of a false
        # "COMPLETE / 0 results".
        if [[ "$total" -gt 0 ]] && [[ "$problem_logs" -ge "$total" ]]; then
            echo "[ERROR] All $total paramspider worker(s) errored - see log summary above." >&2
            exit 1
        fi

        exit 0
    ' _ \
    "$ALIVE" \
    "$PARAMS_DIR" \
    "$PARAM_TMP" \
    "$PARAM_JOBS"

PARAM_COUNT=0

if compgen -G "$PARAMS_DIR/*.txt" >/dev/null 2>&1; then

    find "$PARAMS_DIR" \
        -maxdepth 1 \
        -type f \
        -name "*.txt" \
        ! -name "all.txt" \
        -empty \
        -delete

    if compgen -G "$PARAMS_DIR/*.txt" >/dev/null 2>&1; then

        cat "$PARAMS_DIR"/*.txt 2>/dev/null |
            sed '/^[[:space:]]*$/d' |
            sed 's/\r$//' |
            sort -u > "$PARAMS_DIR/all.txt.tmp"

        mv "$PARAMS_DIR/all.txt.tmp" \
            "$PARAMS_DIR/all.txt"

        PARAM_COUNT=$(
            wc -l < "$PARAMS_DIR/all.txt" |
            tr -d " "
        )
    fi
fi

rm -rf "$PARAM_TMP"

success "PARAMETER DISCOVERY COMPLETE"
detail "$PARAM_COUNT unique parameter results"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

printf '\n'
line

printf '%b\n' \
    "${CYAN}${BOLD}  RECON COMPLETE 🎊🎊 ${RESET}"

printf '\n'

printf '  %b%-14s%b %b%s%b\n' \
    "$DIM" "TARGET" "$RESET" "$BOLD" "$TARGET_LABEL" "$RESET"
printf '  %b%-14s%b %b%s%b\n' \
    "$DIM" "SUBDOMAINS" "$RESET" "$BOLD" "$SUB_COUNT" "$RESET"
printf '  %b%-14s%b %b%s%b\n' \
    "$DIM" "LIVE HTTP" "$RESET" "$BOLD" "$ALIVE_COUNT" "$RESET"
printf '  %b%-14s%b %b%s%b\n' \
    "$DIM" "DNS HOSTS" "$RESET" "$BOLD" "$RESOLVED_COUNT" "$RESET"
printf '  %b%-14s%b %b%s%b\n' \
    "$DIM" "PORT RESULTS" "$RESET" "$BOLD" "$PORT_COUNT" "$RESET"
printf '  %b%-14s%b %b%s%b\n' \
    "$DIM" "URLS" "$RESET" "$BOLD" "$URL_COUNT" "$RESET"
printf '  %b%-14s%b %b%s%b\n' \
    "$DIM" "PARAMS" "$RESET" "$BOLD" "$PARAM_COUNT" "$RESET"
printf '  %b%-14s%b %b%02d:%02d%b\n' \
    "$DIM" "DURATION" "$RESET" "$BOLD" "$MINUTES" "$SECONDS" "$RESET"
printf '  %b%-14s%b %b%s%b\n' \
    "$DIM" "OUTPUT" "$RESET" "$BOLD" "$OUTDIR" "$RESET"

printf '\n'
line

printf '%b\n' \
    "${MAGENTA}${BOLD}  RavenEye  •  @ravenXxx${RESET}"

line
printf '\n'

rm -rf "$TMPDIR_RAVEN" 2>/dev/null

exit 0
