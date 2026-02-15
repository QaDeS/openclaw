#!/usr/bin/env bash
set -euo pipefail

# ── restore-user.sh ──────────────────────────────────────────────────
# Restore a user from a backup tarball created by remove-user.sh.
# Dry-run by default; pass --force to actually execute.
# ────────────────────────────────────────────────────────────────────

FORCE=false
ARCHIVE=""
QUIET=false
LOG_FILE=""
NO_COLOR=false
CONFIRM=true

EXIT_CODE=0
STEP=0

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

log_skip() {
    _echo "  ($1)"
}

log_info() {
    _echo "  ${YELLOW}[INFO]${RESET}  $1"
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

# ── usage ───────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: restore-user.sh [OPTIONS] <tarball>

Restore a user account from a backup tarball created by remove-user.sh.
The tarball must contain a .remove-user-manifest (metadata written by
remove-user.sh v2+).

By default runs in DRY-RUN mode. Pass --force to actually execute.

Arguments:
  <tarball>             Path to the backup tarball (.tar.gz)

Options:
  --force               Execute the restoration (default: dry-run)
  --yes, -y             Skip the interactive confirmation prompt
  --log FILE            Write full output (ANSI-stripped) to FILE
  --quiet, -q           Only print warnings and errors
  --no-color            Disable colored output
  -h, --help            Show this help message

Steps (in order):
  1. Extract and validate manifest from tarball
  2. Verify user/uid/gid don't already exist
  3. Recreate primary group with original gid
  4. Recreate user with original uid, gid, shell, gecos, home
  5. Extract home directory, fix ownership
  6. Restore crontab (if present)
  7. Restore sudoers fragment (if present)
  8. Restore SSH server keys (if present)
  9. Restore AccountsService files (if present)
  10. Restore subuid/subgid entries (from manifest)
  11. Summary and next steps

Exit codes:
  0   Clean restore (or dry run)
  1   Completed with warnings
  2   Errors encountered

Examples:
  # See what would happen:
  sudo ./restore-user.sh /var/backups/removed-users/testuser_20260215_123456.tar.gz

  # Actually restore:
  sudo ./restore-user.sh --force /var/backups/removed-users/testuser_20260215_123456.tar.gz

  # Restore without prompts:
  sudo ./restore-user.sh --force -y /var/backups/removed-users/testuser_20260215_123456.tar.gz
EOF
}

die() {
    setup_colors
    echo -e "${RED}error:${RESET} $*" >&2
    exit 2
}

# ── parse args ──────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)      usage; exit 0 ;;
        --force)        FORCE=true; shift ;;
        --yes|-y)       CONFIRM=false; shift ;;
        --quiet|-q)     QUIET=true; shift ;;
        --no-color)     NO_COLOR=true; shift ;;
        --log)
            [[ -n "${2:-}" ]] || die "--log requires an argument"
            LOG_FILE="$2"; shift 2 ;;
        -*)             die "unknown option: $1" ;;
        *)
            [[ -z "$ARCHIVE" ]] || die "unexpected argument: $1"
            ARCHIVE="$1"; shift ;;
    esac
done

setup_colors

[[ -n "$ARCHIVE" ]] || { usage; exit 1; }
[[ $(id -u) -eq 0 ]] || die "must run as root"
[[ -f "$ARCHIVE" ]] || die "tarball not found: $ARCHIVE"

# ── validate log file early ────────────────────────────────────────

if [[ -n "$LOG_FILE" ]]; then
    log_dir=$(dirname "$LOG_FILE")
    [[ -d "$log_dir" && -w "$log_dir" ]] || die "log directory is not writable: $log_dir"
    : > "$LOG_FILE" || die "cannot write to log file: $LOG_FILE"
    _log_raw "restore-user.sh — $(date -Iseconds) — archive: $ARCHIVE"
    _log_raw "---"
fi

# ── 1. Extract and read manifest ───────────────────────────────────

step "Extract manifest from tarball"

manifest_tmp=$(mktemp)
trap 'rm -f "$manifest_tmp"' EXIT

# the manifest is stored at var/backups/removed-users/.manifest-<user>
# find the manifest path inside the tarball
manifest_path=$(tar tzf "$ARCHIVE" 2>/dev/null | grep '\.manifest-' | head -1 || true)
if [[ -z "$manifest_path" ]]; then
    die "no .remove-user-manifest found in tarball (was it created by remove-user.sh v2+?)"
fi

tar xzf "$ARCHIVE" -C /tmp --include="$manifest_path" 2>/dev/null \
    || die "failed to extract manifest from tarball"
cp "/tmp/$manifest_path" "$manifest_tmp"
rm -f "/tmp/$manifest_path"

