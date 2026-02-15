#!/usr/bin/env bash
set -euo pipefail

# ── test-roundtrip.sh ────────────────────────────────────────────────
# Round-trip integration test for remove-user.sh + restore-user.sh.
# Runs inside a throwaway container (podman or docker).
#
# Usage:
#   ./test-roundtrip.sh              # auto-detect podman/docker
#   ./test-roundtrip.sh --runtime podman
#   ./test-roundtrip.sh --runtime docker
# ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME=""

# ── colors ──────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

info() { echo -e "  ${CYAN}....${RESET}  $1"; }

# ── parse args ──────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runtime)   RUNTIME="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--runtime podman|docker]"
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# auto-detect runtime
if [[ -z "$RUNTIME" ]]; then
    if command -v podman &>/dev/null; then
        RUNTIME=podman
    elif command -v docker &>/dev/null; then
        RUNTIME=docker
    else
        echo -e "${RED}error:${RESET} no container runtime found (podman or docker required)" >&2
        exit 1
    fi
fi

echo -e "${BOLD}Round-trip integration test (runtime: $RUNTIME)${RESET}"
echo ""

# ── build container ─────────────────────────────────────────────────

CONTAINER_NAME="test-user-roundtrip-$$"
IMAGE_NAME="test-user-roundtrip:latest"
TMPDIR_BUILD=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BUILD"' EXIT

info "Building test container image..."

# Copy scripts into build context
cp "$SCRIPT_DIR"/lib-common.sh "$SCRIPT_DIR"/remove-user.sh "$SCRIPT_DIR"/restore-user.sh "$TMPDIR_BUILD/"

# Write the inner test script to a file (avoids quoting hell with
# single-quoted heredocs embedding single quotes for grep patterns)
cat > "$TMPDIR_BUILD/run-test.sh" <<'INNER_TEST'
#!/bin/bash
set -euo pipefail

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

echo "=== Phase 1: Create test user with full setup ==="

# create user
useradd -m -s /bin/bash -c "Test User,,," -u 1500 -g 1500 testuser 2>/dev/null || \
    (groupadd -g 1500 testuser && useradd -m -s /bin/bash -c "Test User,,," -u 1500 -g 1500 testuser)

# set password
echo "testuser:hunter2" | chpasswd

# supplementary groups
usermod -aG extragroup,devteam testuser

# subuid/subgid
echo "testuser:100000:65536" >> /etc/subuid
echo "testuser:100000:65536" >> /etc/subgid

# crontab
mkdir -p /var/spool/cron/crontabs
echo "*/5 * * * * echo hello" > /var/spool/cron/crontabs/testuser
chown root:crontab /var/spool/cron/crontabs/testuser 2>/dev/null || true
chmod 600 /var/spool/cron/crontabs/testuser

# sudoers fragment
echo "testuser ALL=(ALL) NOPASSWD: /usr/bin/apt" > /etc/sudoers.d/testuser
chmod 440 /etc/sudoers.d/testuser

# SSH server keys dir
mkdir -p /etc/ssh/users/testuser
echo "ssh-ed25519 AAAA_fake_key testuser@host" > /etc/ssh/users/testuser/authorized_keys

# home directory content
mkdir -p /home/testuser/.config/containers/systemd
echo "important data" > /home/testuser/myfile.txt
echo "[Unit]" > /home/testuser/.config/containers/systemd/test.container
chown -R 1500:1500 /home/testuser

# another user with testuser SSH key in authorized_keys (for --revoke-ssh)
useradd -m -s /bin/bash -u 1600 otheruser 2>/dev/null || \
    (groupadd -g 1600 otheruser && useradd -m -s /bin/bash -u 1600 -g 1600 otheruser)
mkdir -p /home/otheruser/.ssh
echo "ssh-ed25519 AAAA_other_key otheruser@host" > /home/otheruser/.ssh/authorized_keys
echo "ssh-ed25519 AAAA_fake_key testuser@host" >> /home/otheruser/.ssh/authorized_keys
chown -R 1600:1600 /home/otheruser

