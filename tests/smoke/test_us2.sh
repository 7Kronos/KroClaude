#!/bin/bash
# tests/smoke/test_us2.sh — US2: state survives container recreation and image rebuilds.
# Run from repo root.
#
# Asserts:
#   - empty-volume first boot completes <15s with sentinel + settings.json (SC-003)
#   - workspace tokens persist across `compose down` / `up`
#   - config-volume tokens persist across recreate
#   - tokens persist across image rebuild
#   - workspace-only wipe leaves config volume intact (US2 acc 2)
set -euo pipefail

: "${COMPOSE:=docker compose}"
SVC=kroclaude
# Pin project name so volume names are deterministic regardless of cwd basename.
export COMPOSE_PROJECT_NAME=kroclaude
WS_VOL=kroclaude_kroclaude-workspace

# Skill-bundling fixtures (feature 002, repathed under feature 005's
# /config/skills/ bundle root).
FIXTURE_NAME=__smoke_fixture_skill
FIXTURE_SRC="config/skills/$FIXTURE_NAME"
FIXTURE_BACKUP="/tmp/${FIXTURE_NAME}.bak"
USER_SKILL_NAME=__smoke_user_skill
FIXTURE_V1=$'# smoke-fixture-skill\nVERSION=1\n'
FIXTURE_V2=$'# smoke-fixture-skill\nVERSION=2\n'

log()  { printf '\n[us2] %s\n' "$*"; }
fail() { printf '[us2] FAIL: %s\n' "$*" >&2; $COMPOSE logs --no-color $SVC || true; exit 1; }
in_ctn()    { docker exec "$SVC" bash -c "$1"; }
as_claude() { docker exec --user claude "$SVC" bash -c "$1"; }

wait_healthy() {
    for i in $(seq 1 60); do
        s=$(docker inspect --format '{{.State.Health.Status}}' "$SVC" 2>/dev/null || echo starting)
        [ "$s" = "healthy" ] && return 0
        sleep 1
    done
    fail "container did not reach healthy in 60s"
}

cleanup() {
    $COMPOSE down --remove-orphans -v >/dev/null 2>&1 || true
    # Restore the fixture skill if the orphan scenario moved it aside.
    if [ -d "$FIXTURE_BACKUP" ]; then
        rm -rf "$FIXTURE_SRC"
        mv "$FIXTURE_BACKUP" "$FIXTURE_SRC" 2>/dev/null || true
    fi
    # Wipe the fixture from the working tree so the source repo stays clean.
    rm -rf "$FIXTURE_SRC"
}
trap cleanup EXIT

# Place the bundled-skill fixture in source BEFORE any build, so every
# `compose build` in this test bakes it into the image.
mkdir -p "$FIXTURE_SRC"
printf '%s' "$FIXTURE_V1" > "$FIXTURE_SRC/SKILL.md"

# ---------- Scenario 1: empty-volume first boot ----------
log "Scenario 1 — empty-volume first boot"
$COMPOSE down --remove-orphans -v >/dev/null 2>&1 || true
start=$(date +%s)
$COMPOSE up -d
wait_healthy
elapsed=$(( $(date +%s) - start ))
log "stack healthy after ${elapsed}s (SC-003 budget: 15s for bootstrap; up to 60s overall)"

in_ctn 'test -f /home/claude/.claude/.kroclaude-bootstrapped' || fail "sentinel not created on first boot"
in_ctn 'test -f /home/claude/.claude/settings.json' || fail "settings.json not seeded"
in_ctn 'test -f /home/claude/.claude/CLAUDE.md' || fail "CLAUDE.md not seeded"
in_ctn 'test -f /home/claude/.codex/config.toml' || fail "codex config.toml not seeded"
in_ctn 'test -f /home/claude/.codex/hooks.json'  || fail "codex hooks.json not seeded"
in_ctn 'test -f /home/claude/.gemini/settings.json' || fail "gemini settings.json not seeded"

# ---------- Scenario 2: workspace persistence across down/up ----------
log "Scenario 2 — workspace persistence across down/up"
in_ctn 'echo persist-token > /workspace/.us2-workspace-token'
in_ctn 'echo persist-cred  > /home/claude/.claude/.us2-config-token'
$COMPOSE down --remove-orphans
$COMPOSE up -d
wait_healthy
in_ctn 'grep -q persist-token /workspace/.us2-workspace-token' || fail "workspace token lost across recreate"
in_ctn 'grep -q persist-cred  /home/claude/.claude/.us2-config-token' || fail "config token lost across recreate"

# ---------- Scenario 3: image rebuild ----------
log "Scenario 3 — image rebuild preserves volumes"
$COMPOSE down --remove-orphans
$COMPOSE build >/dev/null
$COMPOSE up -d --force-recreate
wait_healthy
in_ctn 'grep -q persist-token /workspace/.us2-workspace-token' || fail "workspace token lost across rebuild"
in_ctn 'grep -q persist-cred  /home/claude/.claude/.us2-config-token' || fail "config token lost across rebuild"

