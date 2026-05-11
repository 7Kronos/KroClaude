#!/bin/bash
# KroClaude — Container Entrypoint
# First-boot config seeding (sentinel-guarded) → handoff to s6-overlay (PID 1).
# Per FR-014: no PUID/PGID remap, no ~/.claude.json copy loop, no per-CLI
# symlink dance for excluded CLIs, no variant-aware fork.
#
# Authoritative refs:
#   - specs/001-claude-shell-base/research.md (R4, R7, R11)
#   - specs/001-claude-shell-base/contracts/volumes.md
set -euo pipefail

CLAUDE_HOME=/home/claude
CONFIG_DIR="$CLAUDE_HOME/.claude"
# Image-time root for bundled config (feature 005-config-bundling).
# Contains settings.json + CLAUDE.md (first-boot seed) plus the seven
# customization-type subdirectories (skills, commands, agents,
# output-styles, hooks.d, mcp-servers.d, plugins) that get reflected
# into ~/.claude/<type>/ on every boot via the helpers defined below.
SOURCE_DIR=/usr/local/share/kroclaude/config
SENTINEL="$CONFIG_DIR/.kroclaude-bootstrapped"

# ---------- First-boot seeding (kroclaude-config volume) ----------
if [ ! -f "$SENTINEL" ]; then
    install -d -o claude -g claude "$CONFIG_DIR"

    # First-boot-only seeds: top-level config files copied once, sentinel-gated.
    for f in settings.json CLAUDE.md claude-powerline.json; do
        cp "$SOURCE_DIR/$f" "$CONFIG_DIR/$f"
    done

    runuser -u claude -- git config --global safe.directory /workspace
    runuser -u claude -- git config --global user.name  "${GIT_USER_NAME:-KroClaude User}"
    runuser -u claude -- git config --global user.email "${GIT_USER_EMAIL:-noreply@kroclaude.local}"

    touch "$SENTINEL"
    echo "[entrypoint] First-boot seed complete."
fi

# ---------- ~/.claude.json symlink (idempotent, every boot) ----------
# Lives in the writable container layer (not in the volume), so it
# disappears on every container recreation. Without it, claude-code
# can't find its `oauthAccount` pointer and the user has to re-login.
# Re-create the symlink → volume on every boot. Seed the target file
# only if missing so user-written content is preserved.
if [ ! -L "$CLAUDE_HOME/.claude.json" ] || \
   [ "$(readlink "$CLAUDE_HOME/.claude.json" 2>/dev/null)" != "$CONFIG_DIR/.claude.json" ]; then
    ln -sfn "$CONFIG_DIR/.claude.json" "$CLAUDE_HOME/.claude.json"
fi
if [ ! -f "$CONFIG_DIR/.claude.json" ]; then
    echo '{"hasCompletedOnboarding":true,"installMethod":"native"}' > "$CONFIG_DIR/.claude.json"
fi

