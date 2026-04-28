#!/bin/bash
# tests/smoke/test_us6.sh — feature 005-config-bundling US1+US2+US3+US4+US5+US6+US7+US8.
# Run from repo root.
#
# Asserts: each of the seven bundled customization types is reflected
# from /config/<type>/ into ~/.claude/<type>/ correctly, user-installed
# items of the same type with non-colliding names survive, hook/MCP
# fragments merge with the documented precedence rules, malformed
# fragments are isolated (FR-009 / SC-004), and feature 001's
# sentinel-gated first-boot seed of settings.json + CLAUDE.md is
# unaffected.
set -euo pipefail

: "${COMPOSE:=docker compose}"
SVC=kroclaude
export COMPOSE_PROJECT_NAME=kroclaude

REPO_ROOT="$(pwd)"
CONFIG_DIR="$REPO_ROOT/config"
FIXTURES_DIR="$REPO_ROOT/tests/smoke/fixtures/005"
TMP_DIR=$(mktemp -d)
CONFIG_BACKUP="$TMP_DIR/config-backup"

log()  { printf '\n[us6] %s\n' "$*"; }
fail() { printf '[us6] FAIL: %s\n' "$*" >&2; $COMPOSE logs --no-color $SVC || true; exit 1; }

wait_healthy() {
    local svc=${1:-$SVC}
    for i in $(seq 1 60); do
        s=$(docker inspect --format '{{.State.Health.Status}}' "$svc" 2>/dev/null || echo starting)
        [ "$s" = "healthy" ] && return 0
        sleep 1
    done
    fail "container $svc did not reach healthy in 60s"
}

# Copy a fixture into the live /config/ tree. For dir-of-dirs types
# (skills, agents, plugins) <name> is a directory; for dir-of-files
# types (commands, output-styles) it's a file basename without ext;
# for fragment types (hooks.d, mcp-servers.d) it's a .json filename
# without ext.
place_fixture() {
    local type="$1" name="$2"
    local src="$FIXTURES_DIR/$type/$name"
    install -d "$CONFIG_DIR/$type"
    if [ -d "$src" ]; then
        cp -r "$src" "$CONFIG_DIR/$type/$name"
    elif [ -f "$src.md" ]; then
        cp "$src.md" "$CONFIG_DIR/$type/$name.md"
    elif [ -f "$src.json" ]; then
        cp "$src.json" "$CONFIG_DIR/$type/$name.json"
    else
        fail "place_fixture: no fixture found at $src{,.md,.json}"
    fi
}