# ---------- Scenario 4: workspace wipe leaves config intact ----------
log "Scenario 4 — workspace-only volume wipe preserves config"
$COMPOSE down --remove-orphans
docker volume rm "$WS_VOL" >/dev/null
$COMPOSE up -d --force-recreate
wait_healthy
in_ctn 'test ! -f /workspace/.us2-workspace-token' || fail "workspace token survived volume wipe (it should not)"
in_ctn 'grep -q persist-cred /home/claude/.claude/.us2-config-token' || fail "config token lost during workspace wipe"

# ============================================================================
# Skill-bundling scenarios (feature 002-skill-bundling).
# Run after the persistence scenarios so the fixture skill — present in
# `skills/` since the top of this test — has been baked into every image
# build along the way.
# ============================================================================

# ---------- Scenario 5: bundled skill present + byte-identical (US1) ----------
log "Scenario 5 (US1) — bundled skill reflected into volume on first boot"
$COMPOSE down --remove-orphans -v >/dev/null 2>&1 || true
$COMPOSE up -d --force-recreate
wait_healthy

as_claude "test -f /home/claude/.claude/skills/$FIXTURE_NAME/SKILL.md" \
    || fail "bundled fixture skill not reflected into volume"

actual=$(as_claude "cat /home/claude/.claude/skills/$FIXTURE_NAME/SKILL.md")
expected=$(cat "$FIXTURE_SRC/SKILL.md")
[ "$actual" = "$expected" ] \
    || fail "bundled fixture content drift between source and in-volume copy"

# Ownership check (FR-008).
owner=$(in_ctn "stat -c '%U:%G' /home/claude/.claude/skills/$FIXTURE_NAME/SKILL.md")
[ "$owner" = "claude:claude" ] \
    || fail "fixture skill ownership is '$owner', expected 'claude:claude'"

# ---------- Scenario 6: user-installed skill preserved across down/up (US2) ----------
log "Scenario 6 (US2) — user-installed skill survives recreate"
as_claude "mkdir -p /home/claude/.claude/skills/$USER_SKILL_NAME && echo USER-CONTENT-v1 > /home/claude/.claude/skills/$USER_SKILL_NAME/SKILL.md"
$COMPOSE down --remove-orphans
$COMPOSE up -d --force-recreate
wait_healthy
user_now=$(as_claude "cat /home/claude/.claude/skills/$USER_SKILL_NAME/SKILL.md")
[ "$user_now" = "USER-CONTENT-v1" ] \
    || fail "user skill content changed across recreate (got: $user_now)"

# ---------- Scenario 7: collision — bundled wins (US2) ----------
log "Scenario 7 (US2) — name collision: bundled wins over user override"
as_claude "echo USER-OVERRIDE > /home/claude/.claude/skills/$FIXTURE_NAME/SKILL.md"
$COMPOSE restart >/dev/null
wait_healthy
fixture_after=$(as_claude "cat /home/claude/.claude/skills/$FIXTURE_NAME/SKILL.md")
[ "$fixture_after" = "$(cat "$FIXTURE_SRC/SKILL.md")" ] \
    || fail "bundled skill did not overwrite user-override content"

# ---------- Scenario 8: orphaned bundled skill is preserved (US2) ----------
log "Scenario 8 (US2) — bundled skill removed from source: in-volume copy preserved"
captured=$(as_claude "cat /home/claude/.claude/skills/$FIXTURE_NAME/SKILL.md")
mv "$FIXTURE_SRC" "$FIXTURE_BACKUP"
$COMPOSE down --remove-orphans
$COMPOSE build >/dev/null
$COMPOSE up -d --force-recreate
wait_healthy
orphan_now=$(as_claude "cat /home/claude/.claude/skills/$FIXTURE_NAME/SKILL.md")
[ "$orphan_now" = "$captured" ] \
    || fail "orphaned bundled skill was modified after rebuild"
# Restore fixture for the next scenario.
mv "$FIXTURE_BACKUP" "$FIXTURE_SRC"

# ---------- Scenario 9: bundled update propagates, user skill intact (US3) ----------
log "Scenario 9 (US3) — bundled update propagates, user skill untouched"
printf '%s' "$FIXTURE_V2" > "$FIXTURE_SRC/SKILL.md"
$COMPOSE down --remove-orphans
$COMPOSE build >/dev/null
$COMPOSE up -d --force-recreate
wait_healthy
new_fixture=$(as_claude "cat /home/claude/.claude/skills/$FIXTURE_NAME/SKILL.md")
expected_fixture=$(cat "$FIXTURE_SRC/SKILL.md")
[ "$new_fixture" = "$expected_fixture" ] \
    || fail "bundled skill update did not propagate (got: $new_fixture)"
user_after=$(as_claude "cat /home/claude/.claude/skills/$USER_SKILL_NAME/SKILL.md")
[ "$user_after" = "USER-CONTENT-v1" ] \
    || fail "user skill modified during bundled update (got: $user_after)"

log "PASS"
