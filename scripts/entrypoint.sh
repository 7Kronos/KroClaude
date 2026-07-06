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

    touch "$SENTINEL"
    echo "[entrypoint] First-boot seed complete."
fi

# ---------- ~/.claude.json (create-if-missing, every boot) ----------
# A plain file on the persistent home volume — this is where claude-code
# keeps its `oauthAccount` pointer. Migration: pre-home-volume releases
# kept the real file at ~/.claude/.claude.json behind a symlink; adopt
# that file if it's present and the plain file isn't.
[ -L "$CLAUDE_HOME/.claude.json" ] && rm -f "$CLAUDE_HOME/.claude.json"
if [ ! -f "$CLAUDE_HOME/.claude.json" ]; then
    if [ -f "$CONFIG_DIR/.claude.json" ]; then
        mv "$CONFIG_DIR/.claude.json" "$CLAUDE_HOME/.claude.json"
    else
        echo '{"hasCompletedOnboarding":true,"installMethod":"native"}' > "$CLAUDE_HOME/.claude.json"
    fi
fi

# ---------- git identity (idempotent, every boot) ----------
# ~/.gitconfig is a plain file on the persistent home volume, so
# identity and manual `git config` edits survive redeploys without the
# old symlink-into-~/.claude dance. Migration: adopt a pre-home-volume
# ~/.claude/.gitconfig if present.
[ -L "$CLAUDE_HOME/.gitconfig" ] && rm -f "$CLAUDE_HOME/.gitconfig"
if [ ! -f "$CLAUDE_HOME/.gitconfig" ] && [ -f "$CONFIG_DIR/.gitconfig" ]; then
    mv "$CONFIG_DIR/.gitconfig" "$CLAUDE_HOME/.gitconfig"
    chown claude:claude "$CLAUDE_HOME/.gitconfig"
fi
# Precedence: GIT_USER_* env wins when set (latest deploy wins); else keep
# an existing persisted value; else seed a default.
runuser -u claude -- git config --global --get-all safe.directory 2>/dev/null | grep -qxF /workspace \
    || runuser -u claude -- git config --global --add safe.directory /workspace
if [ -n "${GIT_USER_NAME:-}" ]; then
    runuser -u claude -- git config --global user.name "$GIT_USER_NAME"
elif [ -z "$(runuser -u claude -- git config --global user.name 2>/dev/null)" ]; then
    runuser -u claude -- git config --global user.name "KroClaude User"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    runuser -u claude -- git config --global user.email "$GIT_USER_EMAIL"
elif [ -z "$(runuser -u claude -- git config --global user.email 2>/dev/null)" ]; then
    runuser -u claude -- git config --global user.email "noreply@kroclaude.local"
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

# Starship config lives at ~/.config/starship.toml (XDG path), not
# ~/.starship/, so the codex/gemini loop above doesn't fit. Seed it
# directly with the same create-if-missing semantics.
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

# ============================================================================
# Bundled customization reflection (feature 005-config-bundling)
# ----------------------------------------------------------------------------
# Reflects each per-type subdirectory of $SOURCE_DIR/<type>/ into
# ~/.claude/<type>/ on EVERY boot. Two helpers cover the patterns:
#
#   reflect_dir       — skills, agents, plugins (dir-mode, no <ext>);
#                       commands, output-styles (file-mode, with <ext>)
#   merge_fragments   — hooks.d, mcp-servers.d (directory of fragments
#                       jq-merged into a target via a matcher-aware
#                       per-event filter)
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

# ---- Per-type reflection call sites (one line each — SC-003) ----
reflect_dir     "$SOURCE_DIR/skills"        "$CONFIG_DIR/skills"
reflect_dir     "$SOURCE_DIR/agents"        "$CONFIG_DIR/agents"
reflect_dir     "$SOURCE_DIR/plugins"       "$CONFIG_DIR/plugins"
reflect_dir     "$SOURCE_DIR/commands"      "$CONFIG_DIR/commands"      md
reflect_dir     "$SOURCE_DIR/output-styles" "$CONFIG_DIR/output-styles" md
merge_fragments "$SOURCE_DIR/hooks.d"       "$CONFIG_DIR/settings.json" "$HOOKS_MERGE_FILTER" '{}'
merge_fragments "$SOURCE_DIR/mcp-servers.d" "$CONFIG_DIR/.mcp.json"     "$MCP_MERGE_FILTER"   '{"mcpServers":{}}'

# ----------------------------------------------------------------------------
# Plugin marketplaces, plugins, skills, MCP servers (every boot)
# ----------------------------------------------------------------------------
# No sentinel: this whole block runs on every container start so plugins,
# marketplaces, skills, and MCP configs stay current. Each step is shaped
# for re-entry — `add` calls swallow "already exists" errors, `update`
# does the real refresh, MCPs are remove+re-add so env-var changes from
# the deployment propagate. Per-item failure is non-fatal (FR-009).

