#!/bin/bash
# Stage 30 — bundled customization reflection (feature 005-config-bundling).
# Reflects each per-type subdirectory of $SOURCE_DIR/<type>/ into
# ~/.claude/<type>/ on EVERY boot. Two helpers cover the patterns:
#
#   reflect_dir       — skills, agents, plugins (dir-mode, no <ext>);
#                       commands, output-styles (file-mode, with <ext>)
#   merge_fragments   — hooks.d, mcp-servers.d (directory of fragments
#                       jq-merged into a target; filters live as
#                       versioned files under $FILTER_DIR)
#
# Invariants (enforced by every helper):
#   - No-op when source is missing or empty (FR-004 / generalized FR-005).
#   - Per-item failure isolation: a single bad item logs a WARN and skips;
#     other items of the same type and ALL items of other types still
#     reflect (FR-009 / SC-004). Container always boots.
#   - User-installed items under ~/.claude/<type>/ whose names do NOT
#     collide with bundled names are never enumerated, never touched.
#   - All reflected files end up owned by claude:claude (stage 70 sweep).
#   - Re-runs are idempotent (byte-identical output for identical input).
#
# Contracts: specs/005-config-bundling/contracts/{reflection-helpers,merge-filters}.md
set -euo pipefail
. /etc/kroclaude/entrypoint-lib.sh

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
                || { warn "skipped reflecting $item"; continue; }
        done < <(LC_ALL=C find "$src" -maxdepth 1 -type f -name "*.$ext" | LC_ALL=C sort)
    else
        # dir-mode
        for item in "$src"/*/; do
            [ -d "$item" ] || continue
            name=$(basename "$item")
            [ "$name" = ".gitkeep" ] && continue
            rm -rf "$dest/$name" \
                && cp -r "$item" "$dest/$name" \
                || { warn "skipped reflecting $src/$name"; continue; }
        done
    fi
}

# merge_fragments <src-dir> <target-file> <filter-file> <default-target-json>
# Builds $fragments — a JSON ARRAY of all valid bundled fragments in lex
# order — and applies the filter file to the target. The array shape is
# required (vs a single pre-folded bundle): jq's `*` REPLACES nested
# arrays, so folding early would let the lex-last fragment clobber other
# matchers' hook entries under the same event.
merge_fragments() {
    local src_dir="$1" target="$2" filter_file="$3" default_target_json="$4"
    [ -d "$src_dir" ] && [ -n "$(ls -A "$src_dir" 2>/dev/null)" ] || return 0
    local fragments_json='[]' f
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        if ! jq empty "$f" >/dev/null 2>&1; then
            warn "skipping malformed fragment $f"
            continue
        fi
        fragments_json=$(jq -s '.[0] + [.[1]]' <(printf '%s' "$fragments_json") "$f") \
            || { warn "append failed on $f"; continue; }
    done < <(LC_ALL=C find "$src_dir" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
    [ "$fragments_json" = '[]' ] && return 0
    # Ensure target file exists so jq has something to read.
    if [ ! -f "$target" ]; then
        install -d -o claude -g claude "$(dirname "$target")"
        printf '%s\n' "$default_target_json" > "$target"
    fi
    local merged
    merged=$(jq --argjson fragments "$fragments_json" -f "$filter_file" "$target") \
        || { warn "jq merge into $target failed"; return 0; }
    printf '%s\n' "$merged" > "$target.tmp" \
        && mv "$target.tmp" "$target" \
        || { warn "write of merged $target failed"; return 0; }
}

# ---- Per-type reflection call sites (one line each — SC-003) ----
reflect_dir     "$SOURCE_DIR/skills"        "$CONFIG_DIR/skills"
# Codex (and anything else speaking the agent-skills standard) reads
# user skills from ~/.agents/skills — same bundled set, same collision
# semantics. Plugins are deliberately NOT mirrored; they are claude-only.
reflect_dir     "$SOURCE_DIR/skills"        "$CLAUDE_HOME/.agents/skills"
reflect_dir     "$SOURCE_DIR/agents"        "$CONFIG_DIR/agents"
reflect_dir     "$SOURCE_DIR/plugins"       "$CONFIG_DIR/plugins"
reflect_dir     "$SOURCE_DIR/commands"      "$CONFIG_DIR/commands"      md
reflect_dir     "$SOURCE_DIR/output-styles" "$CONFIG_DIR/output-styles" md
merge_fragments "$SOURCE_DIR/hooks.d"       "$CONFIG_DIR/settings.json" "$FILTER_DIR/hooks-merge.jq" '{}'
merge_fragments "$SOURCE_DIR/mcp-servers.d" "$CONFIG_DIR/.mcp.json"     "$FILTER_DIR/mcp-merge.jq"   '{"mcpServers":{}}'
