#!/bin/bash
# /handoff helper: stage the next chat for THIS terminal and end the enclosing Claude
# Code session, so the `claude()` wrapper (claude-wrapper.bash) relaunches it with the staged prompt
# (+ -n from the staged name).
#   usage: printf '%s' "<resume prompt>" | exit.sh <next-session-name> [delay-seconds] [--dry-run]
#
# Per-window staging: the prompt/name are keyed by the ENCLOSING shell's pid (the
# claude process's parent), written to ~/.claude/handoff-staged/<shellpid>.{prompt,name}.
# The wrapper reads the same key as its own $$, and ONLY that key — so two windows
# running /handoff can't clobber each other, and no other window can pick this one up.
# An earlier version used one global staging file; it was readable by every window and
# was how chats crossed over. The prompt arrives on stdin instead (no copy race either).
#
# The kill is scheduled with systemd-run --user because the Bash tool's sandbox reaps
# anything it backgrounds itself (that is why an in-sandbox "self-kill" was brittle).
set -u
WRAPPER_TAG=2026-09-30   # must equal CLAUDE_WRAPPER= in claude-wrapper.bash — BUMP BOTH on any wrapper change
name=""; delay=12; dry=0
for a in "$@"; do
    case "$a" in
        --dry-run) dry=1 ;;
        ''|*[!0-9]*) name="$a" ;;
        *) delay="$a" ;;
    esac
done
usage() { echo "usage: printf '%s' \"<resume prompt>\" | exit.sh <next-session-name> [delay-seconds] [--dry-run]" >&2; exit 64; }
[ -z "$name" ] && usage
[ -t 0 ] && { echo "exit.sh: the resume prompt must be piped on stdin" >&2; usage; }
prompt=$(cat)
[ -z "$prompt" ] && { echo "exit.sh: empty prompt on stdin" >&2; exit 64; }

# Find the enclosing claude process (walk up from the Bash tool's shell).
p=$PPID; pid=""
for _ in 1 2 3 4 5 6 7 8; do
    c=$(ps -o comm= -p "$p" 2>/dev/null) || break
    [ "$c" = claude ] && { pid=$p; break; }
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); { [ -z "$p" ] || [ "$p" = 1 ]; } && break
done
[ -z "$pid" ] && { echo "exit.sh: no enclosing claude process found; nothing staged"; exit 1; }

# Per-window slot, keyed by the enclosing shell (== this claude's parent pid).
# The wrapper computes the same key as its own $$, so the two sides always agree.
# Staged BEFORE the tag check below: a refused kill still leaves the slot ready for the
# manual `source ~/.bashrc; claude` in this same shell (same $$).
wshell=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
{ [ -z "$wshell" ] || [ "$wshell" = 1 ]; } && { echo "exit.sh: claude pid $pid has no parent shell; nothing staged"; exit 1; }
sdir="$HOME/.claude/handoff-staged"; mkdir -p "$sdir"
find "$sdir" -maxdepth 1 -type f -mmin +60 -delete 2>/dev/null
printf '%s' "$prompt" > "$sdir/$wshell.prompt"
printf '%s' "$name" > "$sdir/$wshell.name"
echo "exit.sh: staged per-window handoff for shell $wshell → '$name'"

# Only kill a claude launched by the CURRENT wrapper. An older wrapper or a bare
# `command claude` would not relaunch from the slot; killing it would just drop the user
# to a prompt (happened twice before this check existed).
tag=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CLAUDE_WRAPPER=//p')
if [ "$tag" != "$WRAPPER_TAG" ]; then
    if [ -z "$tag" ]; then echo "exit.sh: claude pid $pid was NOT started by the claude() wrapper (old shell?)."
    else echo "exit.sh: claude pid $pid was started by an older wrapper ($tag; current $WRAPPER_TAG)."; fi
    # Park the slot where the OLD function's relaunch loop can't see it: on Ctrl+D that loop
    # would take it and reopen the old way. The new wrapper reads .pending.
    mv -f "$sdir/$wshell.prompt" "$sdir/$wshell.pending.prompt"
    mv -f "$sdir/$wshell.name" "$sdir/$wshell.pending.name"
    echo "exit.sh: not killing it. Slot is parked (.pending) for this window; tell the user:"
    echo "exit.sh:   press Ctrl+D, then run:  source ~/.bashrc; claude"
    exit 2
fi
if [ "$dry" = 1 ]; then echo "exit.sh: --dry-run, not scheduling the exit of pid $pid"; exit 0; fi
systemd-run --user --quiet --on-active="$delay" --unit="handoff-exit-$pid-$RANDOM" \
    /bin/bash -c "kill -TERM $pid; for i in \$(seq 1 15); do kill -0 $pid 2>/dev/null || exit 0; sleep 1; done; kill -KILL $pid 2>/dev/null; true"
echo "exit.sh: closing claude pid $pid in ${delay}s → wrapper relaunches as '$name'"
