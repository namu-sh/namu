# Mosaic shell integration for bash
# Source this file in your .bashrc or .bash_profile:
#   source /path/to/mosaic.bash
#
# Emits OSC 133 semantic zone markers and property updates so Mosaic can
# track shell state, working directory, and git branch per terminal panel.

# Guard against double-sourcing and non-interactive shells.
[[ "$-" == *i* ]] || return 0
[[ -n "$MOSAIC_SHELL_INTEGRATION" ]] && return 0
export MOSAIC_SHELL_INTEGRATION=bash

# ── OSC helpers ───────────────────────────────────────────────────────────────

# Emit a raw OSC sequence: ESC ] <payload> ESC \
_mosaic_osc() {
    printf '\e]%s\e\\' "$1"
}

# OSC 133 semantic marker
_mosaic_mark() {
    _mosaic_osc "133;$1"
}

# OSC 133 P property: key=value
_mosaic_prop() {
    _mosaic_osc "133;P;$1=$2"
}

# ── PWD reporting ─────────────────────────────────────────────────────────────

# Pure-shell percent-encoding using printf for safe OSC transport.
_mosaic_urlencode() {
    local string="$1"
    local encoded=""
    local i ch
    for (( i = 0; i < ${#string}; i++ )); do
        ch="${string:$i:1}"
        case "$ch" in
            [A-Za-z0-9_.~/-]) encoded+="$ch" ;;
            *) encoded+=$(printf '%%%02X' "'$ch") ;;
        esac
    done
    printf '%s' "$encoded"
}

_mosaic_report_pwd() {
    local encoded
    encoded=$(_mosaic_urlencode "$PWD")
    _mosaic_prop "cwd" "$encoded"
}

# ── Git branch reporting ──────────────────────────────────────────────────────

_mosaic_report_git_branch() {
    local branch=""
    if command -v git &>/dev/null; then
        branch=$(git symbolic-ref --short HEAD 2>/dev/null \
                 || git describe --tags --exact-match HEAD 2>/dev/null \
                 || git rev-parse --short HEAD 2>/dev/null) || branch=""
    fi
    _mosaic_prop "git_branch" "$branch"
}

# ── Exit code tracking ────────────────────────────────────────────────────────

# In bash, PROMPT_COMMAND fires before the prompt but after the command.
# We capture exit code at the top of PROMPT_COMMAND before anything else runs.
_MOSAIC_LAST_EXIT=0

_mosaic_capture_exit() {
    _MOSAIC_LAST_EXIT=$?
}

# ── Hooks ─────────────────────────────────────────────────────────────────────

# PROMPT_COMMAND equivalent of precmd.
_mosaic_prompt_command() {
    # D marker: command finished.
    _mosaic_mark "D;${_MOSAIC_LAST_EXIT}"

    # Update context.
    _mosaic_report_pwd
    _mosaic_report_git_branch

    # A marker: prompt start.
    _mosaic_mark "A"

    # B marker: command input start (immediately before prompt is displayed,
    # which is the closest bash equivalent to the cursor-ready state).
    _mosaic_mark "B"
}

# preexec equivalent via DEBUG trap.
# Fires before each simple command; we filter to only fire once per user command
# using the _MOSAIC_CMD_RUNNING flag.
_MOSAIC_CMD_RUNNING=0

_mosaic_debug_trap() {
    if [[ "$BASH_COMMAND" != "_mosaic_"* && "$BASH_COMMAND" != "_MOSAIC_"* ]]; then
        if [[ $_MOSAIC_CMD_RUNNING -eq 0 ]]; then
            _MOSAIC_CMD_RUNNING=1
            # C marker: command execution start.
            _mosaic_mark "C;${BASH_COMMAND}"
        fi
    fi
}

# Reset the running flag in PROMPT_COMMAND (after each command completes).
_mosaic_reset_running() {
    _MOSAIC_CMD_RUNNING=0
}

# ── Hook registration ─────────────────────────────────────────────────────────

# Prepend to PROMPT_COMMAND so we capture exit code before other hooks.
if [[ -z "$PROMPT_COMMAND" ]]; then
    PROMPT_COMMAND="_mosaic_capture_exit; _mosaic_reset_running; _mosaic_prompt_command"
else
    PROMPT_COMMAND="_mosaic_capture_exit; _mosaic_reset_running; _mosaic_prompt_command; ${PROMPT_COMMAND}"
fi

# Set DEBUG trap, preserving any existing trap.
_mosaic_existing_debug=$(trap -p DEBUG 2>/dev/null | sed "s/trap -- '//;s/' DEBUG//")
if [[ -n "$_mosaic_existing_debug" ]]; then
    trap "_mosaic_debug_trap; ${_mosaic_existing_debug}" DEBUG
else
    trap "_mosaic_debug_trap" DEBUG
fi
unset _mosaic_existing_debug

# ── Initial state ─────────────────────────────────────────────────────────────

_mosaic_report_pwd
_mosaic_report_git_branch
_mosaic_mark "A"
_mosaic_mark "B"
