#!/bin/bash
# populate-cache.sh — Pre-populate the download cache for offline provisioning.
#
# Usage: ./scripts/populate-cache.sh CACHE_DIR [--minimal]
#
# --minimal: creates stub scripts and minimal git repos for testing
#            (no network access required)

set -eo pipefail

CACHE_DIR="${1:-}"
MINIMAL=false
[ "${2:-}" = "--minimal" ] && MINIMAL=true

if [ -z "$CACHE_DIR" ]; then
    echo "Usage: $0 CACHE_DIR [--minimal]"
    exit 1
fi

mkdir -p "$CACHE_DIR"/{scripts,files,repos,pip}

# URLs to cache
SCRIPT_URLS=(
    "https://get.docker.com"
    "https://deb.nodesource.com/setup_22.x"
    "https://lmstudio.ai/install.sh"
    "https://astral.sh/uv/install.sh"
)

FILE_URLS=(
    "https://repo.radeon.com/rocm/rocm.gpg.key"
)

GIT_REPOS=(
    "https://github.com/QaDeS/openclaw.git"
    "https://github.com/ggml-org/llama.cpp.git"
    "https://github.com/comfyanonymous/ComfyUI.git"
    "https://github.com/ltdrdata/ComfyUI-Manager.git"
    "https://github.com/ACE-Step/ACE-Step-1.5.git"
)

# Derive cache key from URL (strip protocol, replace / with _)
cache_key() {
    echo "$1" | sed 's|^https\?://||; s|/|_|g'
}

echo "=== Populating cache in $CACHE_DIR ==="

# Scripts
for url in "${SCRIPT_URLS[@]}"; do
    key=$(cache_key "$url")
    dest="$CACHE_DIR/scripts/$key"
    if [ -f "$dest" ] && [ "$MINIMAL" = false ]; then
        echo "  [skip] scripts/$key (exists)"
        continue
    fi
    if [ "$MINIMAL" = true ]; then
        echo "#!/bin/bash" > "$dest"
        echo "# Minimal stub for $url" >> "$dest"
        echo "exit 0" >> "$dest"
        chmod +x "$dest"
        echo "  [stub] scripts/$key"
    else
        echo "  [download] $url -> scripts/$key"
        curl -fsSL "$url" -o "$dest" || echo "  [WARN] Failed to download $url"
    fi
done

# Files
for url in "${FILE_URLS[@]}"; do
    key=$(cache_key "$url")
    dest="$CACHE_DIR/files/$key"
    if [ -f "$dest" ] && [ "$MINIMAL" = false ]; then
        echo "  [skip] files/$key (exists)"
        continue
    fi
    if [ "$MINIMAL" = true ]; then
        echo "MINIMAL_STUB" > "$dest"
        echo "  [stub] files/$key"
    else
        echo "  [download] $url -> files/$key"
        wget -qO "$dest" "$url" || echo "  [WARN] Failed to download $url"
    fi
done

# Git repos
for url in "${GIT_REPOS[@]}"; do
    name=$(basename "$url" .git)
    dest="$CACHE_DIR/repos/${name}.git"
    if [ -d "$dest" ] && [ "$MINIMAL" = false ]; then
        echo "  [skip] repos/${name}.git (exists)"
        continue
    fi
    if [ "$MINIMAL" = true ]; then
        mkdir -p "$dest"
        (cd "$dest" && git init --bare -q && \
         GIT_DIR="$dest" git commit --allow-empty -m "minimal cache stub" -q 2>/dev/null || true)
        echo "  [stub] repos/${name}.git"
    else
        echo "  [clone] $url -> repos/${name}.git"
        git clone --bare "$url" "$dest" 2>/dev/null || echo "  [WARN] Failed to clone $url"
    fi
done

# Write timestamp
date -Is > "$CACHE_DIR/.populated_at"

echo ""
echo "=== Cache populated at $(cat "$CACHE_DIR/.populated_at") ==="
echo "  Total scripts: $(ls "$CACHE_DIR/scripts/" 2>/dev/null | wc -l)"
echo "  Total files:   $(ls "$CACHE_DIR/files/" 2>/dev/null | wc -l)"
echo "  Total repos:   $(ls -d "$CACHE_DIR/repos/"*.git 2>/dev/null | wc -l)"
