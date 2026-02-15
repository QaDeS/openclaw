#!/usr/bin/env bash
# ── lib-common.sh ────────────────────────────────────────────────────
# Shared helpers for remove-user.sh and restore-user.sh.
# Source this file; callers must set QUIET, LOG_FILE, NO_COLOR, FORCE,
# EXIT_CODE, STEP before sourcing (or accept defaults below).
# ────────────────────────────────────────────────────────────────────

: "${QUIET:=false}"
: "${LOG_FILE:=}"
: "${NO_COLOR:=false}"
: "${FORCE:=false}"
: "${EXIT_CODE:=0}"
: "${STEP:=0}"

# ── colors (auto-disabled when not a TTY) ───────────────────────────

setup_colors() {
    if $NO_COLOR || [[ ! -t 1 ]]; then
        RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
    else
        RED='\033[0;31m'
        YELLOW='\033[1;33m'
        GREEN='\033[0;32m'
        CYAN='\033[0;36m'
        BOLD='\033[1m'
        RESET='\033[0m'
    fi
}

# ── output helpers ──────────────────────────────────────────────────

_log_raw() {
    if [[ -n "$LOG_FILE" ]]; then
        echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
    fi
}

_echo() {
    if ! $QUIET; then
        echo -e "$@"
    fi
    _log_raw "$@"
}

# always print, even in quiet mode (warnings/errors)
_warn() {
    echo -e "$@" >&2
    _log_raw "$@"
}

step() {
    STEP=$((STEP + 1))
    _echo "${BOLD}${STEP}. $1${RESET}"
}

log_action() {
    local label="$1"
    if $FORCE; then
        _echo "  ${GREEN}[EXEC]${RESET}  $label"
    else
        _echo "  ${YELLOW}[DRY]${RESET}   $label"
    fi
}

log_keep() {
    _echo "  ${CYAN}[KEEP]${RESET}  $1"
}

log_info() {
    _echo "  ${YELLOW}[INFO]${RESET}  $1"
}

log_skip() {
    _echo "  ($1)"
}

warn_manual() {
    _warn "  ${YELLOW}[WARN]${RESET}  $1"
    set_exit 1
}

set_exit() {
    if [[ "$1" -gt "$EXIT_CODE" ]]; then
        EXIT_CODE="$1"
    fi
}

run() {
    log_action "$*"
    if $FORCE; then
        if ! "$@"; then
            _warn "  ${RED}[FAIL]${RESET}  command failed: $*"
            set_exit 2
        fi
    fi
}

die() {
    setup_colors
    echo -e "${RED}error:${RESET} $*" >&2
    exit 2
}

# safe alternative to eval — used for sed-in-place on subuid/subgid etc.
remove_line_from_file() {
    local pattern="$1" file="$2"
    log_action "remove lines matching '^${pattern}:' from $file"
    if $FORCE; then
        local tmp
        tmp=$(mktemp)
        grep -v "^${pattern}:" "$file" > "$tmp" || true
        cat "$tmp" > "$file"
        rm -f "$tmp"
    fi
}

# ── manifest helpers ────────────────────────────────────────────────

MANIFEST_VERSION="1"

# Read a manifest file into M_* variables.
# Usage: read_manifest /path/to/manifest
read_manifest() {
    local file="$1"
    M_USERNAME="" M_UID="" M_GID="" M_GROUP="" M_SHELL="" M_GECOS=""
    M_HOME="" M_KEEP_KEYS="" M_SUBUID="" M_SUBGID="" M_REMOVED_AT=""
    M_SUPPLEMENTARY_GROUPS="" M_SHADOW_HASH="" M_REVOKED_SSH_KEYS=""
    M_VERSION=""

    while IFS= read -r line; do
        # skip blank lines
        [[ -n "$line" ]] || continue
        # parse version from comment header
        if [[ "$line" =~ ^#\ remove-user\ manifest\ v([0-9]+) ]]; then
            M_VERSION="${BASH_REMATCH[1]}"
            continue
        fi
        # skip other comments
        [[ "$line" != \#* ]] || continue
        # split on first =
        local key="${line%%=*}"
        local value="${line#*=}"
        key="${key## }"; key="${key%% }"
        case "$key" in
            username)              M_USERNAME="$value" ;;
            uid)                   M_UID="$value" ;;
            gid)                   M_GID="$value" ;;
            group)                 M_GROUP="$value" ;;
            shell)                 M_SHELL="$value" ;;
            gecos)                 M_GECOS="$value" ;;
            home)                  M_HOME="$value" ;;
            keep_keys)             M_KEEP_KEYS="$value" ;;
            subuid)                M_SUBUID="$value" ;;
            subgid)                M_SUBGID="$value" ;;
            removed_at)            M_REMOVED_AT="$value" ;;
            supplementary_groups)  M_SUPPLEMENTARY_GROUPS="$value" ;;
            shadow_hash)           M_SHADOW_HASH="$value" ;;
            revoked_ssh_keys)      M_REVOKED_SSH_KEYS="$value" ;;
        esac
    done < "$file"
}

validate_manifest_version() {
    if [[ -z "$M_VERSION" ]]; then
        die "manifest has no version header (expected '# remove-user manifest v$MANIFEST_VERSION')"
    fi
    if [[ "$M_VERSION" -gt "$MANIFEST_VERSION" ]]; then
        die "manifest version $M_VERSION is newer than this script supports (v$MANIFEST_VERSION). Please update restore-user.sh."
    fi
}
