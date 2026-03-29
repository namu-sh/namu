# Namu shell integration for zsh
# Source this file in your .zshrc:
#   source /path/to/namu.zsh
#
# Emits OSC 133 semantic zone markers and property updates so Namu can
# track shell state, working directory, and git branch per terminal panel.
# Also uses socket-based communication for richer sidebar features when
# $NAMU_SOCKET is available.

# Guard against double-sourcing and non-interactive shells.
[[ -o interactive ]] || return 0
[[ -n "$NAMU_SHELL_INTEGRATION" ]] && return 0
export NAMU_SHELL_INTEGRATION=zsh

# ── Load zsh/datetime for EPOCHSECONDS / EPOCHREALTIME ────────────────────────
zmodload zsh/datetime 2>/dev/null || true

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

# Load zsh/net/socket for zsocket IPC (no subprocess spawn — much faster than ncat/socat).
zmodload zsh/net/socket 2>/dev/null && _NAMU_HAS_ZSOCKET=1 || _NAMU_HAS_ZSOCKET=0

# Send a raw payload to the Namu socket.
# Fast path: zsocket (pure zsh, zero subprocess).
# Fallback chain: ncat → socat → nc.
_namu_send() {
    local payload="$1"
    [[ -S "${NAMU_SOCKET:-}" ]] || return 0

    if (( _NAMU_HAS_ZSOCKET )); then
        local fd
        if zsocket fd "$NAMU_SOCKET" 2>/dev/null; then
            print -r -u "$fd" -- "$payload" 2>/dev/null || true
            exec {fd}>&- 2>/dev/null || true
            return 0
        fi
        # zsocket connect failed (e.g. socket busy); fall through to subprocess methods.
    fi

    if command -v ncat >/dev/null 2>&1; then
        print -r -- "$payload" | ncat -w 1 -U "$NAMU_SOCKET" --send-only >/dev/null 2>&1
    elif command -v socat >/dev/null 2>&1; then
        print -r -- "$payload" | socat -T 1 - "UNIX-CONNECT:$NAMU_SOCKET" >/dev/null 2>&1
    elif command -v nc >/dev/null 2>&1; then
        if print -r -- "$payload" | nc -N -U "$NAMU_SOCKET" >/dev/null 2>&1; then
            :
        else
            print -r -- "$payload" | nc -w 1 -U "$NAMU_SOCKET" >/dev/null 2>&1 || true
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
    # Also send via socket if available and IDs are set.
    if [[ -S "${NAMU_SOCKET:-}" && -n "${NAMU_WORKSPACE_ID:-}" && -n "${NAMU_SURFACE_ID:-}" ]]; then
        local qpwd="${PWD//\"/\\\"}"
        {
            _namu_send "report_pwd \"${qpwd}\" --workspace=$NAMU_WORKSPACE_ID --surface=$NAMU_SURFACE_ID"
        } >/dev/null 2>&1 &!
    fi
}

# ── Git helpers ───────────────────────────────────────────────────────────────

