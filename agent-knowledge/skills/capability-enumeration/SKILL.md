---
name: capability-enumeration
description: Turn any foothold (credential, shell, token, file) into concrete attack actions by asking "what can I DO with this?". Use immediately after gaining any access - new credential, low-priv shell, ticket, key file, or service account.
---

# Capability Enumeration

A foothold is not a finding. A finding is a *mapped action*. For every owned
thing, ask **"what does this let me DO?"** and enumerate the options before
attacking.

## For a credential / identity

**Do this for EVERY new credential, not just the first one.** Different
accounts see different shares, services, and ACL paths. The account you
ignore is often the one that has the access you need.

**Before the per-account checks below, spray the new secret across everyone:**
`spray <dc-or-host> '<secret>'` tests it against the whole account roster in one
call and records the hits. **On a network, spray against EVERY known host** --
not just the one you found the cred on. A password that doesn't work on HOST-A
may work on HOST-B. Run `spray` once per target host, or at minimum against the
DC and every host with SMB/WinRM open. `roster show` tells you which identities
you still haven't tested -- untested accounts are unexplored attack surface, so
don't declare a box stuck while any remain.

### Step 1: Simple access first (before any AD attack chain)
- `nxc smb <T> -u <U> -p '<P>' --shares` -- list shares, then **actually
  browse the contents** of every readable share with `smbclient`. Look for
  files: configs, scripts, backups, memory dumps, credentials.
- `nxc winrm <T> -u <U> -p '<P>'` -- can I get a shell? (`Pwn3d!` = yes)
- Check web apps, MSSQL, SSH, FTP with the new cred.
- Read the flag only AFTER enumerating everything above:
  `nxc smb <T> -u <U> -p '<P>' -x 'type C:\Users\<user>\Desktop\user.txt'`

### Step 2: AD enumeration (only after simple access is checked)
- Enumerate what the account can *do* to other objects (ACLs, group
  membership, delegation rights). Load the `@ad` reference for the
  ACL-right -> attack-primitive matrix.
- Check: can I DCSync, read LAPS/gMSA, reset someone's password, add myself
  to a group, create objects, write SPNs (Kerberoast), write delegation
  attributes (RBCD)?
- ADCS: if `certipy find -vulnerable` shows nothing exploitable, check for
  **phantom templates** -- templates the CA publishes but that don't exist
  in AD. If your account is in `Template_Editors` or similar, you can create
  the missing template as ESC1-vulnerable. Load `@adcs` for the full
  technique.
- Run BloodHound collection: `bloodhound-python -d <dom> -u <user> -p '<pass>' -dc <DC> -c all`
- **Cross-domain trust paths**: if there are multiple domains, check whether
  this identity has rights in another domain (SID history, cross-domain group
  membership, trust abuse). Load `@bloodhound` for headless analysis of edges
  across domains.

### Step 3: Network reachability (multi-host engagements)
- Test this credential against EVERY known host: `spray <host> '<secret>'`
  for each DC, file server, and host with SMB/WinRM open.
- A `Pwn3d!` on a new host = new attack surface. Connect, enumerate that
  host, and look for credentials that take you further.
- Record: `note campaign 'cred <user> -> admin on <host>'`.

## For a low-priv shell
- `whoami /priv` / `id` / `sudo -l` -- privileges change what's possible
  (e.g. no SeDebugPrivilege = exported Kerberos tickets have zero session key).
- `whoami /groups` -- token groups, nested SIDs, interesting local groups
  (Backup Operators, Remote Desktop Users, Remote Management Users).
- `klist` / `rubeus triage` -- existing tickets that may be reusable.
- Stored creds: browsers, DPAPI, `Unattend.xml`, GPP `Groups.xml`, `.kdbx`,
  SSH keys, service configs, scheduled tasks, cron, SUID binaries.
- Running services and listening ports reachable ONLY from this host.

### Network reachability (from every new shell)
Every shell is a potential pivot point. Before moving on, check what this
host can reach that you can't:
```bash
# Interfaces and routes — dual-homed hosts bridge networks
ip addr; ip route          # Linux
ipconfig /all; route print # Windows

# Neighbors and ARP cache — what's alive nearby
arp -a
ip neigh                   # Linux

# Internal listeners and connections — reveals internal services
netstat -tlnp 2>/dev/null || ss -tlnp   # Linux
netstat -ano                             # Windows

# Quick ping sweep of adjacent subnets (if ICMP allowed)
for i in $(seq 1 254); do ping -c1 -W1 172.16.1.$i &>/dev/null && echo "172.16.1.$i alive"; done
# Or from Windows: 1..254 | %{ if (Test-Connection 172.16.1.$_ -Count 1 -Quiet) { "172.16.1.$_ alive" } }

# DNS — internal hostnames reveal architecture
cat /etc/resolv.conf; nslookup <domain>
# Windows: ipconfig /all (DNS servers), nslookup -type=any <domain>
```
If this host sees a segment you can't reach: set up a pivot (load `pivoting`
skill). Record: `note pivot '<tool> via <host> -> <subnet> (<what it reaches>)'`
and `note campaign 'shell on <host> -> sees <subnet>'`.

## For a file / share
- List contents of every share with every identity; map share ACLs, not just
  your own `ls`. Ask *who else* can read it and what they'd put there.
- Flag high-value artifacts:
  - Memory/disk images: `.vmem .vmsn .vhd .vhdx` -- offline SAM/LSASS (load `@forensics`)
  - Credential stores: `.kdbx .kirbi .ccache`
  - Config files: `Unattend.xml`, GPP XML, `.env`, `web.config`, `appsettings.json`
  - Backups, source code with hardcoded credentials
- A share that is *empty to you* may be **readable by another principal** --
  map the ACL, don't just `ls` as yourself.

## Output
Record each mapped capability with
`note finding '<principal> -> <right> -> <attack> -> <target>'`, then rank
attacks by effort and impact.
