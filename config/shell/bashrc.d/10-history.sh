# Bash history persistence (feature 001 research R9): keep history on
# the persistent volume via ~/.claude. Guarded on the directory so
# shells for users without a ~/.claude (e.g. root) keep bash defaults.
if [ -d "$HOME/.claude" ]; then
    export HISTFILE="$HOME/.claude/.bash_history"
fi
export HISTSIZE=10000
export HISTFILESIZE=20000
