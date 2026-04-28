#!/bin/bash
# tests/smoke/test_us3.sh — US3: notifications opt-in + silent-fail.
# Run from repo root. Stack must already be up (US1 path); we don't tear down here.
#
# Asserts:
#   - notify.py exists, executable, apprise importable inside the container
#   - gate-1 silent: no sentinel + no NOTIFY_* → exit 0, no output
#   - gate-2 silent: sentinel + empty NOTIFY_URLS → exit 0, no output
#   - silent-fail: sentinel + bad NOTIFY_URLS → exit 0, no traceback (FR-010)
#   - Codex / Gemini hook files reference notify.py with the right event
set -euo pipefail

: "${COMPOSE:=docker compose}"
SVC=kroclaude

log()  { printf '\n[us3] %s\n' "$*"; }
fail() { printf '[us3] FAIL: %s\n' "$*" >&2; exit 1; }
in_ctn() { docker exec "$SVC" bash -c "$1"; }

# Pre-create the shared external kroclaude-apps network (idempotent).
docker network create kroclaude-apps >/dev/null 2>&1 || true

# Bring stack up if not already running.
if ! docker inspect --format '{{.State.Health.Status}}' "$SVC" >/dev/null 2>&1; then
    log "Stack not running — bringing up"
    $COMPOSE up -d
    for i in $(seq 1 60); do
        s=$(docker inspect --format '{{.State.Health.Status}}' "$SVC" 2>/dev/null || echo starting)
        [ "$s" = "healthy" ] && break
        sleep 1
        [ "$i" -eq 60 ] && fail "container not healthy in 60s"
    done
fi

log "notify.py exists and is executable"
in_ctn 'test -x /usr/local/bin/notify.py' || fail "notify.py missing or not executable"

log "apprise importable in the in-container Python"
in_ctn 'python3 -c "import apprise; print(apprise.__version__)"' >/dev/null || fail "apprise not importable"

log "Gate 1 — no sentinel, no NOTIFY_*: silent exit 0"
in_ctn 'rm -f /home/claude/.claude/notify-on'
out=$(in_ctn 'env -i PATH=$PATH /usr/local/bin/notify.py stop' 2>&1) || fail "exit non-zero with no gates"
[ -z "$out" ] || fail "expected empty output, got: $out"

log "Gate 2 — sentinel set, NOTIFY_URLS empty: silent exit 0"
in_ctn 'touch /home/claude/.claude/notify-on'
out=$(in_ctn 'env -i PATH=$PATH NOTIFY_URLS= /usr/local/bin/notify.py stop' 2>&1) || fail "exit non-zero with empty NOTIFY_URLS"
[ -z "$out" ] || fail "expected empty output, got: $out"

log "Silent-fail — sentinel set, bogus NOTIFY_URLS: exit 0, no traceback"
out=$(in_ctn 'env -i PATH=$PATH NOTIFY_URLS=tgram://bogus_token/0 /usr/local/bin/notify.py stop' 2>&1) || fail "exit non-zero on bogus URL"
echo "$out" | grep -q -i 'traceback' && fail "traceback leaked: $out"

# Cleanup gate
in_ctn 'rm -f /home/claude/.claude/notify-on'

log "Codex hooks reference notify.py stop"
in_ctn 'grep -F "/usr/local/bin/notify.py stop" /home/claude/.codex/hooks.json' >/dev/null \
  || fail "Codex hooks.json missing notify.py stop reference"

log "Gemini hooks reference notify.py stop"
in_ctn 'grep -F "/usr/local/bin/notify.py stop" /home/claude/.gemini/settings.json' >/dev/null \
  || fail "Gemini settings.json missing notify.py stop reference"

log "Claude settings.json hooks reference notify.py"
in_ctn 'grep -F "/usr/local/bin/notify.py" /home/claude/.claude/settings.json' >/dev/null \
  || fail "Claude settings.json missing notify.py reference"

log "PASS"
