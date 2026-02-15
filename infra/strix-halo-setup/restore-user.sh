#!/usr/bin/env bash
set -euo pipefail

# ── restore-user.sh ──────────────────────────────────────────────────
# Restore a user from a backup tarball created by remove-user.sh.
# Dry-run by default; pass --force to actually execute.
# ────────────────────────────────────────────────────────────────────

FORCE=false
ARCHIVE=""
LIST_MODE=false
LIST_DIR="/var/backups/removed-users"
RESTORE_SSH_KEYS=false
QUIET=false
LOG_FILE=""
NO_COLOR=false
CONFIRM=true

EXIT_CODE=0
STEP=0

# ── source shared helpers ──────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

# ── usage ───────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: restore-user.sh [OPTIONS] <tarball>
       restore-user.sh --list [DIR]

Restore a user account from a backup tarball created by remove-user.sh.
The tarball must contain a metadata manifest (written by remove-user.sh v2+).

By default runs in DRY-RUN mode. Pass --force to actually execute.

Arguments:
  <tarball>             Path to the backup tarball (.tar.gz)

Options:
  --force               Execute the restoration (default: dry-run)
  --restore-ssh-keys    Re-add SSH key lines that were revoked from other
                        users' authorized_keys by --revoke-ssh
  --list [DIR]          List all backup tarballs in DIR (default:
                        /var/backups/removed-users/) and exit
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
  5. Restore supplementary group memberships
  6. Restore password hash (if saved with --save-shadow)
  7. Extract home directory, fix ownership
  8. Restore crontab (if present)
  9. Restore sudoers fragment (if present)
  10. Restore SSH server keys (if present)
  11. Restore AccountsService files (if present)
  12. Restore subuid/subgid entries (from manifest)
  13. Restore revoked SSH keys (if --restore-ssh-keys)
  14. Summary and next steps

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

  # Restore and re-add revoked SSH keys to other users:
  sudo ./restore-user.sh --force --restore-ssh-keys /var/backups/removed-users/testuser_20260215_123456.tar.gz

  # List available backups:
  sudo ./restore-user.sh --list
  sudo ./restore-user.sh --list /path/to/custom/backup/dir
EOF
}

