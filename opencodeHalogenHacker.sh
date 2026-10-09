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

# --- Generate AGENTS.md dynamically ---
AGENTS_FILE="$TARGET_DIR/AGENTS.md"
if [ ! -f "$AGENTS_FILE" ]; then
    echo "[*] Generating default AGENTS.md in $TARGET_DIR..."
    cat << 'AGENTSEOF' | sed 's/___FENCE___/```/g' > "$AGENTS_FILE"
# Pentesting Agent Instructions

## Methodology: Enumerate → Research → Exploit

Follow this loop for every target. Do NOT skip to web searches or walkthroughs.

### 1. Enumerate the target
Discover open ports, services, and version strings:
___FENCE___bash
safe-run nmap -sCV -Pn -oA /workspace/loot/initial <TARGET>
___FENCE___
Record every service name and version number you find (e.g. `Apache 2.4.49`,
`OpenSSH 8.2p1`, `ProFTPD 1.3.5`, `Rejetto HFS 2.3`).

### 2. Search for known exploits LOCALLY FIRST
For every identified service+version, search the local exploit database and
Metasploit **before** doing anything else:
___FENCE___bash
safe-run searchsploit <service> <version>          # ExploitDB local mirror
safe-run searchsploit -x <edb-id>                  # read the exploit source
___FENCE___
___FENCE___
search_exploits("<service> <version>")              # Metasploit MCP tool
search_modules("<service>")                         # broader MSF search
___FENCE___
___FENCE___bash
safe-run netexec smb <TARGET> --gen-relay-list /workspace/loot/relay.txt  # AD targets
___FENCE___
Also check for CVEs directly:
___FENCE___bash
safe-run searchsploit -cve <CVE-YYYY-NNNNN>        # if you know a CVE number
safe-run nuclei -u <TARGET> -as                     # auto-detect tech + scan
___FENCE___

### 3. Attempt exploitation
Try the most promising exploit. If it fails, go back to step 2 with different
search terms (product name, protocol, vulnerability class).

### 4. Only THEN go external
If local searches produce nothing after genuine effort:
*   Search the web for `<service> <version> CVE` or `<service> <version> exploit`.
*   **Never search for a walkthrough or writeup of the challenge itself.**
    Searching for `"<box name>" walkthrough` or `"<box name>" writeup` is
    cheating and defeats the purpose.

### Why this matters
*   `searchsploit` and Metasploit contain thousands of ready-to-use exploits
    with no internet round-trip. They are faster and more reliable than web
    searches.
*   Web searches for challenge names return spoilers, not skills. The goal is
    to practice the methodology, not to find the answer.

---

## Metasploit Execution Preference
The Metasploit MCP server's parameter parsing can occasionally be strict. For complex exploitation chains:
1. Do not use the `run_module` MCP tool iteratively.
2. Instead, write your commands to a `.rc` resource script in the `/workspace` directory.
3. Execute the script directly using the terminal via `safe-run msfconsole -q -r your_script.rc`.

## Networking Constraints
*   **Target Scoping:** You are restricted by the `scope.txt` file. Only attack IPs explicitly listed there.
*   **Reverse Shells:** When setting an `LHOST` for a reverse shell payload, you must use the host's VPN IP. Do not use the internal `10.88.x.x` container IP.
*   **Listeners:** Always bind your `LPORT` to a port between `4444` and `4450`, as these are explicitly forwarded through the container NAT.

## Output Handling
*   Save all loot, hashes, and flags to `/workspace/loot/`.

## Cleanup Between Challenges
Run `cleanup -f` inside the container to wipe all workspace data and reset the MSF database.
From the host, launch with `--clean` to destroy the workspace and PG volume before starting.

---

## Windows Target Playbook (Credential-Based Access)

When you obtain valid Windows credentials, use this priority order. Each method is
faster and more reliable than RDP. **Only fall back to RDP if all text-based methods fail
or the challenge explicitly requires GUI interaction.**

### 1. Evil-WinRM (preferred for WinRM / port 5985-5986)
___FENCE___bash
safe-run evil-winrm -i <TARGET> -u <USER> -p '<PASS>'
___FENCE___
*   Full PowerShell session. Upload/download files. Load scripts.
*   If the port is open, try this first.

### 2. Impacket psexec / wmiexec / smbexec (SMB-based shells)
___FENCE___bash
safe-run impacket-psexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'
safe-run impacket-wmiexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'
safe-run impacket-smbexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'
___FENCE___
*   Semi-interactive SYSTEM shells. Good for quick flag grabs on the Administrator desktop.
*   `wmiexec` is stealthier; `psexec` gives SYSTEM; `smbexec` works when psexec is blocked.

### 3. Impacket secretsdump (hash dumping without a shell)
___FENCE___bash
safe-run impacket-secretsdump '<DOMAIN>/<USER>:<PASS>@<TARGET>'
___FENCE___
*   Dumps SAM/LSA/NTDS. Often all you need for a flag hidden in credential stores.

### 4. NetExec (quick credential validation + enumeration)
___FENCE___bash
safe-run netexec smb <TARGET> -u <USER> -p '<PASS>'
safe-run netexec winrm <TARGET> -u <USER> -p '<PASS>'
safe-run netexec rdp <TARGET> -u <USER> -p '<PASS>'
___FENCE___
*   Fast spray: test creds across protocols in seconds.
*   Add `--shares` / `--users` / `--rid-brute` for quick enumeration.
*   Tells you instantly if WinRM is available (look for `Pwn3d!`).

### 5. SMB file access (grab flags from shares directly)
___FENCE___bash
safe-run smbclient '//<TARGET>/C$' -U '<DOMAIN>/<USER>%<PASS>'
___FENCE___
*   If you know the flag path (e.g. `C:\Users\Administrator\Desktop\root.txt`),
    just `get` it. No shell needed.

