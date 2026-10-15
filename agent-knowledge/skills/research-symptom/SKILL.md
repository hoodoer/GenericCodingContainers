---
name: research-symptom
description: How to research failures and versions - local exploit DBs first, then web search keyed on the exact error string, never a walkthrough. Use when an exploit fails, a tool errors, or a version is unknown.
---

# Symptom-Driven Research

## Order of operations
1. **Local first.** `searchsploit <service> <version>`, Metasploit
   `search_exploits`/`search_modules`, `nuclei -as`, bundled `@references`.
   Thousands of ready exploits need no internet round-trip.
2. **Then web, keyed on the symptom.** Use `websearch` (local SearXNG, no
   CAPTCHA). Search the *literal error string*
   (e.g. `websearch 'KRB_AP_ERR_BAD_INTEGRITY ccache zero session key'`) or
   `websearch '<service> <version> CVE'`. To read a result page:
   `websearch --url '<url>'`. Error strings have canonical causes and fixes.
3. **Never search the box name** for a walkthrough/writeup -- that spoils the
   challenge instead of exercising the methodology.

## Treat artifacts as diagnoses
A malformed artifact is a symptom with a known cause, not a "retry" prompt:
- exported ticket with all-zero session key -> exported without
  SeDebugPrivilege -> use `tgtdeleg` (load `@ad` for details).
- `KRB_AP_ERR_BAD_INTEGRITY` with a ccache -> bad/zero session key in ccache.
- `KRB_ERR_C_PRINCIPAL_UNKNOWN` after reboot -> account tombstoned again
  (lab reverted); re-run the restore.
- `KRB_AP_ERR_TKT_EXPIRED` / clock skew -> sync time before retrying.
- `STATUS_ACCESS_DENIED` on a share -> check NTFS ACL vs share ACL vs your
  token; try the right principal. Load `@env` for common access-denied causes.
- `rpc_s_access_denied` from psexec/wmiexec -> you lack admin/DCOM/SVCCTL
  rights; find the intended primitive, don't brute-force exec.
- "No route to host" to a hostname -> stale `/etc/hosts` entry.

## On failure, change the search axis
If an exploit fails: re-search by product name, then protocol, then
vulnerability class, then the exact error. If three axes return nothing new,
the lead is probably wrong -- return to enumeration and find another surface.
