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

    cp "$SOURCE_DIR/settings.json" "$CONFIG_DIR/settings.json"
    cp "$SOURCE_DIR/CLAUDE.md"     "$CONFIG_DIR/CLAUDE.md"

    runuser -u claude -- git config --global safe.directory /workspace
    runuser -u claude -- git config --global user.name  "${GIT_USER_NAME:-KroClaude User}"
    runuser -u claude -- git config --global user.email "${GIT_USER_EMAIL:-noreply@kroclaude.local}"

    chown -R claude:claude "$CONFIG_DIR"
    touch "$SENTINEL"
    chown claude:claude "$SENTINEL"
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
    chown -h claude:claude "$CLAUDE_HOME/.claude.json"
fi
if [ ! -f "$CONFIG_DIR/.claude.json" ]; then
    echo '{"hasCompletedOnboarding":true,"installMethod":"native"}' > "$CONFIG_DIR/.claude.json"
    chown claude:claude "$CONFIG_DIR/.claude.json"
fi

# ---------- Per-CLI dotdir seeding (idempotent, every boot) ----------
# Codex (~/.codex) and Gemini (~/.gemini) live in their own named
# volumes so credentials persist across redeploys. We can't gate
# seeding on $SENTINEL (which lives in kroclaude-config) because a
# user can add these volumes to an existing deployment where the
# sentinel already exists — the volumes would then start empty and
# never be seeded. Each write is "create-if-missing" so user-edited
# files are never overwritten.
install -d -o claude -g claude "$CLAUDE_HOME/.codex" "$CLAUDE_HOME/.gemini"

if [ ! -f "$CLAUDE_HOME/.codex/config.toml" ]; then
    cat > "$CLAUDE_HOME/.codex/config.toml" <<'TOML'
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[features]
codex_hooks = true
TOML
fi

if [ ! -f "$CLAUDE_HOME/.codex/hooks.json" ]; then
    cat > "$CLAUDE_HOME/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/bin/notify.py stop",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
JSON
fi

if [ ! -f "$CLAUDE_HOME/.gemini/settings.json" ]; then
    cat > "$CLAUDE_HOME/.gemini/settings.json" <<'JSON'
{
  "hooks": {
    "SessionEnd": [
      {
        "matcher": "*",
        "hooks": [
          {
            "name": "notify",
            "type": "command",
            "command": "/usr/local/bin/notify.py stop",
            "timeout": 30000
          }
        ]
      }
    ]
  }
}
JSON
fi

chown -R claude:claude "$CLAUDE_HOME/.codex" "$CLAUDE_HOME/.gemini"

# ---------- ~/.config/gh ownership (idempotent, every boot) ----------
# Docker creates the named-volume mount target as root:root when the
# volume is empty (first boot) — gh runs as claude and can't write
# hosts.yml until we fix that. Also chown the parent ~/.config so
# other CLIs the user installs later can drop dotdirs there. Don't
# recurse into ~/.config/gh on later boots: anything inside is
# already claude-owned (gh wrote it).
install -d "$CLAUDE_HOME/.config" "$CLAUDE_HOME/.config/gh"
chown claude:claude "$CLAUDE_HOME/.config" "$CLAUDE_HOME/.config/gh"

# ---------- ~/.vscode-server ownership (idempotent, every boot) ----------
# Same root:root-on-empty-volume issue as ~/.config/gh above. VS Code
# Remote-SSH connects as claude and writes its server install +
# extensions here; without the chown, the first connect after a wipe
# fails silently and VS Code falls back to re-downloading every time.
install -d "$CLAUDE_HOME/.vscode-server"
chown claude:claude "$CLAUDE_HOME/.vscode-server"

# ============================================================================
# Bundled customization reflection (feature 005-config-bundling)
# ----------------------------------------------------------------------------
# Reflects each per-type subdirectory of $SOURCE_DIR/<type>/ into
# ~/.claude/<type>/ on EVERY boot. Three helper functions cover the three
# reflection patterns:
#
#   reflect_dir_of_dirs   — skills, agents, plugins (per-item is a directory)
#   reflect_dir_of_files  — commands, output-styles (per-item is a file)
#   merge_fragments       — hooks.d, mcp-servers.d (jq-merged into a target)
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