cleanup() {
    $COMPOSE down --remove-orphans -v >/dev/null 2>&1 || true
    # Restore /config/ to its pre-test state.
    if [ -d "$CONFIG_BACKUP" ]; then
        rm -rf "$CONFIG_DIR"
        cp -r "$CONFIG_BACKUP" "$CONFIG_DIR"
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Snapshot /config/ so the cleanup trap can restore it AFTER fixtures
# get dropped in.
log "Snapshotting /config/ to $CONFIG_BACKUP"
cp -r "$CONFIG_DIR" "$CONFIG_BACKUP"

# Reuse the US4/US5 keygen pattern for SSH access (entrypoint accepts
# an empty key, but providing one keeps the contract uniform).
ssh-keygen -t ed25519 -N '' -f "$TMP_DIR/id_us6" -q

# Build is needed because we're modifying /config/ between phases and
# the Dockerfile COPYs the bundle at build time.
build_and_up() {
    KROCLAUDE_SSH_AUTHORIZED_KEY="$(cat "$TMP_DIR/id_us6.pub")" \
        $COMPOSE up -d --build --force-recreate
    wait_healthy
}

# ============================================================================
# Phase 1 — bulk: place fixtures for the 5 "easy" types and US7 (plugins),
# then ONE build_and_up. US5 (hooks) and US6 (MCP) get their own restart
# cycles afterward because they need multiple fixture states.
# ============================================================================

log "Phase 1 — placing fixtures for US1, US2, US3, US4, US7"
place_fixture skills hello
place_fixture commands triage
place_fixture agents db-reviewer
place_fixture output-styles brief
place_fixture plugins sample-plugin

build_and_up

# Helper: assert a path exists in the container with claude:claude ownership.
assert_in_container() {
    local path="$1"
    docker exec -u claude $SVC test -e "$path" \
        || fail "expected $path in container — not found"
    local owner
    owner=$(docker exec $SVC stat -c '%U:%G' "$path")
    [ "$owner" = "claude:claude" ] \
        || fail "expected $path owned by claude:claude — got $owner"
}

# ---------- US1: skills ----------
log "US1 — bundled skill reflected to ~/.claude/skills/hello/SKILL.md"
assert_in_container /home/claude/.claude/skills/hello/SKILL.md
docker exec $SVC sha256sum \
    /usr/local/share/kroclaude/config/skills/hello/SKILL.md \
    /home/claude/.claude/skills/hello/SKILL.md \
    | awk '{print $1}' | sort -u | wc -l | grep -qx 1 \
    || fail "US1 — reflected skill content drifted from source"

log "US1 — user-installed skill survives container restart (FR-005)"
docker exec -u claude $SVC mkdir -p /home/claude/.claude/skills/private-user-skill
docker exec -u claude $SVC sh -c 'echo "user-only" > /home/claude/.claude/skills/private-user-skill/SKILL.md'
$COMPOSE restart $SVC >/dev/null
wait_healthy
docker exec -u claude $SVC test -f /home/claude/.claude/skills/private-user-skill/SKILL.md \
    || fail "US1 — user-installed skill 'private-user-skill' was clobbered"
log "US1 PASS"

# ---------- US2: commands ----------
log "US2 — bundled command reflected to ~/.claude/commands/triage.md"
assert_in_container /home/claude/.claude/commands/triage.md
log "US2 — user-installed command survives restart"
docker exec -u claude $SVC mkdir -p /home/claude/.claude/commands
docker exec -u claude $SVC sh -c 'echo "user only" > /home/claude/.claude/commands/local-only.md'
$COMPOSE restart $SVC >/dev/null
wait_healthy
docker exec -u claude $SVC test -f /home/claude/.claude/commands/local-only.md \
    || fail "US2 — user-installed command 'local-only.md' was clobbered"
log "US2 PASS"

# ---------- US3: agents ----------
log "US3 — bundled agent reflected to ~/.claude/agents/db-reviewer/agent.md"
assert_in_container /home/claude/.claude/agents/db-reviewer/agent.md
log "US3 — user-installed agent survives restart"
docker exec -u claude $SVC mkdir -p /home/claude/.claude/agents/private
docker exec -u claude $SVC sh -c 'echo "user only" > /home/claude/.claude/agents/private/agent.md'
$COMPOSE restart $SVC >/dev/null
wait_healthy
docker exec -u claude $SVC test -f /home/claude/.claude/agents/private/agent.md \
    || fail "US3 — user-installed agent 'private' was clobbered"
log "US3 PASS"

# ---------- US4: output-styles ----------
log "US4 — bundled output-style reflected"
assert_in_container /home/claude/.claude/output-styles/brief.md
log "US4 — user-installed output-style survives restart"
docker exec -u claude $SVC mkdir -p /home/claude/.claude/output-styles
docker exec -u claude $SVC sh -c 'echo "user only" > /home/claude/.claude/output-styles/my-mood.md'
$COMPOSE restart $SVC >/dev/null
wait_healthy
docker exec -u claude $SVC test -f /home/claude/.claude/output-styles/my-mood.md \
    || fail "US4 — user-installed output-style 'my-mood' was clobbered"
log "US4 PASS"

# ---------- US7: plugins (deep tree reflection) ----------
log "US7 — bundled plugin manifest reflected"
assert_in_container /home/claude/.claude/plugins/sample-plugin/.claude-plugin/plugin.json
log "US7 — nested plugin skill reflected (whole-tree reflection)"
assert_in_container /home/claude/.claude/plugins/sample-plugin/skills/hello/SKILL.md
log "US7 — user-installed plugin survives restart"
docker exec -u claude $SVC mkdir -p /home/claude/.claude/plugins/private/.claude-plugin
docker exec -u claude $SVC sh -c 'echo "{\"name\":\"private\"}" > /home/claude/.claude/plugins/private/.claude-plugin/plugin.json'
$COMPOSE restart $SVC >/dev/null
wait_healthy
docker exec -u claude $SVC test -f /home/claude/.claude/plugins/private/.claude-plugin/plugin.json \
    || fail "US7 — user-installed plugin 'private' was clobbered"
log "US7 PASS"

# ============================================================================
# Phase 2 — US5 hooks fragment merging (needs multiple fixture states).
# ============================================================================

log "US5 — placing hooks.d fixture (lint.json), rebuilding"
place_fixture hooks.d lint
build_and_up

log "US5 — merged settings.json contains feature 001 notify hooks AND new lint hook"
docker exec -u claude $SVC jq '.hooks | keys' /home/claude/.claude/settings.json \
    | tee "$TMP_DIR/us5_keys.json" \
    | grep -q 'PostToolUse' \
    || fail "US5 — PostToolUse key missing from merged settings.json"
docker exec -u claude $SVC jq -r '.hooks | keys[]' /home/claude/.claude/settings.json \
    | grep -q '^Stop$' \
    || fail "US5 — feature 001's Stop hook clobbered by merge"
docker exec -u claude $SVC jq -r '.hooks.PostToolUse[].hooks[].command' /home/claude/.claude/settings.json \
    | grep -q '\[us6 fixture\] lint' \
    || fail "US5 — bundled lint hook command not present after merge"

log "US5 — fragment precedence: 99-override.json beats 00-base.json (lex-last-wins)"
cat > "$CONFIG_DIR/hooks.d/00-base.json" <<'EOF'
{ "hooks": { "PostToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo BASE" } ] } ] } }
EOF
cat > "$CONFIG_DIR/hooks.d/99-override.json" <<'EOF'
{ "hooks": { "PostToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo OVERRIDE" } ] } ] } }
EOF
build_and_up
docker exec -u claude $SVC jq -r '.hooks.PostToolUse[] | select(.matcher=="Bash") | .hooks[].command' \
    /home/claude/.claude/settings.json \
    | grep -q 'echo OVERRIDE' \
    || fail "US5 — lex-order-last-wins precedence broken; OVERRIDE not present"
