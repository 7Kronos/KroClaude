#!/bin/bash
# KroClaude — Fetch bundled third-party Claude Code plugins & skills.
#
# Pulls a curated set of upstream plugin/skill repositories into the
# `/config/plugins/` and `/config/skills/` subdirectories laid out by
# feature 005-config-bundling. Designed to be invoked from the
# Dockerfile during image build, with a target directory passed as the
# single positional argument:
#
#   scripts/fetch-plugins.sh /usr/local/share/kroclaude/config
#
# Each item's git ref is overridable via an env var (default `main`) so
# CI or a maintainer can pin to a specific commit SHA without editing
# this file:
#
#   CSHARP_LSP_REF=abc1234 scripts/fetch-plugins.sh ./config
#
# Per-item failure is non-fatal: a warning is logged and the remaining
# items are still fetched. This mirrors the FR-009 posture of the
# entrypoint reflection helpers.
set -uo pipefail

TARGET_ROOT="${1:?usage: fetch-plugins.sh <target_config_dir>}"

# ---------- Pinned source URLs and refs ----------
# Anthropic-official monorepo (sparse checkout — we only need three plugins).
ANTHROPIC_OFFICIAL_URL="https://github.com/anthropics/claude-plugins-official.git"
ANTHROPIC_OFFICIAL_REF="${ANTHROPIC_OFFICIAL_REF:-main}"

# Standalone repos.
CLAUDE_MEM_URL="https://github.com/thedotmack/claude-mem.git"
CLAUDE_MEM_REF="${CLAUDE_MEM_REF:-main}"

PLAYWRIGHT_SKILL_URL="https://github.com/lackeyjb/playwright-skill.git"
PLAYWRIGHT_SKILL_REF="${PLAYWRIGHT_SKILL_REF:-main}"

# ---------- Logging ----------
log()  { printf '[fetch-plugins] %s\n' "$*"; }
warn() { printf '[fetch-plugins] WARN: %s\n' "$*" >&2; }

# ---------- Helpers ----------
# fetch_full <url> <ref> <dest_dir>
#   Shallow-clone an entire repository into <dest_dir>, then strip .git.
#   Used when the upstream repo IS the plugin/skill.
fetch_full() {
    local url="$1" ref="$2" dest="$3"
    local name; name="$(basename "$dest")"

    if [ -e "$dest" ] && [ "$(ls -A "$dest" 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
        log "skip $name (destination already populated)"
        return 0
    fi

    log "fetch $name @ $ref from $url"
    rm -rf "$dest"
    if ! git clone --quiet --depth 1 --branch "$ref" "$url" "$dest"; then
        warn "$name: git clone failed — skipping"
        rm -rf "$dest"
        return 0
    fi
    rm -rf "$dest/.git"
}

# fetch_subpath <url> <ref> <subpath> <dest_dir>
#   Sparse-clone <url>, materialize only <subpath>, then move that
#   subpath's contents to <dest_dir>. Used for the Anthropic monorepo.
fetch_subpath() {
    local url="$1" ref="$2" subpath="$3" dest="$4"
    local name; name="$(basename "$dest")"

    if [ -e "$dest" ] && [ "$(ls -A "$dest" 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
        log "skip $name (destination already populated)"
        return 0
    fi

    log "fetch $name @ $ref from $url ($subpath)"
    local tmp; tmp="$(mktemp -d)"
    if ! git clone --quiet --depth 1 --filter=blob:none --sparse \
            --branch "$ref" "$url" "$tmp"; then
        warn "$name: git clone failed — skipping"
        rm -rf "$tmp"
        return 0
    fi
    if ! git -C "$tmp" sparse-checkout set --no-cone "$subpath" >/dev/null; then
        warn "$name: sparse-checkout failed — skipping"
        rm -rf "$tmp"
        return 0
    fi
    if [ ! -d "$tmp/$subpath" ]; then
        warn "$name: subpath '$subpath' not found in $url@$ref — skipping"
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$dest"
    mv "$tmp/$subpath" "$dest"
    rm -rf "$tmp"
}

# ---------- Targets ----------
# Plugins land under a single "marketplace" directory whose
# `.claude-plugin/marketplace.json` (checked in at config/marketplace/)
# turns this whole tree into a Claude Code local marketplace. The
# entrypoint reflects this dir wholesale into
# ~/.claude/kroclaude-marketplace/ and the plugin-defaults.json merge
# wires it up via extraKnownMarketplaces + enabledPlugins.
MARKETPLACE_DIR="$TARGET_ROOT/marketplace"
SKILLS_DIR="$TARGET_ROOT/skills"
mkdir -p "$MARKETPLACE_DIR" "$SKILLS_DIR"

# ---------- Anthropic-official plugins (sparse checkout) ----------
fetch_subpath "$ANTHROPIC_OFFICIAL_URL" "$ANTHROPIC_OFFICIAL_REF" \
    "plugins/csharp-lsp"       "$MARKETPLACE_DIR/csharp-lsp"
fetch_subpath "$ANTHROPIC_OFFICIAL_URL" "$ANTHROPIC_OFFICIAL_REF" \
    "plugins/commit-commands"  "$MARKETPLACE_DIR/commit-commands"
fetch_subpath "$ANTHROPIC_OFFICIAL_URL" "$ANTHROPIC_OFFICIAL_REF" \
    "plugins/feature-dev"      "$MARKETPLACE_DIR/feature-dev"

# ---------- Community plugin ----------
fetch_full "$CLAUDE_MEM_URL" "$CLAUDE_MEM_REF" "$MARKETPLACE_DIR/claude-mem"

# ---------- Community skill ----------
fetch_full "$PLAYWRIGHT_SKILL_URL" "$PLAYWRIGHT_SKILL_REF" \
    "$SKILLS_DIR/playwright-skill"

log "done."