reflect_dir_of_dirs() {
    local src="$1" dest="$2"
    [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ] || return 0
    install -d -o claude -g claude "$dest"
    local item name
    for item in "$src"/*/; do
        [ -d "$item" ] || continue
        name=$(basename "$item")
        # .gitkeep guard: skip the placeholder file masquerading as dir
        [ "$name" = ".gitkeep" ] && continue
        rm -rf "$dest/$name" \
            && cp -r "$item" "$dest/$name" \
            && chown -R claude:claude "$dest/$name" \
            || { echo "[entrypoint] WARN: skipped reflecting $src/$name" >&2; continue; }
    done
}

reflect_dir_of_files() {
    local src="$1" dest="$2" ext="$3"
    [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ] || return 0
    install -d -o claude -g claude "$dest"
    local file name
    while IFS= read -r file; do
        [ -f "$file" ] || continue
        name=$(basename "$file")
        rm -f "$dest/$name" \
            && cp "$file" "$dest/$name" \
            && chown claude:claude "$dest/$name" \
            || { echo "[entrypoint] WARN: skipped reflecting $file" >&2; continue; }
    done < <(LC_ALL=C find "$src" -maxdepth 1 -type f -name "*.$ext" | LC_ALL=C sort)
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
    local src_dir="$1" target="$2" filter_var="$3" default_target_json="$4"
    [ -d "$src_dir" ] && [ -n "$(ls -A "$src_dir" 2>/dev/null)" ] || return 0
    local filter="${!filter_var}"
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
        chown claude:claude "$target"
    fi
    local merged
    merged=$(jq --argjson fragments "$fragments_json" "$filter" "$target") \
        || { echo "[entrypoint] WARN: jq merge into $target failed" >&2; return 0; }
    printf '%s\n' "$merged" > "$target.tmp" \
        && mv "$target.tmp" "$target" \
        && chown claude:claude "$target" \
        || { echo "[entrypoint] WARN: write of merged $target failed" >&2; return 0; }
}

# ---- Per-type reflection call sites (one line each — SC-003) ----
reflect_dir_of_dirs  "$SOURCE_DIR/skills"        "$CONFIG_DIR/skills"
reflect_dir_of_dirs  "$SOURCE_DIR/agents"        "$CONFIG_DIR/agents"
reflect_dir_of_dirs  "$SOURCE_DIR/plugins"       "$CONFIG_DIR/plugins"
reflect_dir_of_files "$SOURCE_DIR/commands"      "$CONFIG_DIR/commands"      md
reflect_dir_of_files "$SOURCE_DIR/output-styles" "$CONFIG_DIR/output-styles" md
merge_fragments      "$SOURCE_DIR/hooks.d"        "$CONFIG_DIR/settings.json" HOOKS_MERGE_FILTER '{}'
merge_fragments      "$SOURCE_DIR/mcp-servers.d"  "$CONFIG_DIR/.mcp.json"     MCP_MERGE_FILTER   '{"mcpServers":{}}'

# ---------- SSH host keys + authorized_keys seeding (feature 003-ssh-access) ----------
# Host keys are generated ONCE (FR-009 fingerprint stability) inside the
# kroclaude-config volume so they survive container recreation.
# authorized_keys is reseeded from KROCLAUDE_SSH_AUTHORIZED_KEY on EVERY
# boot (FR-007 — latest env wins; NOT sentinel-guarded).
SSH_HOST_KEY_DIR="$CONFIG_DIR/.ssh-host-keys"
install -d -m 0700 -o claude -g claude "$SSH_HOST_KEY_DIR"
if [ ! -f "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key" ]; then
    ssh-keygen -t ed25519 -N '' -f "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key" >/dev/null
    chown claude:claude "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key" "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key.pub"
    chmod 0600 "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key"
    chmod 0644 "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key.pub"
fi
if [ ! -f "$SSH_HOST_KEY_DIR/ssh_host_rsa_key" ]; then
    ssh-keygen -t rsa -b 3072 -N '' -f "$SSH_HOST_KEY_DIR/ssh_host_rsa_key" >/dev/null
    chown claude:claude "$SSH_HOST_KEY_DIR/ssh_host_rsa_key" "$SSH_HOST_KEY_DIR/ssh_host_rsa_key.pub"
    chmod 0600 "$SSH_HOST_KEY_DIR/ssh_host_rsa_key"
    chmod 0644 "$SSH_HOST_KEY_DIR/ssh_host_rsa_key.pub"
fi

install -d -m 0700 -o claude -g claude "$CLAUDE_HOME/.ssh"
printf '%s\n' "${KROCLAUDE_SSH_AUTHORIZED_KEY:-}" > "$CLAUDE_HOME/.ssh/authorized_keys"
chmod 0600 "$CLAUDE_HOME/.ssh/authorized_keys"
chown claude:claude "$CLAUDE_HOME/.ssh/authorized_keys"

export DISPLAY=:99

exec /init "$@"