echo ""
echo "=== Phase 1 checks ==="
id testuser &>/dev/null && pass "user testuser exists" || fail "user testuser missing"
[[ -f /home/testuser/myfile.txt ]] && pass "home file exists" || fail "home file missing"
[[ -f /var/spool/cron/crontabs/testuser ]] && pass "crontab exists" || fail "crontab missing"
[[ -f /etc/sudoers.d/testuser ]] && pass "sudoers exists" || fail "sudoers missing"
grep -q "testuser" /etc/subuid && pass "subuid entry exists" || fail "subuid missing"
grep -q "testuser" /etc/subgid && pass "subgid entry exists" || fail "subgid missing"
groups testuser 2>/dev/null | grep -q "extragroup" && pass "supplementary group extragroup" || fail "supplementary group extragroup missing"
groups testuser 2>/dev/null | grep -q "devteam" && pass "supplementary group devteam" || fail "supplementary group devteam missing"
grep -c "testuser" /home/otheruser/.ssh/authorized_keys | grep -q "1" && pass "testuser key in otheruser authorized_keys" || fail "otheruser authorized_keys setup wrong"

# capture shadow hash for later comparison
ORIG_SHADOW=$(getent shadow testuser | cut -d: -f2)

echo ""
echo "=== Phase 2: Remove user ==="
/opt/scripts/remove-user.sh --force -y --save-shadow --revoke-ssh --skip-orphan-scan testuser

echo ""
echo "=== Phase 2 checks ==="
! id testuser &>/dev/null && pass "user testuser removed" || fail "user testuser still exists"
! [[ -d /home/testuser ]] && pass "home directory removed" || fail "home directory still exists"
! [[ -f /var/spool/cron/crontabs/testuser ]] && pass "crontab removed" || fail "crontab still exists"
! [[ -f /etc/sudoers.d/testuser ]] && pass "sudoers removed" || fail "sudoers still exists"
! grep -q "^testuser:" /etc/subuid 2>/dev/null && pass "subuid entry removed" || fail "subuid still present"
! grep -q "^testuser:" /etc/subgid 2>/dev/null && pass "subgid entry removed" || fail "subgid still present"
! [[ -d /etc/ssh/users/testuser ]] && pass "SSH server keys removed" || fail "SSH keys still present"
! grep -qi "testuser" /home/otheruser/.ssh/authorized_keys 2>/dev/null && pass "testuser key revoked from otheruser" || fail "testuser key still in otheruser authorized_keys"

# find the backup tarball
TARBALL=$(ls -t /var/backups/removed-users/testuser_*.tar.gz 2>/dev/null | head -1)
[[ -n "$TARBALL" ]] && pass "backup tarball created: $TARBALL" || { fail "no backup tarball found"; exit 1; }

# verify archive permissions
PERMS=$(stat -c%a "$TARBALL")
[[ "$PERMS" == "600" ]] && pass "archive permissions are 600" || fail "archive permissions are $PERMS (expected 600)"

# verify manifest is in tarball
tar tzf "$TARBALL" | grep -q "\.manifest-" && pass "manifest in tarball" || fail "manifest missing from tarball"

# verify manifest content
MANIFEST_PATH=$(tar tzf "$TARBALL" | grep "\.manifest-" | head -1)
tar xzf "$TARBALL" -C /tmp "$MANIFEST_PATH" 2>/dev/null
MANIFEST="/tmp/$MANIFEST_PATH"

