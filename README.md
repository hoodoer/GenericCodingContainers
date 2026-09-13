# GenericCodingContainers

A suite of isolated, local development sandboxes wrapped in Docker containers for AI-driven terminal coding agents.

These templates provide a predictable, tool-rich environment (`build-essential`, `python3`, `nodejs`, network utilities, text editors) while safeguarding your host system's file space and preventing runaway tool execution from making unvetted modifications to your operating system.

---

## 🛠 Included Environments

1. **Claude Code** (`claudeCodeDocker.sh` / `Dockerfile.claude-code-generic`)
   * Fully sandboxed runtime environment for Anthropic's terminal-based coding agent.
   * Keeps agent file discovery, bash execution, and package installations safely bound inside `/workspace`.

2. **Antigravity & Gemini CLI** (`antigravityDocker.sh` / `Dockerfile.antigravity-generic`)
   * Isolated container for Google-centric CLI tooling, Gemini agent frameworks, and script validation.

3. **OpenCode + Halogen (Qwen 3.8 Flash Next)** (`opencodeHalogenDocker.sh` / `Dockerfile.opencode-halogen`)
   * High-throughput local coding sandbox connected to a local **Halogen Server** backend via host loopback (`http://host.docker.internal:8731/v1`).
   * Configured for **256k context (`262,144` tokens)** and speculative decoding on unified memory hardware.
   * Includes dynamic model selection (`opencode-select`), FastMCP structural navigation (`@ast-grep/cli`), and Flash-optimized execution directives in `AGENTS.md`.

4. **OpenCode + Lemonade** (`opencodeLemonadeDocker.sh` / `Dockerfile.opencode-lemonade`)
   * Sandboxed environment running OpenCode against a local **Lemonade Server (`lemond`)** backend on port `13305`.
   * Includes interactive model discovery, cold-load warmup routines, and conservative token-budget rules designed for dense local LLMs.

---

## 🧩 Sandbox Tooling & Architecture

All OpenCode sandboxes come pre-configured with defensive tooling and structural code inspection:

* **UID/GID Mapping & Non-Root Execution:** Containers run as an unprivileged `developer` user (UID 1000) matching host permissions, preventing permission-locking on modified files.
* **Workspace Isolation & Session Persistence:** Internal agent configuration (`~/.local/share/opencode`) is symlinked directly to `/workspace/.opencode`, ensuring chat histories, plans, and session states persist across container rebuilds.
* **Bounded Output Wrapper (`safe-run`):** Intercepts long-running commands, strips ANSI escape sequences, and enforces execution timeouts and output line caps to prevent token exhaustion.
* **AST Structural Search MCP (`codenav-mcp`):** Exposes `ast_search` and `code_outline` via FastMCP and `@ast-grep/cli`, allowing models to inspect definitions and syntax trees without reading full files.
* **Automated Directives Seeding:** Auto-populates `AGENTS.md` in newly mounted projects, establishing operational rules for architectural planning (`PLAN.md`), lint verification (`ruff`), and tool-use discipline.

---

## 🚀 Getting Started

All launch scripts follow an intuitive workspace mounting pattern. Pass the target project directory as the first argument. If no path is provided, the script mounts your current working directory (`pwd`) to `/workspace`.

### Prerequisites
* **Docker** or **Podman** installed and running on the host.
* For **Halogen**: Ensure the Halogen server container is running and listening on port `8731`.
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