docker exec -u claude $SVC jq -r '.hooks.PostToolUse[] | select(.matcher=="Bash") | .hooks[].command' \
    /home/claude/.claude/settings.json \
    | grep -q 'echo BASE' \
    && fail "US5 — BASE command should have been overridden by lex-last-wins"

log "US5 — merge is idempotent across restarts (FR-007)"
hash1=$(docker exec -u claude $SVC sha256sum /home/claude/.claude/settings.json | awk '{print $1}')
$COMPOSE restart $SVC >/dev/null
wait_healthy
hash2=$(docker exec -u claude $SVC sha256sum /home/claude/.claude/settings.json | awk '{print $1}')
[ "$hash1" = "$hash2" ] \
    || fail "US5 — settings.json changed across restart (not idempotent: $hash1 vs $hash2)"

log "US5 — failure isolation: malformed fragment skipped, valid one still merges (FR-009)"
echo 'not json at all' > "$CONFIG_DIR/hooks.d/00-malformed.json"
build_and_up
docker logs $SVC 2>&1 | grep -q 'WARN: skipping malformed fragment.*00-malformed' \
    || fail "US5 — entrypoint should log WARN about malformed 00-malformed.json"
docker exec -u claude $SVC jq -r '.hooks.PostToolUse[].hooks[].command' /home/claude/.claude/settings.json \
    | grep -q 'echo OVERRIDE' \
    || fail "US5 — valid fragment should still reflect even with malformed sibling"

