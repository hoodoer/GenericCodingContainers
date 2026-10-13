# Pentesting Agent Instructions

## Golden Rules

1. **Simple access before complex attacks.** Check file shares, readable
   directories, and basic credential reuse BEFORE attempting ACL abuse chains,
   Kerberos delegation tricks, or other multi-step AD attacks. The answer is
   often a file sitting in a share readable by a credential you already own.
   Run `nxc smb <T> -u <U> -p <P> --shares` and actually LIST the contents
   of every readable share.
2. **Use EVERY compromised identity.** When you obtain a new credential, hash,
   or ticket, IMMEDIATELY test it across all protocols and enumerate what it
   can access. Different accounts see different shares, services, and ACLs.
   Don't fixate on your first identity -- each new one is a new attack surface.
   Record it with `note cred` and test it against every known target.
3. **Enumerate capabilities, not just existence.** For every owned principal,
   ask "what does this let me DO?" and map it to an attack primitive.
   "I can write an attribute" is not a finding; "GenericWrite on a user ->
   force password reset -> DCSync" is. Load `@ad` for the ACL-to-attack matrix.
4. **Research the symptom, don't retry.** A malformed artifact (zero-key ticket,
   integrity error, access denied) is a *diagnosis* with a known fix, not a
   reason to re-run the same command. Search the exact error string.
5. **Timebox every dead-end.** If a single sub-problem (a shell, a tool, a
   payload) eats >15 min or >10 tool calls without progress, STOP. Record the
   blocker with `note stuck '<what, what you tried, why each failed>'`, then
   either research the symptom or reset the environment.
6. **Never re-run a failing command unchanged.** Change the method, the tool,
   or the inputs. If you're looping, you're not learning.
7. **A reboot is a legitimate tool.** Lab VMs revert to a snapshot on reboot.
   When an interactive channel is deadlocked and you cannot restart its
   service, rebooting is faster than fighting it.
8. **Keep the state board current.** See *Working state* below.

## Working state -- `notes/STATE.md`
- Read `notes/STATE.md` (`note show`) at the start, FIRST after any
  auto-compaction, and before switching to a new attack vector.
- The moment you learn a credential, service, access path, or that a vector
  failed, record it with the `note` CLI -- not "later". Single-quote the text:
      note cred    'svc_acct : Summer2026! -- valid on DC01 (kerberoast)'
      note service '10.10.11.5:445 smb Samba 4.15 -- signing off'
      note access  'www-data on web01 -- regain: curl http://10.10.11.5/s.php?c=id'
      note failed  'anonymous SMB on 10.10.11.5 -- NT_STATUS_ACCESS_DENIED'
      note next    'try ESC1 with the Web template'
      note rm next 'ESC1'            # drop a bullet once done or wrong
  Text containing a `'`: pass it on stdin instead (`note cred <<'EOF'` ...
  `EOF`). `note` echoes what it stored -- check secrets came through intact.
- Sections: scope access cred service finding failed next stuck.
- After 3 failed attempts on the SAME vector, before switching approaches, run
  `note stuck '<what, what you tried, why each failed>'` -- it also logs to
  notes/STUCK.md for human review.
- After `db_nmap` or any MSF scanner/login module, run `note-from-msf`: it
  copies open services and creds from the MSF database onto the board.
- STATE.md is the short board. Depth (per-host/app detail, key output) goes in
  the wiki: `wiki add hosts/<ip> '<detail>'`. Before re-enumerating anything,
  run `wiki search <ip-or-name>` -- you may already have it (wiki skill).

