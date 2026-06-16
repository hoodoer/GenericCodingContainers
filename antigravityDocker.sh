#!/bin/bash
# Usage: ./antigravityDocker.sh [--rebuild] [project directory]

IMAGE_NAME="antigravity-cli-generic"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REBUILD=false

while [[ "$1" == --* ]]; do
    case "$1" in
        --rebuild) REBUILD=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

TARGET_DIR="${1:-.}"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

if $REBUILD; then
    echo "[*] Rebuilding $IMAGE_NAME (no cache)..."
    docker build --no-cache -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile.antigravity-generic" "$SCRIPT_DIR"
elif ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "[*] Building $IMAGE_NAME..."
    docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile.antigravity-generic" "$SCRIPT_DIR"
fi

echo "[*] Launching Antigravity CLI in: $TARGET_DIR"

# Ensure local configuration dir exists
mkdir -p "$HOME/.antigravity-docker-config"

docker run -it --rm \
    --name "antigravity-$(basename "$TARGET_DIR")" \
    --network host \
    --user "$(id -u):$(id -g)" \
    -e HOME=/home/user \
    -v "$TARGET_DIR:/home/user/project" \
    -v "$HOME/.antigravity-docker-config:/home/user/.antigravity" \
    -w /home/user/project \
    "$IMAGE_NAME" "$@"