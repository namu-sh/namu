# Namu shell integration for bash
# Source this file in your .bashrc or .bash_profile:
#   source /path/to/namu.bash
#
# Emits OSC 133 semantic zone markers and property updates so Namu can
# track shell state, working directory, and git branch per terminal panel.
# Also uses socket-based communication for richer sidebar features when
# $NAMU_SOCKET is available.

# Guard against double-sourcing and non-interactive shells.
[[ "$-" == *i* ]] || return 0
[[ -n "$NAMU_SHELL_INTEGRATION" ]] && return 0
export NAMU_SHELL_INTEGRATION=bash

# ── OSC helpers ───────────────────────────────────────────────────────────────

# Emit a raw OSC sequence: ESC ] <payload> ESC \
_namu_osc() {
    printf '\e]%s\e\\' "$1"
}

# OSC 133 semantic marker
_namu_mark() {
    _namu_osc "133;$1"
}

# OSC 133 P property: key=value
_namu_prop() {
    _namu_osc "133;P;$1=$2"
}

# ── Socket communication ──────────────────────────────────────────────────────

# Send a raw payload to the Namu socket using ncat/socat/nc fallback chain.
_namu_send() {
    local payload="$1"
    [[ -S "${NAMU_SOCKET:-}" ]] || return 0
    if command -v ncat >/dev/null 2>&1; then
        printf '%s\n' "$payload" | ncat -w 1 -U "$NAMU_SOCKET" --send-only >/dev/null 2>&1
    elif command -v socat >/dev/null 2>&1; then
        printf '%s\n' "$payload" | socat -T 1 - "UNIX-CONNECT:$NAMU_SOCKET" >/dev/null 2>&1
    elif command -v nc >/dev/null 2>&1; then
        if printf '%s\n' "$payload" | nc -N -U "$NAMU_SOCKET" >/dev/null 2>&1; then
            :
        else
            printf '%s\n' "$payload" | nc -w 1 -U "$NAMU_SOCKET" >/dev/null 2>&1 || true
        fi
    fi
}

# ── PWD reporting ─────────────────────────────────────────────────────────────

