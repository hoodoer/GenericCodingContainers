// Foothold trigger (addresses: qwen gets a foothold then hunts flag files
// instead of enumerating the new identity's privileges and lateral paths).
//
// When bash output shows a new identity context (Pwn3d!, new session, root
// shell, SYSTEM), appends a one-line reminder to the tool output telling the
// model to run the post-foothold sweep checklist before looking for flags.
//
// Signals split into two classes:
//   - "once": persistent contexts (root, SYSTEM, meterpreter) — fire the first
//     time they appear in a session, then never again. The model already knows
//     it has that access; re-firing on every command through the mount is noise.
//   - "every": discrete events (Pwn3d!, new session, Evil-WinRM, secretsdump)
//     — fire each time with a cooldown, because each one may be a new identity.
import { appendFileSync, mkdirSync } from "node:fs";

const SIGNALS = [
  { re: /Pwn3d!/,                                     once: false },
  { re: /session \d+ opened/i,                        once: false },
  { re: /Evil-WinRM\s+shell/i,                        once: false },
  { re: /\[\+\].*\bDumping\b.*\b(?:SAM|LSA|NTDS)\b/i, once: false },
  { re: /\buid=0\(root\)/,                            once: true },
  { re: /\bNT AUTHORITY\\SYSTEM\b/i,                  once: true },
  { re: /meterpreter\s*>/i,                           once: true },
];

const REMINDER =
  "\n\n⚡ NEW FOOTHOLD — run the post-foothold sweep (Phase 3) BEFORE " +
  "hunting flags. Checklist: (1) whoami/id/privs (2) credential material " +
  "on this host (3) spray the roster (4) privesc paths (5) AD rights. " +
  "Flags are LAST — step 6.";

const COOLDOWN = 5;  // skip N bash calls after an "every" trigger before re-arming

export const FootholdTriggerPlugin = async ({ directory } = {}) => {
  const root = directory || "/workspace";
  const countdown = new Map();   // sessionID -> remaining bash calls to skip
  const onceFired = new Map();   // sessionID -> Set of signal indices already fired

  const log = (line) => {
    try {
      mkdirSync(`${root}/notes`, { recursive: true });
      appendFileSync(`${root}/notes/RUN.md`,
        `- ${new Date().toISOString().replace("T", " ").slice(0, 19)} ${line}\n`);
    } catch {}
  };

  return {
    "tool.execute.after": async (input, output) => {
      if (input?.tool !== "bash") return;
      const sid = input.sessionID || "default";
      const cd = countdown.get(sid) || 0;

      if (cd > 0) {
        countdown.set(sid, cd - 1);
        return;
      }

      const text = typeof output?.output === "string" ? output.output
                 : typeof output?.metadata?.output === "string" ? output.metadata.output : "";
      if (!text) return;

      const hitIdx = SIGNALS.findIndex((s) => s.re.test(text));
      if (hitIdx === -1) return;
      const sig = SIGNALS[hitIdx];

      if (sig.once) {
        const fired = onceFired.get(sid) || new Set();
        if (fired.has(hitIdx)) return;   // already reminded for this context
        fired.add(hitIdx);
        onceFired.set(sid, fired);
      }

      if (typeof output?.output === "string") {
        output.output += REMINDER;
      } else if (output?.metadata && typeof output.metadata.output === "string") {
        output.metadata.output += REMINDER;
      }

      if (!sig.once) countdown.set(sid, COOLDOWN);
      log(`FOOTHOLD TRIGGER fired: ${sig.re.toString().slice(0, 60)}`);
    },
  };
};

export default FootholdTriggerPlugin;