_namu_git_resolve_head_path() {
    local dir="$PWD"
    while true; do
        if [[ -d "$dir/.git" ]]; then
            print -r -- "$dir/.git/HEAD"
            return 0
        fi
        if [[ -f "$dir/.git" ]]; then
            local line gitdir
            line="$(<"$dir/.git")"
            if [[ "$line" == gitdir:* ]]; then
                gitdir="${line#gitdir:}"
                gitdir="${gitdir## }"
                gitdir="${gitdir%% }"
                [[ -n "$gitdir" ]] || return 1
                [[ "$gitdir" != /* ]] && gitdir="$dir/$gitdir"
                print -r -- "$gitdir/HEAD"
                return 0
            fi
        fi
        [[ "$dir" == "/" || -z "$dir" ]] && break
        dir="${dir:h}"
    done
    return 1
}

_namu_git_head_signature() {
    local head_path="$1"
    [[ -n "$head_path" && -r "$head_path" ]] || return 1
    local line=""
    IFS= read -r line < "$head_path" && print -r -- "$line"
}

# ── Git branch reporting ──────────────────────────────────────────────────────

_namu_report_git_branch_for_path() {
    local repo_path="${1:-$PWD}"
    [[ -n "$repo_path" ]] || return 0

    git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1 || return 0

    local branch dirty_flag=""
    branch="$(git -C "$repo_path" branch --show-current 2>/dev/null)"
    if [[ -n "$branch" ]]; then
        local first
        first="$(git -C "$repo_path" status --porcelain -uno 2>/dev/null | head -1)"
        [[ -n "$first" ]] && dirty_flag="--status=dirty"
        # OSC-based report
        _namu_prop "git_branch" "$branch"
        # Socket-based report
        if [[ -S "${NAMU_SOCKET:-}" && -n "${NAMU_WORKSPACE_ID:-}" && -n "${NAMU_SURFACE_ID:-}" ]]; then
            _namu_send "report_git_branch $branch $dirty_flag --workspace=$NAMU_WORKSPACE_ID --surface=$NAMU_SURFACE_ID"
        fi
    else
        _namu_prop "git_branch" ""
        if [[ -S "${NAMU_SOCKET:-}" && -n "${NAMU_WORKSPACE_ID:-}" && -n "${NAMU_SURFACE_ID:-}" ]]; then
            _namu_send "clear_git_branch --workspace=$NAMU_WORKSPACE_ID --surface=$NAMU_SURFACE_ID"
        fi
    fi
}

_namu_report_git_branch() {
    _namu_report_git_branch_for_path "$PWD"
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
            {
                local _escaped_cmd="${cmd//\"/\\\"}"
                _namu_send "{\"jsonrpc\":\"2.0\",\"method\":\"report_shell_state\",\"params\":{\"state\":\"running\",\"command\":\"${_escaped_cmd}\",\"surface_id\":\"$NAMU_SURFACE_ID\",\"workspace_id\":\"$NAMU_WORKSPACE_ID\"}}"
            } >/dev/null 2>&1 &!
        fi
    else
        _namu_osc "1337;SetUserVar=namu_activity=idle"
        _namu_prop "activity" "idle"
        _namu_prop "cmd_end" "$ts"
        if [[ -S "${NAMU_SOCKET:-}" && -n "${NAMU_WORKSPACE_ID:-}" && -n "${NAMU_SURFACE_ID:-}" ]]; then
            {
                _namu_send "{\"jsonrpc\":\"2.0\",\"method\":\"report_shell_state\",\"params\":{\"state\":\"prompt\",\"surface_id\":\"$NAMU_SURFACE_ID\",\"workspace_id\":\"$NAMU_WORKSPACE_ID\"}}"
            } >/dev/null 2>&1 &!
        fi
    fi
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
    local bootstrap='[ -f ~/.namu/shell-integration.zsh ] && source ~/.namu/shell-integration.zsh'
    ssh -t "$@" "zsh -i -c '${bootstrap}; exec zsh -i'"
}

# ── State variables ───────────────────────────────────────────────────────────

typeset -g _NAMU_CMD_START=0
typeset -g _NAMU_PWD_LAST_PWD=""
typeset -g _NAMU_GIT_LAST_PWD=""
typeset -g _NAMU_GIT_LAST_RUN=0
typeset -g _NAMU_GIT_JOB_PID=""
typeset -g _NAMU_GIT_JOB_STARTED_AT=0
typeset -g _NAMU_GIT_FORCE=0
typeset -g _NAMU_GIT_HEAD_LAST_PWD=""
typeset -g _NAMU_GIT_HEAD_PATH=""
typeset -g _NAMU_GIT_HEAD_SIGNATURE=""
typeset -g _NAMU_GIT_HEAD_WATCH_PID=""
typeset -g _NAMU_PR_POLL_PID=""
typeset -g _NAMU_PR_POLL_PWD=""
typeset -g _NAMU_PR_POLL_INTERVAL=45
typeset -g _NAMU_PR_FORCE=0
typeset -g _NAMU_ASYNC_JOB_TIMEOUT=20
typeset -g _NAMU_WINCH_GUARD_INSTALLED=0

# ── WINCH guard ───────────────────────────────────────────────────────────────

_namu_install_winch_guard() {
    (( _NAMU_WINCH_GUARD_INSTALLED )) && return 0

    # Respect user-defined WINCH handlers.
    local existing_winch_trap=""
    existing_winch_trap="$(trap -p WINCH 2>/dev/null || true)"
    if (( $+functions[TRAPWINCH] )) || [[ -n "$existing_winch_trap" ]]; then
        _NAMU_WINCH_GUARD_INSTALLED=1
        return 0
    fi

    TRAPWINCH() {
        # Prevent terminal resize from duplicating the prompt line.
        return 0
    }

    _NAMU_WINCH_GUARD_INSTALLED=1
}
_namu_install_winch_guard

# ── Background git HEAD watcher ───────────────────────────────────────────────

_namu_stop_git_head_watch() {
    if [[ -n "$_NAMU_GIT_HEAD_WATCH_PID" ]]; then
        kill "$_NAMU_GIT_HEAD_WATCH_PID" >/dev/null 2>&1 || true
        _NAMU_GIT_HEAD_WATCH_PID=""
    fi
}

_namu_start_git_head_watch() {
    local watch_pwd="$PWD"
    local watch_head_path
    watch_head_path="$(_namu_git_resolve_head_path 2>/dev/null || true)"
    [[ -n "$watch_head_path" ]] || return 0

    local watch_head_signature
    watch_head_signature="$(_namu_git_head_signature "$watch_head_path" 2>/dev/null || true)"

    _NAMU_GIT_HEAD_LAST_PWD="$watch_pwd"
    _NAMU_GIT_HEAD_PATH="$watch_head_path"
    _NAMU_GIT_HEAD_SIGNATURE="$watch_head_signature"

    _namu_stop_git_head_watch
    {
        local last_signature="$watch_head_signature"
        while true; do
            sleep 1
            local signature
            signature="$(_namu_git_head_signature "$watch_head_path" 2>/dev/null || true)"
            if [[ -n "$signature" && "$signature" != "$last_signature" ]]; then
                last_signature="$signature"
                _namu_report_git_branch_for_path "$watch_pwd"
            fi
        done
    } >/dev/null 2>&1 &!
    _NAMU_GIT_HEAD_WATCH_PID=$!
}

# ── PR poll loop ──────────────────────────────────────────────────────────────

_namu_pr_output_indicates_no_pull_request() {
    local output="${1:l}"
    [[ "$output" == *"no pull requests found"* \
        || "$output" == *"no pull request found"* \
        || "$output" == *"no pull requests associated"* \
        || "$output" == *"no pull request associated"* ]]
}

_namu_github_repo_slug_for_path() {
    local repo_path="$1"
    local remote_url="" path_part=""
    [[ -n "$repo_path" ]] || return 0

    remote_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null)"
    [[ -n "$remote_url" ]] || return 0

    case "$remote_url" in
        git@github.com:*)      path_part="${remote_url#git@github.com:}" ;;
        ssh://git@github.com/*) path_part="${remote_url#ssh://git@github.com/}" ;;
        https://github.com/*)  path_part="${remote_url#https://github.com/}" ;;
        http://github.com/*)   path_part="${remote_url#http://github.com/}" ;;
        git://github.com/*)    path_part="${remote_url#git://github.com/}" ;;
        *) return 0 ;;
    esac

    path_part="${path_part%.git}"
    [[ "$path_part" == */* ]] || return 0
    print -r -- "$path_part"
}

