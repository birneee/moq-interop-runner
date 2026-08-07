#!/usr/bin/env bash
# build.sh - Build the birneee-moq (birneee/quiche_moq) Docker image via Nix
#
# Usage:
#   ./build.sh                              # Clone from default ref (main)
#   ./build.sh --ref feature-branch         # Clone specific branch/tag/commit
#   ./build.sh --repo URL                   # Clone from a different repository (fork)
#   ./build.sh --local ~/Git/quiche_moq     # Use local checkout
#
# Unlike other implementations here, this is built with
# `nix build .#interop-image` (interop/interop.nix in quiche_moq), not a
# Dockerfile. `docker load` tags the result birneee-moq:latest directly.
# One image serves both relay and client roles via MOQT_ROLE.
#
# Requires `nix` (flakes enabled) in addition to `docker`.

set -euo pipefail

#############################################################################
# Configuration (implementation-specific)
#############################################################################

IMPL_NAME="birneee-moq"
REPO_URL="https://github.com/birneee/quiche_moq"
DEFAULT_REF="main"
IMAGE_NAME="birneee-moq"

# Build directory (where this script lives)
BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="${BUILD_DIR}/.sources"
RUNNER_ROOT="$(cd "${BUILD_DIR}/../.." && pwd)"

#############################################################################
# Utility Functions
#############################################################################

log() {
    echo "[build] $*" >&2
}

error() {
    echo "[build] ERROR: $*" >&2
    exit 1
}

get_git_commit() {
    local dir="$1"
    git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown"
}

is_git_dirty() {
    local dir="$1"
    if git -C "$dir" diff --quiet HEAD 2>/dev/null && \
       git -C "$dir" diff --cached --quiet HEAD 2>/dev/null; then
        echo "false"
    else
        echo "true"
    fi
}

get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

get_runner_commit() {
    git -C "$RUNNER_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown"
}

#############################################################################
# Argument Parsing
#############################################################################

REF=""
LOCAL_PATH=""
CUSTOM_REPO=""  # override REPO_URL

while [[ $# -gt 0 ]]; do
    case $1 in
        --ref)
            if [[ -z "${2:-}" ]]; then
                error "--ref requires a value"
            fi
            REF="$2"
            shift 2
            ;;
        --repo)
            if [[ -z "${2:-}" ]]; then
                error "--repo requires a value"
            fi
            CUSTOM_REPO="$2"
            shift 2
            ;;
        --local)
            if [[ -z "${2:-}" ]]; then
                error "--local requires a value"
            fi
            LOCAL_PATH="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --ref REF       Git ref to checkout (branch/tag/commit)"
            echo "  --repo URL      Clone from a different repository (fork)"
            echo "  --local PATH    Use local checkout instead of cloning"
            echo "  --help          Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                                # Clone default branch (${DEFAULT_REF})"
            echo "  $0 --ref v0.5.0                   # Clone specific tag"
            echo "  $0 --repo https://github.com/user/quiche_moq --ref branch"
            echo "  $0 --local ~/Git/quiche_moq        # Use local checkout"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

if [[ -n "$CUSTOM_REPO" ]]; then
    REPO_URL="$CUSTOM_REPO"
fi

if [[ -n "$REF" && -n "$LOCAL_PATH" ]]; then
    error "Cannot specify both --ref and --local"
fi

if [[ -n "$CUSTOM_REPO" && -n "$LOCAL_PATH" ]]; then
    error "Cannot specify both --repo and --local"
fi

if [[ -z "$REF" && -z "$LOCAL_PATH" ]]; then
    REF="$DEFAULT_REF"
fi

if ! command -v nix >/dev/null 2>&1; then
    error "nix is required to build birneee-moq (nix build .#interop-image) but was not found on PATH"
fi

#############################################################################
# Source Preparation
#############################################################################

