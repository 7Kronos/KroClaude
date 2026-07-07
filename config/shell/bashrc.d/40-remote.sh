# `remote` — claude remote-control launcher.
# Spins up a Remote Control server in $PWD (controllable from
# claude.ai/code), spawns one isolated git worktree per on-demand session,
# prefixes session names with $(basename $PWD), runs sessions with
# permissions bypassed, and pre-flags $PWD as trusted in ~/.claude.json so
# the workspace-trust dialog never blocks bootstrap. The jq edit writes
# through `cat >` (not mv) so it works whether ~/.claude.json is a plain
# file or a symlink.
remote() {
    local prefix
    prefix=$(basename "$PWD")

    if command -v jq >/dev/null 2>&1 && [ -e "$HOME/.claude.json" ]; then
        local tmp
        if tmp=$(mktemp) && jq --arg p "$PWD" \
                '.projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})' \
                "$HOME/.claude.json" > "$tmp"; then
            cat "$tmp" > "$HOME/.claude.json"
        fi
        [ -n "${tmp:-}" ] && rm -f "$tmp"
    fi

    claude remote-control \
        --spawn worktree \
        --remote-control-session-name-prefix "$prefix" \
        --permission-mode bypassPermissions \
        "$@"
}
