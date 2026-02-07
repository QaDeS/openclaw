#!/usr/bin/env python3
import subprocess
import time
import os

# Scanners to run periodically
SCANNERS = [
    ["a2a-scanner", "scan-network"],
    ["mcp-scanner", "scan-endpoints"],
    ["skill-scanner", "audit-skills"],
    ["audit-project-mutation"]
]

PROJECT_ROOT = "/Projects/clawd/openclaw"
AUDIT_SNAPSHOT = "/home/defense/project_snapshot.txt"

LOG_FILE = "/var/log/cisco-defense.log"

def log(message):
    with open(LOG_FILE, "a") as f:
        f.write(f"[{time.ctime()}] {message}\n")

def run_scanners():
    for cmd in SCANNERS:
        try:
            log(f"Running scanner: {' '.join(cmd)}")
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                log(f"Scanner error: {result.stderr}")
            else:
                log(f"Scanner output: {result.stdout}")
        except FileNotFoundError:
            log(f"Scanner not found: {cmd[0]}")

def audit_project_mutation():
    """Simple file auditing for the self-development loop"""
    log(f"Auditing project mutation in {PROJECT_ROOT}...")
    if not os.path.exists(AUDIT_SNAPSHOT):
        # Create initial snapshot
        subprocess.run(f"find {PROJECT_ROOT} -maxdepth 3 -not -path '*/.*' > {AUDIT_SNAPSHOT}", shell=True)
        log("Initial project snapshot created.")
        return

    # Compare current state with snapshot
    current_state = subprocess.run(f"find {PROJECT_ROOT} -maxdepth 3 -not -path '*/.*'", shell=True, capture_output=True, text=True).stdout
    with open(AUDIT_SNAPSHOT, "r") as f:
        previous_state = f.read()

    if current_state != previous_state:
        log("WARNING: Unauthorized project structure mutation detected!")
        # In a real scenario, we would send an alert or trigger a revert
        # For now, just log the diff
        with open(AUDIT_SNAPSHOT, "w") as f:
            f.write(current_state)

if __name__ == "__main__":
    log("Cisco AI Defense stack daemon started.")
    while True:
        run_scanners()
        audit_project_mutation()
        # Run every 10 minutes
        time.sleep(600)
