// Roster auto-feed (addresses: qwen discovers users but never runs `roster add`).
//
// Discovered accounts show up in tool OUTPUT. Rather than trust the model to
// notice and record them, this watches bash output via tool.execute.after and
// pushes any usernames straight into the roster — the model's judgment is out
// of the loop, so whatever tool finds a user, it lands in `roster`.
//
// Three high-precision sources:
//   - Windows/AD: `DOMAIN\name (SidTypeUser)` (RID brute / lookupsid / samrdump)
//   - Linux: /etc/passwd or `getent passwd` lines (7 colon fields, numeric
//     uid/gid), kept when uid >= 1000 (real users) or a known service account.
//   - Emails: local-part of addresses (jake.h@corp.htb -> jake.h) -- on these
//     boxes the email domain is the org and the local-part is the username.
//     Gated hard: skip role mailboxes (noreply/support/admin...) and freemail,
//     and only feed a domain once it has shown >=2 distinct addresses this
//     session, so one stray vendor address can't leak in.
// Noisier formats (nxc --users tables, GetADUsers) are left to a manual
// `roster add` so the roster doesn't fill with junk to spray.
import { execFile } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

// `1103: DANGLINGTREE\jake.h (SidTypeUser)`  ->  jake.h
const SID_USER = /\\([A-Za-z0-9._-]+)\s+\(SidTypeUser\)/g;
// `www-data:x:33:33:...:/usr/sbin/nologin`  ->  name, uid, shell
const PASSWD = /^([a-z_][a-z0-9._-]*):[^:\n]*:(\d{1,6}):(\d{1,6}):[^:\n]*:[^:\n]*:([^:\n]*)$/gm;
const SKIP = new Set(["krbtgt", "guest", "nobody"]);   // can't / won't authenticate as these
// Service accounts worth spraying even though their uid is < 1000.
const PASSWD_KEEP = new Set(["www-data", "postgres", "mysql", "mariadb", "redis",
  "mongodb", "tomcat", "tomcat8", "tomcat9", "jenkins", "git", "oracle", "svc",
  "jboss", "wildfly", "sonarqube", "ftp", "mail"]);

// `jake.h@corp.htb` -> local-part `jake.h`, domain `corp.htb`
const EMAIL = /\b([a-z0-9][a-z0-9._+-]{0,63})@([a-z0-9.-]+\.[a-z]{2,})\b/gi;
// Role/shared mailboxes that are not personal accounts.
const EMAIL_ROLE = new Set(["noreply", "no-reply", "donotreply", "do-not-reply",
  "postmaster", "hostmaster", "webmaster", "mailer-daemon", "abuse", "support",
  "info", "admin", "administrator", "root", "contact", "help", "helpdesk",
  "sales", "marketing", "newsletter", "newsletters", "notifications",
  "notification", "security", "billing", "accounts", "office", "team", "hello",
  "careers", "jobs", "hr", "enquiries", "privacy", "legal"]);
// Public / placeholder mail domains -- not the target's user namespace.
const EMAIL_FREEMAIL = new Set(["gmail.com", "googlemail.com", "outlook.com",
  "hotmail.com", "live.com", "msn.com", "yahoo.com", "yahoo.co.uk", "aol.com",
  "icloud.com", "me.com", "mail.com", "gmx.com", "yandex.com", "protonmail.com",
  "proton.me", "example.com", "example.org", "example.net", "email.com",
  "test.com", "domain.com", "company.com", "acme.com", "sentry.io", "github.com",
  // Technical domains from protocol banners/nmap output (not user namespaces)
  "openssh.com", "libssh.org", "putty.org", "apache.org", "nginx.org",
  "openssl.org", "ietf.org", "w3.org", "mozilla.org", "kernel.org",
  "redhat.com", "debian.org", "ubuntu.com", "canonical.com"]);