# Git/gh auth for private plugin repos (e.g. 7Kronos/call-me-pilot).
# Prefer the persisted `gh auth login` OAuth (kroclaude-gh volume) and
# only fall back to the deployment-supplied PAT — an invalid PAT must
# never shadow a working login (same precedence trap as the
# ANTHROPIC_API_KEY / `claude login` fix). The token is passed
# per-command via env GH_TOKEN, never exported globally or persisted:
# `gh auth git-credential` resolves auth at run time, so interactive
# shells keep using hosts.yml. Enables the private `marketplace add`,
# `plugin install cmpilot@call-me-pilot`, and call-me-pilot install.sh
# clone below. No token -> skipped, and those private steps then fail
# non-fatally like any other (FR-009). Public marketplaces are unaffected.
GH_BOOT_TOKEN="$(runuser -u claude -- gh auth token 2>/dev/null || true)"
[ -n "$GH_BOOT_TOKEN" ] || GH_BOOT_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
if [ -n "$GH_BOOT_TOKEN" ]; then
    runuser -u claude -- env GH_TOKEN="$GH_BOOT_TOKEN" gh auth setup-git >/dev/null 2>&1 \
        || echo "[entrypoint] WARN: gh auth setup-git failed; private plugins may not install" >&2
fi

# Marketplaces: add (no-op once present), then update all to pull latest manifests.
runuser -u claude -- claude plugin marketplace add github:anthropics/claude-plugins-official >/dev/null 2>&1 || true
runuser -u claude -- claude plugin marketplace add github:thedotmack/claude-mem >/dev/null 2>&1 || true
runuser -u claude -- claude plugin marketplace add github:Yeachan-Heo/oh-my-claudecode >/dev/null 2>&1 || true
runuser -u claude -- claude plugin marketplace add github:7Kronos/gravity >/dev/null 2>&1 || true
runuser -u claude -- claude plugin marketplace add github:7Kronos/call-me-pilot >/dev/null 2>&1 || true
runuser -u claude -- claude plugin marketplace update \
    || echo "[entrypoint] WARN: failed to update marketplaces" >&2

# Plugins: install (idempotent per `claude plugin install`) then update each.
for p in csharp-lsp@claude-plugins-official \
         commit-commands@claude-plugins-official \
         feature-dev@claude-plugins-official \
         claude-mem@claude-mem \
         oh-my-claudecode@oh-my-claudecode \
         gravity-dsl@gravity \
         cmpilot@call-me-pilot; do
    runuser -u claude -- claude plugin install "$p" >/dev/null 2>&1 \
        || echo "[entrypoint] WARN: failed to install plugin $p" >&2
    runuser -u claude -- claude plugin update "${p%@*}" >/dev/null 2>&1 || true
done

# call-me-pilot standalone CLI (private 7Kronos repo). Fetch the installer
# with an auth header — raw.githubusercontent needs it for private repos,
# unlike the git credential helper wired above — then pipe to bash. Its
# internal `git clone https://…` then authenticates via that helper, and
# `cmpilot setup` lands the CLI. timeout-guarded so a stall can't wedge
# boot; non-fatal and token-gated like the plugin steps.
if [ -n "$GH_BOOT_TOKEN" ]; then
    runuser -u claude -- env GH_TOKEN="$GH_BOOT_TOKEN" timeout 180 bash -c \
        'curl -fsSL -H "Authorization: token $GH_TOKEN" https://raw.githubusercontent.com/7Kronos/call-me-pilot/master/install.sh | bash' \
        >/dev/null 2>&1 \
        || echo "[entrypoint] WARN: call-me-pilot install.sh failed" >&2
fi

# playwright-skill is a plain skill (no CLI install path); clone or fast-forward.
if [ -d "$CONFIG_DIR/skills/playwright-skill/.git" ]; then
    runuser -u claude -- git -C "$CONFIG_DIR/skills/playwright-skill" pull --ff-only --quiet \
        || echo "[entrypoint] WARN: failed to update playwright-skill" >&2
elif [ ! -d "$CONFIG_DIR/skills/playwright-skill" ]; then
    runuser -u claude -- git clone --depth 1 \
        https://github.com/lackeyjb/playwright-skill \
        "$CONFIG_DIR/skills/playwright-skill" \
        || echo "[entrypoint] WARN: failed to clone playwright-skill" >&2
fi

# MCP servers: remove + re-add so the command line and env vars always
# reflect the current deployment (env-var swaps take effect next restart).
for name in context7 filesystem exa github; do
    runuser -u claude -- claude mcp remove "$name" >/dev/null 2>&1 || true
