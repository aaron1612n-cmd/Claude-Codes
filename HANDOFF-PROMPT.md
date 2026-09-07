# Handoff prompt — paste at the end of any session, in any project

---

Before we stop, write the notes that let this work continue in a different
chat, with none of your context. Save them as markdown files in the repo and
commit them, so a fresh session that clones the repo picks them up without me
pasting anything.

Write **HANDOFF.md** — the state of play — and, if the codebase has any real
internal shape, **<PROJECT>-INTERNALS.md** as well.

## What HANDOFF.md must lead with

**Open the file with what is *not* done.** Anything I raised that you did not
resolve, anything you were mid-way through, any question you asked me that I
never answered, and anything you are unsure about. If I reported a problem and
never gave you details, say exactly that and say the next session should ask me
for the list rather than guessing. This is the single most valuable part of the
document and it is the part that gets left out.

Be explicit about the difference between **verified**, **assumed**, and **not
checked**. If something passed a test, say which test and what number it
produced. If something was never exercised, say so plainly. Do not let
confident prose imply more than was actually confirmed.

## What else goes in HANDOFF.md

- What this project is, in a couple of sentences, for someone who has never
  seen it.
- Where things live: which branch, which base branch, which files matter, and
  anything non-obvious about the layout.
- **The mechanics that live only in your session and would otherwise be lost** —
  the exact commands to build, run, test, deploy or publish; any URL that must
  be reused rather than recreated (and what goes wrong if it is recreated); any
  scratch tooling you built, reproduced inline so it can be rebuilt.
- The current defaults and settings a newcomer would guess wrong.
- Working agreements: anything I asked for about *how* to work, not just what
  to build — style, testing expectations, how much to check in, what I have
  said I dislike.
- Known rough edges: dead code, papercuts, things that work but not well,
  performance you never profiled.

## What goes in the internals file

Only if there is real structure worth explaining. Cover the data model, the
order things happen in, the rules that govern behaviour, and how to extend it.

Then the part that matters most: **the traps**. Every place where the obvious
change is the wrong one. Every bug that cost real time, written as "do not
reintroduce this" with the reason. Every piece of overloaded or surprising
state. If a constant is the way it is because three other values were tried
first, say so — otherwise someone will tidy it back.

## Rules for writing all of it

- **Do not summarise the diff.** Git already has that. Write down what git
  cannot: intent, rejected alternatives, and why the code is shaped this way.
- Prefer specifics over adjectives. "Terminal velocity ~4 cells/tick, because
  at 9 a pour visibly breaks into packets" beats "tuned the physics".
- Write for a competent stranger, not for me and not for you. Assume no memory
  of this conversation.
- Record decisions I made and preferences I expressed, so the next session does
  not relitigate them or quietly reverse them.
- If you got something wrong during this session and I corrected you, record
  the correction. It is more useful than the tidy final answer.
- Keep it honest. A handoff that oversells what works is worse than none.

## Then

Commit the files with a message explaining what they are for, push to the
working branch, and give them to me directly as well. Finish by telling me — in
one short paragraph, not a list — how to actually pick this up in a new chat:
which branch to check out, which files to read first, any URL to pass through,
and the one thing I should write down myself before I close this session.