# ---------- Per-CLI dotdir seeding (idempotent, every boot) ----------
# Codex (~/.codex) and Gemini (~/.gemini) live in their own named
# volumes so credentials persist across redeploys. We can't gate
# seeding on $SENTINEL (which lives in kroclaude-config) because a
# user can add these volumes to an existing deployment where the
# sentinel already exists — the volumes would then start empty and
# never be seeded. Each write is "create-if-missing" so user-edited
# files are never overwritten. Source files live under
# $SOURCE_DIR/per-cli/<cli>/<file>; mirror that into ~/.<cli>/<file>.
install -d -o claude -g claude "$CLAUDE_HOME/.codex" "$CLAUDE_HOME/.gemini"
for src in "$SOURCE_DIR"/per-cli/codex/* "$SOURCE_DIR"/per-cli/gemini/*; do
    [ -f "$src" ] || continue
    cli=$(basename "$(dirname "$src")")        # codex | gemini
    fname=$(basename "$src")
    dest="$CLAUDE_HOME/.$cli/$fname"
    [ -f "$dest" ] || cp "$src" "$dest"
done

# ---------- ~/.config/gh ownership (idempotent, every boot) ----------
# Docker creates the named-volume mount target as root:root when the
# volume is empty (first boot) — gh runs as claude and can't write
# hosts.yml until we fix that. Also chown the parent ~/.config so
# other CLIs the user installs later can drop dotdirs there. Don't
# recurse into ~/.config/gh on later boots: anything inside is
# already claude-owned (gh wrote it).
install -d -o claude -g claude "$CLAUDE_HOME/.config" "$CLAUDE_HOME/.config/gh"

# ---------- ~/.vscode-server ownership (idempotent, every boot) ----------
# Same root:root-on-empty-volume issue as ~/.config/gh above. VS Code
# Remote-SSH connects as claude and writes its server install +
# extensions here; without the chown, the first connect after a wipe
# fails silently and VS Code falls back to re-downloading every time.
install -d -o claude -g claude "$CLAUDE_HOME/.vscode-server"

# ============================================================================
# Bundled customization reflection (feature 005-config-bundling)
# ----------------------------------------------------------------------------
# Reflects each per-type subdirectory of $SOURCE_DIR/<type>/ into
# ~/.claude/<type>/ on EVERY boot. Five helper functions cover three
# reflection patterns and two merge patterns:
#
#   reflect_dir       — skills, agents, plugins (dir-mode, no <ext>);
#                       commands, output-styles (file-mode, with <ext>)
#   reflect_tree      — marketplace (wholesale tree replace; the source
#                       is a self-contained tree with a top-level
#                       manifest alongside per-item children)
#   merge_fragments   — hooks.d, mcp-servers.d (directory of fragments
#                       jq-merged into a target via a matcher-aware
#                       per-event filter)
#   merge_one         — plugin-defaults.json (single-file top-level
#                       merge into a target via a jq filter)
#
# Invariants (enforced by every helper):
#   - No-op when source is missing or empty (FR-004 / generalized FR-005).
#   - Per-item failure isolation: a single bad item logs a WARN and skips;
#     other items of the same type and ALL items of other types still
#     reflect (FR-009 / SC-004). Container always boots.
#   - User-installed items under ~/.claude/<type>/ whose names do NOT
#     collide with bundled names are never enumerated, never touched
#     (generalizes feature 002 FR-003 across all seven types).
#   - All reflected files end up owned by claude:claude (UID/GID 1000).
#   - Re-runs are idempotent (byte-identical output for identical input).
#
# Contracts: specs/005-config-bundling/contracts/{reflection-helpers,merge-filters}.md
# ============================================================================

# reflect_dir <src> <dest> [<ext>]
#   - If <ext> is provided: file-mode. Iterates *.<ext> files at depth 1.
#   - If <ext> is omitted:  dir-mode.  Iterates direct subdirectories.
reflect_dir() {
    local src="$1" dest="$2" ext="${3:-}"
    [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ] || return 0
    install -d -o claude -g claude "$dest"
    local item name
    if [ -n "$ext" ]; then
        # file-mode
        while IFS= read -r item; do
            [ -f "$item" ] || continue
            name=$(basename "$item")
            [ "$name" = ".gitkeep" ] && continue
            rm -f "$dest/$name" \
                && cp "$item" "$dest/$name" \
                || { echo "[entrypoint] WARN: skipped reflecting $item" >&2; continue; }
        done < <(LC_ALL=C find "$src" -maxdepth 1 -type f -name "*.$ext" | LC_ALL=C sort)
    else
        # dir-mode
        for item in "$src"/*/; do
            [ -d "$item" ] || continue
            name=$(basename "$item")
            [ "$name" = ".gitkeep" ] && continue
            rm -rf "$dest/$name" \
                && cp -r "$item" "$dest/$name" \
                || { echo "[entrypoint] WARN: skipped reflecting $src/$name" >&2; continue; }
        done
    fi
}

# reflect_tree <src> <dest>
#   Wholesale: rm -rf <dest>; cp -r <src> <dest>. Used when the source is
#   a self-contained tree (manifest + per-item children) and per-item
#   precedence rules don't apply.
reflect_tree() {
    local src="$1" dest="$2"
    [ -d "$src" ] || return 0
    rm -rf "$dest" \
        && cp -r "$src" "$dest" \
        || echo "[entrypoint] WARN: reflect_tree $src -> $dest failed" >&2
}

