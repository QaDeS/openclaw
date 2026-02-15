#!/usr/bin/env bash
set -euo pipefail

# ── remove-user.sh ──────────────────────────────────────────────────
# Completely remove a user and all traces from the system.
# Dry-run by default; pass --force to actually execute.
# ────────────────────────────────────────────────────────────────────

FORCE=false
TARGET_USER=""
BACKUP_HOME=true
BACKUP_DIR="/var/backups/removed-users"
KEEP_KEYS=false
SKIP_ORPHAN_SCAN=false
REVOKE_SSH=false
NUKE_ORPHANS=false
DRY_RUN_JSON=false
SAVE_SHADOW=false
QUIET=false
LOG_FILE=""
NO_COLOR=false
CONFIRM=true

EXIT_CODE=0  # 0=clean, 1=warnings, 2=errors
STEP=0

# ── source shared helpers ──────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

# ── JSON / dry-run-json overrides ──────────────────────────────────
# Override step/log_action/warn_manual to feed JSON when in JSON mode.

_orig_step() { command true; }  # placeholder
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

JSON_STEPS=()
_json_cur_actions=()
_json_cur_warnings=()
_json_cur_title=""

json_step() {
    _json_flush_step
    _json_cur_title="$1"
    _json_cur_actions=()
    _json_cur_warnings=()
}

_json_flush_step() {
    [[ -n "${_json_cur_title:-}" ]] || return 0
    local actions="" warnings=""
    for a in "${_json_cur_actions[@]+"${_json_cur_actions[@]}"}"; do
        [[ -n "$actions" ]] && actions+=","
        actions+="\"$(_json_escape "$a")\""
    done
    for w in "${_json_cur_warnings[@]+"${_json_cur_warnings[@]}"}"; do
        [[ -n "$warnings" ]] && warnings+=","
        warnings+="\"$(_json_escape "$w")\""
    done
    local entry
    entry="{\"step\":${#JSON_STEPS[@]},\"title\":\"$(_json_escape "$_json_cur_title")\",\"actions\":[$actions],\"warnings\":[$warnings]}"
    JSON_STEPS+=("$entry")
    _json_cur_title=""
}

json_action() { _json_cur_actions+=("$1"); }
json_warn()   { _json_cur_warnings+=("$1"); }

json_emit() {
    _json_flush_step
    local steps=""
    for s in "${JSON_STEPS[@]+"${JSON_STEPS[@]}"}"; do
        [[ -n "$steps" ]] && steps+=","
        steps+="$s"
    done
    printf '{"user":"%s","uid":%d,"steps":[%s]}\n' \
        "$(_json_escape "$TARGET_USER")" "$UID_NUM" "$steps"
}

# apply JSON overrides (called after arg parsing when DRY_RUN_JSON is known)
_apply_json_overrides() {
    step() {
        STEP=$((STEP + 1))
        if $DRY_RUN_JSON; then
            json_step "$1"
        else
            _echo "${BOLD}${STEP}. $1${RESET}"
        fi
    }
    log_action() {
        local label="$1"
        if $DRY_RUN_JSON; then
            json_action "$label"
        elif $FORCE; then
            _echo "  ${GREEN}[EXEC]${RESET}  $label"
        else
            _echo "  ${YELLOW}[DRY]${RESET}   $label"
        fi
    }
    warn_manual() {
        if $DRY_RUN_JSON; then
            json_warn "$1"
        else
            _warn "  ${YELLOW}[WARN]${RESET}  $1"
        fi
        set_exit 1
    }
}

# ── usage ───────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: remove-user.sh [OPTIONS] <username>

Completely remove a user and all traces from the system.

By default runs in DRY-RUN mode, printing every action it would take
without modifying anything. Pass --force to actually execute.

Arguments:
  <username>            The user account to remove