// Windows built-in group/principal name fragments that appear as email
// local-parts when BloodHound dumps "DOMAIN ADMINS@CORP.HTB" style output.
// Also covers AD container/OU names that leak from LDAP enumeration.
const BUILTIN_NAMES = new Set([
  // Windows built-in groups/principals
  "administrators", "admins", "users", "guests",
  "operators", "controllers", "servers", "builders", "readers", "replicator",
  "everyone", "interactive", "access", "authority", "group", "system",
  "service", "network", "batch", "enterprise", "iis_iusrs", "creator",
  "owner", "terminal", "certificate", "cloneable", "compatible", "computers",
  "denied", "incoming", "outgoing", "performance", "protected", "schema",
  // AD infrastructure containers and well-known objects
  "foreignsecurityprincipals", "policies", "policytype", "policytemplate",
  "wmipolicy", "som", "compartitions", "compartitionsets", "adminsdholder",
  "dnsupdateproxy", "dnsadmins", "domaincontrollers", "managedserviceaccounts",
  "ntds", "tpm", "infrastructure", "lostandfound", "programdata",
  // Common AD group names that aren't personal accounts
  "contractors", "external", "internal", "vendors",
]);

// Git/patch output contains author names that look like usernames but aren't
// box accounts. Reject text whose surrounding context smells like a commit log,
// patch header, or changelog.
const GIT_CONTEXT = /(?:^commit [0-9a-f]{40}|^Author:|^From:|^Signed-off-by:|^Reviewed-by:|^Acked-by:|^Tested-by:|^Reported-by:|^Cc:)/m;

function usersFromText(text) {
  if (GIT_CONTEXT.test(text)) return new Set();
  const out = new Set();
  for (const m of text.matchAll(SID_USER)) {
    const n = m[1];
    if (!n.endsWith("$") && !SKIP.has(n.toLowerCase())) out.add(n);
  }
  for (const m of text.matchAll(PASSWD)) {
    const name = m[1], uid = parseInt(m[2], 10);
    if (SKIP.has(name.toLowerCase())) continue;
    if (uid >= 1000 && uid !== 65534) out.add(name);          // real login users
    else if (PASSWD_KEEP.has(name.toLowerCase())) out.add(name);  // interesting service accts
  }
  return out;
}

export const RosterAutofeedPlugin = async ({ directory } = {}) => {
  const root = directory || "/workspace";
  const seen = new Map();        // sessionID -> Set of names already fed (avoid re-adding)
  const mailDomains = new Map(); // sessionID -> Map(domain -> Set of local-parts seen)

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
      const text = typeof output?.output === "string" ? output.output
                 : typeof output?.metadata?.output === "string" ? output.metadata.output : "";
      // Cheap pre-filter: an AD SID dump, a passwd-style uid:gid line, or an email.
      if (!text || (!text.includes("SidTypeUser") && !/:\d+:\d+:/.test(text)
                    && !/@[a-z0-9.-]+\.[a-z]{2,}/i.test(text))) return;

      const sid = input.sessionID || "default";
      const found = usersFromText(text);

      // If the output looks like git/patch output, skip email extraction too —
      // author emails are not box accounts.
      if (GIT_CONTEXT.test(text)) {
        if (!found.size) return;
        // fall through with whatever SID/passwd found (unlikely but safe)
      }

      // Emails: accumulate per session; feed a domain's local-parts once it has
      // shown >=2 distinct addresses (one stray address stays out of the roster).
      const domains = mailDomains.get(sid) || new Map();
      for (const m of text.matchAll(EMAIL)) {
        const lp = m[1].toLowerCase().split("+")[0];
        const dom = m[2].toLowerCase();
        if (EMAIL_ROLE.has(lp) || EMAIL_FREEMAIL.has(dom)) continue;
        if (BUILTIN_NAMES.has(lp) || SKIP.has(lp)) continue;
        const pre = text.substring(Math.max(0, m.index - 50), m.index);
        if (/[A-Z]{2,}[ \t]+$/.test(pre)) continue;
        if (!/^[a-z0-9][a-z0-9._-]{0,63}$/.test(lp)) continue;
        if (!domains.has(dom)) domains.set(dom, new Set());
        domains.get(dom).add(lp);
      }
      mailDomains.set(sid, domains);
      for (const lps of domains.values()) {
        if (lps.size >= 2) lps.forEach((lp) => found.add(lp));
      }
      if (!found.size) return;
      const already = seen.get(sid) || new Set();
      const fresh = [...found].filter((n) => !already.has(n));
      if (!fresh.length) return;
      fresh.forEach((n) => already.add(n));
      seen.set(sid, already);

      // Fire-and-forget: roster dedups, so a race with a manual add is harmless.
      execFile("roster", ["add", ...fresh], { timeout: 10000 }, () => {});
      log(`roster auto-fed ${fresh.length} user(s) from tool output: ${fresh.join(", ")}`);
    },
  };
};

export default RosterAutofeedPlugin;
