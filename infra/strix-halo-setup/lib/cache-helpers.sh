#!/bin/bash
# cache-helpers.sh — Cache-aware download wrappers.
#
# When CACHE_DIR is set and non-empty, these functions check the cache first
# and fall back to the network on a miss (populating the cache for next time).
# When CACHE_DIR is empty, they pass through to the original commands.
#
# Depends on: log(), warn() from the provisioning framework.

# Save real paths before mocks can override them
_CACHE_CP="${_REAL_CP:-$(command -v cp)}"
_CACHE_MKDIR="${_REAL_MKDIR:-$(command -v mkdir)}"

# Derive a filesystem-safe cache key from a URL.
# Strips protocol prefix, replaces / with _
# Uses pure bash — no external commands (avoids mock interference in tests).
_cache_key() {
    local url="$1"
    # Strip https:// or http://
    url="${url#https://}"
    url="${url#http://}"
    # Replace / with _
    echo "${url//\//_}"
}

# cached_curl_pipe URL CMD...
# Replaces: curl -fsSL URL | CMD
# Cache: $CACHE_DIR/scripts/<key>
cached_curl_pipe() {
    local url="$1"; shift
    local cmd=("$@")

    if [ -z "${CACHE_DIR:-}" ]; then
        curl -fsSL "$url" | "${cmd[@]}"
        return
    fi

    local key
    key=$(_cache_key "$url")
    local cached="$CACHE_DIR/scripts/$key"

    if [ -f "$cached" ]; then
        log "Cache hit: $cached"
        "${cmd[@]}" < "$cached"
    else
        log "Cache miss: downloading $url"
        $_CACHE_MKDIR -p "$CACHE_DIR/scripts"
        curl -fsSL "$url" | tee "$cached" | "${cmd[@]}"
    fi
}

# cached_fetch URL DEST
# Replaces: wget -qO DEST URL (or curl -fsSL -o DEST URL)
# Cache: $CACHE_DIR/files/<key>
cached_fetch() {
    local url="$1"
    local dest="$2"

    if [ -z "${CACHE_DIR:-}" ]; then
        wget -qO "$dest" "$url"
        return
    fi

    local key
    key=$(_cache_key "$url")
    local cached="$CACHE_DIR/files/$key"

    if [ -f "$cached" ]; then
        log "Cache hit: $cached"
        $_CACHE_CP "$cached" "$dest"
    else
        log "Cache miss: downloading $url"
        $_CACHE_MKDIR -p "$CACHE_DIR/files"
        wget -qO "$dest" "$url"
        $_CACHE_CP "$dest" "$cached"
    fi
}

# cached_git_clone URL DIR [BRANCH]
# Replaces: git clone [--branch BRANCH] URL DIR
# Cache: $CACHE_DIR/repos/<name>.git (bare repo used as local reference)
cached_git_clone() {
    local url="$1"
    local dir="$2"
    local branch="${3:-}"

    if [ -z "${CACHE_DIR:-}" ]; then
        if [ -n "$branch" ]; then
            git clone --branch "$branch" "$url" "$dir"
        else
            git clone "$url" "$dir"
        fi
        return
    fi

    # Derive repo name from URL (e.g. https://github.com/foo/bar.git -> bar)
    local repo_name
    repo_name=$(basename "$url" .git)
    local bare="$CACHE_DIR/repos/${repo_name}.git"

    if [ -d "$bare" ]; then
        log "Cache hit: cloning from local bare repo $bare"
        if [ -n "$branch" ]; then
            git clone --branch "$branch" --reference "$bare" "$url" "$dir"
        else
            git clone --reference "$bare" "$url" "$dir"
        fi
    else
        log "Cache miss: cloning $url (will cache bare repo)"
        $_CACHE_MKDIR -p "$CACHE_DIR/repos"
        if [ -n "$branch" ]; then
            git clone --branch "$branch" "$url" "$dir"
        else
            git clone "$url" "$dir"
        fi
        # Populate cache with a bare clone for future use
        git clone --bare "$url" "$bare" 2>/dev/null || true
    fi
}

# cached_pip_index_args SUBDIR
# Returns extra pip flags when a local wheel cache exists.
# When cache hit: outputs --find-links DIR --no-index
# When no cache: outputs nothing (caller uses normal --index-url)
# Usage: pip install $(cached_pip_index_args torch-rocm) --pre torch ...
cached_pip_index_args() {
    local subdir="$1"

    if [ -z "${CACHE_DIR:-}" ]; then
        return
    fi

    local pip_cache="$CACHE_DIR/pip/$subdir"
    if [ -d "$pip_cache" ] && [ -n "$(ls -A "$pip_cache" 2>/dev/null)" ]; then
        log "Pip cache hit: $pip_cache"
        echo "--find-links $pip_cache --no-index"
    fi
}
