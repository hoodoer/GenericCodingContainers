#!/bin/bash

# Follows the exact pattern of your claudeCodeDocker.sh
IMAGE_NAME="opencode-lemonade"
DOCKERFILE="Dockerfile.opencode-lemonade"
CONTAINER_NAME="opencode-sandbox"

REBUILD=0
TARGET_DIR=""

# Parse your standard arguments
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

# Fallback to current directory if no path passed
if [ -z "$TARGET_DIR" ]; then
    TARGET_DIR=$(pwd)
fi

# Resolve absolute path
TARGET_DIR=$(readlink -f "$TARGET_DIR")

# Handle image creation/rebuilding matching your exact script workflow
if [ $REBUILD -eq 1 ] || [ "$(docker images -q $IMAGE_NAME 2> /dev/null)" == "" ]; then
    echo "[*] Building/Rebuilding Docker image: $IMAGE_NAME..."
    docker build --no-cache -t $IMAGE_NAME -f $DOCKERFILE .
fi

echo "[*] Launching OpenCode Container..."
echo "[*] Workspace: $TARGET_DIR"
echo "[*] Routing AI requests to Lemonade Server via host loopback (Port 13305)"

# Spin up using the network gateway mapping
docker run -it --rm \
    --name "$CONTAINER_NAME" \
    --add-host host.docker.internal:host-gateway \
    -v "$TARGET_DIR:/workspace" \
    $IMAGE_NAME opencode-select
