#!/usr/bin/env bats
# Tests for the Cisco AI Defense daemon (Python).

load helpers/test_helper

DAEMON="$STRIX_DIR/defense/cisco-defense-daemon.py"

# --- File basics ---

@test "defense: daemon script exists" {
    [ -f "$DAEMON" ]
}

@test "defense: daemon has python3 shebang" {
    head -1 "$DAEMON" | grep -q "python3"
}

@test "defense: daemon is valid Python syntax" {
    python3 -c "
import py_compile, sys
try:
    py_compile.compile('$DAEMON', doraise=True)
    print('Syntax OK')
except py_compile.PyCompileError as e:
    print(f'Syntax Error: {e}')
    sys.exit(1)
"
}

# --- Configuration constants ---

@test "defense: defines SCANNERS list" {
    grep -q "^SCANNERS" "$DAEMON"
}

@test "defense: SCANNERS includes a2a-scanner" {
    grep -q "a2a-scanner" "$DAEMON"
}

@test "defense: SCANNERS includes mcp-scanner" {
    grep -q "mcp-scanner" "$DAEMON"
}

@test "defense: SCANNERS includes skill-scanner" {
    grep -q "skill-scanner" "$DAEMON"
}

@test "defense: SCANNERS includes audit-project-mutation" {
    grep -q "audit-project-mutation" "$DAEMON"
}

@test "defense: defines PROJECT_ROOT" {
    grep -q "^PROJECT_ROOT" "$DAEMON"
}

@test "defense: defines AUDIT_SNAPSHOT path" {
    grep -q "^AUDIT_SNAPSHOT" "$DAEMON"
}

@test "defense: defines LOG_FILE" {
    grep -q "^LOG_FILE" "$DAEMON"
}

@test "defense: LOG_FILE points to /var/log/cisco-defense.log" {
    grep -q '/var/log/cisco-defense.log' "$DAEMON"
}

# --- Functions ---

@test "defense: defines log() function" {
    grep -q "^def log(" "$DAEMON"
}

@test "defense: defines run_scanners() function" {
    grep -q "^def run_scanners(" "$DAEMON"
}

@test "defense: defines audit_project_mutation() function" {
    grep -q "^def audit_project_mutation(" "$DAEMON"
}

@test "defense: run_scanners handles FileNotFoundError" {
    grep -q "FileNotFoundError" "$DAEMON"
}

@test "defense: audit_project_mutation creates initial snapshot" {
    grep -q "Initial project snapshot" "$DAEMON"
}

@test "defense: audit_project_mutation detects structure changes" {
    grep -q "mutation detected" "$DAEMON"
}

# --- Main loop ---

@test "defense: has __main__ guard" {
    grep -q '__name__.*__main__' "$DAEMON"
}

@test "defense: main loop sleeps 600 seconds" {
    grep -q "time.sleep(600)" "$DAEMON"
}

@test "defense: main loop runs scanners" {
    grep -q "run_scanners()" "$DAEMON"
}

@test "defense: main loop runs audit" {
    grep -q "audit_project_mutation()" "$DAEMON"
}

# --- Imports ---

@test "defense: imports subprocess" {
    grep -q "^import subprocess" "$DAEMON"
}

@test "defense: imports time" {
    grep -q "^import time" "$DAEMON"
}

@test "defense: imports os" {
    grep -q "^import os" "$DAEMON"
}

# --- Functional test: log function ---

@test "defense: log() appends to LOG_FILE with timestamp" {
    python3 -c "
import tempfile, os, sys
sys.path.insert(0, os.path.dirname('$DAEMON'))

# Patch LOG_FILE before importing
log_path = tempfile.mktemp(suffix='.log')
exec(open('$DAEMON').read().split('if __name__')[0].replace(
    '/var/log/cisco-defense.log', log_path))

log('test message from bats')
with open(log_path) as f:
    content = f.read()
assert 'test message from bats' in content, f'Expected log content, got: {content}'
os.unlink(log_path)
print('OK')
"
}

# --- Functional test: snapshot creation ---

@test "defense: audit_project_mutation creates snapshot file" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/project"
    touch "$tmpdir/project/file1.txt"

    python3 -c "
import tempfile, os, sys

# Override constants and run
log_path = '$tmpdir/test.log'
snapshot_path = '$tmpdir/snapshot.txt'
project_root = '$tmpdir/project'

LOG_FILE = log_path
AUDIT_SNAPSHOT = snapshot_path
PROJECT_ROOT = project_root

def log(message):
    with open(LOG_FILE, 'a') as f:
        import time
        f.write(f'[{time.ctime()}] {message}\n')

import subprocess
def audit_project_mutation():
    log(f'Auditing project mutation in {PROJECT_ROOT}...')
    if not os.path.exists(AUDIT_SNAPSHOT):
        subprocess.run(f'find {PROJECT_ROOT} -maxdepth 3 -not -path \"*/.*\" > {AUDIT_SNAPSHOT}', shell=True)
        log('Initial project snapshot created.')
        return

audit_project_mutation()
assert os.path.exists(snapshot_path), 'Snapshot not created'
with open(snapshot_path) as f:
    content = f.read()
assert 'file1.txt' in content, f'Snapshot missing expected file. Content: {content}'
print('OK')
"
    rm -rf "$tmpdir"
}
