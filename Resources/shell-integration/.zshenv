# vim:ft=zsh
#
# Namu ZDOTDIR bootstrap for zsh.
#
# Namu sets ZDOTDIR to this directory so that shell integration is loaded
# automatically. We restore the user's real ZDOTDIR immediately so that
# zsh loads the user's real .zprofile/.zshrc normally.

if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${NAMU_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$NAMU_ZSH_ZDOTDIR"
    builtin unset NAMU_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

{
    builtin typeset _namu_file="${ZDOTDIR-$HOME}/.zshenv"
    [[ ! -r "$_namu_file" ]] || builtin source -- "$_namu_file"
} always {
    if [[ -o interactive ]]; then
        # Load Ghostty's zsh integration if available.
        if [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
            builtin typeset _namu_ghostty="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
            [[ -r "$_namu_ghostty" ]] && builtin source -- "$_namu_ghostty"
        fi

        # Load Namu integration.
        if [[ -n "${NAMU_SHELL_INTEGRATION_DIR:-}" ]]; then
            builtin typeset _namu_integ="$NAMU_SHELL_INTEGRATION_DIR/namu.zsh"
            [[ -r "$_namu_integ" ]] && builtin source -- "$_namu_integ"
        fi
    fi

    builtin unset _namu_file _namu_ghostty _namu_integ
}