# jq filters (defined as bash variables for locality with the helpers).
# Both filters consume `$fragments` — a JSON ARRAY of all bundled
# fragments in lex order. This is required (vs a single pre-folded
# bundle) because jq's `*` operator REPLACES nested arrays rather than
# concatenating them, which would let the lex-last fragment's
# `.hooks.<event>` array clobber earlier fragments' entries for
# different matchers under the same event.
#
# Precedence rules (FR-008):
#   - within bundle: lex-order, later fragment wins on key collision
#   - bundle vs target: bundled wins (matches feature 002 FR-003)
#
# See specs/005-config-bundling/contracts/merge-filters.md for proofs.
read -r -d '' MCP_MERGE_FILTER <<'JQ' || true
.mcpServers = (
  reduce ($fragments[] | (.mcpServers // {})) as $b
    ((.mcpServers // {}); . * $b)
)
JQ
read -r -d '' HOOKS_MERGE_FILTER <<'JQ' || true
def merge_hooks_event(existing; bundled):
  ((existing // []) + (bundled // []))
  | group_by(.matcher // "")
  | map(reduce .[] as $x ({}; . * $x));

.hooks = (
  (.hooks // {}) as $cur
  | (($cur | keys) + ([$fragments[] | (.hooks // {}) | keys] | flatten) | unique) as $events
  | reduce $events[] as $e
      ($cur;
       .[$e] = merge_hooks_event(
                 .[$e];
                 [$fragments[] | (.hooks // {})[$e] // []] | add
               ))
)
JQ

merge_fragments() {
    local src_dir="$1" target="$2" filter="$3" default_target_json="$4"
    [ -d "$src_dir" ] && [ -n "$(ls -A "$src_dir" 2>/dev/null)" ] || return 0
    # Append all valid fragments (in lex order) to a JSON array. Each
    # array element is the WHOLE fragment object — the merge filter
    # decides per-key how to combine them (object-merge for mcpServers,
    # event-keyed concat-then-group_by-matcher for hooks).
    local fragments_json='[]' f
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        if ! jq empty "$f" >/dev/null 2>&1; then
            echo "[entrypoint] WARN: skipping malformed fragment $f" >&2
            continue
        fi
        fragments_json=$(jq -s '.[0] + [.[1]]' <(printf '%s' "$fragments_json") "$f") \
            || { echo "[entrypoint] WARN: append failed on $f" >&2; continue; }
    done < <(LC_ALL=C find "$src_dir" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
    [ "$fragments_json" = '[]' ] && return 0
    # Ensure target file exists so jq has something to read.
    if [ ! -f "$target" ]; then
        install -d -o claude -g claude "$(dirname "$target")"
        printf '%s\n' "$default_target_json" > "$target"
    fi
    local merged
    merged=$(jq --argjson fragments "$fragments_json" "$filter" "$target") \
        || { echo "[entrypoint] WARN: jq merge into $target failed" >&2; return 0; }
    printf '%s\n' "$merged" > "$target.tmp" \
        && mv "$target.tmp" "$target" \
        || { echo "[entrypoint] WARN: write of merged $target failed" >&2; return 0; }
}

# merge_one <target> <source> <filter>
#   Merge one source JSON file into <target> using <filter>. Filter
#   receives target as . and source via --argjson source. Idempotent
#   if filter is.
merge_one() {
    local target="$1" source="$2" filter="$3"
    [ -f "$source" ] && [ -f "$target" ] || return 0
    if ! jq empty "$source" >/dev/null 2>&1; then
        echo "[entrypoint] WARN: merge_one source $source is malformed — skipping" >&2
        return 0
    fi
    local merged
    merged=$(jq --argjson source "$(cat "$source")" "$filter" "$target") \
        || { echo "[entrypoint] WARN: merge_one of $source into $target failed" >&2; return 0; }
    printf '%s\n' "$merged" > "$target.tmp" \
        && mv "$target.tmp" "$target" \
        || echo "[entrypoint] WARN: write of merged $target failed" >&2
}

# ---- Per-type reflection call sites (one line each — SC-003) ----
reflect_dir     "$SOURCE_DIR/skills"        "$CONFIG_DIR/skills"
reflect_dir     "$SOURCE_DIR/agents"        "$CONFIG_DIR/agents"
reflect_dir     "$SOURCE_DIR/plugins"       "$CONFIG_DIR/plugins"
reflect_dir     "$SOURCE_DIR/commands"      "$CONFIG_DIR/commands"      md
reflect_dir     "$SOURCE_DIR/output-styles" "$CONFIG_DIR/output-styles" md
merge_fragments "$SOURCE_DIR/hooks.d"       "$CONFIG_DIR/settings.json" "$HOOKS_MERGE_FILTER" '{}'
merge_fragments "$SOURCE_DIR/mcp-servers.d" "$CONFIG_DIR/.mcp.json"     "$MCP_MERGE_FILTER"   '{"mcpServers":{}}'

# ----------------------------------------------------------------------------
# Plugin marketplace activation (feature 005 follow-up)
# ----------------------------------------------------------------------------
# Bundling plugin trees on disk is necessary but not sufficient — Claude
# Code only activates plugins that are (a) registered through a known
# marketplace and (b) listed in `enabledPlugins`. Three steps:
#
#   1. Reflect the entire $SOURCE_DIR/marketplace/ tree wholesale into
#      ~/.claude/kroclaude-marketplace/ (NOT ~/.claude/plugins/, which
#      Claude Code manages itself).
#   2. Merge $SOURCE_DIR/plugin-defaults.json into ~/.claude/settings.json
#      on every boot. This is the bundle's hook for top-level keys
#      (extraKnownMarketplaces, enabledPlugins) that aren't covered by
#      hooks.d/ or mcp-servers.d/. Bundle wins on collision.
#   3. Clean up orphan plugin directories left under ~/.claude/plugins/
#      by an earlier (pre-marketplace) bundle layout. Only the four
#      previously-bundled names are touched — anything else under that
#      directory is Claude Code's own state and is left alone.
reflect_tree "$SOURCE_DIR/marketplace"        "$CONFIG_DIR/kroclaude-marketplace"
merge_one    "$CONFIG_DIR/settings.json"      "$SOURCE_DIR/plugin-defaults.json" '. * $source'

# Orphan cleanup: any name listed in the bundled marketplace manifest that
# previously lived under ~/.claude/plugins/ (pre-PR #5 layout) gets removed.
# Driven from marketplace.json so adding/removing a plugin needs only one
# edit (the manifest), not two. Anything else under ~/.claude/plugins/ is
# Claude Code's own state or a user install — never touched.
if [ -f "$SOURCE_DIR/marketplace/.claude-plugin/marketplace.json" ]; then
    while IFS= read -r orphan; do
        [ -n "$orphan" ] && [ -d "$CONFIG_DIR/plugins/$orphan" ] \
            && rm -rf "$CONFIG_DIR/plugins/$orphan"
    done < <(jq -r '.plugins[].name // empty' \
        "$SOURCE_DIR/marketplace/.claude-plugin/marketplace.json" 2>/dev/null)
fi

# Runtime manifest backstop: scripts/fetch-plugins.sh exits non-zero at
# build time if any plugin listed in marketplace.json is missing on disk,
# so a healthy image never trips this loop. Log a WARN per missing plugin
# anyway — any future bypass (manual COPY override, sideloaded bundle,
# regression) becomes visible in `docker logs` instead of surfacing as a
# cryptic per-plugin error inside Claude Code. WARN only, never abort
# (FR-009: container always boots).
RUNTIME_MANIFEST="$CONFIG_DIR/kroclaude-marketplace/.claude-plugin/marketplace.json"
if [ -f "$RUNTIME_MANIFEST" ]; then
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ ! -d "$CONFIG_DIR/kroclaude-marketplace/$name" ]; then
            echo "[entrypoint] WARN: bundled marketplace lists plugin '$name' but $CONFIG_DIR/kroclaude-marketplace/$name does not exist — Claude Code will fail to load it" >&2
        fi
    done < <(jq -r '.plugins[].name // empty' "$RUNTIME_MANIFEST" 2>/dev/null)
fi

# ---------- SSH host keys + authorized_keys seeding (feature 003-ssh-access) ----------
# Host keys are generated ONCE (FR-009 fingerprint stability) inside the
# kroclaude-config volume so they survive container recreation.
# authorized_keys is reseeded from KROCLAUDE_SSH_AUTHORIZED_KEY on EVERY
# boot (FR-007 — latest env wins; NOT sentinel-guarded).
SSH_HOST_KEY_DIR="$CONFIG_DIR/.ssh-host-keys"
install -d -m 0700 -o claude -g claude "$SSH_HOST_KEY_DIR"
for spec in "ed25519" "rsa -b 3072"; do
    name=ssh_host_${spec%% *}_key
    if [ ! -f "$SSH_HOST_KEY_DIR/$name" ]; then
        ssh-keygen -t $spec -N '' -f "$SSH_HOST_KEY_DIR/$name" >/dev/null
        chmod 0600 "$SSH_HOST_KEY_DIR/$name"
        chmod 0644 "$SSH_HOST_KEY_DIR/$name.pub"
    fi
done

install -d -m 0700 -o claude -g claude "$CLAUDE_HOME/.ssh"
printf '%s\n' "${KROCLAUDE_SSH_AUTHORIZED_KEY:-}" > "$CLAUDE_HOME/.ssh/authorized_keys"
chmod 0600 "$CLAUDE_HOME/.ssh/authorized_keys"

# ---------- Final ownership sweep (idempotent, every boot) ----------
# Single point of truth: every path under $CLAUDE_HOME is claude-owned
# by the time s6 takes over. /workspace is intentionally NOT swept —
# it's never written-to during docker build, the WORKDIR is chowned
# in the Dockerfile, and Docker's named-volume mount inherits
# ownership from the (claude-owned) target on first boot.
chown -R claude:claude "$CLAUDE_HOME"

export DISPLAY=:99

exec /init "$@"
