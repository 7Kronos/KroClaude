# Shell ergonomics (cherry-picked from dotfiles/home.nix).
# Wires starship prompt, zoxide smart-cd, direnv auto-load, eza ls
# aliases, and fzf key bindings + completion + bat/fd integration.
# Each integration is command-guarded so a missing tool downgrades
# cleanly instead of breaking login.
export EDITOR=nano

command -v starship >/dev/null && eval "$(starship init bash)"
command -v zoxide   >/dev/null && eval "$(zoxide init bash)"
command -v direnv   >/dev/null && eval "$(direnv hook bash)"

if command -v eza >/dev/null; then
    alias ls='eza --icons=auto'
    alias ll='eza --icons=auto -l'
    alias la='eza --icons=auto -la'
    alias lt='eza --icons=auto --tree'
fi

if command -v fzf >/dev/null; then
    [ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && \
        source /usr/share/doc/fzf/examples/key-bindings.bash
    [ -f /usr/share/doc/fzf/examples/completion.bash ] && \
        source /usr/share/doc/fzf/examples/completion.bash
    export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
    export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_CTRL_T_OPTS="--preview 'bat --style=numbers --color=always --line-range :500 {}'"
    export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
fi
