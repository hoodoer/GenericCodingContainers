---
name: creds-and-loot
description: Track every credential, hash, ticket, and flag found - validate usability, store in /workspace/loot, and re-test across protocols. Use whenever a credential, hash, ticket, key, or flag is obtained.
---

# Credentials & Loot Tracking

## Store everything, immediately
All loot goes to `/workspace/loot/` with descriptive names:
`<user>.ntlm`, `<user>.ccache`, `<service>.hash`, `flags.md`. Also record each
one on the state board:
`note cred '<user> : <secret> -- valid on <where> (from <how>)'`.

## Validate usability -- don't assume
- **Password**: test against at least SMB + LDAP + WinRM before moving on;
  a valid cred is often valid everywhere (and re-used later).
  `nxc smb <T> -u <U> -p '<P>'` -- look for `Pwn3d!`.
- **Hash**: verify with `nxc smb <T> -u <U> -H <NTLM>` before using it
  for psexec/secretsdump.
- **Ticket/ccache**: check the session key is non-zero and the ticket isn't
  expired. `impacket-describeTicket <file.ccache>` shows key and expiry.
  A zero-key ticket is a known symptom -- load `@ad` (tgtdeleg).
- **Flags**: save the exact string the moment it's read; don't trust scrollback.
  `echo "<flag>" >> /workspace/loot/flags.md`

## Re-test after environment changes
Reboots/resets invalidate ccaches and may revert accounts to disabled or
tombstoned state. After any reset, re-validate the credential chain from the
start rather than debugging mid-chain.

## Lateral value ranking
When multiple creds exist, rank by impact:
1. Domain Admin / DCSync-capable
2. Local admin on target (Pwn3d!)
3. Shell-capable (WinRM, SSH)
4. Share-read access (may find creds/flags)
5. Crackable hash (offline, time-consuming)
6. Unknown / untested
Spend effort top-down.