# parse manifest (key=value, skip comments and blank lines)
M_USERNAME="" M_UID="" M_GID="" M_GROUP="" M_SHELL="" M_GECOS=""
M_HOME="" M_KEEP_KEYS="" M_SUBUID="" M_SUBGID="" M_REMOVED_AT=""

while IFS='=' read -r key value; do
    [[ -n "$key" && "$key" != \#* ]] || continue
    # trim leading/trailing whitespace from key
    key="${key## }"; key="${key%% }"
    case "$key" in
        username)   M_USERNAME="$value" ;;
        uid)        M_UID="$value" ;;
        gid)        M_GID="$value" ;;
        group)      M_GROUP="$value" ;;
        shell)      M_SHELL="$value" ;;
        gecos)      M_GECOS="$value" ;;
        home)       M_HOME="$value" ;;
        keep_keys)  M_KEEP_KEYS="$value" ;;
        subuid)     M_SUBUID="$value" ;;
        subgid)     M_SUBGID="$value" ;;
        removed_at) M_REMOVED_AT="$value" ;;
    esac
done < "$manifest_tmp"

# validate required fields
for field in M_USERNAME M_UID M_GID M_GROUP M_SHELL M_HOME; do
    eval "val=\$$field"
    [[ -n "$val" ]] || die "manifest missing required field: ${field#M_}"
done

_echo "  ${GREEN}Manifest loaded:${RESET}"
_echo "    user:  ${BOLD}$M_USERNAME${RESET} (uid=$M_UID, gid=$M_GID)"
_echo "    group: $M_GROUP"
_echo "    shell: $M_SHELL"
_echo "    home:  $M_HOME"
_echo "    gecos: $M_GECOS"
if [[ -n "$M_REMOVED_AT" ]]; then
    _echo "    removed at: $M_REMOVED_AT"
fi

# ── header ──────────────────────────────────────────────────────────

_echo ""
if $FORCE; then
    _echo "${GREEN}${BOLD}=== RESTORING USER: $M_USERNAME (uid=$M_UID) ===${RESET}"
else
    _echo "${CYAN}${BOLD}=== DRY RUN: restore $M_USERNAME (uid=$M_UID) ===${RESET}"
    _echo "${CYAN}    No changes will be made. Pass --force to execute.${RESET}"
fi
_echo ""

# ── confirmation gate (--force only) ────────────────────────────────

if $FORCE && $CONFIRM; then
    echo -en "${GREEN}${BOLD}Type YES to confirm restoration of user '$M_USERNAME': ${RESET}"
    read -r answer
    if [[ "$answer" != "YES" ]]; then
        echo "Aborted."
        exit 1
    fi
    echo ""
fi

# ── 2. Validate user/uid/gid don't already exist ──────────────────

step "Validate user/uid/gid are free"
conflict=false
if id "$M_USERNAME" &>/dev/null; then
    die "user '$M_USERNAME' already exists"
fi
if getent passwd "$M_UID" &>/dev/null; then
    die "uid $M_UID is already in use by $(getent passwd "$M_UID" | cut -d: -f1)"
fi
# gid may be in use by a system group — only fail if a different group name claims it
if getent group "$M_GID" &>/dev/null; then
    existing_group=$(getent group "$M_GID" | cut -d: -f1)
    if [[ "$existing_group" != "$M_GROUP" ]]; then
        die "gid $M_GID is already in use by group '$existing_group'"
    fi
fi
log_action "user=$M_USERNAME uid=$M_UID gid=$M_GID — all free"

# ── 3. Recreate primary group ──────────────────────────────────────

step "Recreate primary group"
if getent group "$M_GROUP" &>/dev/null; then
    log_skip "group '$M_GROUP' already exists (gid=$(getent group "$M_GROUP" | cut -d: -f3))"
else
    run groupadd -g "$M_GID" "$M_GROUP"
fi

# ── 4. Recreate user account ──────────────────────────────────────

step "Recreate user account"
useradd_args=(-u "$M_UID" -g "$M_GID" -s "$M_SHELL" -d "$M_HOME" -m)
if [[ -n "$M_GECOS" ]]; then
    useradd_args+=(-c "$M_GECOS")
fi
log_action "useradd ${useradd_args[*]} $M_USERNAME"
if $FORCE; then
    if ! useradd "${useradd_args[@]}" "$M_USERNAME" 2>/dev/null; then
        _warn "  ${RED}[FAIL]${RESET}  useradd failed"
        set_exit 2
    fi
fi

# ── 5. Extract home directory ──────────────────────────────────────

step "Extract home directory from tarball"
# strip leading / from M_HOME to match tarball paths
home_rel="${M_HOME#/}"
if tar tzf "$ARCHIVE" 2>/dev/null | grep -q "^${home_rel}"; then
    log_action "tar xzf $ARCHIVE -C / (home: $home_rel)"
    if $FORCE; then
        tar xzf "$ARCHIVE" -C / "$home_rel" 2>/dev/null || true
        chown -R "$M_UID:$M_GID" "$M_HOME"
    fi