# Pure-shell percent-encoding using printf for safe OSC transport.
_namu_urlencode() {
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

_namu_report_pwd() {
    local encoded
    encoded=$(_namu_urlencode "$PWD")
    _namu_prop "cwd" "$encoded"
    if [[ -S "${NAMU_SOCKET:-}" && -n "${NAMU_WORKSPACE_ID:-}" && -n "${NAMU_SURFACE_ID:-}" ]]; then
        local qpwd="${PWD//\"/\\\"}"
        ( _namu_send "report_pwd \"${qpwd}\" --workspace=$NAMU_WORKSPACE_ID --surface=$NAMU_SURFACE_ID" ) &
    fi
}

# ── Git branch reporting ──────────────────────────────────────────────────────

_namu_report_git_branch() {
    local branch="" dirty_flag=""
    if command -v git &>/dev/null; then
        branch=$(git symbolic-ref --short HEAD 2>/dev/null \
                 || git describe --tags --exact-match HEAD 2>/dev/null \
                 || git rev-parse --short HEAD 2>/dev/null) || branch=""
    fi
    if [[ -n "$branch" ]]; then
        local first
        first="$(git status --porcelain -uno 2>/dev/null | head -1)"
        [[ -n "$first" ]] && dirty_flag="--status=dirty"
    fi
    _namu_prop "git_branch" "$branch"
    if [[ -S "${NAMU_SOCKET:-}" && -n "${NAMU_WORKSPACE_ID:-}" && -n "${NAMU_SURFACE_ID:-}" ]]; then
        if [[ -n "$branch" ]]; then
            ( _namu_send "report_git_branch $branch $dirty_flag --workspace=$NAMU_WORKSPACE_ID --surface=$NAMU_SURFACE_ID" ) &
        else
            ( _namu_send "clear_git_branch --workspace=$NAMU_WORKSPACE_ID --surface=$NAMU_SURFACE_ID" ) &
        fi
    fi
}

# ── Git HEAD watcher ──────────────────────────────────────────────────────────

_NAMU_GIT_HEAD_MTIME=""

_namu_check_git_head() {
    # Find .git/HEAD path without invoking git.
    local dir="$PWD"
    local head_path=""
    while [[ -n "$dir" && "$dir" != "/" ]]; do
        if [[ -d "$dir/.git" ]]; then
            head_path="$dir/.git/HEAD"
            break
        fi
        if [[ -f "$dir/.git" ]]; then
            local line gitdir
            line="$(<"$dir/.git")"
            if [[ "$line" == gitdir:* ]]; then
                gitdir="${line#gitdir:}"
                gitdir="${gitdir## }"
                gitdir="${gitdir%% }"
                [[ -n "$gitdir" ]] || break
                [[ "$gitdir" != /* ]] && gitdir="$dir/$gitdir"
                head_path="$gitdir/HEAD"
            fi
            break
        fi
        dir="${dir%/*}"
    done

    [[ -z "$head_path" || ! -r "$head_path" ]] && return 0

    local mtime
    mtime=$(stat -f '%m' "$head_path" 2>/dev/null || stat -c '%Y' "$head_path" 2>/dev/null || echo "")
    [[ -z "$mtime" ]] && return 0

    if [[ "$mtime" != "$_NAMU_GIT_HEAD_MTIME" ]]; then
        _NAMU_GIT_HEAD_MTIME="$mtime"
        _namu_report_git_branch
    fi
}

# ── Activity state reporting ──────────────────────────────────────────────────

_namu_report_activity() {
    local state="$1"  # idle | running
    local cmd="$2"    # command text (for running state)
    local ts
    ts=$(date -u +%s 2>/dev/null || echo 0)
    if [[ "$state" == "running" ]]; then
        _namu_osc "1337;SetUserVar=namu_activity=running"
        _namu_prop "activity" "running"
        _namu_prop "cmd_start" "$ts"
        _namu_prop "cmd_text" "$cmd"
        if [[ -S "${NAMU_SOCKET:-}" && -n "${NAMU_WORKSPACE_ID:-}" && -n "${NAMU_SURFACE_ID:-}" ]]; then
            ( _namu_send "report_shell_state running --workspace=$NAMU_WORKSPACE_ID --surface=$NAMU_SURFACE_ID" ) &
        fi
    else
        _namu_osc "1337;SetUserVar=namu_activity=idle"
        _namu_prop "activity" "idle"
        _namu_prop "cmd_end" "$ts"
        if [[ -S "${NAMU_SOCKET:-}" && -n "${NAMU_WORKSPACE_ID:-}" && -n "${NAMU_SURFACE_ID:-}" ]]; then
            ( _namu_send "report_shell_state prompt --workspace=$NAMU_WORKSPACE_ID --surface=$NAMU_SURFACE_ID" ) &
        fi
    fi
}

# ── PR poll loop (bash) ───────────────────────────────────────────────────────

_NAMU_PR_POLL_PID=""
_NAMU_PR_POLL_PWD=""

_namu_stop_pr_poll_loop() {
    if [[ -n "$_NAMU_PR_POLL_PID" ]]; then
        kill "$_NAMU_PR_POLL_PID" >/dev/null 2>&1 || true
        _NAMU_PR_POLL_PID=""
    fi
}

_namu_report_pr_for_path() {
    local repo_path="$1"
    [[ -n "$repo_path" && -d "$repo_path" ]] || return 0
    [[ -S "${NAMU_SOCKET:-}" ]] || return 0
    [[ -n "${NAMU_WORKSPACE_ID:-}" ]] || return 0
    [[ -n "${NAMU_SURFACE_ID:-}" ]] || return 0

    local branch
    branch="$(git -C "$repo_path" branch --show-current 2>/dev/null)"
    if [[ -z "$branch" ]] || ! command -v gh >/dev/null 2>&1; then
        _namu_send "clear_pr --workspace=$NAMU_WORKSPACE_ID --surface=$NAMU_SURFACE_ID"
        return 0
    fi

    local remote_url="" path_part="" repo_slug=""
    remote_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null)"
    if [[ -n "$remote_url" ]]; then
        case "$remote_url" in
            git@github.com:*)       path_part="${remote_url#git@github.com:}" ;;
            ssh://git@github.com/*) path_part="${remote_url#ssh://git@github.com/}" ;;
            https://github.com/*)   path_part="${remote_url#https://github.com/}" ;;
            http://github.com/*)    path_part="${remote_url#http://github.com/}" ;;
            git://github.com/*)     path_part="${remote_url#git://github.com/}" ;;
        esac
        path_part="${path_part%.git}"
        [[ "$path_part" == */* ]] && repo_slug="$path_part"
    fi

    local gh_args=()
    [[ -n "$repo_slug" ]] && gh_args=(--repo "$repo_slug")

    local gh_output gh_status
    gh_output="$(
        cd "$repo_path" 2>/dev/null \
            && gh pr view "$branch" \
                "${gh_args[@]}" \
                --json number,state,url \
                --jq '[.number, .state, .url] | @tsv' \
                2>/dev/null
    )"
    gh_status=$?

    if (( gh_status != 0 )) || [[ -z "$gh_output" ]]; then
        return 0
    fi

    local number state url status_opt=""
    IFS=$'\t' read -r number state url <<< "$gh_output"
    [[ -n "$number" && -n "$url" ]] || return 0

    case "$state" in
        MERGED) status_opt="--state=merged" ;;
        OPEN)   status_opt="--state=open" ;;
        CLOSED) status_opt="--state=closed" ;;
        *) return 0 ;;
    esac

    local quoted_branch="${branch//\"/\\\"}"
    _namu_send "report_pr $number $url $status_opt --branch=\"$quoted_branch\" --workspace=$NAMU_WORKSPACE_ID --surface=$NAMU_SURFACE_ID"
}

