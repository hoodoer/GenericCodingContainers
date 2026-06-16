#!/bin/bash
# Usage: claude-code.sh [--rebuild] [project directory]
# Defaults to current directory if none specified
# --rebuild    Force rebuild the Docker image (no cache)

IMAGE_NAME="claude-code-generic"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REBUILD=false

# Parse flags
while [[ "$1" == --* ]]; do
    case "$1" in
        --rebuild)
            REBUILD=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

TARGET_DIR="${1:-.}"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

# Build if image doesn't exist or rebuild requested
if $REBUILD; then
    echo "[*] Rebuilding $IMAGE_NAME image (no cache)..."
    docker build --no-cache -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile.claude-code-generic" "$SCRIPT_DIR"
elif ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "[*] Building $IMAGE_NAME image..."
    docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile.claude-code-generic" "$SCRIPT_DIR"
fi

echo "[*] Launching Claude Code in: $TARGET_DIR"

docker run -it --rm \
    --name "claude-code-$(basename "$TARGET_DIR")" \
    --network host \
    --user "$(id -u):$(id -g)" \
    -e HOME=/home/user \
    -v "$TARGET_DIR:/home/user/project" \
    -v "$HOME/.claude-docker-config:/home/user/.claude" \
    -v "$HOME/.claude-docker-config/.claude.json:/home/user/.claude.json" \
    -w /home/user/project \
    "$IMAGE_NAME"
