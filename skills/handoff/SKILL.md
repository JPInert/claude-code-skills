---
name: handoff
description: Roll this chat over into the next numbered session, distilling what was learned into skills, memory, the project's CLAUDE.md and a short capped state file, so the next session reads its rules automatically instead of inheriting a growing document. Use when the user says /handoff, /cont, /continue, "hand off", "wrap up for a new chat", "continue in a new chat", "close and continue", "roll this chat over", "distil this session", or "update the handoff". Optional argument = topic (e.g. /handoff kodi); otherwise infer it from what this session worked on.
---
<!-- needs: Linux with systemd --user (systemd-run), bash, and the claude() wrapper in claude-wrapper.bash sourced from ~/.bashrc. -->
<!-- no accounts or hardware. Without the wrapper, steps 1-7 still work; you just start the next chat by hand. -->

# Session handoff

This chat closes and reopens as `<name>N+1` in the same terminal, and what it learned goes
to its **right home by lifetime** rather than onto the end of a growing document.

The aim is that the next session needs the state file **only for what is still in flight**.
Everything durable (rules, procedures, lessons, facts) goes where it loads on its own:
`CLAUDE.md` is read automatically, skills and memory load on relevance. A handoff that
pushes this session's learning into the state file has failed even if the file is short.

**Run it at roughly 65% of the context window** (`130k/200k`). Rolling over deliberately
beats letting the compactor run: compaction keeps narrative and drops the numbers, which is
the wrong direction for debugging and measurement work. The four homes below are re-read
from disk by the next session, so they survive what compaction would not.

Never use `/clear`: it wipes this chat's history.

## Triage: every finding goes to exactly one place

| Shape | Home | Test |
|---|---|---|
| A procedure you would repeat | **skill** | "next time I do X, do these steps" |
| A durable lesson or gotcha | **memory** (`type: feedback`) | true next month, and not about this task |
| A stable fact about a system | **memory** (`type: project`/`reference`) | still true if nobody touches it |
| A rule that holds regardless of state | **the project's `CLAUDE.md`** | no expiry date, and it binds |
| What is in flight, pending, or undecided | **state file** | has an expiry date |
| A decision and why it was made | **state file** | "the user chose X when shown both readings" |
| Dated evidence, superseded verdicts | **history file** | nobody needs it unless they doubt a conclusion |

Bias toward the first four. If something could go either way it belongs out of the state
file. That is the whole point.

A global `CLAUDE.md` (the one in your home or main working folder) loads in **every**
project, so only cross-project rules go there; project-specific rules go in that project's
own `CLAUDE.md`. Check whether that repo is public before writing one.

## Steps

1. **Pick the topic.** Argument wins; else infer from the session. Ambiguous: one short
   question.

2. **Harvest to the four durable homes, and write the answers down.** Before the state
   file exists, answer each of these **in the chat, one line per candidate**. A harvest
   nobody wrote down is a harvest that did not happen; this step is why the next session
   can open cold and still know what this one learned.

   | Ask | Where to check first |
   |---|---|
   | What procedure was worked out the hard way? | `ls ~/.claude/skills/`: extend before creating |
   | What rule now holds regardless of state? | that project's own `CLAUDE.md` |
   | Does any rule bind in **every** project? | the global `CLAUDE.md`: almost never; default no |
   | What lesson, fact or correction came out of it? | `~/.claude/projects/*/memory/`: correct a file before adding one |

   **Scanning a long session for this is itself a job; delegate it.** Spawn an Agent with
   `subagent_type: "fork"`; a fork inherits this chat's full context, which a fresh agent
   cannot. Ask it for the candidates in the four-home table above and to mark anything
   already recorded as done. Do not hand it your own list: you want an independent read,
   then you triage. Weigh its answer; do not adopt it wholesale.

   Then apply the test that decides everything below:

   > **If the next session read only `CLAUDE.md`, the skills and memory, and never the
   > state file, what would it get wrong?**

   Whatever you can name goes to one of the four homes **now**. Only what survives that
   question belongs in the state file. The state file is for what has an expiry date, not
   for what this session learned.

3. **Write the skills.** For each procedural finding: new skill, or does an existing one
   just need the new rule? **Extending an existing skill is usually right.**
   - Write to `~/.claude/skills/<name>/SKILL.md`.
   - Frontmatter: `name`, then a `description` naming the **trigger phrases the user would
     actually type**. A skill nobody triggers is dead weight.
   - Include the failures. A rule without the cost it prevented gets "improved" away.

4. **Harvest memory.** One fact per file, per the memory instructions in context.
   - `feedback_*` for lessons: body carries **Why:** and **How to apply:**.
   - Prefer correcting an existing file to adding a near-duplicate; check the directory.
   - Add a one-line pointer to `MEMORY.md`. Never put memory content in `MEMORY.md`.
   - **Save mistakes, not just wins.** The corrections are what change future behaviour.

5. **Write the `CLAUDE.md` rules.** A rule with no expiry date that binds the next
   session belongs here, not in the state file: this is the file the next session reads
   **automatically**, so anything here needs no handoff to survive.
   - Project-specific rule: **that repo's own `CLAUDE.md`**. It only auto-loads when the
     session's working directory is inside that repo, so if the next chat starts elsewhere
     the resume prompt must name it by path.
   - Cross-project rule: the global `CLAUDE.md`. High bar: it must hold for every project
     you run from there. A fact is not a rule; facts go to memory.
   - **Check whether the repo is public before writing one**, and check how the file is
     kept out of git (`git check-ignore -v CLAUDE.md`) rather than trusting what the file
     says about itself.
   - Each rule states the cost it prevents, with the number where there is one. A rule
     without its cost gets "improved" away by a later session.