---

## RDP Playbook (GUI-Required Challenges Only)

**Use RDP only when the challenge requires graphical interaction** — a desktop app,
a browser-based step, or a GUI-only tool. For everything else, use the text-based
methods above.

### Quick-Start Commands (`agent-rdp`)
`agent-rdp` runs as a headless protocol client. It manages session state, UI Automation
accessibility trees, and frame capture without requiring Xvfb or xdotool.

___FENCE___bash
# Connect with UI Automation inspection channel enabled
safe-run agent-rdp connect --host <TARGET_IP> --username <USER> --password '<PASS>' --enable-win-automation

# Inspect state via accessibility tree (preferred over vision)
safe-run agent-rdp automate snapshot -i

# Inspect state via screenshot (saves PNG directly to loot)
safe-run agent-rdp screenshot --output /workspace/loot/screenshots/desktop.png

# Send clicks to an accessibility element index
safe-run agent-rdp mouse click @e1

# Send clipboard commands (preferred over typing to prevent dropped scan codes)
safe-run agent-rdp clipboard set "whoami /priv"
safe-run agent-rdp keyboard press "ctrl+v"
safe-run agent-rdp keyboard press enter

# Send literal text or keys
safe-run agent-rdp keyboard type "cmd.exe"
safe-run agent-rdp keyboard press enter
safe-run agent-rdp keyboard press super          # Opens Start menu

# Disconnect session
safe-run agent-rdp disconnect
___FENCE___

### Performance & Interaction Rules
1.  **Inspect Trees Before Pixels:** Always attempt `agent-rdp automate snapshot -i` first.
    Targeting elements by semantic index (`@e1`, `@e2`) bypasses vision token limits and
    avoids pixel coordinate drift.
2.  **Clipboard Over Keystroke Typing:** When executing commands in cmd, PowerShell, or run
    dialogs, write the payload to the clipboard via `agent-rdp clipboard set` and paste with
    `agent-rdp keyboard press "ctrl+v"`. This prevents truncated characters or dropped shift
    keys.
3.  **Batch Your Actions:** Plan sequences before executing. Do NOT loop snapshot-click-snapshot
    rapidly. Dispatch the action sequence, wait 2–3 seconds for remote UI rendering, and
    capture a single snapshot or screenshot to confirm execution.
4.  **Fallback to Coordinate Clicks:** If custom canvas controls or legacy interfaces do not
    render into the accessibility tree, inspect the captured screenshot and target raw coordinates:
___FENCE___bash
safe-run agent-rdp mouse click 512 384
safe-run agent-rdp mouse double-click 100 200
___FENCE___
5.  **Timeouts & Reconnects:** If a session drops or freezes, disconnect and reconnect cleanly:
___FENCE___bash
safe-run agent-rdp disconnect
safe-run agent-rdp connect --host <TARGET_IP> --username <USER> --password '<PASS>' --enable-win-automation
___FENCE___

### Opening Applications via RDP
When you need to launch a GUI application:
___FENCE___bash
# Open Start Menu → type app name → Enter
safe-run agent-rdp keyboard press super
sleep 1
safe-run agent-rdp keyboard type "cmd"          # or "powershell", "notepad", app name
safe-run agent-rdp keyboard press enter
sleep 2
safe-run agent-rdp automate snapshot -i         # verify window opened
___FENCE___

For browser-based tasks:
___FENCE___bash
safe-run agent-rdp keyboard press super
sleep 1
safe-run agent-rdp keyboard type "msedge"       # or "firefox", "chrome"
safe-run agent-rdp keyboard press enter
sleep 3
safe-run agent-rdp keyboard press "ctrl+l"      # focus address bar
safe-run agent-rdp keyboard type "http://target-url:8080/path"
safe-run agent-rdp keyboard press enter
sleep 3
safe-run agent-rdp screenshot --output /workspace/loot/screenshots/browser.png
___FENCE___

### When to Abandon RDP
If you have spent more than **5 minutes** fighting RDP (connection drops, black screens,
keystrokes not registering), step back and try:
*   `evil-winrm` — might the "GUI app" actually have a CLI equivalent?
*   `impacket-wmiexec` — can you run the same command remotely?
*   `smbclient` — is the flag just a file you can grab over SMB?
*   Port forward the target's service to localhost and interact from the container.

---

## Pivoting and Tunneling
*   **Chisel:** `/usr/local/bin/chisel` — TCP/UDP tunnel over HTTP.
*   **Ligolo-ng:** `/usr/local/bin/ligolo-proxy` — full VPN-style pivot.
*   **Proxychains:** `proxychains4 <command>` — route tools through SOCKS proxy.
*   **SSH tunnels:** `ssh -D 1080 user@target` for dynamic SOCKS, `-L` for local port forwards.
*   **socat:** Relay/redirect any TCP/UDP stream.
AGENTSEOF
fi
# --------------------------------------

echo "[*] Launching OpenCode environment in $TARGET_DIR..."

podman volume create "$PG_VOLUME" >/dev/null 2>&1 || true
podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# Run container with explicit networking capabilities and open ports for callbacks
exec podman run -it --rm \
    --name "$CONTAINER_NAME" \
    --cap-add=NET_RAW \
    --cap-add=NET_ADMIN \
    -p 4444-4450:4444-4450 \
    -w /workspace \
    -e HALOGEN_URL="$HALOGEN_URL" \
    -v "$TARGET_DIR:/workspace:Z" \
    -v "$PG_VOLUME:/var/lib/postgresql:Z" \
    "$IMAGE_NAME" /usr/local/bin/opencode-select