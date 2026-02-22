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

# cached_apt_install PKG...
# Wraps apt install with cache population/restore via CACHE_DIR/apt/.
# On cache hit: copies matching .deb files into /var/cache/apt/archives/ first
# so apt can skip downloading them.  After install, copies any newly downloaded
# .debs back into the cache for next time.
# When CACHE_DIR is empty: plain apt install -y.
cached_apt_install() {
    if [ -z "${CACHE_DIR:-}" ]; then
        apt install -y "$@"
        return
    fi

    local apt_cache="$CACHE_DIR/apt"
    $_CACHE_MKDIR -p "$apt_cache"

    # Pre-seed: copy cached debs into the system apt cache
    if [ -d "$apt_cache" ] && [ -n "$(ls -A "$apt_cache"/*.deb 2>/dev/null)" ]; then
        log "Restoring cached apt debs from $apt_cache"
        $_CACHE_CP "$apt_cache"/*.deb /var/cache/apt/archives/ 2>/dev/null || true
    fi

    apt install -y "$@"

    # Post-seed: copy newly downloaded debs back to cache
    for deb in /var/cache/apt/archives/*.deb; do
        [ -f "$deb" ] || continue
        local base
        base=$(basename "$deb")
        if [ ! -f "$apt_cache/$base" ]; then
            $_CACHE_CP "$deb" "$apt_cache/$base"
        fi
    done
}

# cached_podman_ensure USER IMAGE
# Pre-loads a container image from CACHE_DIR/podman/ if available.
# The archive filename is derived from the image name (slashes → underscores).
# Skips if the image is already in the user's local store.
# When CACHE_DIR is empty: no-op (quadlets pull on first start).
cached_podman_ensure() {
    local user="$1"
    local image="$2"

    if [ -z "${CACHE_DIR:-}" ]; then
        return
    fi

    local safe_name="${image//\//_}"
    safe_name="${safe_name//:/_}"
    local archive="$CACHE_DIR/podman/${safe_name}.tar"

    if [ ! -f "$archive" ]; then
        return
    fi

    local uid
    uid=$(id -u "$user")
    local rtdir="/run/user/${uid}"

    # Check if image already exists in the user's store
    if sudo -u "$user" XDG_RUNTIME_DIR="$rtdir" podman image exists "$image" 2>/dev/null; then
        log "Podman image already present for ${user}: ${image}"
        return
    fi

    log "Loading cached podman image for ${user}: ${archive}"
    sudo -u "$user" XDG_RUNTIME_DIR="$rtdir" podman load -i "$archive"
}

# cached_env_for_pip
# Outputs env var assignments for UV_CACHE_DIR and PIP_CACHE_DIR when CACHE_DIR
# is set.  Intended for use in sudo -u commands:
#   eval "$(cached_env_for_pip)" sudo -u user pip install ...
# When CACHE_DIR is empty: outputs nothing.
cached_env_for_pip() {
    if [ -z "${CACHE_DIR:-}" ]; then
        return
    fi
    echo "UV_CACHE_DIR=\"${CACHE_DIR}/uv\" PIP_CACHE_DIR=\"${CACHE_DIR}/pip\""
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
