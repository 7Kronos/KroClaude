#!/bin/bash
# tests/smoke/test_us1.sh — US1: Spin up a reproducible Claude Code shell.
# Run from repo root.
#
# Asserts:
#   - `docker compose up -d --build` reaches healthy within 60s
#   - claude --version succeeds inside the container
#   - sampled FR-003 tools resolve on PATH
#   - in-container user is `claude` (FR-005)
#   - headless Chromium can fetch example.com (FR-003b end-to-end)
set -euo pipefail

: "${COMPOSE:=docker compose}"
SVC=kroclaude

log()  { printf '\n[us1] %s\n' "$*"; }
fail() { printf '[us1] FAIL: %s\n' "$*" >&2; $COMPOSE logs --no-color $SVC || true; $COMPOSE ps || true; exit 1; }

in_ctn() { docker exec "$SVC" bash -c "$1"; }

cleanup() { $COMPOSE down >/dev/null 2>&1 || true; }
# Volumes are deliberately preserved — US2 reuses them. Caller can `down -v`.

trap cleanup EXIT

log "Building image and bringing stack up"
$COMPOSE up -d --build

log "Waiting for healthy status (max 60s)"
for i in $(seq 1 60); do
    status=$(docker inspect --format '{{.State.Health.Status}}' "$SVC" 2>/dev/null || echo "starting")
    if [ "$status" = "healthy" ]; then
        log "healthy after ${i}s"
        break
    fi
    sleep 1
    if [ "$i" -eq 60 ]; then
        fail "container did not reach healthy status within 60s (last status: $status)"
    fi
done

log "Asserting claude CLI is present and runnable"
in_ctn 'claude --version' || fail "claude --version exited non-zero"

log "Asserting FR-003 sampled tools on PATH"
TOOLS="git curl wget jq rg fd tree tmux fzf bat sudo gh psql redis-cli sqlite3 ffmpeg convert chromium Xvfb python3 node npm pnpm tsx prettier eslint lighthouse gemini codex"
for t in $TOOLS; do
    in_ctn "command -v $t >/dev/null" || fail "tool '$t' not on PATH"
done

log "Asserting in-container user is 'claude'"
USER=$(in_ctn 'id -un')
[ "$USER" = "claude" ] || fail "in-container user is '$USER', expected 'claude'"

log "Asserting Chromium can fetch example.com via Xvfb"
HTML=$(in_ctn 'DISPLAY=:99 chromium --headless --no-sandbox --disable-gpu --dump-dom https://example.com 2>/dev/null') || \
    fail "chromium failed to fetch example.com"
echo "$HTML" | grep -q 'Example Domain' || fail "expected 'Example Domain' in fetched HTML"

log "PASS"