_namu_start_pr_poll_loop() {
    [[ -S "${NAMU_SOCKET:-}" ]] || return 0
    [[ -n "${NAMU_WORKSPACE_ID:-}" ]] || return 0
    [[ -n "${NAMU_SURFACE_ID:-}" ]] || return 0

    local watch_pwd="${1:-$PWD}"
    local watch_shell_pid="$$"
    local interval="${NAMU_PR_POLL_INTERVAL:-45}"

    if [[ "$watch_pwd" == "$_NAMU_PR_POLL_PWD" && -n "$_NAMU_PR_POLL_PID" ]] \
        && kill -0 "$_NAMU_PR_POLL_PID" 2>/dev/null; then
        return 0
    fi

    _namu_stop_pr_poll_loop
    _NAMU_PR_POLL_PWD="$watch_pwd"

    (
        while true; do
            kill -0 "$watch_shell_pid" >/dev/null 2>&1 || break
            _namu_report_pr_for_path "$watch_pwd" || true
            sleep "$interval"
        done
    ) >/dev/null 2>&1 &
    _NAMU_PR_POLL_PID=$!
}

# ── Scrollback restore ────────────────────────────────────────────────────────

_namu_restore_scrollback() {
    local path="${NAMU_RESTORE_SCROLLBACK_FILE:-}"
    [[ -n "$path" ]] || return 0
    unset NAMU_RESTORE_SCROLLBACK_FILE

    if [[ -r "$path" ]]; then
        /bin/cat -- "$path" 2>/dev/null || true
        /bin/rm -f -- "$path" >/dev/null 2>&1 || true
    fi
}

# Restore scrollback immediately on source (before first prompt).
_namu_restore_scrollback

# ── Remote bootstrap ──────────────────────────────────────────────────────────

namu-ssh() {
    local bootstrap='[ -f ~/.namu/shell-integration.bash ] && source ~/.namu/shell-integration.bash'
    ssh -t "$@" "bash -i -c '${bootstrap}; exec bash -i'"
}

# ── Exit code tracking ────────────────────────────────────────────────────────

_NAMU_LAST_EXIT=0
_NAMU_CMD_START=0
_NAMU_PWD_LAST_PWD=""

_namu_capture_exit() {
    _NAMU_LAST_EXIT=$?
}

# ── Hooks ─────────────────────────────────────────────────────────────────────

