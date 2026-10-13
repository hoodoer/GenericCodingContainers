---
name: wiki
description: Engagement wiki for detail that doesn't fit on the state board - per-host and per-web-app pages, users and principals, detailed attempt write-ups. Use BEFORE re-enumerating anything (search first), when recording detail about a host, service or web app, and when you need context from another host.
---

# Engagement wiki (`wiki/`)

Three places, three jobs -- don't mix them:
- `notes/STATE.md` (`note`): the short board -- creds, access, services, failed vectors, next steps.
- `wiki/` (`wiki`): the depth -- what you learned about each host or app, in detail.
- `ASSESSMENT.md` (`assess`): confirmed, reportable findings for the human.

## Commands
    wiki search <term>               # FIRST, before re-enumerating: an ip, vhost, user, or error string
    wiki add <page> '<detail>'       # append to a page; creates it if new
    wiki show <page>                 # read one page
    wiki index                       # list every page with its tags and when to read it
    wiki new <page> '<title>' --tags ad,adcs,smb --use-when '<when to read it>'

Text containing a `'`: pass it on stdin instead (`wiki add <page> <<'EOF'` ... `EOF`).
Multi-line text is kept as a block, so a short table or a few lines of tool output fit.
`wiki/INDEX.md` is generated after every write -- never edit it by hand.

## Pages
| Page | Holds |
|---|---|
| `hosts/<ip>` | ports and versions, shares, interesting files, how you got in, privesc notes |
| `web/<vhost>` | endpoints, parameters, tech stack, auth behaviour, payloads that did or didn't work |
| `users` | accounts and principals, groups, what each one can DO |
| `attempts` | detailed write-ups of attempts, too long for a `note failed` line |

## Rules
- **Search before you scan.** `wiki search 10.10.11.5` costs one call; re-running a
  scan costs minutes and context. `wiki show hosts/<ip>` ends with an "Also
  mentioned in" line pointing to the other pages that name it -- follow it.
- **Write detail right after you learn it**, the same as `note`. A page you plan to
  write "later" never gets written, and compaction erases what you meant to save.
- **Board line, wiki detail.** Put one line on the board and the detail in the page,
  and point from one to the other:
      note finding 'LFI in /download?file= -- detail: wiki web/app.htb'
- **Paste the lines that matter**, not the whole dump. The full output of every
  `safe-run` command is already in `loot/logs/`; cite the log path.
- **Tag pages** you'll want to find by topic, e.g. `--tags ad,adcs` on a DC's page.
