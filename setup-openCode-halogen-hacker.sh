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

# --- State board CLI (notes/STATE.md). Small models follow a CLI more reliably
#     than "edit the file"; it also echoes what it stored so mangled secrets show.
cat << 'NOTEEOF' > /usr/local/bin/note
#!/usr/bin/env python3
"""note -- keep the state board, /workspace/notes/STATE.md, current.

  note <section> '<text>'            add a bullet under <section>
  note --replace <section> '<text>'  replace everything under <section> with this
  note rm <section> '<text>'         delete the one bullet in <section> containing <text>
  note show                          print the board
  note --sync <section> <tag>        (for importers) replace the bullets tagged [<tag>]
                                     with stdin lines; untagged bullets are left alone

  Text containing a ' : pass it on stdin instead, one bullet per line:
      note cred <<'EOF'
      admin : it's$ecret
      EOF

sections: scope access cred service finding failed next stuck
  stuck = record a blocker (goes under failed, and into notes/STUCK.md for human review)
"""
import datetime
import fcntl
import os
import select
import sys

STATE = "/workspace/notes/STATE.md"
STUCK = "/workspace/notes/STUCK.md"
TEMPLATE = "/opt/pentest-agent/templates/STATE.md"
LOCK = "/tmp/.note.lock"
WARN_BYTES = int(os.environ.get("NOTE_WARN_BYTES", "4096"))

HEADERS = {
    "scope": "## Scope",
    "access": "## Access",
    "cred": "## Credentials",
    "service": "## Services",
    "finding": "## Findings",
    "failed": "## Tried & failed (DO NOT REPEAT)",
    "next": "## Next",
}
# Small models pluralise and paraphrase section names; accept the obvious ones.
ALIASES = {
    "creds": "cred", "credential": "cred", "credentials": "cred",
    "services": "service", "findings": "finding",
    "fail": "failed", "tried": "failed", "todo": "next", "stuck": "stuck",
}


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


def section_key(word):
    word = word.lower()
    key = word if word in HEADERS else ALIASES.get(word)
    if key is None:
        die(f"[-] unknown section '{word}'. sections: {' '.join(HEADERS)} stuck")
    return key


def stdin_lines():
    """Heredoc/piped text. Never blocks on an idle stdin."""
    try:
        if sys.stdin.isatty() or not select.select([sys.stdin], [], [], 0.5)[0]:
            return []
        return sys.stdin.read().splitlines()
    except (AttributeError, OSError, ValueError):
        return []


def parse(text):
    """-> (preamble lines, [[header, body lines], ...])"""
    pre, sections = [], []
    for line in text.splitlines():
        line = line.rstrip()
        if line.startswith("## "):
            sections.append([line, []])
        elif sections:
            sections[-1][1].append(line)
        else:
            pre.append(line)
    # Bodies carry no edge blanks, so appends land right after the last bullet.
    return pre, [[h, trim(body)] for h, body in sections]


def trim(lines):
    while lines and not lines[0]:
        lines = lines[1:]
    while lines and not lines[-1]:
        lines = lines[:-1]
    return lines


def render(pre, sections):
    out = trim(pre)
    for header, body in sections:
        out += ["", header] + trim(body)
    return "\n".join(out) + "\n"


def load():
    for path in (STATE, TEMPLATE):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                return f.read()
        except FileNotFoundError:
            pass
    return "# STATE\n" + "".join(f"\n{h}\n" for h in HEADERS.values())


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0 if argv else 2
    if argv[0] == "show":
        try:
            with open(STATE, encoding="utf-8", errors="replace") as f:
                print(f.read(), end="")
        except FileNotFoundError:
            print("(no notes/STATE.md yet -- record something with: note <section> '<text>')")
        return 0

    mode = "add"
    if argv[0] in ("--replace", "rm", "--sync"):
        mode, argv = argv[0].lstrip("-"), argv[1:]
    if not argv:
        die("usage: note [--replace|rm] <section> '<text>'   (note --help)")
    key = section_key(argv[0])
    if mode == "sync":
        if len(argv) != 2:
            die("usage: note --sync <section> <tag>   (bullets on stdin)")
        suffix, text = f" [{argv[1]}]", ""
    else:
        text = " ".join(argv[1:])
    items = [i.strip().removeprefix("- ").strip()
             for i in (text.splitlines() if text else stdin_lines())]
    items = [i for i in items if i]
    if not items and mode != "sync":   # an empty sync clears that tag's bullets
        die(f"[-] no text given. usage: note {argv[0]} '<text>'")
    if key == "stuck" and mode != "add":
        die("[-] stuck only appends; edit that section via 'failed'")
    bullets = [f"STUCK: {i}" for i in items] if key == "stuck" else items
    header = HEADERS["failed" if key == "stuck" else key]
    now = f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}"

    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(LOCK, "w") as lock:
        # Parallel tool calls must not lose each other's read-modify-write.
        fcntl.flock(lock, fcntl.LOCK_EX)
        pre, sections = parse(load())
        sec = next((s for s in sections if s[0].lower() == header.lower()), None)
        if sec is None:
            sec = [header, []]
            sections.append(sec)

        if mode == "rm":
            needle = " ".join(items).lower()
            hits = [l for l in sec[1] if l.lstrip().startswith("- ") and needle in l.lower()]
            if not hits:
                die(f"[-] no bullet under '{header[3:]}' contains: {needle}", 1)
            if len(hits) > 1:
                die("[-] more than one bullet matches; be more specific:\n" + "\n".join(hits), 1)
            sec[1].remove(hits[0])
            report = [f"[-] {key} removed: {hits[0].strip()[2:]}"]
        elif mode == "replace":
            sec[1] = [f"- {b}" for b in bullets]
            report = [f"[+] {key} (replaced): {b}" for b in bullets]
        elif mode == "sync":
            old = [l for l in sec[1] if l.endswith(suffix)]
            new = list(dict.fromkeys(f"- {b}{suffix}" for b in bullets))
            sec[1] = [l for l in sec[1] if not l.endswith(suffix)] + new
            report = ([f"[+] {key}: {l[2:]}" for l in new if l not in old]
                      + [f"[-] {key} removed: {l[2:]}" for l in old if l not in new]
                      + [f"[=] {key}: {sum(l in old for l in new)} unchanged{suffix}"])
        else:
            report = []
            for b in bullets:
                if f"- {b}" in (l.strip() for l in sec[1]):
                    report.append(f"[=] {key} (already recorded): {b}")
                else:
                    sec[1].append(f"- {b}")
                    report.append(f"[+] {key}: {b}")

        stamp = f"_Updated: {now}_"
        at = next((n for n, l in enumerate(pre) if l.startswith("_Updated:")), None)
        if at is None:
            pre.insert(1 if pre else 0, stamp)
        else:
            pre[at] = stamp

        tmp = f"{STATE}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(render(pre, sections))
        os.replace(tmp, STATE)

        if key == "stuck":
            fresh = not os.path.exists(STUCK)
            with open(STUCK, "a", encoding="utf-8") as f:
                if fresh:
                    f.write("# STUCK -- blockers flagged for human review\n\n")
                f.writelines(f"- {now} {i}\n" for i in items)

    print("\n".join(report))
    size = os.path.getsize(STATE)
    if size > WARN_BYTES:
        print(f"[!] STATE.md is {size} bytes -- it is the short board, not a log. Prune stale "
              "bullets (note rm / note --replace) and move detail to the wiki (wiki add <page> '...').")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
