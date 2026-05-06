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

LOG_TAG=us1
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

in_ctn() { docker exec "$SVC" bash -c "$1"; }
as_claude() { docker exec --user claude "$SVC" bash -c "$1"; }

# Volumes are deliberately preserved — US2 reuses them. Caller can `down -v`.
# This is why we DON'T use cleanup_compose here (it removes volumes).
cleanup() { $COMPOSE down >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "Building image and bringing stack up"
$COMPOSE up -d --build

log "Waiting for healthy status (max 60s)"
wait_healthy

log "Asserting claude CLI is present and runnable (as claude user)"
as_claude 'claude --version' || fail "claude --version exited non-zero"

log "Asserting FR-003 sampled tools on PATH (as claude user)"
TOOLS="git curl wget jq rg fd tree tmux fzf bat sudo gh psql redis-cli sqlite3 ffmpeg convert chromium Xvfb python3 node npm pnpm tsx prettier eslint lighthouse gemini codex dotnet nats"
for t in $TOOLS; do
    as_claude "command -v $t >/dev/null" || fail "tool '$t' not on PATH for claude"
done

log "Asserting 'docker exec --user claude' lands as the claude user (FR-005)"
USER=$(as_claude 'id -un')
[ "$USER" = "claude" ] || fail "user shell landed as '$USER', expected 'claude'"

log "Asserting PID 1 (s6-overlay /init) is root — required for service supervision"
PID1_USER=$(in_ctn 'stat -c %U /proc/1')
[ "$PID1_USER" = "root" ] || fail "PID 1 is '$PID1_USER', expected 'root' for s6-overlay"

log "Asserting Chromium can fetch example.com via Xvfb (as claude)"
HTML=$(as_claude 'DISPLAY=:99 chromium --headless --no-sandbox --disable-gpu --dump-dom https://example.com 2>/dev/null') || \
    fail "chromium failed to fetch example.com"
echo "$HTML" | grep -q 'Example Domain' || fail "expected 'Example Domain' in fetched HTML"

log "PASS"
