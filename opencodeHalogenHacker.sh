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
    echo "[*] Building $IMAGE_NAME from$CONTAINERFILE..."
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

# --- Generate AGENTS.md dynamically ---
AGENTS_FILE="$TARGET_DIR/AGENTS.md"
if [ ! -f "$AGENTS_FILE" ]; then
    echo "[*] Generating default AGENTS.md in $TARGET_DIR..."
    cat << 'AGENTSEOF' > "$AGENTS_FILE"
# Pentesting Agent Instructions

## Metasploit Execution Preference
The Metasploit MCP servers parameter parsing can occasionally be strict. For complex exploitation chains:
1. Do not use the `run_module` MCP tool iteratively.
2. Instead, write your commands to a `.rc` resource script in the `/workspace` directory.
3. Execute the script directly using the terminal via `safe-run msfconsole -q -r your_script.rc`.

## Networking Constraints
*   **Target Scoping:** You are restricted by the `scope.txt` file. Only attack IPs explicitly listed there.
*   **Reverse Shells:** When setting an `LHOST` for a reverse shell payload, you must use the hosts VPN IP. Do not use the internal `10.88.x.x` container IP.
*   **Listeners:** Always bind your `LPORT` to a port between `4444` and `4450`, as these are explicitly forwarded through the container NAT.

## Output Handling
*   Save all loot, hashes, and flags to `/workspace/loot/`.
AGENTSEOF
fi
# --------------------------------------

echo "[*] Launching OpenCode environment in $TARGET_DIR..."

podman volume create "$PG_VOLUME" >/dev/null 2>&1 || true
podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# Run container securely with explicit networking capabilities and open ports for callbacks
exec podman run -it --rm \
    --name "$CONTAINER_NAME" \
    --cap-add=NET_RAW \
    --cap-add=NET_ADMIN \
    -p 4444-4450:4444-4450 \
    -e HALOGEN_URL="$HALOGEN_URL" \
    -v "$TARGET_DIR:/workspace:Z" \
    -v "$PG_VOLUME:/var/lib/postgresql:Z" \
    "$IMAGE_NAME" /usr/local/bin/opencode-select