grep -q "^username=testuser$" "$MANIFEST" && pass "manifest: username" || fail "manifest: username wrong"
grep -q "^uid=1500$" "$MANIFEST" && pass "manifest: uid" || fail "manifest: uid wrong"
grep -q "^gid=1500$" "$MANIFEST" && pass "manifest: gid" || fail "manifest: gid wrong"
grep -q "^shell=/bin/bash$" "$MANIFEST" && pass "manifest: shell" || fail "manifest: shell wrong"
grep -q "^subuid=100000:65536$" "$MANIFEST" && pass "manifest: subuid" || fail "manifest: subuid wrong"
grep -q "^subgid=100000:65536$" "$MANIFEST" && pass "manifest: subgid" || fail "manifest: subgid wrong"
grep -q "^supplementary_groups=" "$MANIFEST" && pass "manifest: supplementary_groups field present" || fail "manifest: supplementary_groups missing"
grep -q "^shadow_hash=" "$MANIFEST" && pass "manifest: shadow_hash field present" || fail "manifest: shadow_hash missing"
# verify shadow hash is not empty (--save-shadow was used)
SAVED_HASH=$(grep "^shadow_hash=" "$MANIFEST" | cut -d= -f2-)
[[ -n "$SAVED_HASH" ]] && pass "manifest: shadow hash is non-empty" || fail "manifest: shadow hash is empty"
[[ "$SAVED_HASH" == "$ORIG_SHADOW" ]] && pass "manifest: shadow hash matches original" || fail "manifest: shadow hash mismatch"
grep -q "^revoked_ssh_keys=" "$MANIFEST" && pass "manifest: revoked_ssh_keys field present" || fail "manifest: revoked_ssh_keys missing"
# verify revoked keys is non-empty (--revoke-ssh was used and otheruser had the key)
RSK=$(grep "^revoked_ssh_keys=" "$MANIFEST" | cut -d= -f2-)
[[ -n "$RSK" ]] && pass "manifest: revoked_ssh_keys is non-empty" || fail "manifest: revoked_ssh_keys is empty"

rm -f "$MANIFEST"

echo ""
echo "=== Phase 2b: --list mode ==="
LIST_OUT=$(/opt/scripts/restore-user.sh --list --no-color 2>&1)
echo "$LIST_OUT" | grep -q "testuser" && pass "--list shows testuser" || fail "--list missing testuser"

echo ""
echo "=== Phase 2c: --dry-run-json ==="
# create a temp user to test JSON output
useradd -m -s /bin/bash -u 1700 jsonuser 2>/dev/null || \
    (groupadd -g 1700 jsonuser && useradd -m -s /bin/bash -u 1700 -g 1700 jsonuser)
JSON_OUT=$(/opt/scripts/remove-user.sh --dry-run-json --skip-orphan-scan jsonuser 2>&1) || true
echo "$JSON_OUT" | grep -qF '"user":"jsonuser"' && pass "--dry-run-json user field" || fail "--dry-run-json user field missing"
echo "$JSON_OUT" | grep -qF '"steps":[' && pass "--dry-run-json steps array" || fail "--dry-run-json steps missing"
# clean up json user
userdel -r jsonuser 2>/dev/null || true

echo ""
echo "=== Phase 3: Restore user ==="
/opt/scripts/restore-user.sh --force -y --restore-ssh-keys "$TARBALL"

echo ""
echo "=== Phase 3 checks ==="
id testuser &>/dev/null && pass "user testuser restored" || fail "user testuser not restored"

# uid/gid
[[ "$(id -u testuser)" == "1500" ]] && pass "uid restored to 1500" || fail "uid is $(id -u testuser), expected 1500"
[[ "$(id -g testuser)" == "1500" ]] && pass "gid restored to 1500" || fail "gid is $(id -g testuser), expected 1500"

# shell
RESTORED_SHELL=$(getent passwd testuser | cut -d: -f7)
[[ "$RESTORED_SHELL" == "/bin/bash" ]] && pass "shell restored to /bin/bash" || fail "shell is $RESTORED_SHELL"

# gecos
RESTORED_GECOS=$(getent passwd testuser | cut -d: -f5)
[[ "$RESTORED_GECOS" == "Test User,,," ]] && pass "gecos restored" || fail "gecos is \"$RESTORED_GECOS\""