# PROMPT_COMMAND equivalent of precmd.
_namu_prompt_command() {
    # D marker: command finished.
    _namu_mark "D;${_NAMU_LAST_EXIT}"

    # Calculate and report command duration.
    if (( _NAMU_CMD_START > 0 )); then
        local now duration
        now=$SECONDS
        duration=$(( now - _NAMU_CMD_START ))
        _namu_prop "cmd_duration" "$duration"
        _NAMU_CMD_START=0
    fi

    # Report idle state.
    _namu_report_activity "idle"

    # Restore scrollback if requested.
    _namu_restore_scrollback

    # CWD update.
    local pwd="$PWD"
    if [[ "$pwd" != "$_NAMU_PWD_LAST_PWD" ]]; then
        _NAMU_PWD_LAST_PWD="$pwd"
        _namu_report_pwd
    else
        _namu_report_pwd
    fi

    # Set terminal title to current directory basename.
    printf '\e]0;%s\e\\' "${PWD##*/}"

    # Git HEAD watcher: re-report branch only when HEAD changes.
    _namu_check_git_head

    # PR poll: restart when directory changes.
    if [[ "$pwd" != "$_NAMU_PR_POLL_PWD" ]]; then
        _namu_start_pr_poll_loop "$pwd"
    fi

    # A marker: prompt start.
    _namu_mark "A"

    # B marker: command input start.
    _namu_mark "B"
}

# preexec equivalent via DEBUG trap.
_NAMU_CMD_RUNNING=0
_NAMU_LAST_CMD=""

_namu_debug_trap() {
    if [[ "$BASH_COMMAND" != "_namu_"* && "$BASH_COMMAND" != "_NAMU_"* ]]; then
        if [[ $_NAMU_CMD_RUNNING -eq 0 ]]; then
            _NAMU_CMD_RUNNING=1
            _NAMU_LAST_CMD="$BASH_COMMAND"

            # Record start time for duration calculation.
            _NAMU_CMD_START=$SECONDS

            # Report command text.
            _namu_prop "last_command" "$BASH_COMMAND"

            # Report running state with command text.
            _namu_report_activity "running" "$BASH_COMMAND"
            # C marker: command execution start.
            _namu_mark "C;${BASH_COMMAND}"

            # Set terminal title to the running command.
            printf '\e]0;%s\e\\' "${BASH_COMMAND%% *}"

            # Heuristic: commands that may change git branch/dirty state.
            case "$BASH_COMMAND" in
                git\ checkout\ *|git\ switch\ *|git\ merge\ *|git\ rebase\ *|git\ pull\ *|\
                gh\ pr\ checkout\ *|git\ reset\ *|git\ stash\ *|\
                git\ *|gh\ *)
                    _NAMU_GIT_HEAD_MTIME=""
                    ;;
            esac
        fi
    fi
}

# Reset the running flag in PROMPT_COMMAND (after each command completes).
_namu_reset_running() {
    _NAMU_CMD_RUNNING=0
}

# ── Hook registration ─────────────────────────────────────────────────────────

# Prepend to PROMPT_COMMAND so we capture exit code before other hooks.
if [[ -z "$PROMPT_COMMAND" ]]; then
    PROMPT_COMMAND="_namu_capture_exit; _namu_reset_running; _namu_prompt_command"
else
    PROMPT_COMMAND="_namu_capture_exit; _namu_reset_running; _namu_prompt_command; ${PROMPT_COMMAND}"
fi

# Set DEBUG trap, preserving any existing trap.
_namu_existing_debug=$(trap -p DEBUG 2>/dev/null | sed "s/trap -- '//;s/' DEBUG//")
if [[ -n "$_namu_existing_debug" ]]; then
    trap "_namu_debug_trap; ${_namu_existing_debug}" DEBUG
else
    trap "_namu_debug_trap" DEBUG
fi
unset _namu_existing_debug

# ── Initial state ─────────────────────────────────────────────────────────────

# Report TTY once on load.
_namu_prop "tty" "$(tty 2>/dev/null || echo '')"

_namu_report_pwd
_namu_report_git_branch
_namu_mark "A"
_namu_mark "B"

# Start PR poll if socket is available.
_namu_start_pr_poll_loop "$PWD"

# ── PATH: prepend Resources/bin so the claude wrapper takes priority ──────────

_namu_fix_path() {
    if [[ -n "${GHOSTTY_BIN_DIR:-}" ]]; then
        local gui_dir="${GHOSTTY_BIN_DIR%/}"
        local bin_dir="${gui_dir%/MacOS}/Resources/bin"
        if [[ -d "$bin_dir" ]]; then
            local new_path=""
            local IFS=:
            for d in $PATH; do
                [[ "$d" == "$bin_dir" || "$d" == "$gui_dir" ]] && continue
                new_path="${new_path:+$new_path:}$d"
            done
            PATH="${bin_dir}:${new_path}"
        fi
    fi
}
_namu_fix_path
unset -f _namu_fix_path
