#!/usr/bin/env bash
# agent-setup.sh

# --- Context-budget wrapper
cat << 'EOF' > /usr/local/bin/safe-run
#!/usr/bin/env bash
MAX_LINES=400
TIMEOUT="${SAFE_RUN_TIMEOUT:-120s}"

mkdir -p /workspace/loot/logs
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="/workspace/loot/logs/${STAMP}-$$.log"

OUTPUT=$(NO_COLOR=1 TERM=dumb timeout "$TIMEOUT" "$@" 2>&1)
STATUS=$?
printf '%s\n' "$OUTPUT" > "$LOG"

TOTAL_LINES=$(printf '%s\n' "$OUTPUT" | wc -l)
if [ "$TOTAL_LINES" -gt "$MAX_LINES" ]; then
    printf '%s\n' "$OUTPUT" | head -n "$MAX_LINES"
    echo ""
    echo "[!] Output truncated: ${TOTAL_LINES} lines total. Full output: ${LOG}"
    echo "    Use: safe-run tail -n 80 ${LOG}   or   safe-run grep -i <pat> ${LOG}"
else
    printf '%s\n' "$OUTPUT"
fi

if [ $STATUS -eq 124 ]; then
    echo "[-] Timed out after $TIMEOUT. Partial output: ${LOG}"
    exit 124
fi
exit $STATUS
EOF

# --- Scope check
cat << 'EOF' > /usr/local/bin/scope_check
#!/usr/bin/env bash
SCOPE_FILE="${SCOPE_FILE:-/workspace/scope.txt}"
TARGET="$1"
[ -z "$TARGET" ] && exit 2
if [ ! -f "$SCOPE_FILE" ]; then
    echo "WARN: no ${SCOPE_FILE}; treating all targets as in scope"
    exit 0
fi

python3 - "$SCOPE_FILE" "$TARGET" << 'PYEOF'
import ipaddress, sys
path, target = sys.argv[1], sys.argv[2].strip().lower()
entries = [l.strip() for l in open(path)
           if l.strip() and not l.strip().startswith('#')]
if not entries:
    sys.exit(0)
try:
    ip = ipaddress.ip_address(target)
    for e in entries:
        try:
            if '/' in e and ip in ipaddress.ip_network(e, strict=False):
                sys.exit(0)
            elif str(ipaddress.ip_address(e)) == str(ip):
                sys.exit(0)
        except ValueError:
            continue
    sys.exit(2)
except ValueError:
    t = target.split(':')[0]
    for e in entries:
        e = e.split(':')[0].lower()
        if e == t or e.lstrip('*.') == t.lstrip('*.') or t.endswith('.' + e.lstrip('.')):
            sys.exit(0)
    sys.exit(2)
PYEOF
EOF

# --- Scope enforcement wrapper
cat << 'EOF' > /usr/local/bin/run_guarded
#!/usr/bin/env bash
ALL_ARGS="$*"
SCOPE_FILE="${SCOPE_FILE:-/workspace/scope.txt}"

if [ -f "$SCOPE_FILE" ]; then
    TOKENS=$(printf '%s\n' "$ALL_ARGS" \
      | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?|[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}' \
      | sort -u || true)
    for tok in $TOKENS; do
        if ! scope_check "$tok" >/dev/null 2>&1; then
            echo "[-] BLOCKED: '${tok}' is not listed in ${SCOPE_FILE}."
            echo "    Add it to scope.txt, or run with explicit human approval."
            exit 3
        fi
    done
fi
exec safe-run $ALL_ARGS
EOF

# --- Stateless Metasploit wrapper
cat << 'EOF' > /usr/local/bin/msf-run
#!/usr/bin/env bash
set -uo pipefail
MODULE="$1"; shift || true
ACTION="exploit"
SETS=()
for arg in "$@"; do
    case "$arg" in
        set) continue ;;
        run|exploit|check|back|exit) ACTION="$arg" ;;
        *=*) SETS+=("set -g ${arg}") ;;
    esac
done

CHAIN="db_status"
for s in "${SETS[@]}"; do CHAIN+="; ${s}"; done
CHAIN+="; ${ACTION}"
[ "$ACTION" != "check" ] && CHAIN+="; exit"

echo "[*] msfconsole -q -x '${CHAIN}'" >&2
NO_COLOR=1 TERM=dumb msfconsole -q -x "$CHAIN" 2>&1
EOF

# --- Metasploit MCP Server
cat << 'EOF' > /usr/local/bin/msf-mcp
#!/usr/bin/env python3
import re
import subprocess
import mcp.server.fastmcp as _fm

FastMCP = _fm.FastMCP
mcp = FastMCP("metasploit")
TIMEOUT = 300

def _msf(chain):
    try:
        r = subprocess.run(
            ["msfconsole", "-q", "-x", chain + "; exit"],
            capture_output=True, text=True, timeout=TIMEOUT,
            env={"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/root",
                 "TERM": "dumb", "NO_COLOR": "1"},
        )
        out = (r.stdout or "") + (r.stderr or "")
        out = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", out)
        return "\n".join(out.splitlines()[:400]) or "(no output)"
    except subprocess.TimeoutExpired:
        return "[-] msfconsole timed out after %ds" % TIMEOUT