_namu_kill_process_tree() {
    local pid="$1"
    local signal="${2:-TERM}"
    local child_pid=""
    [[ -n "$pid" ]] || return 0
    while IFS= read -r child_pid; do
        [[ -n "$child_pid" ]] || continue
        [[ "$child_pid" == "$pid" ]] && continue
        _namu_kill_process_tree "$child_pid" "$signal"
    done < <(/bin/ps -ax -o pid= -o ppid= 2>/dev/null | /usr/bin/awk -v parent="$pid" '$2 == parent { print $1 }')
    kill "-$signal" "$pid" >/dev/null 2>&1 || true
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

    local repo_slug="" gh_repo_args=()
    repo_slug="$(_namu_github_repo_slug_for_path "$repo_path")"
    [[ -n "$repo_slug" ]] && gh_repo_args=(--repo "$repo_slug")

    local err_file gh_output gh_error gh_status
    err_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/namu-gh-pr-view.XXXXXX" 2>/dev/null || true)"
    [[ -n "$err_file" ]] || return 1

    gh_output="$(
        builtin cd "$repo_path" 2>/dev/null \
            && gh pr view "$branch" \
                "${gh_repo_args[@]}" \
                --json number,state,url \
                --jq '[.number, .state, .url] | @tsv' \
                2>"$err_file"
    )"
    gh_status=$?

    if [[ -f "$err_file" ]]; then
        gh_error="$("/bin/cat" -- "$err_file" 2>/dev/null || true)"
        /bin/rm -f -- "$err_file" >/dev/null 2>&1 || true
    fi

    if (( gh_status != 0 )) || [[ -z "$gh_output" ]]; then
        if _namu_pr_output_indicates_no_pull_request "$gh_error"; then
            _namu_send "clear_pr --workspace=$NAMU_WORKSPACE_ID --surface=$NAMU_SURFACE_ID"
        fi
        return 0
    fi

    local number state url status_opt=""
    local IFS=$'\t'
    read -r number state url <<< "$gh_output"
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

