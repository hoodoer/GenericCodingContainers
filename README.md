# GenericCodingContainers

A suite of isolated, local sandboxes wrapped in Docker/Podman containers for AI-driven terminal agents — both coding assistants and a Kali-based penetration-testing environment.

These templates provide a predictable, tool-rich environment while safeguarding your host system's file space and preventing runaway tool execution from making unvetted modifications to your operating system.

---

## 🛠 Included Environments

1. **Claude Code** (`claudeCodeDocker.sh` / `Dockerfile.claude-code-generic`)
   * Fully sandboxed runtime environment for Anthropic's terminal-based coding agent.
   * Keeps agent file discovery, bash execution, and package installations safely bound inside the mounted project directory.

2. **Antigravity & Gemini CLI** (`antigravityDocker.sh` / `Dockerfile.antigravity-generic`)
   * Isolated container for Google-centric CLI tooling, Gemini agent frameworks, and script validation.

3. **OpenCode + Halogen (Qwen 3.8 Flash Next)** (`opencodeHalogenDocker.sh` / `Dockerfile.opencode-halogen`)
   * High-throughput local coding sandbox connected to a local **Halogen Server** backend via host networking (`http://127.0.0.1:8731/v1`).
   * Configured for **256k context (`262,144` tokens)** and speculative decoding on unified memory hardware.
   * Includes dynamic model selection (`opencode-select`), FastMCP structural navigation (`@ast-grep/cli`), and Flash-optimized execution directives in `AGENTS.md`.
   * Polyglot toolchains: Rust (incl. `wasm32`), Go, C/C++ (SDL2/X11), Node 20, Python, Playwright + headless Chromium, and `xvfb` for headless GUI/game verification.

4. **OpenCode + Lemonade** (`opencodeLemonadeDocker.sh` / `Dockerfile.opencode-lemonade`)
   * Sandboxed environment running OpenCode against a local **Lemonade Server (`lemond`)** backend on port `13305`.
   * Includes interactive model discovery, cold-load warmup routines, and conservative token-budget rules designed for dense local LLMs.