# home directory
[[ -d /home/testuser ]] && pass "home directory restored" || fail "home directory missing"
[[ -f /home/testuser/myfile.txt ]] && pass "home file myfile.txt restored" || fail "myfile.txt missing"
CONTENT=$(cat /home/testuser/myfile.txt)
[[ "$CONTENT" == "important data" ]] && pass "home file content intact" || fail "home file content: \"$CONTENT\""

# ownership
FILE_OWNER=$(stat -c%u:%g /home/testuser/myfile.txt)
[[ "$FILE_OWNER" == "1500:1500" ]] && pass "home file ownership 1500:1500" || fail "ownership is $FILE_OWNER"

# crontab
[[ -f /var/spool/cron/crontabs/testuser ]] && pass "crontab restored" || fail "crontab not restored"
grep -q "echo hello" /var/spool/cron/crontabs/testuser 2>/dev/null && pass "crontab content intact" || fail "crontab content wrong"

# sudoers
[[ -f /etc/sudoers.d/testuser ]] && pass "sudoers restored" || fail "sudoers not restored"
SUDOERS_PERMS=$(stat -c%a /etc/sudoers.d/testuser)
[[ "$SUDOERS_PERMS" == "440" ]] && pass "sudoers perms 440" || fail "sudoers perms $SUDOERS_PERMS"

# SSH server keys
[[ -d /etc/ssh/users/testuser ]] && pass "SSH server keys dir restored" || fail "SSH keys dir missing"

# subuid/subgid
grep -q "^testuser:100000:65536$" /etc/subuid && pass "subuid restored" || fail "subuid not restored"
grep -q "^testuser:100000:65536$" /etc/subgid && pass "subgid restored" || fail "subgid not restored"

# supplementary groups
groups testuser 2>/dev/null | grep -q "extragroup" && pass "supplementary group extragroup restored" || fail "extragroup not restored"
groups testuser 2>/dev/null | grep -q "devteam" && pass "supplementary group devteam restored" || fail "devteam not restored"

# password hash
RESTORED_SHADOW=$(getent shadow testuser | cut -d: -f2)
[[ "$RESTORED_SHADOW" == "$ORIG_SHADOW" ]] && pass "password hash restored" || fail "password hash mismatch (got: $RESTORED_SHADOW)"

# revoked SSH keys restored to otheruser
grep -q "testuser" /home/otheruser/.ssh/authorized_keys 2>/dev/null && pass "revoked SSH key re-added to otheruser" || fail "revoked SSH key not re-added"

echo ""
echo "=============================="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "=============================="
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
INNER_TEST

cat > "$TMPDIR_BUILD/Dockerfile" <<'DOCKERFILE'
FROM ubuntu:24.04
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        passwd sudo cron procps iproute2 uidmap 2>/dev/null && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /var/backups/removed-users /etc/ssh/users /var/spool/cron/crontabs && \
    groupadd -g 2000 extragroup && \
    groupadd -g 2001 devteam
COPY lib-common.sh remove-user.sh restore-user.sh /opt/scripts/
COPY run-test.sh /opt/scripts/
RUN chmod +x /opt/scripts/*.sh
DOCKERFILE

$RUNTIME build -t "$IMAGE_NAME" "$TMPDIR_BUILD" 2>&1 | while read -r line; do info "$line"; done

# ── run the test inside the container ───────────────────────────────

info "Starting container..."

$RUNTIME run --rm --name "$CONTAINER_NAME" \
    "$IMAGE_NAME" \
    /opt/scripts/run-test.sh 2>&1
CONTAINER_EXIT=$?

echo ""
if [[ "$CONTAINER_EXIT" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All tests passed.${RESET}"
else
    echo -e "${RED}${BOLD}Some tests failed (exit code: $CONTAINER_EXIT).${RESET}"
fi

# cleanup
$RUNTIME rmi "$IMAGE_NAME" &>/dev/null || true

exit "$CONTAINER_EXIT"
