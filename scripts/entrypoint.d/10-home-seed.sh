#!/bin/bash
# Stage 10 — persistent-home seeding.
#   - first-boot, sentinel-gated seed of settings.json / CLAUDE.md /
#     claude-powerline.json (feature 001 contract)
#   - ~/.claude.json create-if-missing (claude-code oauthAccount pointer)
#   - per-CLI config seeds for codex / gemini / starship (create-if-missing)
#   - one-time adoption of pre-home-volume dotdir layouts
set -euo pipefail
. /etc/kroclaude/entrypoint-lib.sh

# ---------- First-boot seeding (sentinel-gated) ----------
if [ ! -f "$SENTINEL" ]; then
    install -d -o claude -g claude "$CONFIG_DIR"
    for f in settings.json CLAUDE.md claude-powerline.json; do
        cp "$SOURCE_DIR/$f" "$CONFIG_DIR/$f"
    done
    touch "$SENTINEL"
    echo "[entrypoint] First-boot seed complete."
fi

# ---------- ~/.claude.json (create-if-missing, every boot) ----------
# A plain file on the persistent home volume. Migration: pre-home-volume
# releases kept the real file at ~/.claude/.claude.json behind a
# symlink; adopt that file if it's present and the plain file isn't.
[ -L "$CLAUDE_HOME/.claude.json" ] && rm -f "$CLAUDE_HOME/.claude.json"
if [ ! -f "$CLAUDE_HOME/.claude.json" ]; then
    if [ -f "$CONFIG_DIR/.claude.json" ]; then
        mv "$CONFIG_DIR/.claude.json" "$CLAUDE_HOME/.claude.json"
    else
        echo '{"hasCompletedOnboarding":true}' > "$CLAUDE_HOME/.claude.json"
    fi
fi

# ---------- OMC shared-state marker on /workspace (every boot) ----------
# Replaces the former omc-init busybox one-shot compose service; same
# semantics (create-if-empty, mode 0644, root-owned).
if [ -d /workspace ]; then
    [ -s /workspace/.omc-workspace ] || echo '{}' > /workspace/.omc-workspace
    chmod 0644 /workspace/.omc-workspace
fi

# ---------- Per-CLI dotdir seeding (create-if-missing, every boot) ----------
# Not sentinel-gated: a user can wipe ~/.codex without wiping ~/.claude,
# and the seed must come back. Each write is create-if-missing so
# user-edited files are never overwritten. Source files live under
# $SOURCE_DIR/per-cli/<cli>/<file>; mirrored into ~/.<cli>/<file>.
install -d -o claude -g claude "$CLAUDE_HOME/.codex" "$CLAUDE_HOME/.gemini" \
    "$CLAUDE_HOME/.agents/skills"
for src in "$SOURCE_DIR"/per-cli/codex/* "$SOURCE_DIR"/per-cli/gemini/*; do
    [ -f "$src" ] || continue
    cli=$(basename "$(dirname "$src")")        # codex | gemini
    fname=$(basename "$src")
    dest="$CLAUDE_HOME/.$cli/$fname"
    [ -f "$dest" ] || cp "$src" "$dest"
done

# Starship config lives at ~/.config/starship.toml (XDG path), not
# ~/.starship/, so the loop above doesn't fit. Same create-if-missing
# semantics.
install -d -o claude -g claude "$CLAUDE_HOME/.config"
if [ -f "$SOURCE_DIR/per-cli/starship/starship.toml" ] && \
   [ ! -f "$CLAUDE_HOME/.config/starship.toml" ]; then
    install -m 0644 -o claude -g claude \
        "$SOURCE_DIR/per-cli/starship/starship.toml" \
        "$CLAUDE_HOME/.config/starship.toml"
fi

# ---------- Pre-home-volume dotdir adoption (idempotent, every boot) ----------
# /home/claude is one persistent volume now, so every CLI's dotdir
# persists at its natural location with no symlinks or env redirects.
# Releases before this refactor parked dotdirs under ~/.claude/<name>
# (persist_dotdir symlinks: kube/supabase/docker/nats) or redirected
# them via HELM_*_HOME / K9S_CONFIG_DIR env vars. If such a directory
# is found and the natural location is still empty, move it into place
# once. No-op on fresh volumes and on every boot after adoption.
migrate_dotdir() {
    local src="$CONFIG_DIR/$1" dest="$2"
    [ -d "$src" ] || return 0
    [ -L "$dest" ] && rm -f "$dest"
    [ -e "$dest" ] && return 0
    install -d -o claude -g claude "$(dirname "$dest")"
    mv "$src" "$dest"
    chown -R claude:claude "$dest"
}

migrate_dotdir kube        "$CLAUDE_HOME/.kube"                # kubectl
migrate_dotdir supabase    "$CLAUDE_HOME/.supabase"            # supabase login token
migrate_dotdir docker      "$CLAUDE_HOME/.docker"              # docker login auth
migrate_dotdir nats        "$CLAUDE_HOME/.config/nats"         # nats contexts (auth)
migrate_dotdir helm-config "$CLAUDE_HOME/.config/helm"         # ex-HELM_CONFIG_HOME
migrate_dotdir helm-data   "$CLAUDE_HOME/.local/share/helm"    # ex-HELM_DATA_HOME
migrate_dotdir helm-cache  "$CLAUDE_HOME/.cache/helm"          # ex-HELM_CACHE_HOME
migrate_dotdir k9s         "$CLAUDE_HOME/.config/k9s"          # ex-K9S_CONFIG_DIR