done

runuser -u claude -- claude mcp add --scope user context7 -- \
    npx -y @upstash/context7-mcp \
    || echo "[entrypoint] WARN: failed to add context7 MCP" >&2
runuser -u claude -- claude mcp add --scope user filesystem -- \
    npx -y @modelcontextprotocol/server-filesystem /workspace \
    || echo "[entrypoint] WARN: failed to add filesystem MCP" >&2

if [ -n "${EXA_API_KEY:-}" ]; then
    runuser -u claude -- claude mcp add --scope user -e "EXA_API_KEY=$EXA_API_KEY" exa -- \
        npx -y exa-mcp-server \
        || echo "[entrypoint] WARN: failed to add exa MCP" >&2
fi
if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
    runuser -u claude -- claude mcp add --scope user \
        -e "GITHUB_PERSONAL_ACCESS_TOKEN=$GITHUB_PERSONAL_ACCESS_TOKEN" github -- \
        docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN \
        ghcr.io/github/github-mcp-server \
        || echo "[entrypoint] WARN: failed to add github MCP" >&2
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

# ---------- /etc/environment propagation (idempotent, every boot) ----------
# sshd does NOT inherit PID 1's environment — each login session is built
# from /etc/environment (via pam_env, UsePAM yes), /etc/profile, and the
# user's shell rc files. To make compose-supplied runtime vars visible to
# SSH login shells, regenerate /etc/environment from an explicit allowlist
# on every boot. The list is a SUBSET of docker-compose.yaml `environment:`
# minus secrets — see DELIBERATELY EXCLUDED below. Empty values are
# skipped so unset vars don't show up as empty strings in the shell.
# /etc/environment is mode 0644 (world-readable) by pam_env requirement —
# acceptable in this single-user container, but do not add vars here that
# must be hidden from non-claude processes.
#
# DELIBERATELY EXCLUDED:
#   - ANTHROPIC_API_KEY: claude-code's auth precedence treats this env var
#     as overriding the persisted OAuth login (~/.claude/.credentials.json).
#     Propagating it to SSH login shells made `claude login` appear not to
#     persist across container restarts — the saved OAuth was silently
#     bypassed in favour of the API key. PID 1 still has it (compose
#     environment), so any `claude` started under s6 or via `docker exec`
#     still falls back to it when no OAuth login is persisted.
#
# All other secrets stay in this list because MCP server fragments under
# config/mcp-servers.d/ reference them as ${VAR} placeholders that
# claude-code expands from the shell env at MCP-spawn time — login shells
# need them present to bring the MCP servers up.
{
    printf 'PATH="/home/claude/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n'
    printf 'DOCKER_HOST="tcp://localhost:2375"\n'
    for var in TZ GIT_USER_NAME GIT_USER_EMAIL \
               NODE_OPTIONS NOTIFY_URLS \
               EXA_API_KEY GITHUB_PERSONAL_ACCESS_TOKEN \
               COOLIFY_ACCESS_TOKEN COOLIFY_BASE_URL \
               NUGET_REGISTRY_USER NUGET_REGISTRY_TOKEN; do
        val="${!var:-}"
        [ -n "$val" ] || continue
        printf '%s="%s"\n' "$var" "${val//\"/\\\"}"
    done
    # GH_TOKEN is deliberately NOT mirrored here: gh gives an env token
    # precedence over the persisted `gh auth login` in hosts.yml, so a
    # stale PAT would shadow a working login in every SSH shell (same
    # trap as ANTHROPIC_API_KEY above). Interactive private git/gh ops
    # authenticate via the persisted login + gh credential helper.
} > /etc/environment
chmod 0644 /etc/environment

# ---------- Ownership sweep (idempotent, every boot) ----------
# Everything this script wrote as root becomes claude-owned before s6
# takes over. Scoped to the paths the entrypoint actually touches — a
# recursive chown of the entire home volume (which now includes
# ~/.vscode-server and other large trees) would slow every boot.
# /workspace is intentionally NOT swept — it's never written-to during
# docker build, the WORKDIR is chowned in the Dockerfile, and Docker's
# named-volume mount inherits ownership from the claude-owned target.
chown claude:claude "$CLAUDE_HOME" "$CLAUDE_HOME/.claude.json"
[ -f "$CLAUDE_HOME/.gitconfig" ] && chown claude:claude "$CLAUDE_HOME/.gitconfig"
chown -R claude:claude "$CONFIG_DIR" \
    "$CLAUDE_HOME/.codex" "$CLAUDE_HOME/.gemini" \
    "$CLAUDE_HOME/.config" "$CLAUDE_HOME/.ssh"

export DISPLAY=:99

exec /init "$@"
