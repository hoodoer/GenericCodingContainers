---
name: web-recon
description: Web application reconnaissance and attack workflow - enumerate tech stack, discover content and vhosts, find injection points, test authentication. Use when a web application or API is discovered on a target.
---

# Web Application Recon & Attack Workflow

## Phase 1: Fingerprint the stack
Before fuzzing or injecting, understand what you're attacking:
```bash
whatweb -a 3 https://target.com
httpx-toolkit -u https://target.com -sc -cl -title -tech-detect -fr
```
Note the framework (WordPress, Flask, .NET, Node, PHP), web server (Apache,
Nginx, IIS), language, and any version strings. Search these for known CVEs
with `searchsploit` and `nuclei -as` before manual testing.

## Phase 2: Content discovery
Run in parallel where possible:
- **Directories/files**: `ffuf` with `raft-medium-directories.txt`, add
  extensions matching the tech stack (`.php` for PHP, `.aspx` for .NET, etc.)
- **Virtual hosts**: `ffuf -H "Host: FUZZ.target.com"` to find hidden subdomains
  served on the same IP.
- **API docs**: check `/api`, `/api/v1`, `/swagger.json`, `/openapi.json`,
  `/graphql` (try introspection query), `/.well-known/`.
- **Interesting files**: `robots.txt`, `sitemap.xml`, `.git/HEAD`,
  `.env`, `web.config`, `wp-config.php.bak`, `backup.zip`.

## Phase 3: Map the attack surface
For each discovered endpoint:
- What parameters does it accept? (Use `arjun` for hidden params)
- Does it reflect user input? (test for XSS/SSTI)
- Does it query a database? (test for SQLi)
- Does it include files or fetch URLs? (test for LFI/SSRF)
- Does it accept file uploads? (test bypass techniques)
- Does it use JWT or session cookies? (test for auth bypass)

## Phase 4: Test and exploit
Load `@web` for attack-specific syntax (SQLi, SSTI, SSRF, XXE, JWT, etc.)

**Priority order** (highest impact first):
1. Known CVEs for the exact version (searchsploit/nuclei)
2. Authentication bypass (default creds, JWT none-alg, IDOR)
3. SQL injection -> credential dump or OS shell
4. File upload -> webshell
5. LFI -> source code / credential file read
6. SSRF -> internal service access
7. SSTI -> RCE
8. XSS (usually lower impact in CTF context unless it chains)

## Anti-patterns
- Don't fuzz with huge wordlists before checking `robots.txt` and obvious paths.
- Don't run `sqlmap` on every parameter -- identify likely injection points
  first (error messages, numeric IDs, search fields).
- Don't ignore non-HTTP services. A web app may be the foothold, but the
  real path is through a service running on another port (check `nmap` results).
- Don't forget to test with authenticated sessions -- many vulns are post-auth.