Options:
  --force               Execute the removal (default: dry-run)
  --no-backup           Skip archiving before deletion
                        (default: backup to /var/backups/removed-users/)
  --backup-dir DIR      Custom backup destination
  --keep-keys           Preserve /etc/ssh/users/<user>/ so that re-adding
                        the user restores SSH access with the same keys
  --skip-orphan-scan    Skip the final filesystem-wide orphan scan
                        (can be slow on large filesystems)
  --revoke-ssh          Remove lines mentioning the target user from other
                        users' authorized_keys (default: report-only).
                        Revoked lines are saved in the manifest for restore.
  --nuke-orphans        Delete all orphaned files owned by the uid after
                        removal (default: report-only)
  --save-shadow         Save the password hash from /etc/shadow in the
                        manifest (sensitive; opt-in only)
  --dry-run-json        Output a machine-readable JSON plan to stdout and
                        exit (implies dry-run, suppresses normal output)
  --yes, -y             Skip the interactive confirmation prompt
  --log FILE            Write full output (ANSI-stripped) to FILE
  --quiet, -q           Only print warnings and errors
  --no-color            Disable colored output
  -h, --help            Show this help message

Steps (in order):
  - Back up all user artifacts (home, crontabs, sudoers, SSH keys,
    AccountsService, etc.) into a single tarball with metadata manifest
  - Kill processes, clean IPC objects
  - Remove crontabs, at jobs, systemd units/timers, loginctl sessions
  - Remove temp files, print jobs, XDG runtime dir
  - Remove container rootless data, quadlet units
  - Remove subuid/subgid entries, sudoers, AccountsService data
  - Remove /etc/ssh/users/<user>/ (unless --keep-keys)
  - Remove user account + home + mail spool (userdel -r)
  - Remove primary group if empty
  - Report orphaned files (unless --skip-orphan-scan)

Exit codes:
  0   Clean removal (or dry run), no issues
  1   Completed with warnings (manual review items found)
  2   Errors encountered during removal

Examples:
  # See what would happen:
  sudo ./remove-user.sh testuser

  # Actually remove the user:
  sudo ./remove-user.sh --force testuser

  # Remove without backing up home:
  sudo ./remove-user.sh --force --no-backup testuser

  # Remove user but keep SSH keys for future re-add:
  sudo ./remove-user.sh --force --keep-keys testuser

  # Remove with audit log, no prompts:
  sudo ./remove-user.sh --force -y --log /var/log/remove-testuser.log testuser

  # Machine-readable plan (JSON to stdout):
  sudo ./remove-user.sh --dry-run-json testuser

  # Remove and also revoke SSH keys from other users:
  sudo ./remove-user.sh --force --revoke-ssh testuser

  # Remove and delete all orphaned files:
  sudo ./remove-user.sh --force --nuke-orphans testuser

  # Preserve password hash for seamless restore:
  sudo ./remove-user.sh --force --save-shadow testuser
EOF
}

# ── parse args ──────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)           usage; exit 0 ;;
        --force)             FORCE=true; shift ;;
        --no-backup)         BACKUP_HOME=false; shift ;;
        --keep-keys)         KEEP_KEYS=true; shift ;;
        --skip-orphan-scan)  SKIP_ORPHAN_SCAN=true; shift ;;
        --revoke-ssh)        REVOKE_SSH=true; shift ;;
        --nuke-orphans)      NUKE_ORPHANS=true; shift ;;
        --save-shadow)       SAVE_SHADOW=true; shift ;;
        --dry-run-json)      DRY_RUN_JSON=true; QUIET=true; NO_COLOR=true; shift ;;
        --yes|-y)            CONFIRM=false; shift ;;
        --quiet|-q)          QUIET=true; shift ;;
        --no-color)          NO_COLOR=true; shift ;;
        --log)
            [[ -n "${2:-}" ]] || die "--log requires an argument"
            LOG_FILE="$2"; shift 2 ;;
        --backup-dir)
            [[ -n "${2:-}" ]] || die "--backup-dir requires an argument"
            BACKUP_DIR="$2"; shift 2 ;;
        -*)                  die "unknown option: $1" ;;
        *)
            [[ -z "$TARGET_USER" ]] || die "unexpected argument: $1"
            TARGET_USER="$1"; shift ;;
    esac
