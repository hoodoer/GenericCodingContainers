#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="opencode-halogen-hacker"
CONTAINERFILE="$SCRIPT_DIR/Containerfile.openCode-halogen-hacker"
CONTAINER_NAME="opencode-halogen-hacker"
PG_VOLUME="halogen-pentest-pgdata"

REBUILD=0
TARGET_DIR=""
HALOGEN_URL="${HALOGEN_URL:-http://host.containers.internal:8731/v1}"

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--rebuild)   REBUILD=1; shift ;;
        --halogen)      HALOGEN_URL="$2"; shift 2 ;;
        --halogen=*)    HALOGEN_URL="${1#*=}"; shift ;;
        *)              TARGET_DIR="$1"; shift ;;
    esac
done

if ! command -v podman >/dev/null 2>&1; then
    echo "[-] podman not found on PATH."; exit 1
fi

if [ $REBUILD -eq 1 ]; then
    echo "[*] Explicit rebuild requested."
    echo "[*] Building $IMAGE_NAME from $CONTAINERFILE..."
    podman build --no-cache -t "$IMAGE_NAME" -f "$CONTAINERFILE" "$SCRIPT_DIR" 2>&1 | tee build.log
    echo "[+] Image $IMAGE_NAME built. Exiting without launching."
    exit 0
fi

if [ -z "$(podman images -q "$IMAGE_NAME" 2>/dev/null)" ]; then
    echo "[*] Image $IMAGE_NAME not found. Running initial build..."
    podman build -t "$IMAGE_NAME" -f "$CONTAINERFILE" "$SCRIPT_DIR" 2>&1 | tee build.log
fi

[ -z "$TARGET_DIR" ] && TARGET_DIR=$(pwd)
TARGET_DIR=$(readlink -f "$TARGET_DIR")

echo "[*] Launching OpenCode environment in $TARGET_DIR..."

podman volume create "$PG_VOLUME" >/dev/null 2>&1 || true
podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# Run container securely with explicit networking capabilities for Nmap/Ligolo
exec podman run -it --rm \
    --name "$CONTAINER_NAME" \
    --cap-add=NET_RAW \
    --cap-add=NET_ADMIN \
    -p 4444-4450:4444-4450 \
    -e HALOGEN_URL="$HALOGEN_URL" \
    -v "$TARGET_DIR:/workspace:Z" \
    -v "$PG_VOLUME:/var/lib/postgresql:Z" \
    "$IMAGE_NAME" /usr/local/bin/opencode-select