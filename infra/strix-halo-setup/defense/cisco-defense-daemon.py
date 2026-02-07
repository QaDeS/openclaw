#!/usr/bin/env python3
import subprocess
import time
import os

# Scanners to run periodically
SCANNERS = [
    ["a2a-scanner", "scan-network"],
    ["mcp-scanner", "scan-endpoints"],
    ["skill-scanner", "audit-skills"]
]

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

if __name__ == "__main__":
    log("Cisco AI Defense stack daemon started.")
    while True:
        run_scanners()
        # Run every 10 minutes
        time.sleep(600)
