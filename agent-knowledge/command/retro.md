---
description: Closing retro - distil ONE reusable lesson from this box into lessonsLearned.md
---

The engagement on this box is wrapping up. Do a short retrospective.

Look back over what happened (check `notes/STATE.md`, the wiki, and
`notes/STUCK.md` if it exists). Identify the SINGLE most valuable reusable
lesson — something that will hold on the next box with the same fingerprint,
not a fact that is only true here.

A good lesson is one of:
- a reference claimed X would work and it didn't (and why),
- something worked that no reference covered,
- a stuck period and what finally unblocked it,
- a tool or wrapper that misbehaved (an `env` lesson).

Then write exactly ONE entry with the `lesson` CLI, filling the fingerprint
with the OS and key services (never the box name or IP):

    lesson <phase> <type> '<the lesson>' --fp '<OS + key services>' --evidence '<loot/logs/... or command>' --dest '<reference/skill to amend, or Containerfile>'

If nothing this box taught would help on a different box, say so and write
nothing — one real lesson beats five restatements of things we already knew.
Do not dump the whole engagement; this is the candidate pile for human review.