## Lessons -- `lessonsLearned.md` (candidates for the knowledge base)
Separate from working notes. Write a lesson with the `lesson` CLI when, and
ONLY when, it will hold on the NEXT box with the same fingerprint:
- a reference said X would work and it didn't (record why),
- something worked that no reference covered,
- a stuck period got resolved (what unblocked it),
- a tool/wrapper misbehaved (that's an `env` lesson).
    lesson privesc technique 'GTFOBins less trick needs no tty here' --fp 'Ubuntu 22.04, sudo less' --dest '@linux'
NOT a lesson: anything true only on THIS box -- that goes in the wiki or notes.
At the end of a box, run `/retro` to capture one closing lesson.

## Assessment write-up -- `ASSESSMENT.md` (for the human report)
When you CONFIRM something reportable (foothold, valid cred, exploitable vuln,
flag), append an entry -- what it is, impact, exact repro, evidence path:
    assess 'SQLi in /login (auth bypass)' 'POST user=... bypasses auth. Repro: <cmd>. Evidence: loot/logs/<file>.log'
Terse operational state stays in STATE.md; don't mix the two.

---

## Core Methodology: Enumerate -> Capability-Map -> Research -> Exploit

### Phase 1: Enumerate the target
Discover open ports, services, and version strings:
```bash
safe-run nmap -sCV -Pn -oA /workspace/loot/initial <TARGET>
```
Record every service name and version number (e.g. `Apache 2.4.49`,
`OpenSSH 8.2p1`, `ProFTPD 1.3.5`).

### Phase 2: Search for exploits LOCALLY FIRST
For every service+version, search local databases before the web:
```bash
safe-run searchsploit <service> <version>
safe-run searchsploit -x <edb-id>                  # read the exploit
```
```
search_exploits("<service> <version>")              # Metasploit MCP tool
search_modules("<service>")                         # broader MSF search
```
```bash
safe-run nuclei -u <TARGET> -as                     # auto-detect + scan
```

### Phase 3: Map capabilities (MANDATORY after any foothold)
Every time you gain a credential, shell, token, ticket, or file access,
run this checklist. **Do it for EVERY new identity, not just the first.**

**Simple access first (before complex AD attacks):**
- **Shares**: `nxc smb <T> -u <U> -p <P> --shares` with EVERY owned identity,
  then `smbclient` to LIST and READ contents of every readable share.
  Flag `.vmem/.vhd/.kdbx/.kirbi/Unattend.xml/GPP` files, scripts, configs.
  A share empty to one identity may have critical files for another.
- **Lateral move**: `nxc winrm/smb/rdp <T> -u <U> -p <P>` -- does this
  identity get `Pwn3d!` on any target the previous one didn't?
- **Direct flag**: can you just read `user.txt`/`root.txt` via SMB or a shell?

**Then deeper enumeration:**
- **Shell**: `whoami /priv` / `id` / `sudo -l`. Note privileges that change
  what's possible (SeDebugPrivilege, SeBackupPrivilege, sudo entries).
- **AD ACLs**: enumerate what this identity can *do* to other objects. Load `@ad`.
- **Files**: a memory/disk image = offline SAM/LSASS. Load `@forensics`.

Record each mapped capability: `note finding '<principal> -> <right> -> <attack>'`.

### Phase 4: Exploit the most promising lead
If it fails, go back to Phase 2 with different search terms (product name,
protocol, vulnerability class). Do NOT retry unchanged.

### Phase 5: External research (only after local sources exhausted)
Search the web for `<service> <version> CVE` or the exact error string.
**Never search for the box name, walkthrough, or writeup.**

---

## Available Skills and References

### Skills (auto-discovered, invoked when relevant)
| Skill | When to use |
|---|---|
| `pentest-loop` | Start of engagement or when progress stalls |
| `capability-enumeration` | After gaining any foothold (cred, shell, ticket, file) |
| `research-symptom` | When an exploit fails or a tool errors |
| `shell-and-transfer` | Catching a shell, uploading/downloading, or when a shell dies |
| `creds-and-loot` | Whenever a credential, hash, ticket, or flag is obtained |
| `pivoting` | When a foothold sees networks the attacker cannot reach |
| `web-recon` | When a web application or API is discovered on a target |
| `wiki` | Recording per-host/app detail; searching what you already know |

### References (load with @name when the topic comes up)
| Reference | Trigger |
|---|---|
| `@ad` | Attacking AD domains: ACL abuse matrix, Kerberos errors/tgtdeleg, dMSA/badSuccessor, RBCD, shadow credentials, delegation, tombstone reanimation |
| `@adcs` | Certificate attacks: ADCS ESC1-16 with certipy commands |
| `@windows` | Windows lateral movement, execution methods, flag/secret locations |
| `@linux` | Linux privilege escalation: SUID, sudo, capabilities, cron, kernel |
| `@forensics` | Memory/disk image credential extraction: volatility3, offline hive dumps |
| `@web` | Web/API attacks: SQLi, SSTI, SSRF, XXE, JWT, LFI, file upload, fuzzing, GraphQL |
| `@env` | Lab environment gotchas: clock skew, /etc/hosts, NAT, tool syntax quirks |

---

## Noisy enumeration -> the `enum` subagent
linpeas, winpeas, BloodHound collection/analysis, and large ffuf / feroxbuster /
nuclei runs ALWAYS go through the `enum` subagent -- their raw output will bury
the context. Hand the command to `enum` and read back its summary; open the
`loot/logs/` file only if the summary flags something worth a closer look.
Everything else you run directly as usual.

## Metasploit Execution
The MCP server's parameter parsing can be strict. For complex chains:
1. Write commands to a `.rc` resource script in `/workspace/`.
2. Execute via `safe-run msfconsole -q -r script.rc`.

## Networking Constraints
- **Scope**: only attack IPs in `scope.txt`.
- **LHOST**: use the VPN IP, never the container `10.88.x.x` IP.
- **LPORT**: bind to forwarded ports: 80, 443, 445, 4444-4460, 8080-8090.
  Use 4444-4460 for reverse shells, 80/443 for HTTP callbacks and relay
  attacks, 8080-8090 for chisel/ligolo/HTTP staging.
- **Payload delivery**: if inbound ports are blocked, stage via SMB shares.

---

## Windows Target Playbook (Credential-Based Access)

Use this priority order. Only fall back to RDP if all text-based methods fail
or the challenge explicitly requires GUI interaction.

### 1. Evil-WinRM (port 5985-5986)
```bash
safe-run evil-winrm -i <TARGET> -u <USER> -p '<PASS>'
safe-run evil-winrm -i <TARGET> -u <USER> -H <NTLM>   # pass-the-hash
```
Full PowerShell session. Upload/download files. Load PS scripts with `-s`.

### 2. Impacket psexec / wmiexec / smbexec
```bash
safe-run impacket-psexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'
safe-run impacket-wmiexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'
safe-run impacket-smbexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'
```
`wmiexec` is stealthier; `psexec` gives SYSTEM; `smbexec` when psexec blocked.

### 3. Impacket secretsdump (no shell needed)
```bash
safe-run impacket-secretsdump '<DOMAIN>/<USER>:<PASS>@<TARGET>'
```

### 4. NetExec (credential validation + quick enum)
```bash
safe-run netexec smb <TARGET> -u <USER> -p '<PASS>'        # Pwn3d! = admin
safe-run netexec winrm <TARGET> -u <USER> -p '<PASS>'
safe-run netexec smb <TARGET> -u <USER> -p '<PASS>' --shares --users
```

### 5. SMB direct file access
```bash
safe-run smbclient '//<TARGET>/C$' -U '<DOMAIN>/<USER>%<PASS>'
```
If you know the flag path, just `get` it. No shell needed.

---

## RDP Playbook (GUI-Required Challenges Only)

`agent-rdp` runs as a headless protocol client with UI Automation support.

### Quick-Start
```bash
safe-run agent-rdp connect --host <IP> --username <USER> --password '<PASS>' --enable-win-automation
safe-run agent-rdp automate snapshot -i          # accessibility tree (preferred)
safe-run agent-rdp screenshot --output /workspace/loot/screenshots/desktop.png
safe-run agent-rdp mouse click @e1               # click by element index
safe-run agent-rdp clipboard set "whoami /priv"  # clipboard for reliable typing
safe-run agent-rdp keyboard press "ctrl+v"
safe-run agent-rdp keyboard press enter
safe-run agent-rdp disconnect
```

### Rules
1. **Inspect trees before pixels.** `automate snapshot -i` first; target by
   semantic index (`@e1`). Only fall back to coordinates for canvas controls.
2. **Clipboard over keystrokes.** `clipboard set` + `ctrl+v` prevents dropped
   characters.
3. **Batch actions.** Plan sequences, execute, wait 2-3s, then snapshot once.
4. **Abandon after 5 min of fighting.** Try evil-winrm, wmiexec, or smbclient.

### Opening Applications
```bash
safe-run agent-rdp keyboard press super
sleep 1
safe-run agent-rdp keyboard type "cmd"
safe-run agent-rdp keyboard press enter
sleep 2
safe-run agent-rdp automate snapshot -i
```

---

## Pivoting and Tunneling
- **Chisel**: `/usr/local/bin/chisel` -- TCP/UDP tunnel over HTTP.
- **Ligolo-ng**: `/usr/local/bin/ligolo-proxy` -- full VPN-style pivot.
- **Proxychains**: `proxychains4 <command>` -- route through SOCKS proxy.
- **SSH tunnels**: `ssh -D 1080 user@target` for dynamic SOCKS, `-L` for local.
- **socat**: relay/redirect any TCP/UDP stream.
Load `@env` for NAT/routing gotchas when setting up tunnels.

---

## Pre-Staged Tools
- **Windows tools** (for upload to targets): `/opt/windows-tools/`
  contains `Rubeus.exe`, `SharpHound.exe`, `Certify.exe`.
- **WebSocket clients**: `websocat`, `wscat`
- **Linux target tools**: `pspy64` (cron spy), `kerbrute` (Kerberos enum)
- **PowerShell**: `pwsh` is available for running PS scripts from Linux.
- **pypykatz**: parse LSASS dumps on Linux without volatility.
- **PKINITtools**: `gettgtpkinit.py`, `gets4uticket.py` for cert-based auth.
- **petitpotam.py**: NTLM coercion for ADCS relay attacks.

## Output
- Save all loot, hashes, and flags to `/workspace/loot/`.
