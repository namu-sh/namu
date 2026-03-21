# Mosaic shell integration for zsh
# Source this file in your .zshrc:
#   source /path/to/mosaic.zsh
#
# Emits OSC 133 semantic zone markers and property updates so Mosaic can
# track shell state, working directory, and git branch per terminal panel.

# Guard against double-sourcing and non-interactive shells.
[[ -o interactive ]] || return 0
[[ -n "$MOSAIC_SHELL_INTEGRATION" ]] && return 0
export MOSAIC_SHELL_INTEGRATION=zsh

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

# ── Hooks ─────────────────────────────────────────────────────────────────────

# precmd runs before every prompt.
_mosaic_precmd() {
    local exit_code=$?

    # D marker: command finished with exit code.
    _mosaic_mark "D;$exit_code"

    # Update context before the next prompt.
    _mosaic_report_pwd
    _mosaic_report_git_branch

    # A marker: prompt start.
    _mosaic_mark "A"
}

# preexec runs after the user presses Enter, before the command runs.
# $1 is the command string as typed.
_mosaic_preexec() {
    local cmd="$1"
    # C marker: command execution start, with command text.
    _mosaic_mark "C;${cmd}"
}

# zle line-init runs when the prompt is drawn and the user can type.
_mosaic_zle_line_init() {
    # B marker: command input start.
    _mosaic_mark "B"
}

# ── Hook registration ─────────────────────────────────────────────────────────

autoload -Uz add-zsh-hook

add-zsh-hook precmd  _mosaic_precmd
add-zsh-hook preexec _mosaic_preexec

# Register zle widget for B marker (command input start).
if [[ -n "$ZLE_RPROMPT_INDENT" ]] || zle -l &>/dev/null; then
    zle -N _mosaic_zle_line_init
    # Hook into the line-init widget without clobbering existing bindings.
    if [[ "$(bindkey '^[' 2>/dev/null)" != *"_mosaic"* ]]; then
        # Use zle -N to wrap; safe even if zle-line-init already exists.
        if zle -l zle-line-init &>/dev/null; then
            # Preserve existing zle-line-init
            zle -N _mosaic_orig_zle_line_init
            function zle-line-init() {
                _mosaic_zle_line_init
                _mosaic_orig_zle_line_init 2>/dev/null || true
            }
            zle -N zle-line-init
        else
            function zle-line-init() { _mosaic_zle_line_init; }
            zle -N zle-line-init
        fi
    fi
fi

# ── Initial state ─────────────────────────────────────────────────────────────

# Emit initial pwd/branch so Mosaic has context immediately.
_mosaic_report_pwd
_mosaic_report_git_branch
_mosaic_mark "A"