@mcp.tool()
def search_exploits(query):
    return _msf("search type:exploit name:%s" % query)

@mcp.tool()
def search_modules(query, module_type="all"):
    return _msf("search type:%s %s" % (module_type, query))

@mcp.tool()
def module_options(module):
    return _msf("use %s; show options" % module)

@mcp.tool()
def run_module(module, options="", action="run"):
    chain = "use %s" % module
    for pair in options.split():
        if "=" in pair:
            chain += "; set -g %s" % pair
    chain += "; %s" % action
    return _msf(chain)

@mcp.tool()
def db_nmap(target, args="-sV -Pn"):
    return _msf("db_nmap %s %s" % (args, target))

@mcp.tool()
def db_query(table="services", filters=""):
    return _msf("db_%s %s" % (table, filters))

@mcp.tool()
def msfvenom_build(payload, fmt="elf", outfile="", options=""):
    cmd = ["msfvenom", "-p", payload, "-f", fmt]
    for pair in options.split():
        if "=" in pair:
            cmd.append(pair)
    if outfile:
        cmd += ["-o", outfile]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        out = (r.stdout or "") + (r.stderr or "")
        return out if out.strip() else "[+] wrote %s" % (outfile or "stdout")
    except subprocess.TimeoutExpired:
        return "[-] msfvenom timed out"

if __name__ == "__main__":
    mcp.run(transport="stdio")
EOF

# =======================================================================
# --- Cleanup script: wipe workspace data + drop/recreate MSF database
# =======================================================================
cat << 'CLEANEOF' > /usr/local/bin/cleanup
#!/usr/bin/env bash
set -e

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
RST='\033[0m'

FORCE=0
for arg in "$@"; do
    case "$arg" in
        -f|--force) FORCE=1 ;;
        -h|--help)
            echo "Usage: cleanup [-f|--force]"
            echo "  Wipes /workspace contents and resets the Metasploit database."
            echo "  -f  Skip confirmation prompt."
            exit 0
            ;;
    esac
done

if [ "$FORCE" -ne 1 ]; then
    echo -e "${YLW}[!] This will DESTROY:${RST}"
    echo "      - All files under /workspace  (loot, logs, AGENTS.md, scope.txt, ...)"
    echo "      - The entire Metasploit database  (hosts, services, creds, loot)"
    echo ""
    read -p "    Type 'yes' to confirm: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "[-] Aborted."
        exit 1
    fi
fi

# --- 1. Reset Metasploit database ---
echo -e "${YLW}[*] Resetting Metasploit database...${RST}"
if pg_isready -q 2>/dev/null; then
    # Kill any lingering msf connections
    sudo -u postgres psql -c \
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='msf' AND pid <> pg_backend_pid();" \
      >/dev/null 2>&1 || true
    sudo -u postgres dropdb --if-exists msf 2>/dev/null || true
    sudo -u postgres createdb -O msf msf 2>/dev/null || true
    echo -e "${GRN}[+] MSF database dropped and recreated.${RST}"
else
    echo "[!] PostgreSQL not running. Starting it..."
    pg_ctlcluster "$(pg_lsclusters -h | awk '{print $1}' | head -n1)" main start 2>/dev/null \
      || service postgresql start 2>/dev/null || true
    sleep 2
    if pg_isready -q 2>/dev/null; then
        sudo -u postgres psql -c \
          "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='msf' AND pid <> pg_backend_pid();" \
          >/dev/null 2>&1 || true
        sudo -u postgres dropdb --if-exists msf 2>/dev/null || true
        sudo -u postgres createdb -O msf msf 2>/dev/null || true
        echo -e "${GRN}[+] MSF database dropped and recreated.${RST}"
    else
        echo -e "${RED}[-] Could not start PostgreSQL. Database NOT cleaned.${RST}"
    fi
fi

# --- 2. Wipe workspace ---
echo -e "${YLW}[*] Cleaning /workspace...${RST}"
# Remove everything except hidden mount metadata
find /workspace -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
echo -e "${GRN}[+] /workspace wiped.${RST}"

# --- 3. Clear OpenCode session state ---
echo -e "${YLW}[*] Clearing OpenCode sessions...${RST}"
rm -rf "$HOME/.local/share/opencode" /workspace/.opencode 2>/dev/null || true
echo -e "${GRN}[+] Sessions cleared.${RST}"

echo ""
echo -e "${GRN}[+] Cleanup complete. Ready for the next challenge.${RST}"
CLEANEOF

# =======================================================================
# --- Xvfb + RDP helper: start virtual display and connect to target
# =======================================================================
cat << 'RDPEOF' > /usr/local/bin/rdp-connect
#!/usr/bin/env bash
set -eo pipefail
# Usage: rdp-connect <target_ip> <user> <password> [resolution]
#   Starts Xvfb if needed, connects xfreerdp headlessly.
#   Screenshots: rdp-screenshot
#   Keystrokes:  rdp-type "commands here"
#   Kill:        rdp-disconnect

