#!/usr/bin/env bash
# build.sh - Build quiche-moq Docker images from source
#
# Usage:
#   ./build.sh                      # Clone from default ref (main)
#   ./build.sh --ref feature-branch # Clone specific branch/tag/commit
#   ./build.sh --local ~/git/quiche # Use local checkout
#   ./build.sh --target relay       # Build only relay image
#
# This script follows the same pattern as builds/moq-rs/build.sh.

set -euo pipefail

#############################################################################
# Configuration (implementation-specific)
#############################################################################

IMPL_NAME="quiche-moq"
REPO_URL="https://github.com/google/quiche"
DEFAULT_REF="main"

# Build directory (where this script lives)
BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="${BUILD_DIR}/.sources"
RUNNER_ROOT="$(cd "${BUILD_DIR}/../.." && pwd)"

#############################################################################
# Utility Functions (candidates for shared library)
#############################################################################

log() {
    echo "[build] $*" >&2
}

error() {
    echo "[build] ERROR: $*" >&2
    exit 1
}

# Get git commit hash from a directory
get_git_commit() {
    local dir="$1"
    git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown"
}

# Check if git working directory is dirty
is_git_dirty() {
    local dir="$1"
    if git -C "$dir" diff --quiet HEAD 2>/dev/null && \
       git -C "$dir" diff --cached --quiet HEAD 2>/dev/null; then
        echo "false"
    else
        echo "true"
    fi
}

# Get current timestamp in ISO 8601 format
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Get the moq-interop-runner repo commit
get_runner_commit() {
    git -C "$RUNNER_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown"
}

#############################################################################
# Argument Parsing
#############################################################################

REF=""
LOCAL_PATH=""
TARGET=""  # empty = build all targets

while [[ $# -gt 0 ]]; do
    case $1 in
        --ref)
            if [[ -z "${2:-}" ]]; then
                error "--ref requires a value"
            fi
            REF="$2"
            shift 2
            ;;
        --local)
            if [[ -z "${2:-}" ]]; then
                error "--local requires a value"
            fi
            LOCAL_PATH="$2"
            shift 2
            ;;
        --target)
            if [[ -z "${2:-}" ]]; then
                error "--target requires a value"
            fi
            TARGET="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --ref REF       Git ref to checkout (branch/tag/commit)"
            echo "  --local PATH    Use local checkout instead of cloning"
            echo "  --target NAME   Build only specific target (relay)"
            echo "  --help          Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                           # Clone main branch"
            echo "  $0 --ref v1.0.0              # Clone specific tag"
            echo "  $0 --local ~/git/quiche      # Use local checkout"
            echo "  $0 --local ~/git/quiche --target relay"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Validate: can't specify both --ref and --local
if [[ -n "$REF" && -n "$LOCAL_PATH" ]]; then
    error "Cannot specify both --ref and --local"
fi

# Default to cloning if neither specified
if [[ -z "$REF" && -z "$LOCAL_PATH" ]]; then
    REF="$DEFAULT_REF"
fi

#############################################################################
# Source Preparation
#############################################################################

if [[ -n "$LOCAL_PATH" ]]; then
    # Using local checkout
    if [[ ! -d "$LOCAL_PATH" ]]; then
        error "Local path does not exist: $LOCAL_PATH"
    fi
    SOURCE_DIR="$(cd "$LOCAL_PATH" && pwd)"
    SOURCE_TYPE="local"
    log "Using local checkout: $SOURCE_DIR"
else
    # Clone from remote
    SOURCE_DIR="${SOURCES_DIR}/${IMPL_NAME}"
    SOURCE_TYPE="git"
    
    mkdir -p "$SOURCES_DIR"
    
    if [[ -d "$SOURCE_DIR/.git" ]]; then
        log "Updating existing clone..."
        git -C "$SOURCE_DIR" fetch origin
    else
        log "Cloning $REPO_URL..."
        rm -rf "$SOURCE_DIR"
        git clone "$REPO_URL" "$SOURCE_DIR"
    fi
    
    log "Checking out ref: $REF"
    git -C "$SOURCE_DIR" checkout "$REF"
    git -C "$SOURCE_DIR" pull origin "$REF" 2>/dev/null || true
fi

# Capture source provenance
SOURCE_COMMIT=$(get_git_commit "$SOURCE_DIR")
SOURCE_DIRTY=$(is_git_dirty "$SOURCE_DIR")

#############################################################################
# Docker Builds
#############################################################################

BUILT_IMAGES=()

# Check for extra CA cert (useful for networks with TLS inspection)
CA_CERT_FILE="${BUILD_DIR}/extra-ca.pem"
SECRET_ARGS=""
if [[ -f "$CA_CERT_FILE" ]]; then
    log "Found extra CA certificate: $CA_CERT_FILE"
    SECRET_ARGS="--secret id=ca_cert,src=${CA_CERT_FILE}"
fi

build_target() {
    local target="$1"
    local dockerfile=""
    local image_name=""
    local entrypoint_script=""
    
    case "$target" in
        relay)
            dockerfile="${BUILD_DIR}/Dockerfile.relay"
            image_name="quiche-moq-relay"
            entrypoint_script="${BUILD_DIR}/entrypoint-relay.sh"
            ;;
        *)
            error "Unknown target: $target (quiche-moq only supports: relay)"
            ;;
    esac
    
    log "Building ${target} -> ${image_name}:latest"
    log "  Dockerfile: ${dockerfile}"
    log "  Context: ${SOURCE_DIR}"
    log ""
    log "Note: quiche uses Bazel — first build will be slow (10-20 min)."
    log "Subsequent builds with cached layers will be much faster."
    
    # Copy entrypoint script to build context (cleaned up after build)
    local entrypoint_dest="${SOURCE_DIR}/$(basename "$entrypoint_script")"
    cp "$entrypoint_script" "$entrypoint_dest"
    
    # shellcheck disable=SC2086
    if docker build \
        -f "${dockerfile}" \
        $SECRET_ARGS \
        -t "${image_name}:latest" \
        "$SOURCE_DIR"; then
        rm -f "$entrypoint_dest"
    else
        rm -f "$entrypoint_dest"
        error "Docker build failed for ${target}"
    fi
    
    BUILT_IMAGES+=("{\"target\": \"${target}\", \"image\": \"${image_name}:latest\"}")
}

if [[ -n "$TARGET" ]]; then
    build_target "$TARGET"
else
    build_target "relay"
fi

#############################################################################
# Provenance Output
#############################################################################

TIMESTAMP=$(get_timestamp)
RUNNER_COMMIT=$(get_runner_commit)
IMAGES_JSON=$(IFS=,; echo "${BUILT_IMAGES[*]}")

# Use jq for safe JSON generation to avoid injection issues
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
    --argjson images "[$IMAGES_JSON]" \
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
        images: $images
    }'
)

# Save to file
echo "$PROVENANCE" > "${BUILD_DIR}/.last-build.json"
log "Provenance saved to ${BUILD_DIR}/.last-build.json"

# Output to stdout for capture
echo ""
echo "=== Build Provenance ==="
echo "$PROVENANCE"

log "Build complete!"
