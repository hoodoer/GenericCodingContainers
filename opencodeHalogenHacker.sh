#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="opencode-halogen-hacker"
CONTAINERFILE="$SCRIPT_DIR/Containerfile.openCode-halogen-hacker"
CONTAINER_NAME="opencode-halogen-hacker"
PG_VOLUME="halogen-pentest-pgdata"

REBUILD=0
CLEAN=0
TARGET_DIR=""
HALOGEN_URL="${HALOGEN_URL:-http://host.containers.internal:8731/v1}"

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--rebuild)   REBUILD=1; shift ;;
        -c|--clean)     CLEAN=1; shift ;;
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

# --- Handle --clean before image check — cleaning doesn't need the image ---
[ -z "$TARGET_DIR" ] && TARGET_DIR=$(pwd)
TARGET_DIR=$(readlink -f "$TARGET_DIR")

if [ $CLEAN -eq 1 ]; then
    echo "[*] --clean requested. Wiping state for a fresh challenge."

    # Wipe workspace contents on the host side
    if [ -d "$TARGET_DIR" ]; then
        echo "[*] Cleaning $TARGET_DIR..."
        find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
        echo "[+] Workspace cleaned."
    fi

    # Destroy and recreate the PG volume so the MSF database starts fresh
    echo "[*] Destroying PostgreSQL volume ($PG_VOLUME)..."
    podman volume rm -f "$PG_VOLUME" >/dev/null 2>&1 || true
    echo "[+] Volume removed. A fresh volume will be created on launch."
    echo ""
    echo "[+] Clean complete. Run without --clean to start a fresh session."
    exit 0
fi

if [ -z "$(podman images -q "$IMAGE_NAME" 2>/dev/null)" ]; then
    echo "[*] Image $IMAGE_NAME not found. Running initial build..."
    podman build -t "$IMAGE_NAME" -f "$CONTAINERFILE" "$SCRIPT_DIR" 2>&1 | tee build.log
fi

# Agent knowledge is bootstrapped inside the container by opencode-select
# from /opt/pentest-agent/ -> /workspace/ on every launch.
# --------------------------------------

echo "[*] Launching OpenCode environment in $TARGET_DIR..."

podman volume create "$PG_VOLUME" >/dev/null 2>&1 || true
podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# Run container with explicit networking capabilities and open ports for callbacks
exec podman run -it --rm \
    --name "$CONTAINER_NAME" \
    --cap-add=NET_RAW \
    --cap-add=NET_ADMIN \
    -p 80:80 \
    -p 443:443 \
    -p 445:445 \
    -p 4444-4460:4444-4460 \
    -p 8080-8090:8080-8090 \
    -w /workspace \
    -e HALOGEN_URL="$HALOGEN_URL" \
    -v "$TARGET_DIR:/workspace:Z" \
    -v "$PG_VOLUME:/var/lib/postgresql:Z" \
    "$IMAGE_NAME" /usr/local/bin/opencode-select