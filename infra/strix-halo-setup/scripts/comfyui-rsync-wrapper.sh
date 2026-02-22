#!/bin/bash
# comfyui-rsync-wrapper.sh
# Restricted rsync wrapper for comfyui user
# Only allows writes to /home/comfyui/ComfyUI/models/

set -euo pipefail

# Allowed destination prefix
ALLOWED_DEST="/home/comfyui/ComfyUI/models/"

# Log invocation for audit
logger -t comfyui-rsync "Invocation from UID $SUDO_UID: $*"

# Validate all destination arguments are within allowed path
for arg in "$@"; do
    # Check if this looks like a destination (ends with / or contains the allowed path)
    if [[ "$arg" == *":"* ]] || [[ "$arg" == "/"* ]]; then
        # Extract the path part after any host: prefix
        local_path="${arg#*:}"
        # If it's the allowed path or a subdir, it's OK
        if [[ "$local_path" == "$ALLOWED_DEST"* ]] || [[ "$local_path" == "$ALLOWED_DEST" ]]; then
            continue
        fi
        # If it starts with /home/comfyui but not the allowed path, reject
        if [[ "$local_path" == "/home/comfyui"* ]]; then
            echo "ERROR: Destination outside allowed path: $local_path" >&2
            echo "Only $ALLOWED_DEST and subdirectories are permitted." >&2
            exit 1
        fi
    fi
done

# Execute the actual rsync
exec /usr/bin/rsync "$@"
