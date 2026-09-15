#!/usr/bin/env bash
set -eo pipefail

# Resolve the absolute path to this script and its Dockerfile
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="opencode-halogen"
DOCKERFILE="$SCRIPT_DIR/Dockerfile.opencode-halogen"
CONTAINER_NAME="opencode-halogen-sandbox"

REBUILD=0
TARGET_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--rebuild)
            REBUILD=1
            shift
            ;;
        *)
            TARGET_DIR="$1"
            shift
            ;;
    esac
done

# If --rebuild was explicitly passed: build, report status, and exit immediately
if [ $REBUILD -eq 1 ]; then
    echo "[*] Explicit rebuild requested."
    echo "[*] Building Docker image: $IMAGE_NAME from $DOCKERFILE..."
    docker build --no-cache -t "$IMAGE_NAME" -f "$DOCKERFILE" "$SCRIPT_DIR"
    echo "[+] Image $IMAGE_NAME built successfully. Exiting without launching OpenCode."
    exit 0
fi

# Auto-build only if the image does not exist at all
if [ -z "$(docker images -q "$IMAGE_NAME" 2>/dev/null)" ]; then
    echo "[*] Image $IMAGE_NAME not found. Running initial build..."
    docker build --no-cache -t "$IMAGE_NAME" -f "$DOCKERFILE" "$SCRIPT_DIR"
fi

if [ -z "$TARGET_DIR" ]; then
    TARGET_DIR=$(pwd)
fi
TARGET_DIR=$(readlink -f "$TARGET_DIR")

# Clean up any lingering container with the same name before running
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "[*] Launching OpenCode Halogen Container..."
echo "[*] Workspace: $TARGET_DIR"
echo "[*] Routing AI requests to Halogen Server via host loopback (Port 8731)"

docker run -it --rm \
    --name "$CONTAINER_NAME" \
    --network host \
    --ipc=host \
    -e OPENCODE_EXPERIMENTAL_PLAN_MODE=1 \
    -v "$TARGET_DIR:/workspace" \
    "$IMAGE_NAME" opencode-select