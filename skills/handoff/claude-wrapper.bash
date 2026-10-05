# claude-wrapper.bash: the shell side of /handoff. Source it from ~/.bashrc:
#     [ -f ~/.claude/skills/handoff/claude-wrapper.bash ] && source ~/.claude/skills/handoff/claude-wrapper.bash
#
# After `claude` exits, this function looks for a prompt that /handoff (exit.sh) staged for
# THIS terminal window and, if there is one, relaunches claude with it. Staging is keyed by
# this shell's pid ($$), so two windows never pick up each other's handoff.
#
# Optional settings (environment):
#   CLAUDE_HANDOFF_RC=1      a relaunched chat also gets --remote-control <name>
#   CLAUDE_EXTRA_ARGS="..."  extra flags for every launch (word-split)
#
# Any change to this function must bump CLAUDE_WRAPPER below AND WRAPPER_TAG in exit.sh.
# exit.sh refuses to end a session started by an older wrapper, because the old function
# already loaded in that shell would not relaunch the way you expect.

# An older `alias claude=...` makes `claude() {` a syntax error when re-sourced; drop it.
unalias claude 2>/dev/null

claude() {
    local sdir="$HOME/.claude/handoff-staged" slot="$HOME/.claude/handoff-staged/$$"
    local prompt; local -a nameopt=() extra=()
    # shellcheck disable=SC2206
    [ -n "${CLAUDE_EXTRA_ARGS:-}" ] && extra=($CLAUDE_EXTRA_ARGS)
    # _hoff_take: consume this window's slot into $prompt / $nameopt; false if none.
    _hoff_take() {
        prompt=""; nameopt=()
        [ -d "$sdir" ] && find "$sdir" -maxdepth 1 -type f -mmin +60 -delete 2>/dev/null
        # "$slot.pending" = staged by exit.sh for a shell on an OLDER wrapper: parked under a
        # name the old function never reads, so only this function (after `source ~/.bashrc`)
        # takes it.
        local f="$slot"; [ -f "$slot.prompt" ] || f="$slot.pending"
        [ -f "$f.prompt" ] || return 1
        prompt=$(<"$f.prompt"); rm -f "$f.prompt"
        if [ -f "$f.name" ]; then nameopt=(-n "$(<"$f.name")"); rm -f "$f.name"; fi
        [ -n "$prompt" ]
    }
    _claude_run() {
        CLAUDE_WRAPPER=2026-09-30 command claude "${extra[@]}" "$@"
    }
    # --remote-control takes an OPTIONAL name, so it must always be given one explicitly:
    # bare, it would swallow the next argument (the resume prompt) as the name.
    _rc_opt() {
        rcopt=()
        [ "${CLAUDE_HANDOFF_RC:-0}" = 1 ] && rcopt=(--remote-control "${nameopt[1]:-handoff}")
    }
    local -a rcopt=()
    if [ $# -eq 0 ] && _hoff_take; then
        _rc_opt
        echo "claude(): starting staged handoff session${nameopt[1]:+ '${nameopt[1]}'}"
        _claude_run "${rcopt[@]}" "${nameopt[@]}" "$prompt"
    else
        _claude_run "$@"
    fi
    # /handoff staged a follow-up for THIS window: relaunch it in this terminal.
    while _hoff_take; do
        _rc_opt
        echo "claude(): relaunching staged handoff session${nameopt[1]:+ '${nameopt[1]}'}"
        _claude_run "${rcopt[@]}" "${nameopt[@]}" "$prompt"
    done
    unset -f _hoff_take _claude_run _rc_opt
}
