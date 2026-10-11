---
name: shell-and-transfer
description: Reliable shell establishment and file transfer - looping listeners, payload delivery when inbound ports are blocked, clock/hosts hygiene, and recovering or resetting wedged shells. Use when catching a shell, uploading/downloading payloads, or when a shell dies.
---

# Shell & Transfer Hygiene

## Listeners
- One-shot `nc` loses your shell on disconnect. Loop it:
  `while true; do nc -lvnp <PORT> | tee -a /workspace/loot/rs.log; sleep 1; done`
- Bind only to NAT-forwarded ports: 80, 443, 4444-4460, 8080-8090.
  Use 4444-4460 for reverse shells, 80/443 for relay/HTTP callbacks,
  8080-8090 for chisel/ligolo/staging servers.
  Use the VPN/tunnel IP as LHOST, never the container-internal IP.

## Payload delivery when inbound is blocked
- If the target can't reach your HTTP port, **stage via a writable share**
  (SMB put) and pull from the target's *local* path of that share
  (`C:\Shares\...`), not a UNC path that may fail to authenticate.
- `impacket-smbclient`'s `-p` is a PORT flag (139/445), not password.
  Use samba `smbclient -U 'DOM/user%pass'` for password auth.
- For serving files: `impacket-smbserver share /workspace/loot -smb2support`
- Large downloads go in a background tmux session; never block the foreground
  on a multi-minute transfer.

## Environment hygiene before shells/Kerberos
- Sync the clock with the DC: `sudo ntpdate -b <DC>` or `chronyc`. Kerberos
  fails beyond 5 min skew.
- Check `/etc/hosts` resolves the target to the CURRENT IP; remove stale
  entries (first match wins). On bind-mounted files, edit in place
  (`grep -v old /etc/hosts | sudo tee /etc/hosts`), `sed -i` fails.

## Wedged shell recovery
1. Try a fresh listener + fresh connect before touching the target.
2. If the shell's parent process/agent is wedged and you lack rights to
   restart it, **reset the environment (reboot)** and re-run the access chain
   -- don't re-drop payloads ten times.
3. After any reset, re-mint tickets and re-stage files; assume ephemeral
   state (shares, created objects, ccaches) is gone.