5. **OpenCode + Halogen "Hacker" (Pentesting)** (`opencodeHalogenHacker.sh` / `Containerfile.openCode-halogen-hacker`)
   * Kali Linux (`kali-rolling`) based offensive-security sandbox driven by OpenCode against the same local **Halogen Server** backend. **Podman-only.**
   * **Recon & web surface:** nmap, masscan, nuclei, subfinder, naabu, katana, dnsx, httpx-toolkit, ffuf, feroxbuster, gobuster, dirb, dirsearch, wfuzz, nikto, sqlmap, whatweb, wafw00f, testssl.sh, arjun, mitmproxy, graphqlmap, jwt_tool.
   * **Cracking & exploitation:** hydra, john, hashcat, Metasploit Framework, netexec, Impacket, exploitdb/searchsploit, evil-winrm.
   * **Active Directory:** certipy-ad, BloodHound, ldap3, responder, mitm6, dnstool, pywhisker, PKINITtools, PetitPotam, pypykatz, plus `krb5`/`smbclient`/`ldap-utils` plumbing.
   * **RDP & GUI automation:** xfreerdp3, agent-rdp (headless RDP with UI Automation), Xvfb virtual framebuffer, xdotool/wmctrl for input injection, scrot + tesseract OCR for screenshot capture and text extraction.
   * **PowerShell & .NET:** `pwsh` and .NET SDK 8.0 for running/compiling C# tooling (Rubeus, etc.) from Linux.
   * **Pivoting:** ligolo-ng proxy, chisel, websocat, socat, proxychains4, with `seclists`/wordlists bundled.
   * **Pre-staged Windows tools:** `/opt/windows-tools/` contains pre-compiled Rubeus.exe, SharpHound.exe, and Certify.exe ready for upload to targets.
   * **Metasploit MCP (`msf-mcp`):** exposes `search_exploits`, `search_modules`, `module_options`, `run_module`, `db_nmap`, `db_query`, and `msfvenom_build` to the agent via FastMCP.
   * **Persistent Metasploit DB:** PostgreSQL runs inside the container with its data directory backed by a named Podman volume (`halogen-pentest-pgdata`), so `db_nmap` results and msf session data survive container rebuilds.
   * **Agent knowledge system:** Ships a structured knowledge base (`agent-knowledge/`) that is bootstrapped into the workspace on every launch — see [Agent Knowledge](#-agent-knowledge-hacker-edition) below.

---

## 🧩 Sandbox Tooling & Architecture

All OpenCode sandboxes come pre-configured with defensive tooling and bounded execution:

* **UID/GID Mapping & Non-Root Execution:** Coding containers run as an unprivileged `developer` user (UID 1000) matching host permissions, preventing permission-locking on modified files. (The Hacker edition runs as root inside the container — required for PostgreSQL, raw-socket tooling, and packet capture.)
* **Workspace Isolation & Session Persistence:** Internal agent configuration (`~/.local/share/opencode`) is symlinked directly to `/workspace/.opencode`, ensuring chat histories, plans, and session states persist across container rebuilds.
* **Bounded Output Wrapper (`safe-run`):** Intercepts long-running commands, strips ANSI escape sequences, and enforces execution timeouts and output line caps to prevent token exhaustion. In the Hacker edition it also archives full command output to `/workspace/loot/logs/` for engagement notes.
* **AST Structural Search MCP (`codenav-mcp`):** Exposes `ast_search` and `code_outline` via FastMCP and `@ast-grep/cli`, allowing models to inspect definitions and syntax trees without reading full files (coding containers).
* **Automated Directives Seeding:** Auto-populates `AGENTS.md` in newly mounted projects, establishing operational rules for architectural planning (`PLAN.md`), lint verification (`ruff`), and tool-use discipline.

### 🎯 Pentest Scope Enforcement (Hacker edition)

* **`scope_check`:** Validates an IP, CIDR, or domain against `/workspace/scope.txt` (supports CIDR ranges, wildcards, and subdomain matching). Missing file = everything in scope.
* **`run_guarded`:** Scope-enforcing wrapper that extracts targets from a command line and blocks execution (exit 3) if any token falls outside `scope.txt` before delegating to `safe-run`.
* **`msf-run`:** Stateless one-shot `msfconsole` wrapper (`msf-run <module> [set K=V ...] [run|exploit|check]`) so the agent drives Metasploit without interactive sessions.

### 🖥 RDP Tooling (Hacker edition)

Helper scripts for headless RDP sessions against Windows targets:

* **`rdp-connect <ip> <user> <pass> [WxH]`:** Starts Xvfb and connects xfreerdp3 headlessly on a virtual display.
* **`rdp-screenshot [--ocr]`:** Captures the RDP session to `/workspace/loot/screenshots/`. Pass `--ocr` to run tesseract OCR on the capture.
* **`rdp-type "text"` / `rdp-type --cmd "command"` / `rdp-type --key Return`:** Sends keystrokes or commands to the RDP window via xdotool.
* **`rdp-disconnect`:** Tears down the xfreerdp3 and Xvfb processes.
* **`agent-rdp`:** Higher-level headless RDP client with UI Automation support — use `agent-rdp connect`, `agent-rdp automate snapshot -i`, `agent-rdp mouse click @e1`, etc.

### 🧹 Cleanup (Hacker edition)

* **`cleanup [-f]`** (inside the container): Wipes `/workspace`, clears OpenCode sessions, and drops/recreates the Metasploit database. Use `-f` to skip the confirmation prompt.
* **`--clean` flag** (from the host): `./opencodeHalogenHacker.sh --clean` destroys the workspace directory contents and the PostgreSQL Podman volume, then exits — ready for a fresh engagement.

---

## 🧠 Agent Knowledge (Hacker edition)

The Hacker container ships a structured knowledge base in `agent-knowledge/` that is baked into the image at build time and bootstrapped into the workspace on every launch. This gives the agent domain-specific methodology, attack references, and reusable skills without consuming context window on every session.

### How it works

1. **Build time:** `agent-knowledge/` is `COPY`'d into `/opt/pentest-agent/` inside the image.
2. **Launch time:** `opencode-select` copies `AGENTS.md`, `opencode.json` (workspace config), `references/`, and `skills/` into `/workspace/` so the agent picks them up automatically.
3. **`AGENTS.md`** provides the agent's core pentesting methodology — golden rules (simple access before complex attacks, use every identity, enumerate capabilities, timebox dead-ends), a phased workflow (enumerate → capability-map → research → exploit), and playbooks for Windows credential-based access, RDP/GUI, and pivoting.

### Skills

Skill definitions live in `agent-knowledge/skills/` and are deployed to `/workspace/.opencode/skills/` on launch. The agent invokes them automatically when relevant.

| Skill | Purpose |
|---|---|
| `pentest-loop` | Core engagement workflow — enumerate, exploit, research errors, timebox |
| `capability-enumeration` | Map every foothold to concrete attack actions |
| `creds-and-loot` | Handle new credentials, hashes, tickets, or flags |
| `research-symptom` | Diagnose tool failures and exploit errors |
| `shell-and-transfer` | Catch shells, upload/download files, recover dead sessions |
| `pivoting` | Set up tunnels when a foothold sees unreachable networks |
| `web-recon` | Web app recon — tech stack, content discovery, injection testing |

### References

Domain-specific attack references live in `agent-knowledge/references/` and are loaded on demand via `@name` syntax (configured in `opencode-workspace.json`).

| Reference | Topics |
|---|---|
| `@ad` | ACL abuse matrix, Kerberos, dMSA/badSuccessor, RBCD, shadow creds, delegation, tombstone reanimation |
| `@adcs` | ADCS ESC1–16 with certipy commands, certificate-based auth |
| `@windows` | Lateral movement, execution methods, flag/secret locations |
| `@linux` | Privilege escalation: SUID, sudo, capabilities, cron, kernel exploits |
| `@forensics` | Memory/disk image credential extraction with volatility3, offline hive dumps |
| `@web` | SQLi, SSTI, SSRF, XXE, JWT, LFI, file upload, GraphQL, fuzzing |
| `@env` | Lab environment gotchas: clock skew, `/etc/hosts`, NAT, tool syntax quirks |

---

## 🚀 Getting Started

All launch scripts follow an intuitive workspace mounting pattern. Pass the target project directory as the first argument. If no path is provided, the script mounts your current working directory (`pwd`) to `/workspace`.

### Prerequisites
* **Docker** (coding containers) or **Podman** (required for the Hacker edition) installed and running on the host.
* For **Halogen**: Ensure the Halogen server container is running and listening on port `8731`. If it's reached through an SSH tunnel, bind it to `0.0.0.0` so the container can reach it.
* For **Lemonade**: Ensure Lemonade is running and listening on port `13305`.

---

### 1. Launching OpenCode with Halogen (Recommended for Local LLM Coding)
```bash
# Launch in the current directory
./opencodeHalogenDocker.sh

# Target a specific project directory
./opencodeHalogenDocker.sh /path/to/your/project

# Force a clean rebuild of the container image
./opencodeHalogenDocker.sh -r /path/to/your/project
```

### 2. Launching OpenCode with Lemonade
```bash
./opencodeLemonadeDocker.sh                       # current directory
./opencodeLemonadeDocker.sh /path/to/your/project # specific project
./opencodeLemonadeDocker.sh -r                    # force rebuild
```

### 3. Launching Claude Code
```bash
./claudeCodeDocker.sh                       # current directory
./claudeCodeDocker.sh /path/to/your/project # specific project
./claudeCodeDocker.sh --rebuild             # force rebuild
```
Claude authentication state persists via `~/.claude-docker-config` on the host.

### 4. Launching Antigravity CLI
```bash
./antigravityDocker.sh                       # current directory
./antigravityDocker.sh /path/to/your/project # specific project
./antigravityDocker.sh --rebuild             # force rebuild
```

### 5. Launching the Pentest Sandbox (OpenCode + Halogen Hacker)
```bash
# Launch against the current engagement directory
./opencodeHalogenHacker.sh

# Target a specific engagement directory
./opencodeHalogenHacker.sh /path/to/engagement

# Point at a non-default Halogen endpoint
./opencodeHalogenHacker.sh --halogen http://10.0.0.5:8731/v1 /path/to/engagement

# Force a clean rebuild of the Kali image
./opencodeHalogenHacker.sh -r

# Wipe workspace + destroy PostgreSQL volume for a fresh engagement
./opencodeHalogenHacker.sh --clean /path/to/engagement
```
On launch the container starts PostgreSQL (initializing the `msf` database/role on first run), queries Halogen for loaded models, lets you pick one, bootstraps agent knowledge (AGENTS.md, skills, references) into the workspace, and drops you into OpenCode with the Metasploit MCP attached.

**Forwarded ports:** 80, 443, 445, 4444–4460, 8080–8090. Use 4444–4460 for reverse shells, 80/443 for HTTP callbacks and relay attacks (e.g. NTLM relay via PetitPotam), 445 for SMB relay, and 8080–8090 for chisel/ligolo/HTTP staging.

**Recommended:** drop a `scope.txt` in your engagement directory listing authorized targets (one IP, CIDR, or domain per line) so `run_guarded` can block out-of-scope scanning and attacks:
```
10.10.0.0/24
# example.com
*.example.com
```

---

## 📁 Repository Layout

| File | Purpose |
|---|---|
| `Dockerfile.claude-code-generic` / `claudeCodeDocker.sh` | Claude Code sandbox (Docker) |
| `Dockerfile.antigravity-generic` / `antigravityDocker.sh` | Antigravity/Gemini CLI sandbox (Docker) |
| `Dockerfile.opencode-halogen` / `opencodeHalogenDocker.sh` | OpenCode + Halogen coding sandbox (Docker) |
| `Dockerfile.opencode-lemonade` / `opencodeLemonadeDocker.sh` | OpenCode + Lemonade coding sandbox (Docker) |
| `Containerfile.openCode-halogen-hacker` / `opencodeHalogenHacker.sh` | OpenCode + Halogen pentest sandbox (Podman) |
| `setup-openCode-halogen-hacker.sh` | In-image agent tooling installer (safe-run, scope tools, RDP helpers, cleanup, msf wrappers, `msf-mcp`, `opencode-select`) |
| `agent-knowledge/AGENTS.md` | Pentesting agent methodology, golden rules, playbooks |
| `agent-knowledge/opencode-workspace.json` | Workspace config: compaction settings, `@name` reference mappings |
| `agent-knowledge/skills/` | 7 OpenCode skill definitions (pentest-loop, capability-enumeration, etc.) |
| `agent-knowledge/references/` | Domain-specific attack references (AD, ADCS, web, forensics, linux, windows, environment) |