_namu_stop_pr_poll_loop() {
    if [[ -n "$_NAMU_PR_POLL_PID" ]]; then
        _namu_kill_process_tree "$_NAMU_PR_POLL_PID" KILL
        _NAMU_PR_POLL_PID=""
    fi
}

_namu_start_pr_poll_loop() {
    [[ -S "${NAMU_SOCKET:-}" ]] || return 0
    [[ -n "${NAMU_WORKSPACE_ID:-}" ]] || return 0
    [[ -n "${NAMU_SURFACE_ID:-}" ]] || return 0

    local watch_pwd="${1:-$PWD}"
    local force_restart="${2:-0}"
    local watch_shell_pid="$$"
    local interval="${_NAMU_PR_POLL_INTERVAL:-45}"

    if [[ "$force_restart" != "1" && "$watch_pwd" == "$_NAMU_PR_POLL_PWD" && -n "$_NAMU_PR_POLL_PID" ]] \
        && kill -0 "$_NAMU_PR_POLL_PID" 2>/dev/null; then
        return 0
    fi

    _namu_stop_pr_poll_loop
    _NAMU_PR_POLL_PWD="$watch_pwd"

    {
        while true; do
            kill -0 "$watch_shell_pid" >/dev/null 2>&1 || break
            _namu_report_pr_for_path "$watch_pwd" || true
            sleep "$interval"
        done
    } >/dev/null 2>&1 &!
    _NAMU_PR_POLL_PID=$!
}

# ── Shell exit cleanup ────────────────────────────────────────────────────────

_namu_zshexit() {
    _namu_stop_git_head_watch
    _namu_stop_pr_poll_loop
}

# ── Hooks ─────────────────────────────────────────────────────────────────────

