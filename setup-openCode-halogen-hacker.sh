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

# --- Stateless Metasploit wrapper (Removed -n flag)
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

# --- Metasploit MCP Server (Removed -n flag)
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

# --- Launcher Script (Added DB YAML generation)
cat << 'EOF' > /usr/local/bin/opencode-select
#!/usr/bin/env bash
HALOGEN_URL="${HALOGEN_URL:-http://host.containers.internal:8731/v1}"

echo "[*] Starting PostgreSQL..."
pg_ctlcluster "$(pg_lsclusters -h | awk '{print $1}' | head -n1)" main start 2>/dev/null \
  || service postgresql start 2>/dev/null || true
sleep 2

if ! pg_isready -q; then
    echo "[!] PostgreSQL not reachable; db_nmap and db_* queries will fail."
fi

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='msf'" 2>/dev/null | grep -q 1; then
    echo "[*] Initialising msf database role..."
    sudo -u postgres psql -c "CREATE ROLE msf LOGIN PASSWORD 'msf';" >/dev/null 2>&1
    sudo -u postgres psql -c "CREATE DATABASE msf OWNER msf;" >/dev/null 2>&1
fi

# Ensure Metasploit connects to the local database
mkdir -p /root/.msf4
if [ ! -f /root/.msf4/database.yml ]; then
    echo "[*] Generating Metasploit database.yml..."
    cat << 'DBEOF' > /root/.msf4/database.yml
production:
  adapter: postgresql
  database: msf
  username: msf
  password: msf
  host: 127.0.0.1
  port: 5432
  pool: 75
  timeout: 5
DBEOF
fi

echo "[*] Querying Halogen Server at ${HALOGEN_URL}..."
RESPONSE=$(curl -s --connect-timeout 5 "${HALOGEN_URL}/models")
if [ -z "$RESPONSE" ] || ! echo "$RESPONSE" | jq -e '.data' > /dev/null 2>&1; then
    echo "[-] Error: could not reach Halogen at ${HALOGEN_URL}"
    echo "    Make sure Halogen is running and listening on port 8731,"
    echo "    and your SSH tunnel is bound to 0.0.0.0."
    exit 1
fi

mapfile -t MODELS < <(echo "$RESPONSE" | jq -r '.data[].id')
if [ ${#MODELS[@]} -eq 0 ]; then
    echo "[-] No models loaded in Halogen."
    exit 1
fi

echo ""
echo "================================================================="
echo "                    Available Halogen Models                     "
echo "================================================================="
for i in "${!MODELS[@]}"; do
    MODEL_ID="${MODELS[$i]}"
    printf " [%d] %s\n" "$((i+1))" "$MODEL_ID"
done
echo "================================================================="
echo ""

if [ ${#MODELS[@]} -eq 1 ]; then
    SELECTED_MODEL="${MODELS[0]}"
    echo "[*] Automatically selected active model: $SELECTED_MODEL"
else
    while true; do
        read -p "Select a model to load [1-${#MODELS[@]}]: " SELECTION
        if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "${#MODELS[@]}" ]; then
            SELECTED_MODEL="${MODELS[$((SELECTION-1))]}"
            break
        else
            echo "Invalid selection. Enter a number between 1 and ${#MODELS[@]}."
        fi
    done
fi

mkdir -p "$HOME/.config/opencode"

echo "$RESPONSE" | jq --arg sel "$SELECTED_MODEL" --arg base "$HALOGEN_URL" '{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "halogen": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Halogen Server",
      "options": {
        "baseURL": $base,
        "apiKey": "halogen",
        "temperature": 0.2,
        "timeout": 600000,
        "headerTimeout": 60000,
        "chunkTimeout": 300000
      },
      "models": (
        [.data[]]
        | reduce .[] as $m ({}; . + {
            ($m.id): {
              "name": $m.id,
              "attachment": true,
              "modalities": {
                "input": ["text", "image"],
                "output": ["text"]
              },
              "limit": {
                "context": 262144,
                "output": 16384
              }
            }
          })
      )
    }
  },
  "model": ("halogen/" + $sel),
  "mcp": {
    "metasploit": {
      "type": "local",
      "command": [
        "/usr/local/bin/msf-mcp"
      ],
      "enabled": true
    }
  },
  "permission": {
    "*": "allow",
    "external_directory": "allow",
    "doom_loop": "allow"
  }
}' > "$HOME/.config/opencode/opencode.json"

echo "[+] Configured OpenCode with active model: $SELECTED_MODEL"

# Preserve sessions inside workspace
rm -rf "$HOME/.local/share/opencode"
mkdir -p /workspace/.opencode
mkdir -p "$HOME/.local/share"
ln -sfn /workspace/.opencode "$HOME/.local/share/opencode"

echo "[*] Starting OpenCode..."
echo ""

exec opencode "$@"
EOF

# --- Finalize Permissions
chmod +x /usr/local/bin/safe-run /usr/local/bin/scope_check \
         /usr/local/bin/run_guarded /usr/local/bin/msf-run \
         /usr/local/bin/msf-mcp /usr/local/bin/opencode-select

echo "[+] Agent tools installed successfully."