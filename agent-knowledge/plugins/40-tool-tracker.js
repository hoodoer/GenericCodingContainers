// Tool modification tracker: logs when the model writes to /usr/local/bin/
// so the change survives compaction via RUN.md.
//
// The model is root and free to modify any tool. This doesn't block — it just
// records the event. After compaction, the checkpoint plugin carries RUN.md
// context forward, so the model knows it customized something.
import { appendFileSync, mkdirSync } from "node:fs";

const WATCH_PATHS = ["/usr/local/bin/", "/usr/local/sbin/", "/opt/pentest-agent/"];
const logged = new Set();

export const ToolTrackerPlugin = async ({ directory } = {}) => {
  const root = directory || "/workspace";

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
      const cmd = typeof output?.args?.command === "string" ? output.args.command
                : typeof input?.args?.command === "string" ? input.args.command : "";
      if (!cmd) return;

      for (const prefix of WATCH_PATHS) {
        const esc = prefix.replace(/\//g, "\\/");
        const patterns = [
          new RegExp(`(?:tee|cp|mv|install)\\s+.*${esc}`, "i"),
          new RegExp(`(?:sed|patch)\\s+-i.*${esc}`, "i"),
          new RegExp(`>\\s*${esc}`, "i"),
          new RegExp(`(?:echo|printf|cat\\s*<<).*>\\s*${esc}`, "i"),
          new RegExp(`chmod\\s+.*${esc}`, "i"),
        ];
        for (const pat of patterns) {
          if (!pat.test(cmd)) continue;
          const key = cmd.slice(0, 200);
          if (logged.has(key)) return;
          logged.add(key);
          log(`TOOL MODIFIED: command wrote to ${prefix}*: ${cmd.slice(0, 160)}`);
          return;
        }
      }
    },
  };
};

export default ToolTrackerPlugin;