done

setup_colors
_apply_json_overrides

[[ -n "$TARGET_USER" ]] || { usage; exit 1; }
[[ $(id -u) -eq 0 ]] || die "must run as root"

# ── validate username ───────────────────────────────────────────────

if [[ "$TARGET_USER" == "root" ]]; then
    die "refusing to remove root"
fi

if ! [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    die "invalid username: '$TARGET_USER' (must match ^[a-z_][a-z0-9_-]*\$)"
fi

id "$TARGET_USER" &>/dev/null || die "user '$TARGET_USER' does not exist"

if $DRY_RUN_JSON && $FORCE; then
    die "--dry-run-json and --force are mutually exclusive"
fi

UID_NUM=$(id -u "$TARGET_USER")
GID_NUM=$(id -g "$TARGET_USER")
GROUP_NAME=$(getent group "$GID_NUM" | cut -d: -f1 || true)
PASSWD_ENTRY=$(getent passwd "$TARGET_USER")
HOME_DIR=$(echo "$PASSWD_ENTRY" | cut -d: -f6)
USER_SHELL=$(echo "$PASSWD_ENTRY" | cut -d: -f7)
USER_GECOS=$(echo "$PASSWD_ENTRY" | cut -d: -f5)

# supplementary groups (comma-separated list, excluding the primary group)
SUPP_GROUPS=$(id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -v "^${GROUP_NAME}$" | paste -sd, || true)

# ── validate backup dir early ──────────────────────────────────────

if $BACKUP_HOME; then
    if $FORCE; then
        mkdir -p "$BACKUP_DIR" 2>/dev/null || die "cannot create backup dir: $BACKUP_DIR"
        [[ -w "$BACKUP_DIR" ]] || die "backup dir is not writable: $BACKUP_DIR"
    fi
fi

# ── validate log file early ────────────────────────────────────────

if [[ -n "$LOG_FILE" ]]; then
    log_dir=$(dirname "$LOG_FILE")
    [[ -d "$log_dir" && -w "$log_dir" ]] || die "log directory is not writable: $log_dir"
    : > "$LOG_FILE" || die "cannot write to log file: $LOG_FILE"
    _log_raw "remove-user.sh — $(date -Iseconds) — target: $TARGET_USER (uid=$UID_NUM)"
    _log_raw "arguments: force=$FORCE backup=$BACKUP_HOME keep_keys=$KEEP_KEYS revoke_ssh=$REVOKE_SSH nuke_orphans=$NUKE_ORPHANS save_shadow=$SAVE_SHADOW"
    _log_raw "---"
fi

# ── header ──────────────────────────────────────────────────────────

if ! $DRY_RUN_JSON; then
    _echo ""
    if $FORCE; then
        _echo "${RED}${BOLD}=== REMOVING USER: $TARGET_USER (uid=$UID_NUM) ===${RESET}"
    else
        _echo "${CYAN}${BOLD}=== DRY RUN: $TARGET_USER (uid=$UID_NUM) ===${RESET}"
        _echo "${CYAN}    No changes will be made. Pass --force to execute.${RESET}"
    fi
    _echo ""
fi

# ── confirmation gate (--force only) ────────────────────────────────

if $FORCE && $CONFIRM; then
    echo -en "${RED}${BOLD}Type YES to confirm removal of user '$TARGET_USER': ${RESET}"
    read -r answer
    if [[ "$answer" != "YES" ]]; then
        echo "Aborted."
        exit 1
    fi
    echo ""
fi

# ── 1. comprehensive backup ────────────────────────────────────────

step "Backup user artifacts"
_revoked_keys_list=""
if $BACKUP_HOME; then
    archive="$BACKUP_DIR/${TARGET_USER}_$(date +%Y%m%d_%H%M%S).tar.gz"
    manifest_tmp="$BACKUP_DIR/.manifest-${TARGET_USER}"

    # collect all paths that exist into a file list
    backup_list=$(mktemp)
    trap 'rm -f "$backup_list" "$manifest_tmp"' EXIT

    for p in \
        "$HOME_DIR" \
        "/var/spool/cron/crontabs/$TARGET_USER" \
        "/var/spool/cron/$TARGET_USER" \
        "/etc/sudoers.d/$TARGET_USER" \
        "/etc/ssh/users/$TARGET_USER" \
        "/var/lib/AccountsService/users/$TARGET_USER" \
        "/var/lib/AccountsService/icons/$TARGET_USER" \
        "/var/mail/$TARGET_USER" \
        "/var/spool/mail/$TARGET_USER" \
    ; do
        if [[ -e "$p" ]]; then
            echo "${p#/}" >> "$backup_list"
            log_info "backup: $p"
        fi
    done

    # pre-scan: gather revoked SSH key lines (read-only) before backup
    _revoked_keys_list=""
    if $REVOKE_SSH; then
        while IFS=: read -r _ _ _uid _ _ _hdir _; do
            [[ "$_uid" -ge 1000 && "$_uid" != "$UID_NUM" ]] || continue
            _ak="$_hdir/.ssh/authorized_keys"
            if [[ -f "$_ak" ]] && grep -qi "$TARGET_USER" "$_ak" 2>/dev/null; then
                _revoked_lines=$(grep -i "$TARGET_USER" "$_ak" 2>/dev/null || true)
                if [[ -n "$_revoked_lines" ]]; then
                    while IFS= read -r _rline; do
                        _encoded=$(echo -n "$_rline" | base64 -w0)
                        [[ -n "$_revoked_keys_list" ]] && _revoked_keys_list+="|"
                        _revoked_keys_list+="${_ak}:${_encoded}"
                    done <<< "$_revoked_lines"
                fi
            fi
        done < /etc/passwd
    fi

    # gather manifest metadata (needed for both dry-run display and actual write)
    _sub_uid=""
    _sub_gid=""
    if [[ -f /etc/subuid ]]; then
        _sub_uid=$(grep "^${TARGET_USER}:" /etc/subuid 2>/dev/null | head -1 | cut -d: -f2-3 || true)
    fi
    if [[ -f /etc/subgid ]]; then
        _sub_gid=$(grep "^${TARGET_USER}:" /etc/subgid 2>/dev/null | head -1 | cut -d: -f2-3 || true)
    fi

    _shadow_hash=""
    if $SAVE_SHADOW && [[ -f /etc/shadow ]]; then
        _shadow_hash=$(getent shadow "$TARGET_USER" 2>/dev/null | cut -d: -f2 || true)
    fi

    _linger="false"
    if [[ -f "/var/lib/systemd/linger/$TARGET_USER" ]]; then
        _linger="true"
    fi

    # show manifest metadata
    log_action "write metadata manifest for restore"
    log_info "manifest: user=$TARGET_USER uid=$UID_NUM gid=$GID_NUM group=$GROUP_NAME"
    log_info "manifest: shell=$USER_SHELL home=$HOME_DIR"
    [[ -z "$USER_GECOS" ]]  || log_info "manifest: gecos=$USER_GECOS"
    [[ -z "$SUPP_GROUPS" ]] || log_info "manifest: supplementary_groups=$SUPP_GROUPS"
    [[ -z "$_sub_uid" ]]    || log_info "manifest: subuid=$_sub_uid"
    [[ -z "$_sub_gid" ]]    || log_info "manifest: subgid=$_sub_gid"
    [[ -z "$_shadow_hash" ]]|| log_info "manifest: shadow_hash=(saved)"
    [[ "$_linger" != "true" ]] || log_info "manifest: linger=true"
    [[ -z "$_revoked_keys_list" ]] || log_info "manifest: revoked_ssh_keys=($(echo "$_revoked_keys_list" | tr '|' '\n' | wc -l) entries)"

    if $FORCE; then
        cat > "$manifest_tmp" <<MANIFEST
# remove-user manifest v1
username=$TARGET_USER
uid=$UID_NUM
gid=$GID_NUM
group=$GROUP_NAME
shell=$USER_SHELL
gecos=$USER_GECOS
home=$HOME_DIR
keep_keys=$KEEP_KEYS
subuid=$_sub_uid
subgid=$_sub_gid
supplementary_groups=$SUPP_GROUPS
shadow_hash=$_shadow_hash
linger=$_linger
revoked_ssh_keys=$_revoked_keys_list
removed_at=$(date -Iseconds)
MANIFEST
        echo "${manifest_tmp#/}" >> "$backup_list"
    fi

    # create tarball immediately (before any destructive steps)
    entry_count=$(wc -l < "$backup_list")
    if [[ "$entry_count" -gt 0 ]]; then
        # build a comma-separated summary of the backed-up root paths
        _backup_summary=$(sed 's|^|/|' "$backup_list" | paste -sd, | sed 's/,/, /g')
        log_action "tar czf $archive — ${_backup_summary}"
        if $FORCE; then
            if tar czf "$archive" -C / -T "$backup_list" 2>/dev/null; then
                chmod 600 "$archive"
                archive_size=$(stat -c%s "$archive" 2>/dev/null || stat -f%z "$archive" 2>/dev/null || echo "?")
                _echo "  ${GREEN}backed up to $archive ($archive_size bytes)${RESET}"
            else
                _warn "  ${RED}[FAIL]${RESET}  backup failed — aborting to prevent data loss"
                rm -f "$backup_list" "$manifest_tmp"
                exit 2
            fi
        fi
    else
        log_skip "no files to back up"
    fi

    rm -f "$backup_list" "$manifest_tmp"
    trap - EXIT
else
    log_skip "skipped — --no-backup was set"
fi

# ── kill running processes ──────────────────────────────────────────

step "Processes"
procs=$(ps -u "$UID_NUM" -o pid=,comm= 2>/dev/null || true)
if [[ -n "$procs" ]]; then
    while read -r pid comm; do
        log_action "kill -TERM $pid ($comm)"
    done <<< "$procs"
    if $FORCE; then
        pkill -TERM -u "$UID_NUM" 2>/dev/null || true
        sleep 2
        pkill -KILL -u "$UID_NUM" 2>/dev/null || true
        # retry loop: ensure all processes are dead before userdel
        for _attempt in 1 2 3; do
            remaining=$(ps -u "$UID_NUM" 2>/dev/null | wc -l) || true
            if [[ "$remaining" -le 1 ]]; then break; fi
            pkill -KILL -u "$UID_NUM" 2>/dev/null || true
            sleep 1
        done
    fi
else
    log_skip "no running processes"
fi

# ── IPC objects ─────────────────────────────────────────────────────

step "IPC objects"
has_ipc=false
for type in -m -s -q; do
    ids=$(ipcs "$type" -p 2>/dev/null | awk -v uid="$UID_NUM" '$3 == uid {print $1}' || true)
    if [[ -n "$ids" ]]; then
        has_ipc=true
        for ipc_id in $ids; do
            run ipcrm "$type" "$ipc_id"
        done
    fi
done
if ! $has_ipc; then log_skip "no IPC objects"; fi

# ── crontabs ────────────────────────────────────────────────────────

step "Crontabs"
if [[ -f "/var/spool/cron/crontabs/$TARGET_USER" ]]; then
    run rm -f "/var/spool/cron/crontabs/$TARGET_USER"
elif [[ -f "/var/spool/cron/$TARGET_USER" ]]; then
    run rm -f "/var/spool/cron/$TARGET_USER"
else
    log_skip "no user crontab"
fi

# system cron references
for f in /etc/cron.d/* /etc/crontab; do
    [[ -f "$f" ]] || continue
    if grep -q "\\b${TARGET_USER}\\b" "$f" 2>/dev/null; then
        warn_manual "found reference in $f (manual review recommended)"
    fi
done

# ── at jobs ─────────────────────────────────────────────────────────

step "at(1) jobs"
if command -v atq &>/dev/null; then
    at_jobs=$(atq 2>/dev/null | awk -v u="$TARGET_USER" '$NF == u {print $1}' || true)
    if [[ -n "$at_jobs" ]]; then
        for job in $at_jobs; do
            run atrm "$job"
        done
    else
        log_skip "no at jobs"
    fi
else
    log_skip "atq not available"
fi

# ── systemd user units, timers & lingering ──────────────────────────

step "systemd user services, timers & lingering"

# stop running user timers/services before removing files
if $FORCE && command -v systemctl &>/dev/null; then
    systemctl stop "user@${UID_NUM}.service" 2>/dev/null || true
fi

user_systemd="$HOME_DIR/.config/systemd/user"
if [[ -d "$user_systemd" ]]; then
    run rm -rf "$user_systemd"
else
    log_skip "no user systemd units"
fi

# quadlet units
quadlet_dir="$HOME_DIR/.config/containers/systemd"
if [[ -d "$quadlet_dir" ]]; then
    run rm -rf "$quadlet_dir"
else
    log_skip "no quadlet units"
fi

if [[ -f "/var/lib/systemd/linger/$TARGET_USER" ]]; then
    log_action "disable linger for $TARGET_USER"
    if $FORCE; then
        if ! loginctl disable-linger "$TARGET_USER" 2>/dev/null; then
            # fallback: remove the linger file directly (works without systemd)
            rm -f "/var/lib/systemd/linger/$TARGET_USER"
        fi
    fi
else
    log_skip "lingering not enabled"
fi

# ── loginctl sessions ──────────────────────────────────────────────

step "loginctl sessions"
sessions=$(loginctl list-sessions --no-legend 2>/dev/null \
    | awk -v u="$TARGET_USER" '$3 == u {print $1}' || true)
if [[ -n "$sessions" ]]; then
    for sess in $sessions; do
        run loginctl terminate-session "$sess"
    done
else
    log_skip "no active sessions"
fi

# ── temp files ──────────────────────────────────────────────────────

step "Temp files (/tmp, /var/tmp)"
tmp_count=$(find /tmp /var/tmp -user "$TARGET_USER" -maxdepth 3 2>/dev/null | wc -l || echo 0)
if [[ "$tmp_count" -gt 0 ]]; then
    log_action "remove $tmp_count file(s) owned by $TARGET_USER in /tmp and /var/tmp"
    if $FORCE; then
        find /tmp /var/tmp -user "$TARGET_USER" -maxdepth 3 -delete 2>/dev/null || true
    fi
else
    log_skip "no temp files"
fi

# ── CUPS print jobs ─────────────────────────────────────────────────

step "CUPS print jobs"
if command -v lpstat &>/dev/null; then
    cups_jobs=$(lpstat -u "$TARGET_USER" 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$cups_jobs" ]]; then
        for job in $cups_jobs; do
            run cancel "$job"
        done
    else
        log_skip "no print jobs"
    fi
else
    log_skip "CUPS not available"
fi

# ── XDG runtime dir ─────────────────────────────────────────────────

step "XDG runtime directory"
xdg_dir="/run/user/$UID_NUM"
if [[ -d "$xdg_dir" ]]; then
    run rm -rf "$xdg_dir"
else
    log_skip "no XDG runtime dir"
fi

# ── podman/docker rootless data ─────────────────────────────────────

step "Container rootless data"
found_containers=false
for d in "$HOME_DIR/.local/share/containers" "$HOME_DIR/.local/share/docker"; do
    if [[ -d "$d" ]]; then
        found_containers=true
        run rm -rf "$d"
    fi
done
if ! $found_containers; then log_skip "no rootless container data"; fi

# ── subuid / subgid ─────────────────────────────────────────────────

step "/etc/subuid and /etc/subgid"
for f in /etc/subuid /etc/subgid; do
    if [[ -f "$f" ]] && grep -q "^${TARGET_USER}:" "$f" 2>/dev/null; then
        remove_line_from_file "$TARGET_USER" "$f"
    else
        log_skip "no entry in $f"
    fi
done

# ── sudoers fragments ──────────────────────────────────────────────

step "Sudoers"
sudoers_frag="/etc/sudoers.d/$TARGET_USER"
if [[ -f "$sudoers_frag" ]]; then
    run rm -f "$sudoers_frag"
else
    log_skip "no /etc/sudoers.d/$TARGET_USER"
fi
if grep -q "\\b${TARGET_USER}\\b" /etc/sudoers 2>/dev/null; then
    warn_manual "found reference in /etc/sudoers (manual edit with visudo recommended)"
fi

# ── AccountsService ─────────────────────────────────────────────────

step "AccountsService"
found_acct=false
for f in "/var/lib/AccountsService/users/$TARGET_USER" \
         "/var/lib/AccountsService/icons/$TARGET_USER"; do
    if [[ -e "$f" ]]; then
        found_acct=true
        run rm -f "$f"
    fi
done
if ! $found_acct; then log_skip "no AccountsService data"; fi

# ── NetworkManager / polkit per-user rules ──────────────────────────

step "NetworkManager & polkit per-user rules"
found_nm=false
for d in /etc/NetworkManager/system-connections /etc/polkit-1/localauthority.conf.d \
         /etc/polkit-1/localauthority /var/lib/polkit-1/localauthority; do
    [[ -d "$d" ]] || continue
    matches=$(grep -rl "\\b${TARGET_USER}\\b" "$d" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
        found_nm=true
        while read -r f; do
            warn_manual "$f references '$TARGET_USER' — review manually"
        done <<< "$matches"
    fi
done
if ! $found_nm; then log_skip "no per-user NetworkManager/polkit rules"; fi

# ── SSH authorized_keys references elsewhere ────────────────────────

if $REVOKE_SSH; then
    step "SSH key references (revoking)"
else
    step "SSH key references (informational)"
fi
found_ssh=false
while IFS=: read -r _ _ uid _ _ hdir _; do
    [[ "$uid" -ge 1000 && "$uid" != "$UID_NUM" ]] || continue
    ak="$hdir/.ssh/authorized_keys"
    if [[ -f "$ak" ]] && grep -qi "$TARGET_USER" "$ak" 2>/dev/null; then
        found_ssh=true
        if $REVOKE_SSH; then
            log_action "remove lines mentioning '$TARGET_USER' from $ak"
            if $FORCE; then
                local_tmp=$(mktemp)
                grep -vi "$TARGET_USER" "$ak" > "$local_tmp" || true
                cat "$local_tmp" > "$ak"
                rm -f "$local_tmp"
            fi
        else
            warn_manual "$ak mentions '$TARGET_USER' — review manually (use --revoke-ssh to auto-remove)"
        fi
    fi
done < /etc/passwd
if ! $found_ssh; then log_skip "no references found"; fi

# ── SSH server keys (/etc/ssh/users/<user>) ─────────────────────────

step "SSH server keys (/etc/ssh/users/$TARGET_USER)"
ssh_user_dir="/etc/ssh/users/$TARGET_USER"
if [[ -d "$ssh_user_dir" ]]; then
    if $KEEP_KEYS; then
        log_keep "$ssh_user_dir (--keep-keys: preserved for future re-add)"
    else
        run rm -rf "$ssh_user_dir"
    fi
else
    log_skip "no $ssh_user_dir directory"
fi

# ── faillog / lastlog entries ───────────────────────────────────────

step "faillog & lastlog"
cleaned_login=false
if command -v faillog &>/dev/null; then
    log_action "faillog -r -u $TARGET_USER (reset failure count)"
    if $FORCE; then
        faillog -r -u "$TARGET_USER" 2>/dev/null || true
    fi
    cleaned_login=true
fi
if [[ -f /var/log/lastlog ]]; then
    log_info "lastlog entry will become orphaned (uid $UID_NUM) — cosmetic only"
fi
if ! $cleaned_login; then log_skip "faillog not available"; fi

# ── remove user account + home + mail ───────────────────────────────

step "Remove user account"
log_action "userdel -r $TARGET_USER"
if $FORCE; then
    _userdel_ok=false
    for _attempt in 1 2 3; do
        if userdel -r "$TARGET_USER" 2>/dev/null; then
            _userdel_ok=true
            break
        fi
        _warn "  ${YELLOW}[RETRY]${RESET} userdel failed (attempt $_attempt/3), killing stragglers..."
        pkill -KILL -u "$UID_NUM" 2>/dev/null || true
        sleep 2
    done
    if ! $_userdel_ok; then
        _warn "  ${RED}[FAIL]${RESET}  userdel -r $TARGET_USER failed after 3 attempts"
        set_exit 2
    fi
fi

# ── remove primary group if empty ───────────────────────────────────

step "Remove primary group"
if [[ -n "$GROUP_NAME" ]] && getent group "$GROUP_NAME" &>/dev/null; then
    members=$(getent group "$GROUP_NAME" | cut -d: -f4)
    if [[ -z "$members" ]]; then
        run groupdel "$GROUP_NAME"
    else
        log_skip "group '$GROUP_NAME' has other members: $members — keeping"
    fi
else
    log_skip "group already removed by userdel or does not exist"
fi

# ── leftover files owned by uid ─────────────────────────────────────

step "Orphaned files owned by uid $UID_NUM"
if $SKIP_ORPHAN_SCAN; then
    log_skip "skipped — --skip-orphan-scan was set"
else
    # build exclusion list (always exclude /proc, /sys; add SSH keys dir when --keep-keys)
    _find_excludes=( -not -path "/proc/*" -not -path "/sys/*" )
    if $KEEP_KEYS && [[ -d "$ssh_user_dir" ]]; then
        _find_excludes+=( -not -path "${ssh_user_dir}/*" -not -path "$ssh_user_dir" )
    fi

    orphans=$(find / -xdev -uid "$UID_NUM" \
        "${_find_excludes[@]}" \
        2>/dev/null || true)
    if [[ -n "$orphans" ]]; then
        _orphan_summary=$(echo "$orphans" | paste -sd, | sed 's/,/, /g')
        count=$(echo "$orphans" | wc -l)
        log_info "${count} orphaned file(s): ${_orphan_summary}"
        if $NUKE_ORPHANS; then
            log_action "delete all files owned by uid $UID_NUM"
            if $FORCE; then
                find / -xdev -uid "$UID_NUM" \
                    "${_find_excludes[@]}" \
                    -delete 2>/dev/null || true
            fi
        else
            warn_manual "orphaned files remain — run: find / -xdev -uid $UID_NUM -delete (or use --nuke-orphans)"
        fi
    else
        log_skip "no orphaned files"
    fi
fi

# ── summary ─────────────────────────────────────────────────────────

if $DRY_RUN_JSON; then
    json_emit
else
    _echo ""
    if $FORCE; then
        case $EXIT_CODE in
            0) _echo "${GREEN}${BOLD}Done. User '$TARGET_USER' has been removed cleanly.${RESET}" ;;
            1) _warn "${YELLOW}${BOLD}Done. User '$TARGET_USER' removed with warnings (review items above).${RESET}" ;;
            2) _warn "${RED}${BOLD}Done. User '$TARGET_USER' removal completed with errors (see above).${RESET}" ;;
        esac
    else
        _echo "${CYAN}${BOLD}Dry run complete. No changes were made.${RESET}"
        _echo "${CYAN}Re-run with --force to execute the above actions.${RESET}"
    fi

    if [[ -n "$LOG_FILE" ]]; then
        _log_raw "---"
        _log_raw "exit code: $EXIT_CODE"
        _echo "  Log written to ${BOLD}$LOG_FILE${RESET}"
    fi
fi

exit "$EXIT_CODE"
