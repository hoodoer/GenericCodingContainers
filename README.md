# GenericCodingContainers

A suite of isolated, local development sandboxes wrapped in Docker containers for AI-driven terminal coding agents.

These templates provide a predictable, tool-rich environment (`build-essential`, `python3`, `nodejs`, network utilities, text editors) while safeguarding your host system's file space and preventing runaway tool execution from making unvetted modifications to your operating system.

---

## 🛠 Included Environments

1. **Claude Code** (`claudeCodeDocker.sh` / `Dockerfile.claude-code-generic`)
   * Fully sandboxed runtime environment for Anthropic's terminal-based coding agent.
   * Keeps agent file discovery and command execution safely bound inside a containerized `/workspace`.

2. **Antigravity & Gemini CLI** (`antigravityDocker.sh` / `Dockerfile.antigravity-generic`)
   * Isolated container for Google-centric CLI tooling, Gemini agent frameworks, and script validation.

3. **OpenCode + Lemonade** (`opencodeDocker.sh` / `Dockerfile.opencode-lemonade`)
   * Sandboxed environment for running OpenCode against a local **Lemonade Server (`lemond`)** backend over host networking (`--network host`).
   * Includes **`opencode-select`**, an interactive helper that queries your live Lemonade models, pre-warms the chosen LLM to prevent cold-load timeouts, dynamically configures OpenCode, and starts the agent.

---

## 🚀 Getting Started

All launch scripts follow an intuitive workspace mounting pattern. Pass the directory path you want to audit or code in as the first argument. If no directory is provided, the script automatically mounts your current working directory (`pwd`) to `/workspace`.

### 1. Launching Claude Code Sandbox
```bash
./claudeCodeDocker.sh /path/to/your/project