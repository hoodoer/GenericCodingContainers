---
name: network-recon
description: Network-level reconnaissance for multi-host engagements - discover hosts, map subnets, identify DCs and key infrastructure, plan the attack graph. Use when you have access to a network segment (initial VPN access, or after pivoting to a new subnet).
---

# Network Reconnaissance

When you land on a new network segment — either via VPN or a pivot — map the
terrain before diving into individual hosts.

## Step 1: Discover the network
```bash
# What subnet am I on?
ip addr show
ip route

# From the attacker box (VPN):
nmap -sn <CIDR> -oA loot/pingsweep          # ping sweep
nmap -sn -PS22,80,135,443,445 <CIDR>        # TCP SYN sweep (no ICMP)
arp-scan -l                                   # local segment only

# From a compromised host (through a pivot):
# Use nxc or nmap through proxychains — BUT limit scope:
proxychains4 nmap -sT -Pn -p 22,80,135,139,445,389,636,3389,5985 <CIDR> --open -oA loot/internal-scan
# Or faster with nxc (one protocol at a time):
proxychains4 nxc smb <CIDR>                  # find Windows hosts + OS info
```

Record every live host: `note campaign '<IP> alive (<OS/hostname if known>)'`

## Step 2: Identify key infrastructure
Priority targets on any AD network:
1. **Domain Controllers** — port 389/636 (LDAP), 88 (Kerberos), 53 (DNS)
2. **Certificate Authorities** — `certipy find` or port 80/443 on CA hosts
3. **File servers** — large SMB shares, backup servers
4. **Database servers** — MSSQL (1433), MySQL (3306), PostgreSQL (5432)
5. **Web applications** — HTTP/HTTPS on non-standard ports
6. **Management interfaces** — IPMI (623), iLO, vCenter, jump boxes

```bash
# Quick identification of DCs:
nxc smb <CIDR> --gen-relay-list relay-targets.txt  # also shows signing status
nmap -p 88,389 <CIDR> --open                       # Kerberos + LDAP = DC

# DNS zone transfer (often available from DC):
dig axfr <domain> @<DC-IP>
# Reverse lookups for the whole range:
for i in $(seq 1 254); do dig +short -x <subnet>.$i @<DC-IP>; done 2>/dev/null
```

## Step 3: Per-host enumeration
For each discovered host, run targeted scans (not full nmap on everything):
```bash
# Top ports + version detection on key hosts
nmap -sCV -Pn -p- --min-rate 1000 <TARGET> -oA loot/<hostname>-full
# Or via MSF MCP for DB integration:
db_nmap("<TARGET>", args="-sCV -Pn -p-")
```

After scanning, run `note-from-msf` to sync services onto the state board.

## Step 4: Map the AD domain
Once you have domain creds (even low-priv):
```bash
# BloodHound collection
bloodhound-python -d <dom> -u <user> -p '<pass>' -dc <DC-FQDN> -c all -ns <DC-IP>
mv *.json loot/bloodhound/

# Domain trust enumeration
nxc smb <DC> -u <user> -p '<pass>' -M enum_trusts

# Quick AD enumeration
nxc smb <DC> -u <user> -p '<pass>' --users       # domain users
nxc smb <DC> -u <user> -p '<pass>' --groups       # domain groups
nxc ldap <DC> -u <user> -p '<pass>' -M adcs       # find CAs
nxc ldap <DC> -u <user> -p '<pass>' -M laps       # LAPS passwords

# All users -> roster (so spray covers everyone)
nxc smb <DC> -u <user> -p '<pass>' --users | awk '{print $5}' | grep -v '\[' | roster add
```

## Step 5: Check relay attack surface
```bash
# SMB signing disabled = relay target
nxc smb <CIDR> --gen-relay-list loot/relay-targets.txt

# LDAP signing/channel binding on DCs
nxc ldap <DC> -u <user> -p '<pass>' -M ldap-checker

# HTTP enrollment on CAs (ESC8)
nxc http <CA-IP> -u <user> -p '<pass>'
```

## Step 6: Record the network map
```bash
note campaign '<DC-IP> (<hostname>) -- Domain Controller for <domain>'
note campaign '<subnet> reachable from <pivot-host> via <tunnel>'
note campaign 'Trust: <child-dom> <-> <parent-dom> (bidirectional)'
```

Per-host detail goes in the wiki:
```bash
wiki add hosts/<IP> '<hostname>: <OS>, key services: <ports>'
```

## Network progression pattern
1. Map the network (this skill)
2. For each host: enumerate services, try existing creds (`spray`)
3. For each foothold: post-foothold sweep (capability-enumeration skill)
4. For each new credential: spray it across ALL known hosts
5. For each new network segment: pivot and repeat from step 1
6. Use BloodHound to plan shortest path to DA
7. After DA: check for cross-domain trusts, repeat in other domains