if [[ -n "$LOCAL_PATH" ]]; then
    if [[ ! -d "$LOCAL_PATH" ]]; then
        error "Local path does not exist: $LOCAL_PATH"
    fi
    SOURCE_DIR="$(cd "$LOCAL_PATH" && pwd)"
    SOURCE_TYPE="local"
    log "Using local checkout: $SOURCE_DIR"
    # Nix flakes only see git-tracked files - run 'git add' on new files
    # first if the build below fails with "not tracked by Git".
    if git -C "$SOURCE_DIR" status --porcelain 2>/dev/null | grep -q '^??'; then
        log "NOTE: $SOURCE_DIR has untracked files"
    fi
else
    SOURCE_DIR="${SOURCES_DIR}/${IMPL_NAME}"
    SOURCE_TYPE="git"

    mkdir -p "$SOURCES_DIR"

    if [[ -d "$SOURCE_DIR/.git" ]]; then
        EXISTING_URL=$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null || echo "")
        if [[ "$EXISTING_URL" != "$REPO_URL" ]]; then
            log "Repo URL changed ($EXISTING_URL -> $REPO_URL), re-cloning..."
            rm -rf "$SOURCE_DIR"
            git clone "$REPO_URL" "$SOURCE_DIR"
        else
            log "Updating existing clone..."
            git -C "$SOURCE_DIR" fetch origin
        fi
    else
        log "Cloning $REPO_URL..."
        rm -rf "$SOURCE_DIR"
        git clone "$REPO_URL" "$SOURCE_DIR"
    fi

    log "Checking out ref: $REF"
    git -C "$SOURCE_DIR" checkout "$REF"
    git -C "$SOURCE_DIR" pull origin "$REF" 2>/dev/null || true
fi

SOURCE_COMMIT=$(get_git_commit "$SOURCE_DIR")
SOURCE_DIRTY=$(is_git_dirty "$SOURCE_DIR")

#############################################################################
# Nix Build + docker load
#############################################################################

log "Building interop-image via Nix (first build compiles quiche/boring from"
log "source and can take several minutes; cached on subsequent builds)..."
log "  Flake: ${SOURCE_DIR}#interop-image"

OUT_LINK="${BUILD_DIR}/.result-interop-image"
if ! nix build "${SOURCE_DIR}#interop-image" -o "$OUT_LINK"; then
    error "nix build failed for interop-image"
fi

log "Loading image into Docker..."
if ! docker load < "$OUT_LINK"; then
    error "docker load failed"
fi

log "Loaded ${IMAGE_NAME}:latest"

#############################################################################
# Provenance Output
#############################################################################

TIMESTAMP=$(get_timestamp)
RUNNER_COMMIT=$(get_runner_commit)

# shellcheck disable=SC2016
PROVENANCE=$(jq -n \
    --arg impl "$IMPL_NAME" \
    --arg ts "$TIMESTAMP" \
    --arg runner_commit "$RUNNER_COMMIT" \
    --arg source_type "$SOURCE_TYPE" \
    --arg repo "$REPO_URL" \
    --arg ref "${REF:-}" \
    --arg local_path "${LOCAL_PATH:-}" \
    --arg commit "$SOURCE_COMMIT" \
    --argjson dirty "$SOURCE_DIRTY" \
    --arg image "${IMAGE_NAME}:latest" \
    '{
        implementation: $impl,
        timestamp: $ts,
        runner_commit: $runner_commit,
        source: {
            type: $source_type,
            repository: $repo,
            ref: (if $ref == "" then "local" else $ref end),
            local_path: (if $local_path == "" then null else $local_path end),
            commit: $commit,
            dirty: $dirty
        },
        images: [{"target": "image", "image": $image}]
    }'
)

echo "$PROVENANCE" > "${BUILD_DIR}/.last-build.json"
log "Provenance saved to ${BUILD_DIR}/.last-build.json"

echo ""
echo "=== Build Provenance ==="
echo "$PROVENANCE"

log "Build complete!"
