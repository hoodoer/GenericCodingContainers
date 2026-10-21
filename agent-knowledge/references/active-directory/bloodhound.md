# BloodHound Collection & Analysis

## Collection
```bash
# From Linux with valid creds (all collection methods)
bloodhound-python -d <domain> -u <user> -p '<pass>' -dc <DC-FQDN> -c all -ns <DC-IP>
# With hash
bloodhound-python -d <domain> -u <user> --hashes :<NTLM> -dc <DC-FQDN> -c all -ns <DC-IP>
# Through a pivot (SOCKS proxy)
proxychains4 bloodhound-python -d <domain> -u <user> -p '<pass>' -dc <DC-FQDN> -c all -ns <DC-IP>
```
Output: JSON files in the current directory. Move to `loot/bloodhound/`.

From a Windows shell (SharpHound):
```powershell
.\SharpHound.exe -c All --outputdirectory C:\Temp
# or in Evil-WinRM: upload /opt/windows-tools/SharpHound.exe
```

## Analysis without the GUI
The GUI needs a browser + Neo4j. For headless analysis, use the JSON directly:

### Quick wins from raw JSON
```bash
# Kerberoastable users (SPNs set, not disabled)
jq -r '.data[] | select(.Properties.hasspn==true and .Properties.enabled==true) | .Properties.name' loot/bloodhound/*users*.json

# AS-REP roastable (no preauth required)
jq -r '.data[] | select(.Properties.dontreqpreauth==true and .Properties.enabled==true) | .Properties.name' loot/bloodhound/*users*.json

# Unconstrained delegation (not DCs)
jq -r '.data[] | select(.Properties.unconstraineddelegation==true) | .Properties.name' loot/bloodhound/*computers*.json

# Constrained delegation targets
jq -r '.data[] | select(.Properties.allowedtodelegate | length > 0) | "\(.Properties.name) -> \(.Properties.allowedtodelegate[])"' loot/bloodhound/*computers*.json loot/bloodhound/*users*.json 2>/dev/null

# Domain Admins members
jq -r '.data[] | select(.Properties.name | test("DOMAIN ADMINS@"; "i")) | .Members[].MemberId' loot/bloodhound/*groups*.json

# Users with AdminCount=1 (high-value targets)
jq -r '.data[] | select(.Properties.admincount==true and .Properties.enabled==true) | .Properties.name' loot/bloodhound/*users*.json

# LAPS-readable computers
jq -r '.data[] | select(.Properties.haslaps==true) | .Properties.name' loot/bloodhound/*computers*.json

# Computers where a user has local admin (from sessions/admin edges)
# These are in the *_aces.json or relationship edges -- structure varies by version.
```

### Key relationships to check for each owned principal
For each identity you own, check what it can reach:
- **GenericAll / GenericWrite / WriteDacl / WriteOwner** on users/computers/groups
- **ForceChangePassword** on other users
- **AddMember** on privileged groups
- **ReadLAPSPassword / ReadGMSAPassword**
- **Owns** on objects
- **AllExtendedRights** (includes DCSync on the domain)
- **AddKeyCredentialLink** (shadow credentials)
- **WriteSPN** (targeted Kerberoasting)

### Attack path planning on a network
On a multi-host/multi-domain network, BloodHound data answers:
1. **Where am I relative to DA?** — count the hops from each owned principal
2. **Which host should I target next?** — the one where an owned identity has local admin, or where a session exists for a high-value user
3. **Cross-domain trust abuse** — look for users in Domain A with rights in Domain B, SID history, or cross-domain group membership
4. **What does this new credential unlock?** — re-check edges from the newly owned node

### Domain trust enumeration
```bash
# Enumerate trusts
nxc smb <DC> -u <U> -p '<P>' -M enum_trusts
# Or via LDAP
ldapsearch -H ldap://<DC> -D '<user>@<domain>' -w '<pass>' -b 'CN=System,DC=...' '(objectClass=trustedDomain)' trustPartner trustDirection trustType flatName
# bloodhound-python also collects trust data in the domain JSON
```

Trust directions: 0=disabled, 1=inbound (they trust us), 2=outbound (we trust them), 3=bidirectional.
Trust types: 1=downlevel (NT4), 2=uplevel (AD), 3=MIT (Kerberos realm).

## Network engagement workflow
1. Collect from every domain you have creds in
2. Merge all JSON into one loot/bloodhound/ directory
3. For each owned identity: check outbound edges for attack paths
4. Prioritize: shortest path to DA > cross-trust abuse > new host compromise
5. After each new compromise: re-check what the new identity unlocks
6. Record the attack graph: `note campaign '<from> -> <right> -> <to>'`
