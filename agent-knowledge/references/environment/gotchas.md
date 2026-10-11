# Lab Environment Gotchas & Tool Syntax

## Clock skew
Targets often run non-UTC local time; Kerberos fails silently beyond 5 min
skew. Sync first:
```bash
sudo ntpdate -b <DC>
# OR if ntpdate is missing:
sudo timedatectl set-ntp false
sudo date -s "$(nxc smb <DC> 2>&1 | grep -oP 'signing:.*? (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')"
# OR with faketime:
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/faketime/libfaketime.so.1 FAKETIME="+Nh" <command>
```

## /etc/hosts
- Bind-mounted in many containers: `sed -i` fails ("Device or resource busy").
  Edit in place:
  ```bash
  grep -v '<stale-ip-or-hostname>' /etc/hosts | sudo tee /etc/hosts
  echo '<new-ip> <hostname>' | sudo tee -a /etc/hosts
  ```
- First matching line wins -- a stale DC IP sends everything to a dead box
  ("No route to host"). Re-check after every target IP change.

## NAT / port forwarding
Forwarded ports: **80, 443, 445, 4444-4460, 8080-8090**.
- **4444-4460**: reverse shells, Metasploit listeners.
- **80/443**: HTTP/HTTPS for ntlmrelayx, SSRF callbacks, payload hosting.
- **8080-8090**: chisel, ligolo, HTTP staging servers, web proxies.
- Anything outside these ranges is NOT reachable from the target. If you
  need a port not in this list, use one that IS forwarded instead.
- LHOST = the VPN IP, never the container-internal `10.88.x.x` IP.

## Tool-specific quirks

### impacket
- Kali binary names use `impacket-` prefix: `impacket-secretsdump`,
  `impacket-getTGT`, `impacket-getST`, `impacket-psexec`, etc.
- `impacket-smbclient`'s `-p` flag is **PORT** (139/445), NOT password.
  For password auth to shares, use samba `smbclient -U 'DOM/user%pass'`.
- Kerberos auth: `KRB5CCNAME=file.ccache impacket-<tool> -k -no-pass`

### bloodyAD
- Global flags: `--host <DC> -d <domain> -u <user> -p '<pass>'`
- Kerberos: `--host <DC> -d <dom> -k ccache=/path/to.ccache`
- The flag style may vary between builds. Check `bloodyAD --help` for
  `--host` vs `-H` vs `-i` in your container.
- Kerberos auth flags go before the subcommand.

### NetExec (nxc)
- Protocols: `smb`, `ldap`, `winrm`, `rdp`, `mssql`, `ssh`, `ftp`, `vnc`, `wmi`
- `Pwn3d!` in output = local admin access confirmed.
- Pass-the-hash: `-H <NTLM>` (just the NT hash, no LM prefix needed).
- Module flags: `-M <module>` with `-o KEY=VALUE` for module options.

### certipy
- Kali package may be `certipy-ad` (not just `certipy`).
- `certipy find -vulnerable -enabled` to enumerate exploitable templates.
- `certipy auth -pfx cert.pfx -dc-ip <DC>` to authenticate with certificate.

### smbclient (samba)
- Password auth: `smbclient '//<T>/Share' -U 'DOMAIN/user%password'`
- List shares: `smbclient -L //<T>/ -U 'DOMAIN/user%password'`
- No-password guest: `smbclient '//<T>/Share' -N`

## VM reset behavior
- Tombstones re-delete, created objects (dMSAs, computers) vanish.
- Shares wipe, staged files disappear.
- ccaches go stale, tickets expire.
- After any reset: **re-run the full initial-access chain** from the start.
  Don't debug mid-chain; re-validate credentials, re-restore tombstones,
  re-create dMSAs, re-mint tickets.

## nc listener
`nc` is one-shot; loop it:
```bash
while true; do nc -lvnp 4444 | tee -a /workspace/loot/rs.log; sleep 1; done
```

## UNC vs local path
A shell spawned by an agent may not authenticate to `\\dc\share` ("Access
denied") but CAN read the same folder via its local path (`C:\Shares\...`).
Prefer local paths on the target.
