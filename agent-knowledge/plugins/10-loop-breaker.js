// Loop circuit-breaker (addresses the qwen looping seen in testing).
//
// OpenCode's own doom_loop guard only fires on 3 CONSECUTIVE, byte-identical
// tool calls. A small model loops in ways that slip past that: the command
// varies a little each pass, it alternates A/B/A/B, or a note/thought lands
// between repeats. This catches a command (normalized) recurring too often in a
// short window — consecutive or not — and, instead of silently blocking, swaps
// it for an `echo` that tells the model it is looping and to change approach.
// Feeding back a DIFFERENT result is what actually breaks the cycle; a plain
// veto just gets retried.
//
// Scope: the bash tool only (where a command can be safely rewritten). Other
// tools still fall to OpenCode's doom_loop guard. The state CLIs are exempt —
// re-reading the board is not a harmful loop and must never be blocked.
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

const WINDOW = 12;     // how many recent bash commands to remember per session
const THRESHOLD = 3;   // same normalized command this many times in the window -> trip
const EXEMPT = new Set(["note", "assess", "wiki", "lesson", "export-session",
                        "note-from-msf", "roster", "cat", "ls", "cd", "pwd"]);

const history = new Map();   // sessionID -> [normalized command, ...]

const norm = (s) => String(s || "").trim().replace(/\s+/g, " ");
const firstWord = (s) => norm(s).split(/[\s|;&]/)[0].replace(/.*\//, "");
const sq = (s) => "'" + String(s).replace(/'/g, "'\\''") + "'";

export const LoopBreakerPlugin = async ({ directory } = {}) => {
  const runLog = `${directory || "/workspace"}/notes/RUN.md`;
  const log = (line) => {
    try {
      mkdirSync(dirname(runLog), { recursive: true });
      appendFileSync(runLog, `- ${new Date().toISOString().replace("T", " ").slice(0, 19)} ${line}\n`);
    } catch {}
  };

  return {
    "tool.execute.before": async (input, output) => {
      if (input?.tool !== "bash") return;
      const cmd = output?.args?.command;
      if (typeof cmd !== "string" || !cmd.trim()) return;
      if (EXEMPT.has(firstWord(cmd))) return;               // never block state/board reads
      if (/loop[ _-]?breaker/i.test(cmd)) return;           // don't re-trip on our own echo

      const sid = input.sessionID || "default";
      const key = norm(cmd);
      const hist = history.get(sid) || [];
      const count = hist.filter((c) => c === key).length + 1;   // incl. this call
      hist.push(key);
      while (hist.length > WINDOW) hist.shift();
      history.set(sid, hist);

      if (count < THRESHOLD) return;

      // Tripped: rewrite the command so the model gets a different, corrective result.
      history.set(sid, hist.filter((c) => c !== key));      // reset so it re-arms after a change
      log(`LOOP BREAKER tripped (x${count}): ${key.slice(0, 120)}`);
      const msg = [
        "⟲ LOOP BREAKER — this command was BLOCKED and did NOT run.",
        `You have already run this (or a near-identical) command ${count} times this session:`,
        "    " + key.slice(0, 160),
        "Running it again returns the same thing you already have. Do NOT reissue it. Instead:",
        "  1. note show        — re-read the state board; the answer may already be recorded",
        "  2. change the approach: a different tool, different inputs, or a different lead",
        "  3. if this vector is a dead end: note stuck '<what, what you tried, why>' then move on",
      ].join("\n");
      output.args.command = `printf '%s\\n' ${sq(msg)}`;
    },
  };
};

export default LoopBreakerPlugin;