# ── parse args ──────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)             usage; exit 0 ;;
        --force)               FORCE=true; shift ;;
        --restore-ssh-keys)    RESTORE_SSH_KEYS=true; shift ;;
        --yes|-y)              CONFIRM=false; shift ;;
        --quiet|-q)            QUIET=true; shift ;;
        --no-color)            NO_COLOR=true; shift ;;
        --list)
            LIST_MODE=true; shift
            # optional positional: directory
            if [[ $# -gt 0 && "$1" != -* ]]; then
                LIST_DIR="$1"; shift
            fi
            ;;
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

# ── --list mode ────────────────────────────────────────────────────

if $LIST_MODE; then
    [[ $(id -u) -eq 0 ]] || die "must run as root"
    [[ -d "$LIST_DIR" ]] || die "directory not found: $LIST_DIR"

    printf "${BOLD}%-20s  %-6s  %-6s  %-20s  %-20s  %s${RESET}\n" \
        "USERNAME" "UID" "GID" "REMOVED AT" "GROUPS" "ARCHIVE"

    found=0
    for tarball in "$LIST_DIR"/*.tar.gz; do
        [[ -f "$tarball" ]] || continue
        # extract manifest to a temp location
        mpath=$(tar tzf "$tarball" 2>/dev/null | grep '\.manifest-' | head -1 || true)
        [[ -n "$mpath" ]] || continue

        tmp_manifest=$(mktemp)
        tar xzf "$tarball" -C /tmp "$mpath" 2>/dev/null || { rm -f "$tmp_manifest"; continue; }
        cp "/tmp/$mpath" "$tmp_manifest" 2>/dev/null || { rm -f "$tmp_manifest"; continue; }
        rm -f "/tmp/$mpath"

        read_manifest "$tmp_manifest"
        rm -f "$tmp_manifest"

        printf "%-20s  %-6s  %-6s  %-20s  %-20s  %s\n" \
            "${M_USERNAME:--}" "${M_UID:--}" "${M_GID:--}" \
            "${M_REMOVED_AT:--}" "${M_SUPPLEMENTARY_GROUPS:--}" \
            "$(basename "$tarball")"
        found=$((found + 1))
    done

    if [[ "$found" -eq 0 ]]; then
        _echo "  (no backup tarballs with manifests found in $LIST_DIR)"
    fi
    exit 0
fi

# ── normal restore mode ────────────────────────────────────────────

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

# find the manifest path inside the tarball
manifest_path=$(tar tzf "$ARCHIVE" 2>/dev/null | grep '\.manifest-' | head -1 || true)
if [[ -z "$manifest_path" ]]; then
    die "no manifest found in tarball (was it created by remove-user.sh v2+?)"
fi

tar xzf "$ARCHIVE" -C /tmp "$manifest_path" 2>/dev/null \
    || die "failed to extract manifest from tarball"
cp "/tmp/$manifest_path" "$manifest_tmp"
rm -f "/tmp/$manifest_path"

# parse manifest using shared helper
read_manifest "$manifest_tmp"

# validate version
validate_manifest_version

# validate required fields
for field in M_USERNAME M_UID M_GID M_GROUP M_SHELL M_HOME; do
    eval "val=\$$field"
    [[ -n "$val" ]] || die "manifest missing required field: ${field#M_}"
done

_echo "  ${GREEN}Manifest loaded (v${M_VERSION}):${RESET}"
_echo "    user:  ${BOLD}$M_USERNAME${RESET} (uid=$M_UID, gid=$M_GID)"
_echo "    group: $M_GROUP"
_echo "    shell: $M_SHELL"
_echo "    home:  $M_HOME"
_echo "    gecos: $M_GECOS"
if [[ -n "$M_SUPPLEMENTARY_GROUPS" ]]; then
    _echo "    supplementary groups: $M_SUPPLEMENTARY_GROUPS"
fi
if [[ -n "$M_SHADOW_HASH" ]]; then
    _echo "    shadow hash: ${CYAN}(saved)${RESET}"
fi
if [[ -n "$M_REVOKED_SSH_KEYS" ]]; then
    # count pipe-separated entries
    _rsk_count=$(echo "$M_REVOKED_SSH_KEYS" | tr '|' '\n' | wc -l)
    _echo "    revoked SSH keys: $_rsk_count entries"
fi
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
if id "$M_USERNAME" &>/dev/null; then
    die "user '$M_USERNAME' already exists"
fi
if getent passwd "$M_UID" &>/dev/null; then
    die "uid $M_UID is already in use by $(getent passwd "$M_UID" | cut -d: -f1)"
fi
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

# ── 5. Restore supplementary group memberships ─────────────────────

step "Restore supplementary group memberships"
if [[ -n "$M_SUPPLEMENTARY_GROUPS" ]]; then
    # verify each group exists
    IFS=',' read -ra _groups <<< "$M_SUPPLEMENTARY_GROUPS"
    _valid_groups=()
    for g in "${_groups[@]}"; do
        if getent group "$g" &>/dev/null; then
            _valid_groups+=("$g")
        else
            log_info "group '$g' does not exist — skipping"
        fi
    done
    if [[ ${#_valid_groups[@]} -gt 0 ]]; then
        _groups_csv=$(IFS=,; echo "${_valid_groups[*]}")
        log_action "usermod -aG $_groups_csv $M_USERNAME"
        if $FORCE; then
            usermod -aG "$_groups_csv" "$M_USERNAME" 2>/dev/null || {
                _warn "  ${RED}[FAIL]${RESET}  usermod -aG failed"
                set_exit 2
            }
        fi
    else
        log_skip "no valid supplementary groups to restore"
    fi
else
    log_skip "no supplementary groups in manifest"
fi

# ── 6. Restore password hash ──────────────────────────────────────

step "Restore password hash"
if [[ -n "$M_SHADOW_HASH" ]]; then
    log_action "restore password hash from manifest"
    if $FORCE; then
        echo "$M_USERNAME:$M_SHADOW_HASH" | chpasswd -e 2>/dev/null || {
            _warn "  ${RED}[FAIL]${RESET}  chpasswd -e failed"
            set_exit 2
        }
    fi
else
    log_skip "no shadow hash in manifest (set password manually)"
fi

# ── 7. Extract home directory ──────────────────────────────────────

step "Extract home directory from tarball"
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

# ── 8. Restore crontab ────────────────────────────────────────────

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

# ── 9. Restore sudoers fragment ───────────────────────────────────

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

# ── 10. Restore SSH server keys ─────────────────────────────────────

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

# ── 11. Restore AccountsService files ──────────────────────────────

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

# ── 12. Restore subuid/subgid entries ─────────────────────────────

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

# ── 13. Restore revoked SSH keys ──────────────────────────────────

step "Restore revoked SSH keys"
if [[ -n "$M_REVOKED_SSH_KEYS" ]] && $RESTORE_SSH_KEYS; then
    # format: file:base64_line|file:base64_line|...
    IFS='|' read -ra _rsk_entries <<< "$M_REVOKED_SSH_KEYS"
    for entry in "${_rsk_entries[@]}"; do
        _rsk_file="${entry%%:*}"
        _rsk_b64="${entry#*:}"
        _rsk_line=$(echo -n "$_rsk_b64" | base64 -d 2>/dev/null || true)
        if [[ -z "$_rsk_line" ]]; then
            log_info "skipping malformed revoked key entry"
            continue
        fi
        if [[ -f "$_rsk_file" ]]; then
            # avoid duplicates
            if grep -qF "$_rsk_line" "$_rsk_file" 2>/dev/null; then
                log_skip "key already present in $_rsk_file"
            else
                log_action "re-add revoked key to $_rsk_file"
                if $FORCE; then
                    echo "$_rsk_line" >> "$_rsk_file"
                fi
            fi
        else
            log_info "$_rsk_file does not exist — cannot restore key"
        fi
    done
elif [[ -n "$M_REVOKED_SSH_KEYS" ]] && ! $RESTORE_SSH_KEYS; then
    _rsk_count=$(echo "$M_REVOKED_SSH_KEYS" | tr '|' '\n' | wc -l)
    log_info "$_rsk_count revoked SSH key(s) available — use --restore-ssh-keys to re-add"
else
    log_skip "no revoked SSH keys in manifest"
fi

# ── 14. Summary ─────────────────────────────────────────────────────

_echo ""
if $FORCE; then
    case $EXIT_CODE in
        0) _echo "${GREEN}${BOLD}Done. User '$M_USERNAME' has been restored.${RESET}" ;;
        1) _echo "${YELLOW}${BOLD}Done. User '$M_USERNAME' restored with warnings (see above).${RESET}" ;;
        2) _warn "${RED}${BOLD}Done. User '$M_USERNAME' restore completed with errors (see above).${RESET}" ;;
    esac
    _echo ""
    _echo "  ${YELLOW}Next steps:${RESET}"
    if [[ -z "$M_SHADOW_HASH" ]]; then
        _echo "    - Set a password:  ${BOLD}passwd $M_USERNAME${RESET}"
    fi
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
