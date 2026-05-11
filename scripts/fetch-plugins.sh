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
    mkdir -p "$dest"
    if ! git -C "$dest" init; then
        warn "$name: git init failed (see git output above) — skipping"
        rm -rf "$dest"
        return 0
    fi
    if ! git -C "$dest" remote add origin "$url"; then
        warn "$name: git remote add failed (see git output above) — skipping"
        rm -rf "$dest"
        return 0
    fi
    if ! git -C "$dest" fetch --depth 1 origin "$ref"; then
        warn "$name: git fetch failed (see git output above) — skipping"
        rm -rf "$dest"
        return 0
    fi
    if ! git -C "$dest" checkout FETCH_HEAD; then
        warn "$name: git checkout failed (see git output above) — skipping"
        rm -rf "$dest"
        return 0
    fi
    rm -rf "$dest/.git"
}

# fetch_subpaths <url> <ref> <subpath:dest> [<subpath:dest> ...]
#   Sparse-clone <url> ONCE, materialize all listed subpaths in a single
#   working tree, then move each into its dest. Used for the Anthropic
#   monorepo where we want multiple plugins from one repo without
#   repeating init+fetch+checkout per plugin.
#   Per-pair skip-if-populated mirrors the old fetch_subpath behaviour;
#   if every dest is already populated, the network fetch is skipped.
fetch_subpaths() {
    local url="$1" ref="$2"; shift 2
    local pairs=("$@")

    # Pre-pass: if every destination is already populated, skip entirely.
    local pair subpath dest name any_pending=0
    for pair in "${pairs[@]}"; do
        dest="${pair#*:}"
        name="$(basename "$dest")"
        if [ -e "$dest" ] && [ "$(ls -A "$dest" 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
            log "skip $name (destination already populated)"
        else
            any_pending=1
        fi
    done
    if [ "$any_pending" -eq 0 ]; then
        return 0
    fi

    # Log a fetch line per pending subpath, matching the old format.
    for pair in "${pairs[@]}"; do
        subpath="${pair%%:*}"
        dest="${pair#*:}"
        name="$(basename "$dest")"
        if [ -e "$dest" ] && [ "$(ls -A "$dest" 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
            continue
        fi
        log "fetch $name @ $ref from $url ($subpath)"
    done

    local tmp; tmp="$(mktemp -d)"
    if ! git -C "$tmp" init; then
        warn "monorepo git init failed (see git output above) — skipping all subpaths"
        rm -rf "$tmp"; return 0
    fi
    if ! git -C "$tmp" remote add origin "$url"; then
        warn "monorepo git remote add failed (see git output above) — skipping all subpaths"
        rm -rf "$tmp"; return 0
    fi
    if ! git -C "$tmp" config core.sparseCheckout true; then
        warn "monorepo git config sparseCheckout failed (see git output above) — skipping all subpaths"
        rm -rf "$tmp"; return 0
    fi
    if ! git -C "$tmp" sparse-checkout init --no-cone; then
        warn "monorepo sparse-checkout init failed (see git output above) — skipping all subpaths"
        rm -rf "$tmp"; return 0
    fi
    for pair in "${pairs[@]}"; do
        subpath="${pair%%:*}"
        if ! git -C "$tmp" sparse-checkout add --no-cone "$subpath"; then
            warn "monorepo sparse-checkout add '$subpath' failed (see git output above) — skipping all subpaths"
            rm -rf "$tmp"; return 0
        fi
    done
    if ! git -C "$tmp" fetch --depth 1 --filter=blob:none origin "$ref"; then
        warn "monorepo git fetch failed (see git output above) — skipping all subpaths"
        rm -rf "$tmp"; return 0
    fi
    if ! git -C "$tmp" checkout FETCH_HEAD; then
        warn "monorepo git checkout failed (see git output above) — skipping all subpaths"
        rm -rf "$tmp"; return 0
    fi

    for pair in "${pairs[@]}"; do
        subpath="${pair%%:*}"
        dest="${pair#*:}"
        name="$(basename "$dest")"
        if [ -e "$dest" ] && [ "$(ls -A "$dest" 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
            continue
        fi
        if [ ! -d "$tmp/$subpath" ]; then
            warn "$name: subpath '$subpath' not found in $url@$ref — skipping"
            continue
        fi
        rm -rf "$dest"
        if ! mv "$tmp/$subpath" "$dest"; then
            warn "$name: mv failed — skipping"
        fi
    done
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

# ---------- Anthropic-official plugins (single sparse checkout) ----------
fetch_subpaths "$ANTHROPIC_OFFICIAL_URL" "$ANTHROPIC_OFFICIAL_REF" \
    "plugins/csharp-lsp:$MARKETPLACE_DIR/csharp-lsp" \
    "plugins/commit-commands:$MARKETPLACE_DIR/commit-commands" \
    "plugins/feature-dev:$MARKETPLACE_DIR/feature-dev"

# ---------- Community plugin ----------
fetch_full "$CLAUDE_MEM_URL" "$CLAUDE_MEM_REF" "$MARKETPLACE_DIR/claude-mem"

# ---------- Community skill ----------
fetch_full "$PLAYWRIGHT_SKILL_URL" "$PLAYWRIGHT_SKILL_REF" \
    "$SKILLS_DIR/playwright-skill"

log "done."

# ---------- Manifest verification ----------
# Every plugin listed in marketplace.json MUST have a directory next to
# it after the fetches above. If any are missing, the build is broken —
# fail loudly here rather than baking a half-empty bundle into the image
# and letting the entrypoint reflect it into
# ~/.claude/kroclaude-marketplace/ where Claude Code will then complain
# to the user about "Plugin directory not found at path".
MANIFEST="$MARKETPLACE_DIR/.claude-plugin/marketplace.json"
if [ -f "$MANIFEST" ]; then
    missing=()
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [ -d "$MARKETPLACE_DIR/$name" ] || missing+=("$name")
    done < <(jq -r '.plugins[].name // empty' "$MANIFEST")
    if [ "${#missing[@]}" -gt 0 ]; then
        warn "manifest lists plugins not present on disk: ${missing[*]}"
        warn "check the git fetch errors above for the root cause"
        exit 1
    fi
fi