6. **Rewrite the state file to a cap.** `HANDOFF-<topic>.md` in the working folder.
   **Hard cap: 200 lines.** Rewrite, never append. It holds only:
   - **Access**: paths, units, how to query, where logs are.
   - **CURRENT STATE**, stamped with today's date: what is live, what is in flight, what
     awaits the user's decision, what is scheduled and when.
   - **Open items**: renumber, strike what is done.
   - Anything dated, superseded or evidential moves to `HANDOFF-<topic>-history.md`
     (uncapped; nobody reads it unless a conclusion is doubted). **Say in the state file
     that it is there.** A distilled lesson cannot carry *"we tried that on the 9th and it
     failed for this specific reason"*, and that is the one thing only the history holds.
   - **If you cannot get under the cap, steps 2-5 were done too timidly**: extract
     more rather than raising it. The one honest exception is **open items**: a long-running
     project accumulates pending decisions that are neither lessons nor procedures, so they
     have nowhere else to go. The test on each is whether a *decision* is still attached; an
     item nobody can act on any more goes to history.
   - Never paste secrets into it.
   - **Do not rename the file.** Memory pointers and the resume prompt reference it by name.
   - After the cut, `wc -l` both files. If history did not grow by roughly what state
     shrank, something was dropped rather than moved.

7. **Do NOT commit** unless asked. Say plainly what is uncommitted.

8. **Close and reopen.** The `claude()` function in `claude-wrapper.bash` (next to this
   file; source it from `~/.bashrc`) relaunches claude in the same terminal when the
   session exits, with the staged prompt as its first message and `-n <name>`. If
   `CLAUDE_HANDOFF_RC=1` is set it also passes `--remote-control <name>`, so a rollover
   comes back with Remote Control already connected. That flag's name argument is **not
   optional in practice**: bare, it swallows the next argument (the resume prompt) as the
   session name.

   **The relaunch only happens if the shell holds the CURRENT wrapper.** A shell keeps the
   `claude()` function it sourced at login; editing `~/.bashrc` does not reach it. In one
   case 13 of 17 live chats came back without Remote Control because a wrapper change
   shipped without bumping the tag, so old shells passed the tag check and relaunched the
   old way. **Any change to `claude()` must bump BOTH `CLAUDE_WRAPPER` (wrapper) and
   `WRAPPER_TAG` (exit.sh).** A stale tag makes `exit.sh` exit 2 and park the slot as
   `<shellpid>.pending.*`, which the old function's relaunch loop cannot read; only the new
   wrapper, after `source ~/.bashrc`, takes it.

   Staging is **per terminal window**: `exit.sh` writes
   `~/.claude/handoff-staged/<shellpid>.{prompt,name}`, and the wrapper reads only its own
   window's slot (valid 60 min). Never use a global staging file: an earlier version did,
   every window could read it, and other terminals reopened the wrong chat.

   a. Resume prompt, one line of plain text:
      `Continuing <topic>: read HANDOFF-<topic>.md (short, capped). CLAUDE.md, skills and
      memory carry the rest and load on relevance. Then ask what they want done.`
      When the work lives in another repo whose `CLAUDE.md` does not auto-load from the
      working folder, name that path **first** in the prompt: it is rules, and rules are
      read before state.
   b. `<next-name>`: increment the current session name's trailing number
      (`kodi33` to `kodi34`; no number: append `2`; unnamed: `<topic>2`).
   c. `printf '%s' '<prompt>' | ~/.claude/skills/handoff/exit.sh <next-name>`
      It stages this window's slot and schedules SIGTERM to this claude process about 12 s
      later via `systemd-run --user`, outside the tool sandbox, which reaps its own
      background jobs. Never try `kill … &` from the Bash tool.
      **On exit 2** ("NOT started by the wrapper" / "started by an older wrapper"):
      do not kill. The slot IS staged, so end with:

      > Handoff written to `HANDOFF-<topic>.md`. This terminal's shell is older than the
      > current claude wrapper, so it can't auto-reopen: press Ctrl+D, then run
      > `source ~/.bashrc; claude`. It picks up this window's staged prompt and opens as
      > **<next-name>** (valid for an hour).
   d. Otherwise end with what became a **skill**, what became a **memory**, the state
      file's new line count against the cap, then exactly:

      > Handoff written to `HANDOFF-<topic>.md`. This chat closes itself in a few seconds
      > and reopens as **<next-name>** in this terminal.
      > (If it drops to a shell instead: `source ~/.bashrc; claude`. The wrapper picks
      > this window's staged prompt and name up for an hour.)

   The old session stays in `claude --resume` under its name.

## Wrapper gotchas

- A shell that still has an old `alias claude=…` makes `claude() {` a syntax error when
  the file is re-sourced. The wrapper runs `unalias claude` first. In such a terminal, run
  `unalias claude; source ~/.bashrc` as one line, then `claude` on a **separate** line:
  bash alias-expands a whole line at parse time.
- Closing a terminal outright orphans its staged chat. The HANDOFF file is still there:
  run `claude` and paste the prompt.