else
    log_skip "no home directory in tarball"
fi

# ── 6. Restore crontab ────────────────────────────────────────────

step "Restore crontab"
cron_restored=false
for cron_path in "var/spool/cron/crontabs/$M_USERNAME" "var/spool/cron/$M_USERNAME"; do
    if tar tzf "$ARCHIVE" 2>/dev/null | grep -q "^${cron_path}$"; then
        log_action "extract $cron_path"
        if $FORCE; then
            tar xzf "$ARCHIVE" -C / "$cron_path" 2>/dev/null || true
            chown root:crontab "/$cron_path" 2>/dev/null || true
            chmod 600 "/$cron_path" 2>/dev/null || true
        fi
        cron_restored=true
        break
    fi
done
if ! $cron_restored; then log_skip "no crontab in tarball"; fi

# ── 7. Restore sudoers fragment ───────────────────────────────────

step "Restore sudoers fragment"
sudoers_path="etc/sudoers.d/$M_USERNAME"
if tar tzf "$ARCHIVE" 2>/dev/null | grep -q "^${sudoers_path}$"; then
    log_action "extract $sudoers_path"
    if $FORCE; then
        tar xzf "$ARCHIVE" -C / "$sudoers_path" 2>/dev/null || true
        chown root:root "/$sudoers_path"
        chmod 440 "/$sudoers_path"
    fi
else
    log_skip "no sudoers fragment in tarball"
fi

# ── 8. Restore SSH server keys ─────────────────────────────────────

step "Restore SSH server keys"
ssh_path="etc/ssh/users/$M_USERNAME"
if tar tzf "$ARCHIVE" 2>/dev/null | grep -q "^${ssh_path}"; then
    log_action "extract $ssh_path"
    if $FORCE; then
        tar xzf "$ARCHIVE" -C / "$ssh_path" 2>/dev/null || true
    fi
else
    log_skip "no SSH server keys in tarball"
fi

# ── 9. Restore AccountsService files ──────────────────────────────

step "Restore AccountsService files"
acct_restored=false
for acct_path in "var/lib/AccountsService/users/$M_USERNAME" \
                 "var/lib/AccountsService/icons/$M_USERNAME"; do
    if tar tzf "$ARCHIVE" 2>/dev/null | grep -q "^${acct_path}$"; then
        log_action "extract $acct_path"
        if $FORCE; then
            tar xzf "$ARCHIVE" -C / "$acct_path" 2>/dev/null || true
        fi
        acct_restored=true
    fi
done
if ! $acct_restored; then log_skip "no AccountsService data in tarball"; fi

# ── 10. Restore subuid/subgid entries ─────────────────────────────

step "Restore subuid/subgid entries"
if [[ -n "$M_SUBUID" ]]; then
    log_action "add $M_USERNAME:$M_SUBUID to /etc/subuid"
    if $FORCE; then
        echo "$M_USERNAME:$M_SUBUID" >> /etc/subuid
    fi
else
    log_skip "no subuid range in manifest"
fi
if [[ -n "$M_SUBGID" ]]; then
    log_action "add $M_USERNAME:$M_SUBGID to /etc/subgid"
    if $FORCE; then
        echo "$M_USERNAME:$M_SUBGID" >> /etc/subgid
    fi
else
    log_skip "no subgid range in manifest"
fi

# ── 11. Summary ─────────────────────────────────────────────────────

_echo ""
if $FORCE; then
    case $EXIT_CODE in
        0) _echo "${GREEN}${BOLD}Done. User '$M_USERNAME' has been restored.${RESET}" ;;
        1) _echo "${YELLOW}${BOLD}Done. User '$M_USERNAME' restored with warnings (see above).${RESET}" ;;
        2) _warn "${RED}${BOLD}Done. User '$M_USERNAME' restore completed with errors (see above).${RESET}" ;;
    esac
    _echo ""
    _echo "  ${YELLOW}Next steps:${RESET}"
    _echo "    - Set a password:  ${BOLD}passwd $M_USERNAME${RESET}"
    _echo "    - Unlock account:  ${BOLD}usermod -U $M_USERNAME${RESET} (if locked)"
    _echo "    - Re-enable any services the user was running"
else
    _echo "${CYAN}${BOLD}Dry run complete. No changes were made.${RESET}"
    _echo "${CYAN}Re-run with --force to execute the above actions.${RESET}"
fi

if [[ -n "$LOG_FILE" ]]; then
    _log_raw "---"
    _log_raw "exit code: $EXIT_CODE"
    _echo "  Log written to ${BOLD}$LOG_FILE${RESET}"
fi

rm -f "$manifest_tmp"
trap - EXIT

exit "$EXIT_CODE"