# precmd runs before every prompt.
_namu_precmd() {
    local exit_code=$?

    # D marker: command finished with exit code.
    _namu_mark "D;$exit_code"

    # Calculate and report command duration.
    if (( _NAMU_CMD_START > 0 )); then
        local duration
        duration=$(( EPOCHREALTIME - _NAMU_CMD_START ))
        _namu_prop "cmd_duration" "$duration"
        _NAMU_CMD_START=0
    fi

    _namu_stop_git_head_watch

    # Report idle/prompt state.
    _namu_report_activity "idle"

    # Restore scrollback if requested.
    _namu_restore_scrollback

    local now=$EPOCHSECONDS
    local pwd="$PWD"

    # CWD: keep the app in sync with the actual shell directory.
    if [[ "$pwd" != "$_NAMU_PWD_LAST_PWD" ]]; then
        _NAMU_PWD_LAST_PWD="$pwd"
        _namu_report_pwd
    else
        _namu_report_pwd
    fi

    # Set terminal title to current directory basename.
    printf '\e]0;%s\e\\' "${PWD##*/}"

    # Track HEAD path changes when cwd changes.
    if [[ "$pwd" != "$_NAMU_GIT_HEAD_LAST_PWD" ]]; then
        _NAMU_GIT_HEAD_LAST_PWD="$pwd"
        _NAMU_GIT_HEAD_PATH="$(_namu_git_resolve_head_path 2>/dev/null || true)"
        _NAMU_GIT_HEAD_SIGNATURE=""
    fi

    local git_head_changed=0
    if [[ -n "$_NAMU_GIT_HEAD_PATH" ]]; then
        local head_signature
        head_signature="$(_namu_git_head_signature "$_NAMU_GIT_HEAD_PATH" 2>/dev/null || true)"
        if [[ -n "$head_signature" ]]; then
            if [[ -z "$_NAMU_GIT_HEAD_SIGNATURE" ]]; then
                _NAMU_GIT_HEAD_SIGNATURE="$head_signature"
            elif [[ "$head_signature" != "$_NAMU_GIT_HEAD_SIGNATURE" ]]; then
                _NAMU_GIT_HEAD_SIGNATURE="$head_signature"
                git_head_changed=1
                _NAMU_GIT_FORCE=1
                _NAMU_PR_FORCE=1
            fi
        fi
    fi

    # Git branch/dirty: async, throttled.
    local should_git=0
    if [[ "$pwd" != "$_NAMU_GIT_LAST_PWD" ]]; then
        should_git=1
    elif (( _NAMU_GIT_FORCE )); then
        should_git=1
    elif (( now - _NAMU_GIT_LAST_RUN >= 3 )); then
        should_git=1
    fi

    # Reap stale git job.
    if [[ -n "$_NAMU_GIT_JOB_PID" ]]; then
        if ! kill -0 "$_NAMU_GIT_JOB_PID" 2>/dev/null; then
            _NAMU_GIT_JOB_PID=""
            _NAMU_GIT_JOB_STARTED_AT=0
        elif (( _NAMU_GIT_JOB_STARTED_AT > 0 )) && (( now - _NAMU_GIT_JOB_STARTED_AT >= _NAMU_ASYNC_JOB_TIMEOUT )); then
            _NAMU_GIT_JOB_PID=""
            _NAMU_GIT_JOB_STARTED_AT=0
            _NAMU_GIT_FORCE=1
        fi
    fi

    if (( should_git )); then
        local can_launch_git=1
        if [[ -n "$_NAMU_GIT_JOB_PID" ]] && kill -0 "$_NAMU_GIT_JOB_PID" 2>/dev/null; then
            if [[ "$pwd" != "$_NAMU_GIT_LAST_PWD" ]] || (( _NAMU_GIT_FORCE )); then
                kill "$_NAMU_GIT_JOB_PID" >/dev/null 2>&1 || true
                _NAMU_GIT_JOB_PID=""
                _NAMU_GIT_JOB_STARTED_AT=0
            else
                can_launch_git=0
            fi
        fi
        if (( can_launch_git )); then
            _NAMU_GIT_FORCE=0
            _NAMU_GIT_LAST_PWD="$pwd"
            _NAMU_GIT_LAST_RUN=$now
            {
                _namu_report_git_branch_for_path "$pwd"
            } >/dev/null 2>&1 &!
            _NAMU_GIT_JOB_PID=$!
            _NAMU_GIT_JOB_STARTED_AT=$now
        fi
    fi

    # PR poll loop.
    local should_restart_pr_poll=0
    local pr_context_changed=0
    if [[ -n "$_NAMU_PR_POLL_PWD" && "$pwd" != "$_NAMU_PR_POLL_PWD" ]]; then
        pr_context_changed=1
    elif (( git_head_changed )); then
        pr_context_changed=1
    fi
    if [[ "$pwd" != "$_NAMU_PR_POLL_PWD" ]]; then
        should_restart_pr_poll=1
    elif (( _NAMU_PR_FORCE )); then
        should_restart_pr_poll=1
    elif [[ -z "$_NAMU_PR_POLL_PID" ]] || ! kill -0 "$_NAMU_PR_POLL_PID" 2>/dev/null; then
        should_restart_pr_poll=1
    fi

    if (( should_restart_pr_poll )); then
        _NAMU_PR_FORCE=0
        if (( pr_context_changed )); then
            [[ -S "${NAMU_SOCKET:-}" && -n "${NAMU_WORKSPACE_ID:-}" && -n "${NAMU_SURFACE_ID:-}" ]] \
                && _namu_send "clear_pr --workspace=$NAMU_WORKSPACE_ID --surface=$NAMU_SURFACE_ID" || true
        fi
        _namu_start_pr_poll_loop "$pwd" 1
    fi

    # A marker: prompt start.
    _namu_mark "A"
}