# Cleanup hooks.d fixtures so US6 starts clean.
rm -f "$CONFIG_DIR/hooks.d/00-base.json" "$CONFIG_DIR/hooks.d/99-override.json" "$CONFIG_DIR/hooks.d/00-malformed.json"
log "US5 PASS"

# ============================================================================
# Phase 3 — US6 MCP fragment merging.
# ============================================================================

log "US6 — placing mcp-servers.d fixture (postgres.json), rebuilding"
place_fixture mcp-servers.d postgres
build_and_up

log "US6 — bundled postgres entry present in .mcp.json"
docker exec -u claude $SVC jq -r '.mcpServers | keys[]' /home/claude/.claude/.mcp.json \
    | grep -qx 'postgres' \
    || fail "US6 — postgres entry missing from .mcp.json"

log "US6 — user-installed mcp server survives merge (non-colliding key preserved)"
docker exec -u claude $SVC jq '.mcpServers["local-only"] = {"command": "echo", "args": ["local"]}' \
    /home/claude/.claude/.mcp.json > "$TMP_DIR/us6_user.json"
docker cp "$TMP_DIR/us6_user.json" $SVC:/home/claude/.claude/.mcp.json
docker exec $SVC chown claude:claude /home/claude/.claude/.mcp.json
$COMPOSE restart $SVC >/dev/null
wait_healthy
docker exec -u claude $SVC jq -r '.mcpServers | keys[]' /home/claude/.claude/.mcp.json \
    | tee "$TMP_DIR/us6_keys" >/dev/null
grep -qx 'postgres'   "$TMP_DIR/us6_keys" || fail "US6 — postgres lost after restart"
grep -qx 'local-only' "$TMP_DIR/us6_keys" || fail "US6 — local-only user entry was clobbered"

log "US6 — failure isolation: malformed mcp fragment skipped (FR-009)"
echo '{not valid json' > "$CONFIG_DIR/mcp-servers.d/00-malformed.json"
build_and_up
docker logs $SVC 2>&1 | grep -q 'WARN: skipping malformed fragment.*00-malformed' \
    || fail "US6 — entrypoint should log WARN about malformed 00-malformed.json"
docker exec -u claude $SVC jq -r '.mcpServers | keys[]' /home/claude/.claude/.mcp.json \
    | grep -qx 'postgres' \
    || fail "US6 — valid postgres entry should still reflect even with malformed sibling"

rm -f "$CONFIG_DIR/mcp-servers.d/00-malformed.json"
log "US6 PASS"

# ============================================================================
# Phase 4 — US8 regression: settings.json + CLAUDE.md sentinel-gated seed.
# ============================================================================

log "US8 — edit ~/.claude/CLAUDE.md, restart, expect edit to SURVIVE (sentinel-gated)"
docker exec -u claude $SVC sh -c 'echo "## US8 marker line" >> /home/claude/.claude/CLAUDE.md'
$COMPOSE restart $SVC >/dev/null
wait_healthy
docker exec -u claude $SVC grep -q '## US8 marker line' /home/claude/.claude/CLAUDE.md \
    || fail "US8 — CLAUDE.md was overwritten on restart (sentinel gate broken)"

log "US8 — wipe volume, fresh boot expects bundled CLAUDE.md content"
$COMPOSE down -v >/dev/null
KROCLAUDE_SSH_AUTHORIZED_KEY="$(cat "$TMP_DIR/id_us6.pub")" \
    $COMPOSE up -d --force-recreate
wait_healthy
docker exec -u claude $SVC grep -q '## US8 marker line' /home/claude/.claude/CLAUDE.md \
    && fail "US8 — fresh volume should have the bundled CLAUDE.md, NOT the marker line"
docker exec -u claude $SVC test -f /home/claude/.claude/CLAUDE.md \
    || fail "US8 — fresh-volume CLAUDE.md missing entirely"
log "US8 PASS"

log "ALL PHASES PASS"
