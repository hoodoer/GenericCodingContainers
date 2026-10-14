#!/usr/bin/env bash
# Build-time hook-regression guard (DEV-PLAN Cross-cutting §A).
#
# OpenCode is installed unpinned, so every rebuild floats to @latest and the
# plugin layer rides experimental.* hooks that can change between releases. This
# turns a silent mid-engagement break into a loud build failure.
#
# Two checks:
#   1. Each plugin imports cleanly and exports the hooks it relies on   -> FATAL
#      (reliable: catches a broken plugin file, the common regression).
#   2. The installed opencode still contains those hook-name strings    -> WARN
#      (a rename/removal upstream; only a warning because a change to how the
#      binary is bundled could hide the string without the hook being gone).
set -uo pipefail

PLUGIN_DIR="${1:-/opt/pentest-agent/plugins}"
# Hooks each plugin must still export, keyed by basename. A plugin with no entry
# here is only checked for loading cleanly.
hooks_for() {
    case "$1" in
        00-checkpoint.js)  echo "experimental.session.compacting event" ;;
        10-loop-breaker.js) echo "tool.execute.before" ;;
        20-roster-autofeed.js) echo "tool.execute.after" ;;
        30-foothold-trigger.js) echo "tool.execute.after" ;;
        *)                 echo "" ;;
    esac
}
# Hook-name strings the plugins depend on OpenCode still calling.
OPENCODE_HOOKS="experimental.session.compacting tool.execute.before tool.execute.after"

fail=0

echo "[hook-smoke] OpenCode $(opencode --version 2>/dev/null || echo '(version unknown)')"

# --- 1. Plugins import and export the required hooks (FATAL) -------------------
shopt -s nullglob
plugins=("$PLUGIN_DIR"/*.js)
if [ ${#plugins[@]} -eq 0 ]; then
    echo "[hook-smoke] no plugins in $PLUGIN_DIR -- nothing to check."
else
    for p in "${plugins[@]}"; do
        req="$(hooks_for "$(basename "$p")")"
        if node --input-type=module -e '
          import { pathToFileURL } from "node:url";
          const need = process.argv[2].split(" ").filter(Boolean);
          const mod = await import(pathToFileURL(process.argv[1]).href);
          const factory = mod.default ?? Object.values(mod).find((v) => typeof v === "function");
          if (typeof factory !== "function") { console.error("  no exported plugin function"); process.exit(1); }
          const hooks = await factory({ directory: "/tmp" });
          const missing = need.filter((h) => typeof hooks?.[h] !== "function");
          if (missing.length) { console.error("  missing hook(s): " + missing.join(", ")); process.exit(1); }
        ' "$p" "$req"; then
            echo "[hook-smoke] OK   $(basename "$p") loads${req:+ (exports: $req)}"
        else
            echo "[hook-smoke] FAIL $(basename "$p") did not load / is missing a hook"
            fail=1
        fi
    done
fi

# --- 2. OpenCode still references the hook names the plugins use (WARN) --------
BIN="$(command -v opencode || true)"
BIN="$(readlink -f "$BIN" 2>/dev/null || echo "$BIN")"
if [ -n "$BIN" ] && [ -r "$BIN" ]; then
    for h in $OPENCODE_HOOKS; do
        if LC_ALL=C grep -qF -- "$h" "$BIN" 2>/dev/null; then
            echo "[hook-smoke] OK   opencode references '$h'"
        else
            echo "[hook-smoke] WARN opencode no longer references '$h' -- the hook may be"
            echo "             renamed/removed upstream (or the binary is bundled differently)."
            echo "             Re-check the checkpoint plugin against this OpenCode release."
        fi
    done
else
    echo "[hook-smoke] WARN could not locate the opencode binary to scan for hook names."
fi

if [ "$fail" -ne 0 ]; then
    echo "[hook-smoke] FAILED: a plugin regressed. Fix it or the agent loses compaction state."
    exit 1
fi
echo "[hook-smoke] passed."
