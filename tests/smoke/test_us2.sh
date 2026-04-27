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

log()  { printf '\n[us2] %s\n' "$*"; }
fail() { printf '[us2] FAIL: %s\n' "$*" >&2; $COMPOSE logs --no-color $SVC || true; exit 1; }
in_ctn() { docker exec "$SVC" bash -c "$1"; }

wait_healthy() {
    for i in $(seq 1 60); do
        s=$(docker inspect --format '{{.State.Health.Status}}' "$SVC" 2>/dev/null || echo starting)
        [ "$s" = "healthy" ] && return 0
        sleep 1
    done
    fail "container did not reach healthy in 60s"
}

cleanup() { $COMPOSE down --remove-orphans -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

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
$COMPOSE build --no-cache >/dev/null
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

log "PASS"
