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
   * **Recon & web surface:** nmap, masscan, nuclei, subfinder, naabu, katana, dnsx, ffuf, feroxbuster, gobuster, dirb, dirsearch, wfuzz, nikto, sqlmap, whatweb, wafw00f, testssl.sh.
   * **Cracking & exploitation:** hydra, john, hashcat, Metasploit Framework, netexec, Impacket.
   * **Active Directory:** certipy-ad, BloodHound, ldap3, responder, mitm6, dnstool, plus `krb5`/`smbclient`/`ldap-utils` plumbing.
   * **Pivoting:** ligolo-ng proxy and chisel (fetched from GitHub releases at build time), with `seclists`/wordlists bundled.
   * **Metasploit MCP (`msf-mcp`):** exposes `search_exploits`, `search_modules`, `module_options`, `run_module`, `db_nmap`, `db_query`, and `msfvenom_build` to the agent via FastMCP.
   * **Persistent Metasploit DB:** PostgreSQL runs inside the container with its data directory backed by a named Podman volume (`halogen-pentest-pgdata`), so `db_nmap` results and msf session data survive container rebuilds.

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
```
On launch the container starts PostgreSQL (initializing the `msf` database/role on first run), queries Halogen for loaded models, lets you pick one, and drops you into OpenCode with the Metasploit MCP attached.

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
| `setup-openCode-halogen-hacker.sh` | In-image agent tooling installer (safe-run, scope tools, msf wrappers, `msf-mcp`, `opencode-select`) |
