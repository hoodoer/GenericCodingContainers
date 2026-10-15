// Compaction checkpoint (DEV-PLAN Phase 2) + runtime canary (Cross-cutting §A).
//
// OpenCode's default compaction prompt is coding-shaped and drops pentest state.
// This adds the state board and pentest-specific instructions to every
// compaction request. It uses output.context, which OpenCode appends to its
// default prompt. Setting output.prompt instead would replace that prompt, and
// with it the previous compaction's summary, from the second compaction on.
//
// Canary: OpenCode floats to @latest and this hook is experimental. Every
// compaction-related event is checked against the hook having fired; a miss is
// written to notes/RUN.md, the OpenCode log, and a TUI toast.
import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { dirname } from "node:path";

const HEADER = "This session is a LIVE penetration test. Write the summary as a continuation";
const MAX_STATE = 16 * 1024;
const CANARY_DELAY_MS = 15_000;          // a "compaction started" event may precede the hook
const HOOK_WINDOW_MS = 60 * 60 * 1000;

// Module-level so that if a loader registers this module twice (named + default
// export), the registrations share state and the work still happens once.
const fired = new Map();    // sessionID -> last time the compaction hook ran
const warned = new Map();   // sessionID -> last time a miss was reported

const stamp = () => {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
         `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
};

const read = (path) => {
  try { return readFileSync(path, "utf8"); } catch { return ""; }
};

const checkpoint = (state) => [
  HEADER,
  "checkpoint for the next assistant, and preserve verbatim where possible:",
  "- current access, and the EXACT command to regain each shell/session",
  "- every credential: user / secret / where it is valid",
  "- hosts, ports, services and versions found",
  "- vectors already TRIED AND FAILED, with the reason (they must not be repeated)",
  "- the immediate next steps",
  "- which wiki pages hold the detail (by page name, e.g. hosts/10.10.11.5) -- don't copy them",
  "",
  "The state board, notes/STATE.md, is below. It is ground truth: carry ALL of it",
  "forward, never contradict it, and summarize the conversation around it.",
  "End the summary with the line: Re-read notes/STATE.md before acting.",
  "",
  "<STATE>",
  state.trim() || "(notes/STATE.md is empty or unreadable -- reconstruct the state from the conversation.)",
  "</STATE>",
].join("\n");

export const CheckpointPlugin = async ({ client, directory } = {}) => {
  const root = directory || "/workspace";
  const runLog = `${root}/notes/RUN.md`;

  const run = (line) => {
    try {
      mkdirSync(dirname(runLog), { recursive: true });
      appendFileSync(runLog, `- ${stamp()} ${line}\n`);
    } catch {}
  };
  const alert = async (message) => {
    run(`WARNING: ${message}`);
    try { await client?.app?.log?.({ body: { service: "checkpoint", level: "error", message } }); } catch {}
    try { await client?.tui?.showToast?.({ body: { message, variant: "error" } }); } catch {}
  };

  run(`checkpoint plugin loaded (opencode ${read("/opt/opencode.version").trim() || "version unknown"})`);

  return {
    "experimental.session.compacting": async (input, output) => {
      fired.set(input?.sessionID, Date.now());
      if (!Array.isArray(output?.context)) {
        await alert("compaction hook shape changed (no output.context): STATE.md was NOT injected");
        return;
      }
      if (output.context.some((c) => String(c).startsWith(HEADER))) return;   // already added
      let state = read(`${root}/notes/STATE.md`);
      if (state.length > MAX_STATE) {
        state = state.slice(0, MAX_STATE) + "\n...(truncated; the full board is notes/STATE.md)";
      }
      output.context.push(checkpoint(state));
      const nextCount = (state.match(/^- (?!STUCK:)/gm) || []).length;
      const nextSection = state.split(/^## Next$/m)[1] || "";
      const nextItems = (nextSection.split(/^## /m)[0].match(/^- /gm) || []).length;
      let extra = "";
      if (nextItems > 5) {
        extra = ` | ⚠ ${nextItems} items in Next — prune stale leads (note rm next '<done>')`;
        output.context.push(
          `The Next section has ${nextItems} items. Before adding more leads, prune entries ` +
          "that are done, wrong, or superseded. Stale leads waste your attention after compaction."
        );
      }
      const n = (read(runLog).match(/ compaction #\d+:/g) || []).length + 1;
      run(`compaction #${n}: STATE.md injected (${state.length} bytes)${extra}`);
    },

    event: async ({ event } = {}) => {
      const type = String(event?.type ?? "");
      if (!type.includes("compact")) return;
      const sid = event?.properties?.sessionID;
      const seenAt = Date.now();
      const timer = setTimeout(() => {
        if (seenAt - (fired.get(sid) ?? 0) < HOOK_WINDOW_MS) return;
        if (Date.now() - (warned.get(sid) ?? 0) < HOOK_WINDOW_MS) return;
        warned.set(sid, Date.now());
        alert(`${type} happened without the checkpoint hook, so that compaction did NOT carry ` +
              "STATE.md. OpenCode's plugin hook surface may have changed.");
      }, CANARY_DELAY_MS);
      timer.unref?.();
    },
  };
};

export default CheckpointPlugin;