NOTEEOF

# --- Assessment write-up CLI (ASSESSMENT.md). Append-only, so the model can
#     never rewrite (or clobber) a growing report.
cat << 'ASSESSEOF' > /usr/local/bin/assess
#!/usr/bin/env bash
# assess '<title>' '<text>'    append a timestamped, report-ready entry to ASSESSMENT.md
# assess '<title>' <<'EOF'     ...or pass the body on stdin (multi-line is fine)
set -uo pipefail
DOC="/workspace/ASSESSMENT.md"
TEMPLATE="/opt/pentest-agent/templates/ASSESSMENT.md"

TITLE="${1:-}"
[ $# -gt 0 ] && shift
if [ -z "$TITLE" ]; then
    echo "usage: assess '<title>' '<what it is, impact, exact repro, evidence path>'" >&2
    exit 2
fi
if [ $# -gt 0 ]; then
    TEXT="$*"
elif [ ! -t 0 ]; then
    TEXT=$(timeout 2 cat)   # heredoc/pipe; the timeout guards against an idle stdin
else
    TEXT=""
fi
if [ -z "${TEXT//[[:space:]]/}" ]; then
    echo "[-] no body given: say what it is, impact, exact repro, evidence path" >&2
    exit 2
fi

[ -f "$DOC" ] || cp "$TEMPLATE" "$DOC" 2>/dev/null || printf '# Assessment\n' > "$DOC"
printf '\n## %s — %s\n\n%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TITLE" "$TEXT" >> "$DOC"
echo "[+] appended to ASSESSMENT.md: $TITLE"
ASSESSEOF

# --- MSF DB -> state board. Reads the Metasploit Postgres DB directly (instant,
#     no msfconsole boot, no table-scraping) and syncs through `note`.
cat << 'MSFNOTEEOF' > /usr/local/bin/note-from-msf
#!/usr/bin/env python3
"""note-from-msf -- import open services and credentials from the Metasploit
database onto the state board, and write the full dump to notes/msf.md.

Run it after db_nmap or any MSF scanner / login module. Safe to re-run: the
imported bullets are tagged [msf] and replaced on each run (note --sync), and
anything already on the board in your own words is not repeated.
"""
import csv
import datetime
import io
import json
import os
import re
import subprocess
import sys

NOTES = "/workspace/notes"
STATE = f"{NOTES}/STATE.md"
DUMP = f"{NOTES}/msf.md"
LOOT = "/workspace/loot/msf-creds"
TAG = "msf"
MAX_INLINE = 200   # longer secrets (SSH keys, krb5tgs hashes, pfx) go to a file
MAX_INFO = 120

# The database opencode-select provisions (see /root/.msf4/database.yml).
PG = {"PGHOST": "127.0.0.1", "PGPORT": "5432", "PGUSER": "msf",
      "PGPASSWORD": "msf", "PGDATABASE": "msf"}

# Schema: metasploit-framework db/schema.rb.
HOSTS_SQL = """
SELECT host(address) AS address, name, os_name, os_flavor FROM hosts ORDER BY address
"""
SERVICES_SQL = """
SELECT host(h.address) AS address, s.port, s.proto, s.name, s.state, s.info,
       to_jsonb(s)->'resource' AS resource   -- NULL on MSF builds predating the column
FROM services s JOIN hosts h ON h.id = s.host_id
ORDER BY h.address, s.port, s.proto, s.name
"""
# One row per (credential, login), the way msfconsole's `creds` lists them.
CREDS_SQL = """
SELECT c.id, c.origin_type, pub.username, priv.type AS private_type,
       priv.data AS secret, priv.jtr_format, r.key AS realm_key, r.value AS realm,
       l.status, host(lh.address) AS l_host, ls.port AS l_port,
       ls.proto AS l_proto, ls.name AS l_name,
       host(oh.address) AS o_host, os.port AS o_port,
       os.proto AS o_proto, os.name AS o_name
FROM metasploit_credential_cores c
LEFT JOIN metasploit_credential_publics pub ON pub.id = c.public_id
LEFT JOIN metasploit_credential_privates priv ON priv.id = c.private_id
LEFT JOIN metasploit_credential_realms r ON r.id = c.realm_id
LEFT JOIN metasploit_credential_logins l ON l.core_id = c.id
LEFT JOIN services ls ON ls.id = l.service_id
LEFT JOIN hosts lh ON lh.id = ls.host_id
LEFT JOIN metasploit_credential_origin_services osv
       ON c.origin_type = 'Metasploit::Credential::Origin::Service' AND osv.id = c.origin_id
LEFT JOIN services os ON os.id = osv.service_id
LEFT JOIN hosts oh ON oh.id = os.host_id
ORDER BY c.id, l.id
"""

TYPES = {"Password": "password", "NTLMHash": "NTLM hash", "NonreplayableHash": "hash",
         "PostgresMD5": "postgres md5", "SSHKey": "SSH key", "KrbEncKey": "krb enc key",
         "Pkcs12": "pkcs12"}
ORIGINS = {"Session": "from a session", "Import": "from an import", "Manual": "entered manually",
           "CrackedPassword": "cracked from a hash"}


def query(sql):
    env = {**PG, **os.environ}   # an explicit PG* variable wins
    try:
        r = subprocess.run(["psql", "-X", "-q", "--csv", "-v", "ON_ERROR_STOP=1", "-c", sql],
                           capture_output=True, text=True, env=env, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        sys.exit(f"[-] can't run psql against the MSF database: {e}")
    if r.returncode:
        err = r.stderr.strip()
        if 'relation "' in err:
            sys.exit("[-] the MSF database has no tables yet -- run an MSF module "
                     "(e.g. the db_nmap MCP tool) first")
        sys.exit(f"[-] can't query the MSF database: {err.splitlines()[0] if err else r.returncode}")
    return list(csv.DictReader(io.StringIO(r.stdout)))


def where(host, port, proto, name):
    return f"{host}:{port}/{proto}" + (f" {name}" if name else "")


def short(text, limit):
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[:limit - 3] + "..."


def service_line(s, limit):
    line = where(s["address"], s["port"], s["proto"], s["name"])
    if s["info"]:
        line += f" -- {short(s['info'], limit)}"
    try:
        res = json.loads(s["resource"] or "{}")
    except ValueError:
        res = s["resource"]
    if res:
        line += " (" + (", ".join(f"{k}={v}" for k, v in res.items())
                        if isinstance(res, dict) else str(res)) + ")"
    return line


def host_line(h):
    os_name = " ".join(x for x in (h["os_name"], h["os_flavor"]) if x and x != "Unknown")
    if not (h["name"] or os_name):
        return None
    return f"{h['address']} host: " + " ".join(
        x for x in (h["name"], f"({os_name})" if os_name else "") if x)


def cred_line(row, logins):
    user = row["username"] or ""
    if row["realm"] and row["realm_key"] == "Active Directory Domain":
        who = f"{row['realm']}\\{user}"
    elif row["realm"]:
        who = f"{user}@{row['realm']}"
    else:
        who = user
    origin = (row["origin_type"] or "").rsplit("::", 1)[-1]
    ptype = (row["private_type"] or "").rsplit("::", 1)[-1]
    kind = TYPES.get(ptype, ptype.lower() or "no secret")
    if ptype == "NonreplayableHash" and row["jtr_format"]:
        kind = f"hash {row['jtr_format']}"
    secret = row["secret"] or ""
    if len(secret) > MAX_INLINE or "\n" in secret:
        os.makedirs(LOOT, exist_ok=True)
        path = f"{LOOT}/core-{row['id']}.txt"
        with open(path, "w", encoding="utf-8") as f:
            f.write(secret + "\n")
        secret = f"<in {path.removeprefix('/workspace/')}>"

    by_status = {}
    for status, w in logins:
        by_status.setdefault(status, []).append(w)
    parts = []
    for status in sorted(by_status, key=lambda s: s != "Successful"):
        ws = by_status[status]
        label = "valid on" if status == "Successful" else f"{status.lower()} on"
        parts.append(f"{label} {', '.join(ws[:3])}" + (f" +{len(ws) - 3} more" if len(ws) > 3 else ""))
    if not parts:
        if row["o_host"]:
            parts.append("from " + where(row["o_host"], row["o_port"], row["o_proto"], row["o_name"]))
        else:
            parts.append(ORIGINS.get(origin, f"from {origin or 'msf'}"))
    return f"{who or '(no user)'} : {secret or '(none)'} ({kind}) -- {'; '.join(parts)}", user, row["secret"] or ""


def own_bullets(header):
    """Bullets the model wrote itself (untagged) under one board section."""
    try:
        with open(STATE, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return []
    out, inside = [], False
    for line in lines:
        if line.startswith("## "):
            inside = line.strip().lower() == header.lower()
        elif inside and line.startswith("- ") and not line.endswith(f" [{TAG}]"):
            out.append(line.lower())
    return out


def sync(section, lines):
    r = subprocess.run(["note", "--sync", section, TAG], input="\n".join(lines) + "\n",
                       capture_output=True, text=True)
    print((r.stdout + r.stderr).rstrip())
    if r.returncode:
        sys.exit(r.returncode)


def main():
    hosts = query(HOSTS_SQL)
    services = query(SERVICES_SQL)
    creds = {}
    for row in query(CREDS_SQL):
        c = creds.setdefault(row["id"], (row, []))
        if row["status"]:
            c[1].append((row["status"], where(row["l_host"], row["l_port"], row["l_proto"], row["l_name"])))
    cred_lines = [cred_line(row, logins) for row, logins in creds.values()]

    # Full detail -> notes/msf.md (regenerated each run).
    os.makedirs(NOTES, exist_ok=True)
    with open(DUMP, "w", encoding="utf-8") as f:
        f.write("# MSF database dump\n_Regenerated by note-from-msf at "
                f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}; the [msf] bullets in STATE.md come from here._\n")
        f.write("\n## Hosts\n" + "".join(
            "- " + " ".join(x for x in (h["address"], h["name"], h["os_name"], h["os_flavor"]) if x) + "\n"
            for h in hosts))
        f.write("\n## Services\n" + "".join(f"- {service_line(s, 10**6)} [{s['state']}]\n" for s in services))
        f.write("\n## Credentials\n" + "".join(f"- {line}\n" for line, _, _ in cred_lines))

    # Short board: open services and creds, minus noise and what's already there.
    own_svc, own_cred = own_bullets("## Services"), own_bullets("## Credentials")
    svc_lines, skipped_rpc, skipped_dup = [h for h in map(host_line, hosts) if h], 0, 0
    for s in services:
        if s["state"] != "open":
            continue
        if s["name"] == "msrpc" and int(s["port"]) >= 49152:   # dynamic RPC endpoints
            skipped_rpc += 1
            continue
        key = re.compile(r"(?<![\d.])" + re.escape(f"{s['address']}:{s['port']}") + r"(?!\d)")
        if any(key.search(b) for b in own_svc):
            skipped_dup += 1
            continue
        svc_lines.append(service_line(s, MAX_INFO))
    board_creds = []
    for line, user, secret in cred_lines:
        if secret and any(secret.lower() in b and user.lower() in b for b in own_cred):
            skipped_dup += 1
            continue
        board_creds.append(line)

    sync("service", svc_lines)
    sync("cred", board_creds)

    # Feed every username MSF knows into the account roster (deduped there).
    usernames = sorted({row["username"] for row, _ in creds.values() if row["username"]})
    if usernames:
        subprocess.run(["roster", "add", *usernames], capture_output=True, text=True)
    print(f"[*] {len(hosts)} hosts, {len(services)} services, {len(creds)} creds in MSF; "
          f"skipped {skipped_rpc} dynamic-RPC ports and {skipped_dup} already on the board. "
          f"Everything is in notes/msf.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
MSFNOTEEOF

# --- Engagement wiki CLI (wiki/). Depth that doesn't fit on the state board;
#     INDEX.md is generated after every write, never hand-written.
cat << 'WIKIEOF' > /usr/local/bin/wiki
#!/usr/bin/env python3
"""wiki -- the engagement wiki: detail that doesn't fit on the state board.

  wiki search <term>            find what you already know -- do this BEFORE re-enumerating
  wiki add <page> '<text>'      append to a page (created if new); text on stdin works too
  wiki show <page>              print a page
  wiki index                    list every page (wiki/INDEX.md, rebuilt after every write)
  wiki new <page> '<title>' [--tags a,b] [--use-when '<when to read it>']
                                create a page, or retitle / add tags to an existing one

pages: hosts/<ip>  web/<vhost>  users  attempts  (or any name)
e.g.   wiki add hosts/10.10.11.5 'nginx 1.18 on 80; /admin returns 401 without a cookie'
"""
import argparse
import difflib
import fcntl
import os
import re
import select
import sys

WIKI = "/workspace/wiki"
INDEX = f"{WIKI}/INDEX.md"
LOCK = "/tmp/.wiki.lock"
RESERVED = {"INDEX", "AGENTS"}
MAX_HITS = 60
WARN_BYTES = 12 * 1024

# Frontmatter for pages created implicitly: (title, tags, use_when).
DIR_DEFAULTS = {
    "hosts": ("Host {name}", ["host"], "working on {name}: ports, services, foothold, privesc"),
    "web": ("Web app {name}", ["web"], "attacking {name}: endpoints, params, auth, payloads"),
}
PAGE_DEFAULTS = {
    "users": ("Users and principals", ["users"], "looking up accounts, groups, and what each can do"),
    "attempts": ("Attempts in detail", ["attempts"], "checking exactly how something was already tried"),
}


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(f"{path}.tmp", "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(f"{path}.tmp", path)


def stdin_lines():
    """Heredoc/piped text. Never blocks on an idle stdin."""
    try:
        if sys.stdin.isatty() or not select.select([sys.stdin], [], [], 0.5)[0]:
            return []
        return sys.stdin.read().splitlines()
    except (AttributeError, OSError, ValueError):
        return []


def page_of(name):
    """Accept the spellings a model reaches for: hosts/x, wiki/hosts/x.md, /workspace/wiki/hosts/x.md."""
    p = name.strip()
    m = re.search(r"(?:^|/)wiki/", p)
    p = (p[m.end():] if m else p).removeprefix("./").removesuffix(".md").strip("/")
    parts = p.split("/")
    if (not re.fullmatch(r"[A-Za-z0-9._@-]+(/[A-Za-z0-9._@-]+)*", p)
            or any(x in (".", "..") for x in parts) or p in RESERVED):
        die(f"[-] bad page name '{name}'. use e.g. hosts/10.10.11.5, web/app.htb, users")
    return p, f"{WIKI}/{p}.md"


def split_front(text):
    if text.startswith("---\n"):
        end = text.find("\n---\n", 3)
        if end != -1:
            meta = {}
            for line in text[4:end].splitlines():
                key, sep, val = line.partition(":")
                if sep:
                    meta[key.strip()] = val.strip()
            return meta, text[end + 5:]
    return {}, text


def tags_of(meta):
    return [t.strip() for t in meta.get("tags", "").strip("[]").split(",") if t.strip()]


def join_front(meta, body):
    head = [f"title: {meta.get('title', '')}", f"tags: [{', '.join(tags_of(meta))}]",
            f"use_when: {meta.get('use_when', '')}"]
    head += [f"{k}: {v}" for k, v in meta.items() if k not in ("title", "tags", "use_when")]
    return "---\n" + "\n".join(head) + "\n---\n" + body


def defaults(p):
    top, _, rest = p.partition("/")
    if top in DIR_DEFAULTS and rest:
        title, tags, use = DIR_DEFAULTS[top]
    elif p in PAGE_DEFAULTS:
        title, tags, use = PAGE_DEFAULTS[p]
    else:
        title, tags, use = p.rsplit("/", 1)[-1].replace("-", " ").replace("_", " "), [], ""
    name = rest or p
    return {"title": title.format(name=name), "tags": ", ".join(tags), "use_when": use.format(name=name)}


def pages():
    out = []
    for dirpath, _, files in os.walk(WIKI):
        for f in files:
            rel = os.path.relpath(os.path.join(dirpath, f), WIKI)
            if f.endswith(".md") and rel[:-3] not in RESERVED:
                out.append(rel[:-3])
    return sorted(out)


def build_index():
    lines = ["# Wiki index",
             "_Generated by `wiki` after every write -- do not edit. Read a page: `wiki show <page>`._", ""]
    for p in pages():
        meta, body = split_front(read(f"{WIKI}/{p}.md"))
        heading = next((l[2:].strip() for l in body.splitlines() if l.startswith("# ")), "")
        line = f"- {p} -- {meta.get('title') or heading or p}"
        if tags_of(meta):
            line += f" [{', '.join(tags_of(meta))}]"
        if meta.get("use_when"):
            line += f" -- use when {meta['use_when']}"
        lines.append(line)
    if len(lines) == 3:
        lines.append("(no pages yet -- start one with: wiki add hosts/<ip> '<detail>')")
    write(INDEX, "\n".join(lines) + "\n")
    return lines


class Locked:
    def __enter__(self):
        self.f = open(LOCK, "w")
        fcntl.flock(self.f, fcntl.LOCK_EX)   # parallel tool calls must not lose writes

    def __exit__(self, *exc):
        self.f.close()


def cmd_add(args):
    if not args:
        die("usage: wiki add <page> '<text>'   (or text on stdin)")
    p, path = page_of(args[0])
    text = (" ".join(args[1:]) or "\n".join(stdin_lines())).strip("\n")
    if not text.strip():
        die(f"[-] no text given. usage: wiki add {args[0]} '<text>'")
    block = text if "\n" in text else f"- {text.strip().removeprefix('- ')}"
    with Locked():
        existing = read(path)
        meta, body = split_front(existing) if existing else ({}, "")
        if not meta:
            meta = defaults(p)
        if not body.strip():
            body = f"# {meta['title']}\n"
        if (block.strip() in body if "\n" in block
                else block.strip() in (l.strip() for l in body.splitlines())):
            print(f"[=] wiki/{p}.md already has: {text.strip().splitlines()[0][:100]}")
            return 0
        body = body.rstrip("\n") + "\n"
        last = body.rstrip("\n").splitlines()[-1]
        joined = "\n" not in block and last.startswith("- ")
        body += ("" if joined else "\n") + block + "\n"
        write(path, join_front(meta, body))
        build_index()
    print(f"[+] wiki/{p}.md: {text.strip().splitlines()[0][:100]}")
    size = os.path.getsize(path)
    if size > WARN_BYTES:
        print(f"[!] wiki/{p}.md is {size} bytes -- split it (e.g. {p}-web, {p}-privesc) "
              "so reading one doesn't flood the context.")
    return 0


def cmd_new(args):
    ap = argparse.ArgumentParser(prog="wiki new")
    ap.add_argument("page")
    ap.add_argument("title", nargs="*")
    ap.add_argument("--tags", default="")
    ap.add_argument("--use-when", default="")
    a = ap.parse_intermixed_args(args)
    p, path = page_of(a.page)
    with Locked():
        existing = read(path)
        meta, body = split_front(existing) if existing else ({}, "")
        meta = {**defaults(p), **meta}
        if a.title:
            meta["title"] = " ".join(a.title)
        new_tags = [t.strip() for t in a.tags.split(",") if t.strip()]
        meta["tags"] = ", ".join(dict.fromkeys(tags_of(meta) + new_tags))
        if a.use_when:
            meta["use_when"] = a.use_when
        if not body.strip():
            body = f"# {meta['title']}\n"
        write(path, join_front(meta, body))
        build_index()
    print(f"[+] wiki/{p}.md {'updated' if existing else 'created'}: {meta['title']} "
          f"[{meta['tags']}] -- use when {meta['use_when'] or '(not set)'}")
    return 0


def cross_refs(p):
    """Other pages that mention this host/app's key (ip or vhost), so reading one
    page surfaces the rest -- a small model reaches for `show`, not `search`.
    Returns (key, [page:line, ...]); empty for pages with no useful key."""
    top, _, rest = p.partition("/")
    if top not in ("hosts", "web") or not rest:
        return "", []
    key = rest   # the ip or the vhost
    refs = []
    for other in pages():
        if other == p:
            continue
        for n, line in enumerate(read(f"{WIKI}/{other}.md").splitlines(), 1):
            if key.lower() in line.lower():
                refs.append(f"{other}:{n}")
                break   # one hit per page is enough to point there
    return key, refs[:8]


def cmd_show(args):
    if not args:
        die("usage: wiki show <page>   (wiki index lists pages)")
    p, path = page_of(args[0])
    text = read(path)
    if not text:
        near = difflib.get_close_matches(p, pages(), n=3, cutoff=0.5)
        die(f"[-] no page wiki/{p}.md" + (f" -- did you mean: {', '.join(near)}" if near else
                                          " (wiki index lists pages)"), 1)
    print(text if text.endswith("\n") else text + "\n", end="")
    key, refs = cross_refs(p)
    if refs:
        print(f"\n_Also mentioned in: {', '.join(refs)} -- `wiki search {key}` for the lines._")
    return 0


def cmd_search(args):
    term = " ".join(args).strip()
    if not term:
        die("usage: wiki search <term>")
    hits = []
    for p in pages():
        for n, line in enumerate(read(f"{WIKI}/{p}.md").splitlines(), 1):
            if term.lower() in line.lower():
                hits.append(f"{p}:{n}: {line.strip()}")
    if not hits:
        print(f"(no wiki page mentions '{term}')")
        return 0
    print("\n".join(hits[:MAX_HITS]))
    if len(hits) > MAX_HITS:
        print(f"... {len(hits) - MAX_HITS} more matches -- use a narrower term")
    return 0


def main(argv):
    cmds = {"add": cmd_add, "new": cmd_new, "show": cmd_show, "search": cmd_search}
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0 if argv else 2
    if argv[0] == "index":
        with Locked():
            print("\n".join(build_index()))
        return 0
    if argv[0] not in cmds:
        die(f"[-] unknown command '{argv[0]}'. commands: search add show index new")
    return cmds[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
WIKIEOF

# --- Lessons-learned CLI (lessonsLearned.md). The one-way CANDIDATE channel from
#     this engagement to the baked-in knowledge: the model proposes, the human
#     reviews and promotes. Append-only; nothing here is auto-promoted.
cat << 'LESSONEOF' > /usr/local/bin/lesson
#!/usr/bin/env python3
"""lesson -- propose a reusable lesson for the knowledge base (human-reviewed).

  lesson <phase> <type> '<lesson>' [--fp '<os + key services>']
                                   [--evidence '<loot/logs/... or exact command>']
                                   [--dest '<reference/skill to amend, or Containerfile>']

Write one ONLY when it will hold on the NEXT box with the same fingerprint:
  - a reference said X would work and it didn't (say why),
  - something worked that no reference covered,
  - a stuck period got resolved (what unblocked it),
  - a tool/wrapper misbehaved (that is a `env` lesson).
NOT a lesson: anything true only on THIS box -- that goes in the wiki or notes.

phase: recon web foothold privesc ad lateral post
type:  technique tool env
Text with a ' : pass the lesson on stdin instead.
"""
import datetime
import os
import select
import sys

DOC = "/workspace/lessonsLearned.md"
PHASES = {"recon", "web", "foothold", "privesc", "ad", "lateral", "post"}
TYPES = {"technique", "tool", "env"}
ALIASES = {"initial": "foothold", "access": "foothold", "priv": "privesc",
           "escalation": "privesc", "privilege-escalation": "privesc",
           "activedirectory": "ad", "active-directory": "ad", "domain": "ad",
           "lateral-movement": "lateral", "movement": "lateral", "post-exploitation": "post",
           "postexploitation": "post", "enum": "recon", "enumeration": "recon",
           "tooling": "tool", "environment": "env", "config": "env"}

HEADER = ("# Lessons learned -- candidates for the knowledge base\n"
          "> Proposed by the agent, one per entry. REVIEW before promoting any of this into\n"
          "> agent-knowledge/ by hand -- nothing here is applied automatically.\n")


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


def canon(word, valid, label):
    w = word.lower()
    w = w if w in valid else ALIASES.get(w, w)
    if w not in valid:
        die(f"[-] unknown {label} '{word}'. {label}: {' '.join(sorted(valid))}")
    return w


def stdin_text():
    try:
        if sys.stdin.isatty() or not select.select([sys.stdin], [], [], 0.5)[0]:
            return ""
        return sys.stdin.read().strip()
    except (AttributeError, OSError, ValueError):
        return ""


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0 if argv else 2

    pos, opts, i = [], {}, 0
    while i < len(argv):
        a = argv[i]
        if a in ("--fp", "--fingerprint", "--evidence", "--dest"):
            key = {"--fingerprint": "--fp"}.get(a, a)
            if i + 1 >= len(argv):
                die(f"[-] {a} needs a value")
            opts[key], i = argv[i + 1], i + 2
        else:
            pos.append(a)
            i += 1

    if len(pos) < 2:
        die("usage: lesson <phase> <type> '<lesson>'   (lesson --help)")
    phase = canon(pos[0], PHASES, "phase")
    typ = canon(pos[1], TYPES, "type")
    lesson = " ".join(pos[2:]).strip() or stdin_text()
    if not lesson:
        die("[-] no lesson text. usage: lesson <phase> <type> '<lesson>'")

    fp = opts.get("--fp", "").strip()
    if not fp:
        print("[!] no --fp: a lesson with no fingerprint can't be matched to a future box; "
              "add '--fp \"<OS + key services>\"' (recording anyway).", file=sys.stderr)
    now = f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}"
    entry = (f"\n### {now} - {phase} - {typ}\n"
             f"- Fingerprint: {fp or '(not given -- which boxes does this apply to?)'}\n"
             f"- Lesson: {lesson}\n"
             f"- Evidence: {opts.get('--evidence', '(none)')}\n"
             f"- Suggested destination: {opts.get('--dest', '(unsure -- reviewer decides)')}\n")

    fresh = not os.path.exists(DOC)
    os.makedirs(os.path.dirname(DOC), exist_ok=True)
    with open(DOC, "a", encoding="utf-8") as f:
        if fresh:
            f.write(HEADER)
        f.write(entry)
    print(f"[+] lessonsLearned.md ({phase}/{typ}): {lesson[:100]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
LESSONEOF

# --- Transcript exporter: render an OpenCode session from the SQLite store to a
#     readable markdown file you can review without the TUI. (Sessions live in
#     .opencode/opencode.db -- session/message/part tables with JSON `data`.)
cat << 'EXPORTEOF' > /usr/local/bin/export-session
#!/usr/bin/env python3
"""export-session -- write an OpenCode session to loot/transcript-<ts>.md.

  export-session              latest session in this workspace
  export-session --list       list sessions (id, time, title)
  export-session <id>         a specific session
  export-session --all        every session, newest first

Best-effort and resilient to schema drift: unknown record shapes are skipped,
never fatal. Full command output for safe-run commands is in loot/logs/.
"""
import datetime
import json
import os
import sqlite3
import sys

DB = "/workspace/.opencode/opencode.db"
OUT_DIR = "/workspace/loot"
MAX_TOOL_LINES = 40


def connect():
    if not os.path.exists(DB):
        sys.exit(f"[-] no session store at {DB} (has OpenCode run in this workspace yet?)")
    try:
        return sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    except sqlite3.Error as e:
        sys.exit(f"[-] can't open {DB}: {e}")


def loads(s):
    try:
        return json.loads(s)
    except (TypeError, ValueError):
        return {}


def sessions(con):
    try:
        rows = con.execute("SELECT id, title, directory, time_created FROM session "
                           "ORDER BY time_created").fetchall()
    except sqlite3.Error:
        return []
    return rows


def when(ms):
    try:
        return datetime.datetime.fromtimestamp(ms / 1000).strftime("%Y-%m-%d %H:%M:%S")
    except (TypeError, ValueError, OSError):
        return "?"


def fence(text, lines=MAX_TOOL_LINES):
    body = (text or "").rstrip("\n").split("\n")
    clipped = body[:lines]
    out = "\n".join(clipped)
    if len(body) > lines:
        out += f"\n... ({len(body) - lines} more lines)"
    return out


def render_tool(data):
    tool = data.get("tool", "tool")
    state = data.get("state") or {}
    inp = state.get("input") or {}
    if tool == "bash":
        head = inp.get("command", "")
    else:
        head = ", ".join(f"{k}={v}" for k, v in inp.items() if k != "content")
    lines = [f"**{tool}**" + (f" — `{head}`" if head else "")]
    status = state.get("status")
    if status and status != "completed":
        lines.append(f"_({status})_")
    output = state.get("output")
    if output:
        lines.append("```\n" + fence(str(output)) + "\n```")
    return "\n".join(lines)


def render(con, sid):
    out = []
    try:
        msgs = con.execute("SELECT id, data FROM message WHERE session_id=? ORDER BY time_created, id",
                           (sid,)).fetchall()
    except sqlite3.Error as e:
        return [f"_(could not read messages: {e})_"]
    for mid, mdata in msgs:
        role = loads(mdata).get("role", "?")
        try:
            parts = con.execute("SELECT data FROM part WHERE message_id=? ORDER BY time_created, id",
                                (mid,)).fetchall()
        except sqlite3.Error:
            parts = []
        blocks = []
        for (pdata,) in parts:
            d = loads(pdata)
            t = d.get("type")
            if t == "text" and d.get("text", "").strip():
                blocks.append(d["text"].strip())
            elif t == "reasoning" and d.get("text", "").strip():
                blocks.append("> _thinking:_ " + d["text"].strip().replace("\n", "\n> "))
            elif t == "tool":
                blocks.append(render_tool(d))
            # step-start / step-finish / unknown: skipped
        if blocks:
            out.append(f"### {role}\n\n" + "\n\n".join(blocks))
    return out or ["_(no renderable content)_"]


def export(con, sid, title, directory, created):
    os.makedirs(OUT_DIR, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    path = f"{OUT_DIR}/transcript-{ts}-{sid[:12]}.md"
    body = render(con, sid)
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"# Transcript — {title or '(untitled)'}\n")
        f.write(f"_session {sid} · {directory or '?'} · started {when(created)} · {len(body)} turns_\n\n")
        f.write("\n\n".join(body) + "\n")
    print(f"[+] {path}")
    return path


def main(argv):
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    con = connect()
    rows = sessions(con)
    if not rows:
        sys.exit("[-] no sessions found in the store.")
    if argv and argv[0] == "--list":
        for sid, title, _, created in rows:
            print(f"{sid}  {when(created)}  {title or '(untitled)'}")
        return 0
    if argv and argv[0] == "--all":
        for sid, title, directory, created in reversed(rows):
            export(con, sid, title, directory, created)
        return 0
    if argv:
        row = next((r for r in rows if r[0] == argv[0] or r[0].startswith(argv[0])), None)
        if not row:
            sys.exit(f"[-] no session matching '{argv[0]}' (export-session --list)")
    else:
        row = rows[-1]   # latest by time_created
    export(con, *row)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
EXPORTEOF

# --- Account roster: the list of discovered identities and which have been
#     tested. qwen fixates on its first identity; this makes "who haven't I
#     tried yet" a thing it can see and `spray` act on.
cat << 'ROSTEREOF' > /usr/local/bin/roster
#!/usr/bin/env python3
"""roster -- track every discovered account and whether it's been tested.

  roster add <user> [<user>...]     record discovered accounts (stdin lines ok)
  roster rm <user> [<user>...]      remove junk entries (typos, group names)
  roster show                       tested vs untested
  roster untested                   print untested accounts, one per line
  roster tested <user> [result...]  mark an account tested (with a note)

Usernames are stored bare (DOMAIN\\user and user@dom collapse to the SAM name),
deduped case-insensitively. Every identity is new attack surface -- when you get
a new password or hash, `spray` it across this roster.
"""
import datetime
import fcntl
import os
import re
import select
import sys

ROSTER = "/workspace/notes/roster.md"
LOCK = "/tmp/.roster.lock"


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


def bare(u):
    u = u.strip().strip('"').strip("'")
    if "\\" in u:
        u = u.rsplit("\\", 1)[1]
    if "@" in u:
        u = u.split("@", 1)[0]
    return u.strip()


def stdin_tokens():
    try:
        if sys.stdin.isatty() or not select.select([sys.stdin], [], [], 0.5)[0]:
            return []
        return sys.stdin.read().split()
    except (AttributeError, OSError, ValueError):
        return []


def load():
    """-> dict keyed by lowercased name: {'name':display, 'tested':bool, 'note':str}"""
    out = {}
    try:
        with open(ROSTER, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r"- \[([ xX])\] (\S+)(?: -- (.*))?$", line.rstrip())
                if m:
                    out[m.group(2).lower()] = {"name": m.group(2),
                                               "tested": m.group(1).lower() == "x",
                                               "note": (m.group(3) or "").strip()}
    except FileNotFoundError:
        pass
    return out


def save(entries):
    os.makedirs(os.path.dirname(ROSTER), exist_ok=True)
    rows = sorted(entries.values(), key=lambda e: (e["tested"], e["name"].lower()))
    body = [f"# Account roster", f"_Updated: {datetime.datetime.now():%Y-%m-%d %H:%M:%S}_",
            "> Every discovered identity. `spray` a new secret across the untested ones.", ""]
    for e in rows:
        box = "x" if e["tested"] else " "
        body.append(f"- [{box}] {e['name']}" + (f" -- {e['note']}" if e["note"] else ""))
    tmp = f"{ROSTER}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(body) + "\n")
    os.replace(tmp, ROSTER)


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0 if argv else 2
    cmd, rest = argv[0], argv[1:]
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        entries = load()

        if cmd == "add":
            names = [bare(x) for x in (rest or stdin_tokens())]
            names = [n for n in names if n]
            if not names:
                die("usage: roster add <user> [<user>...]")
            added = []
            for n in names:
                if n.lower() not in entries:
                    entries[n.lower()] = {"name": n, "tested": False, "note": ""}
                    added.append(n)
            save(entries)
            print(f"[+] roster +{len(added)}: {', '.join(added) or '(all already known)'} "
                  f"({sum(not e['tested'] for e in entries.values())} untested of {len(entries)})")
            return 0

        if cmd == "rm":
            names = [bare(x) for x in (rest or stdin_tokens())]
            names = [n for n in names if n]
            if not names:
                die("usage: roster rm <user> [<user>...]")
            removed = []
            for n in names:
                key = n.lower()
                if key in entries:
                    removed.append(entries[key]["name"])
                    del entries[key]
            save(entries)
            print(f"[-] roster -{len(removed)}: {', '.join(removed) or '(none found)'} "
                  f"({len(entries)} remaining)")
            return 0

        if cmd == "tested":
            if not rest:
                die("usage: roster tested <user> [result...]")
            key = bare(rest[0]).lower()
            if key not in entries:
                entries[key] = {"name": bare(rest[0]), "tested": False, "note": ""}
            entries[key]["tested"] = True
            if rest[1:]:
                entries[key]["note"] = " ".join(rest[1:])
            save(entries)
            print(f"[+] marked tested: {entries[key]['name']}")
            return 0

        if cmd in ("show", "list", "untested"):
            untested = [e["name"] for e in entries.values() if not e["tested"]]
            tested = [e["name"] for e in entries.values() if e["tested"]]
            if cmd == "untested":
                print("\n".join(sorted(untested, key=str.lower)))
                return 0
            if not entries:
                print("(roster empty -- 'roster add <user>...' or run note-from-msf / enumerate users)")
                return 0
            print(f"untested ({len(untested)}): {', '.join(sorted(untested, key=str.lower)) or '-'}")
            print(f"tested   ({len(tested)}): {', '.join(sorted(tested, key=str.lower)) or '-'}")
            if untested:
                print(f"[!] {len(untested)} identities never tested -- spray a known secret across them.")
            return 0

    die(f"[-] unknown command '{cmd}'. commands: add rm show untested tested")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
ROSTEREOF

# --- Credential spray: test ONE secret against ALL roster accounts in a single
#     nxc call, record hits, mark each account tested. Mechanizes the step qwen
#     keeps skipping ("test reuse across every identity").
cat << 'SPRAYEOF' > /usr/local/bin/spray
#!/usr/bin/env python3
"""spray -- test one secret against every account in the roster.

  spray <target> <secret> [proto]      proto = smb (default) | winrm | ldap | rdp | ssh

<secret> is a password, or an NTLM hash (32 hex, or LM:NT) -- auto-detected.
Testing one secret across many users is one attempt per account, so it does NOT
risk lockout the way repeated guesses against one account do. Valid hits are
recorded with `note cred` and every sprayed account is marked tested in roster.
"""
import os
import re
import subprocess
import sys

LOGDIR = "/workspace/loot/logs"


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


def roster_untested_and_all():
    out = subprocess.run(["roster", "show"], capture_output=True, text=True)
    allu = subprocess.run(["roster", "untested"], capture_output=True, text=True)
    # Spray tests ALL known users (a fresh secret is worth trying on everyone),
    # so read the full roster file rather than only untested.
    names = []
    try:
        with open("/workspace/notes/roster.md", encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r"- \[[ xX]\] (\S+)", line.rstrip())
                if m:
                    names.append(m.group(1))
    except FileNotFoundError:
        pass
    return names


def is_hash(secret):
    return bool(re.fullmatch(r"[0-9a-fA-F]{32}", secret) or
                re.fullmatch(r"[0-9a-fA-F]{32}:[0-9a-fA-F]{32}", secret) or
                re.fullmatch(r"aad3b435b51404eeaad3b435b51404ee:[0-9a-fA-F]{32}", secret))


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if argv else 2
    if len(argv) < 2:
        die("usage: spray <target> <secret> [proto]")
    target, secret = argv[0], argv[1]
    proto = (argv[2] if len(argv) > 2 else "smb").lower()
    if proto not in ("smb", "winrm", "ldap", "rdp", "ssh"):
        die(f"[-] proto must be smb|winrm|ldap|rdp|ssh, not '{proto}'")

    users = roster_untested_and_all()
    if not users:
        die("[-] roster is empty. Add accounts first: roster add <user>... (or run note-from-msf)")

    os.makedirs(LOGDIR, exist_ok=True)
    userfile = f"{LOGDIR}/spray-users.txt"
    with open(userfile, "w", encoding="utf-8") as f:
        f.write("\n".join(users) + "\n")

    cred_flag = "-H" if is_hash(secret) else "-p"
    cmd = ["nxc", proto, target, "-u", userfile, cred_flag, secret, "--continue-on-success"]
    print(f"[*] {' '.join(cmd[:-1])} <secret> ({len(users)} accounts, {cred_flag})", file=sys.stderr)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=600,
                           env={**os.environ, "NO_COLOR": "1", "TERM": "dumb"})
    except FileNotFoundError:
        die("[-] netexec (nxc) not found on PATH.")
    except subprocess.TimeoutExpired:
        die("[-] spray timed out after 600s.")
    raw = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", (r.stdout or "") + (r.stderr or ""))
    log = f"{LOGDIR}/spray-{proto}-{target.replace('/', '_')}.log"
    with open(log, "w", encoding="utf-8") as f:
        f.write(" ".join(cmd) + "\n\n" + raw)

    valid, invalid = {}, []
    for line in raw.splitlines():
        m = re.search(r"\[([+\-])\]\s+(\S+)", line)
        if not m:
            continue
        blob = m.group(2)
        if ":" not in blob:
            continue
        user = blob.split(":", 1)[0].split("\\")[-1]
        if m.group(1) == "+":
            valid[user] = "admin" if re.search(r"Pwn3d|\(admin\)", line, re.I) else "valid"
        else:
            invalid.append(user)

    for user in users:
        key = user.split("\\")[-1].split("@")[0]
        hit = valid.get(key) or valid.get(user)
        result = f"{proto}: {hit}" if hit else f"{proto}: no"
        subprocess.run(["roster", "tested", user, f"spray {target} -> {result}"],
                       capture_output=True, text=True)
        if hit:
            label = f"valid on {target} {proto}" + (" (admin!)" if hit == "admin" else "")
            subprocess.run(["note", "cred", f"{user} : {secret} -- {label} (spray)"],
                           capture_output=True, text=True)

    print(f"\n=== spray {proto}://{target} ===")
    if valid:
        for u, lvl in sorted(valid.items()):
            print(f"  [+] {u:20} {proto} {'ADMIN' if lvl == 'admin' else 'valid'}")
        print(f"[+] {len(valid)} hit(s) recorded with note cred. Use them: each is new attack surface.")
    else:
        print("  (no valid logins)")
    print(f"[*] {len(users)} accounts tested, {len(invalid)} invalid. Full log: {log.removeprefix('/workspace/')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
SPRAYEOF

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

# --- Launcher Script (container entrypoint)
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
                "context": 196608,
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
    "question": "deny",
    "doom_loop": "ask"
  },
  "tool_output": {
    "max_lines": 500,
    "max_bytes": 24576
  }
}' > "$HOME/.config/opencode/opencode.json"

echo "[+] Configured OpenCode with active model: $SELECTED_MODEL"

# Bootstrap agent knowledge from image into workspace.
# Knowledge/config is image-owned: refreshed on EVERY launch (the image is the
# source of truth). Engagement state is created only if absent, so a relaunch
# without --clean resumes the box instead of resetting it.
echo "[*] Refreshing agent knowledge from image..."
# Replace rather than copy over, so files dropped from the image (e.g. a
# retired plugin) don't linger in a long-lived workspace.
mirror() { rm -rf "$2"; if [ -d "$1" ]; then mkdir -p "$(dirname "$2")" && cp -a "$1" "$2"; fi; }
cp -f /opt/pentest-agent/AGENTS.md /workspace/AGENTS.md
cp -f /opt/pentest-agent/opencode-workspace.json /workspace/opencode.json
mirror /opt/pentest-agent/references /workspace/references
mirror /opt/pentest-agent/skills     /workspace/.opencode/skills
mirror /opt/pentest-agent/plugins    /workspace/.opencode/plugins
mirror /opt/pentest-agent/agent      /workspace/.opencode/agent
mirror /opt/pentest-agent/command    /workspace/.opencode/command
# Marks this dir as a box workspace; opencodeHalogenHacker.sh --clean requires it.
echo "Halogen hacker workspace (written by opencode-select on launch)" > /workspace/.halogen-workspace

echo "[*] Scaffolding engagement state (only if absent)..."
mkdir -p /workspace/loot/logs /workspace/notes
# One-time migration: boards started before notes/STATE.md lived at loot/STATE.md.
# Old headings are demoted so they don't collide with the board's sections.
if [ -f /workspace/loot/STATE.md ] && [ ! -f /workspace/notes/STATE.md ]; then
    { cat /opt/pentest-agent/templates/STATE.md
      printf '\n## Carried over from loot/STATE.md\n'
      sed -E 's/^(#+) /\1## /' /workspace/loot/STATE.md
    } > /workspace/notes/STATE.md
    mv /workspace/loot/STATE.md /workspace/loot/STATE.md.migrated
    echo "[+] Migrated loot/STATE.md -> notes/STATE.md"
fi
[ -f /workspace/notes/STATE.md ] || cp /opt/pentest-agent/templates/STATE.md /workspace/notes/STATE.md
[ -f /workspace/ASSESSMENT.md ]  || cp /opt/pentest-agent/templates/ASSESSMENT.md /workspace/ASSESSMENT.md
mkdir -p /workspace/wiki/hosts /workspace/wiki/web
wiki index >/dev/null 2>&1 || true   # regenerate: pages may have been hand-edited since the last write
echo "[+] Agent knowledge deployed; engagement state kept (notes/, wiki/, ASSESSMENT.md, loot/)"

# Preserve sessions inside workspace
rm -rf "$HOME/.local/share/opencode"
mkdir -p /workspace/.opencode
mkdir -p "$HOME/.local/share"
ln -sfn /workspace/.opencode "$HOME/.local/share/opencode"

echo "[*] Starting OpenCode in /workspace..."
echo ""

cd /workspace || exit 1
exec opencode "$@"
EOF

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
         /usr/local/bin/note /usr/local/bin/assess /usr/local/bin/note-from-msf \
         /usr/local/bin/wiki /usr/local/bin/lesson /usr/local/bin/export-session \
         /usr/local/bin/roster /usr/local/bin/spray \
         /usr/local/bin/msf-mcp /usr/local/bin/opencode-select \
         /usr/local/bin/cleanup \
         /usr/local/bin/rdp-connect /usr/local/bin/rdp-screenshot \
         /usr/local/bin/rdp-type /usr/local/bin/rdp-disconnect

echo "[+] Agent tools installed successfully."