TARGET="${1:?Usage: rdp-connect <ip> <user> <pass> [WxH]}"
USER="${2:?}"
PASS="${3:?}"
RES="${4:-1024x768}"
DISPLAY_NUM="${RDP_DISPLAY:-99}"
export DISPLAY=":${DISPLAY_NUM}"

# Start Xvfb if not already running on this display
if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    echo "[*] Starting Xvfb on $DISPLAY (${RES})..."
    Xvfb "$DISPLAY" -screen 0 "${RES}x24" -ac +extension GLX +render -noreset &
    XVFB_PID=$!
    echo "$XVFB_PID" > /tmp/xvfb.pid
    sleep 1
    if ! kill -0 "$XVFB_PID" 2>/dev/null; then
        echo "[-] Xvfb failed to start."
        exit 1
    fi
    echo "[+] Xvfb running (PID $XVFB_PID)"
fi

# Kill any existing xfreerdp on this display
pkill -f "xfreerdp3.*${TARGET}" 2>/dev/null || true
sleep 0.5

echo "[*] Connecting to ${TARGET} as ${USER}..."
xfreerdp3 /v:"${TARGET}" /u:"${USER}" /p:"${PASS}" \
    /size:"${RES}" /cert:ignore /sec:any \
    /bpp:16 -wallpaper -aero -menu-anims -themes -fonts \
    +clipboard /dynamic-resolution \
    /log-level:ERROR &
RDP_PID=$!
echo "$RDP_PID" > /tmp/xfreerdp.pid
echo "[+] xfreerdp3 launched (PID $RDP_PID). DISPLAY=$DISPLAY"
echo "    Use: rdp-screenshot, rdp-type, rdp-disconnect"
RDPEOF

cat << 'RDPSCR' > /usr/local/bin/rdp-screenshot
#!/usr/bin/env bash
# Take a screenshot of the RDP session. Optionally OCR it.
DISPLAY_NUM="${RDP_DISPLAY:-99}"
export DISPLAY=":${DISPLAY_NUM}"
OUTDIR="/workspace/loot/screenshots"
mkdir -p "$OUTDIR"
STAMP=$(date +%Y%m%d-%H%M%S)
IMG="$OUTDIR/rdp-${STAMP}.png"

if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    echo "[-] No display at $DISPLAY. Run rdp-connect first."
    exit 1
fi

scrot -d 1 "$IMG" 2>/dev/null || import -window root "$IMG"
echo "[+] Screenshot: $IMG"

# If --ocr flag is passed, run tesseract
if [ "${1:-}" = "--ocr" ] || [ "${1:-}" = "-o" ]; then
    TXT="${IMG%.png}.txt"
    tesseract "$IMG" "${IMG%.png}" --psm 6 2>/dev/null
    if [ -f "$TXT" ]; then
        echo "--- OCR output ---"
        cat "$TXT"
        echo "--- end OCR ---"
    fi
fi
RDPSCR

cat << 'RDPTYPE' > /usr/local/bin/rdp-type
#!/usr/bin/env bash
# Send keystrokes to the RDP window.
# Usage: rdp-type "text to type"
#        rdp-type --key Return      (send a single key)
#        rdp-type --cmd "whoami"    (type + press Enter)
DISPLAY_NUM="${RDP_DISPLAY:-99}"
export DISPLAY=":${DISPLAY_NUM}"

if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    echo "[-] No display at $DISPLAY. Run rdp-connect first."
    exit 1
fi

# Small delay to make sure window has focus
sleep 0.3

case "${1:-}" in
    --key)
        shift
        xdotool key "$@"
        ;;
    --cmd)
        shift
        xdotool type --clearmodifiers --delay 30 "$*"
        sleep 0.1
        xdotool key Return
        ;;
    *)
        xdotool type --clearmodifiers --delay 30 "$*"
        ;;
esac
RDPTYPE

cat << 'RDPDC' > /usr/local/bin/rdp-disconnect
#!/usr/bin/env bash
echo "[*] Killing xfreerdp3..."
pkill -f xfreerdp3 2>/dev/null || true
echo "[*] Killing Xvfb..."
if [ -f /tmp/xvfb.pid ]; then
    kill "$(cat /tmp/xvfb.pid)" 2>/dev/null || true
    rm -f /tmp/xvfb.pid
fi
pkill -f Xvfb 2>/dev/null || true
rm -f /tmp/xfreerdp.pid
echo "[+] RDP session torn down."
RDPDC

# --- Finalize Permissions
chmod +x /usr/local/bin/safe-run /usr/local/bin/scope_check \
         /usr/local/bin/run_guarded /usr/local/bin/msf-run \
         /usr/local/bin/msf-mcp /usr/local/bin/opencode-select \
         /usr/local/bin/cleanup \
         /usr/local/bin/rdp-connect /usr/local/bin/rdp-screenshot \
         /usr/local/bin/rdp-type /usr/local/bin/rdp-disconnect

echo "[+] Agent tools installed successfully."
