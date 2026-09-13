#!/bin/bash

IMAGE_NAME="opencode-halogen"
DOCKERFILE="Dockerfile.opencode-halogen"
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

if [ -z "$TARGET_DIR" ]; then
    TARGET_DIR=$(pwd)
fi

TARGET_DIR=$(readlink -f "$TARGET_DIR")

if [ $REBUILD -eq 1 ] || [ "$(docker images -q $IMAGE_NAME 2> /dev/null)" == "" ]; then
    echo "[*] Building/Rebuilding Docker image: $IMAGE_NAME..."
    docker build --no-cache -t $IMAGE_NAME -f $DOCKERFILE .
fi

echo "[*] Launching OpenCode Halogen Container..."
echo "[*] Workspace: $TARGET_DIR"
echo "[*] Routing AI requests to Halogen Server via host loopback (Port 8731)"

docker run -it --rm \
    --name "$CONTAINER_NAME" \
    --add-host host.docker.internal:host-gateway \
    --ipc=host \
    -e OPENCODE_EXPERIMENTAL_PLAN_MODE=1 \
    -v "$TARGET_DIR:/workspace" \
    $IMAGE_NAME opencode-select
