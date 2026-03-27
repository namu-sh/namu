# vim:ft=zsh
#
# Fallback shim: Namu restores ZDOTDIR in .zshenv so this file should
# rarely be reached. If it is, restore ZDOTDIR and source the user's .zshrc.

if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${NAMU_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$NAMU_ZSH_ZDOTDIR"
    builtin unset NAMU_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

builtin typeset _namu_file="${ZDOTDIR-$HOME}/.zshrc"
[[ ! -r "$_namu_file" ]] || builtin source -- "$_namu_file"
builtin unset _namu_file
