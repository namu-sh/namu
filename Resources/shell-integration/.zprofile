# vim:ft=zsh
if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${NAMU_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$NAMU_ZSH_ZDOTDIR"
    builtin unset NAMU_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

builtin typeset _namu_file="${ZDOTDIR-$HOME}/.zprofile"
[[ ! -r "$_namu_file" ]] || builtin source -- "$_namu_file"
builtin unset _namu_file
