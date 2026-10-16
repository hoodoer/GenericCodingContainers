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

// SSH login success: command starts with ssh/sshpass AND output has a
// login banner (Last login, Welcome, motd markers) without auth failure.
const SSH_CMD = /^\s*(?:ssh|sshpass)\b/;
const SSH_SUCCESS = /(?:Last login:|Welcome to|Linux \S+ \d+\.\d+|Ubuntu|Debian|CentOS)/i;
const SSH_FAIL = /(?:Permission denied|Connection refused|Connection closed|No route to host|Could not resolve|Host key verification failed)/i;

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

      // Reject false positives: if the command is reading files, browsing docs,
      // or searching (cat/less/head/grep/curl/websearch/searchsploit), the
      // signal is in static text, not a live shell.
      const cmd = typeof input?.args?.command === "string" ? input.args.command : "";
      const isRead = /^\s*(?:cat|head|tail|less|more|grep|strings|file|xxd|curl|wget|websearch|searchsploit|man|apt|dpkg)\b/.test(cmd);

      // Check standard signals first, then SSH login as a separate path.
      let hitIdx = SIGNALS.findIndex((s) => s.re.test(text));
      let isSsh = false;
      if (hitIdx === -1) {
        if (SSH_CMD.test(cmd) && SSH_SUCCESS.test(text) && !SSH_FAIL.test(text)) {
          isSsh = true;
        } else {
          return;
        }
      }
      if (isRead && !isSsh) return;   // signal appeared in static output, not a live shell

      if (!isSsh) {
        const sig = SIGNALS[hitIdx];
        if (sig.once) {
          const fired = onceFired.get(sid) || new Set();
          if (fired.has(hitIdx)) return;
          fired.add(hitIdx);
          onceFired.set(sid, fired);
        }
      }

      if (typeof output?.output === "string") {
        output.output += REMINDER;
      } else if (output?.metadata && typeof output.metadata.output === "string") {
        output.metadata.output += REMINDER;
      }

      const isOnce = !isSsh && SIGNALS[hitIdx].once;
      if (!isOnce) countdown.set(sid, COOLDOWN);
      log(`FOOTHOLD TRIGGER fired: ${isSsh ? "SSH login" : SIGNALS[hitIdx].re.toString().slice(0, 60)}`);
    },
  };
};

export default FootholdTriggerPlugin;