# preexec runs after the user presses Enter, before the command runs.
_namu_preexec() {
    local cmd="$1"

    # Record high-resolution start time for duration calculation.
    _NAMU_CMD_START=$EPOCHREALTIME

    # Report the command text.
    _namu_prop "last_command" "$cmd"

    # Report running state with command text and start timestamp.
    _namu_report_activity "running" "$cmd"
    # C marker: command execution start, with command text.
    _namu_mark "C;${cmd}"

    # Set terminal title to the running command.
    printf '\e]0;%s\e\\' "${cmd%% *}"

    # Heuristic: commands that may change git branch/dirty state.
    case "${cmd## }" in
        git\ checkout\ *|git\ switch\ *|git\ merge\ *|git\ rebase\ *|git\ pull\ *|\
        gh\ pr\ checkout\ *|git\ reset\ *|git\ stash\ *|\
        git\ *|gh\ *|lazygit|lazygit\ *|tig|tig\ *)
            _NAMU_GIT_FORCE=1
            _NAMU_PR_FORCE=1
            ;;
    esac

    _namu_stop_pr_poll_loop
    _namu_start_git_head_watch
}

# zle line-init runs when the prompt is drawn and the user can type.
_namu_zle_line_init() {
    # B marker: command input start.
    _namu_mark "B"
}

# ── Hook registration ─────────────────────────────────────────────────────────

autoload -Uz add-zsh-hook

add-zsh-hook precmd  _namu_precmd
add-zsh-hook preexec _namu_preexec
add-zsh-hook zshexit _namu_zshexit

# Register zle widget for B marker (command input start).
if [[ -n "$ZLE_RPROMPT_INDENT" ]] || zle -l &>/dev/null; then
    zle -N _namu_zle_line_init
    if [[ "$(bindkey '^[' 2>/dev/null)" != *"_namu"* ]]; then
        if zle -l zle-line-init &>/dev/null; then
            zle -N _namu_orig_zle_line_init
            function zle-line-init() {
                _namu_zle_line_init
                _namu_orig_zle_line_init 2>/dev/null || true
            }
            zle -N zle-line-init
        else
            function zle-line-init() { _namu_zle_line_init; }
            zle -N zle-line-init
        fi
    fi
fi

# ── PATH: prepend Resources/bin so the claude wrapper takes priority ──────────

_namu_fix_path() {
    if [[ -n "${GHOSTTY_BIN_DIR:-}" ]]; then
        local gui_dir="${GHOSTTY_BIN_DIR%/}"
        local bin_dir="${gui_dir%/MacOS}/Resources/bin"
        if [[ -d "$bin_dir" ]]; then
            local -a parts=("${(@s/:/)PATH}")
            parts=("${(@)parts:#$bin_dir}")
            parts=("${(@)parts:#$gui_dir}")
            PATH="${bin_dir}:${(j/:/)parts}"
        fi
    fi
    add-zsh-hook -d precmd _namu_fix_path
}

add-zsh-hook precmd _namu_fix_path

# ── Initial state ─────────────────────────────────────────────────────────────

# Report TTY once on load.
_namu_prop "tty" "$(tty 2>/dev/null || echo '')"

# Emit initial pwd/branch so Namu has context immediately.
_namu_report_pwd
_namu_report_git_branch
_namu_mark "A"
