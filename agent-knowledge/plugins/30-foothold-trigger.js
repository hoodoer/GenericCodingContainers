// Foothold trigger (addresses: qwen gets a foothold then hunts flag files
// instead of enumerating the new identity's privileges and lateral paths).
//
// When bash output shows a new identity context (Pwn3d!, new session, root
// shell, SYSTEM), appends a one-line reminder to the tool output telling the
// model to run the post-foothold sweep checklist before looking for flags.
// A cooldown prevents the reminder from firing on every subsequent command.
import { appendFileSync, mkdirSync } from "node:fs";

const SIGNALS = [
  /Pwn3d!/,                                    // nxc admin confirmation
  /session \d+ opened/i,                       // Metasploit session
  /Evil-WinRM\s+shell/i,                       // Evil-WinRM connected
  /\buid=0\(root\)/,                           // Linux root
  /\bNT AUTHORITY\\SYSTEM\b/i,                 // Windows SYSTEM
  /meterpreter\s*>/i,                          // Meterpreter prompt
  /\[\+\].*\bDumping\b.*\b(?:SAM|LSA|NTDS)\b/i, // secretsdump hashes
];

const REMINDER =
  "\n\n⚡ NEW FOOTHOLD — run the post-foothold sweep (Phase 3) BEFORE " +
  "hunting flags. Checklist: (1) whoami/id/privs (2) credential material " +
  "on this host (3) spray the roster (4) privesc paths (5) AD rights. " +
  "Flags are LAST — step 6.";

const COOLDOWN = 5;  // skip N bash calls after a trigger before re-arming

export const FootholdTriggerPlugin = async ({ directory } = {}) => {
  const root = directory || "/workspace";
  const countdown = new Map();   // sessionID -> remaining bash calls to skip

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

      const hit = SIGNALS.find((re) => re.test(text));
      if (!hit) return;

      if (typeof output?.output === "string") {
        output.output += REMINDER;
      } else if (output?.metadata && typeof output.metadata.output === "string") {
        output.metadata.output += REMINDER;
      }

      countdown.set(sid, COOLDOWN);
      log(`FOOTHOLD TRIGGER fired: ${hit.toString().slice(0, 60)}`);
    },
  };
};

export default FootholdTriggerPlugin;
