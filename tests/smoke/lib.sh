#!/bin/bash
# tests/smoke/lib.sh — shared scaffolding for the smoke test suite.
#
# Sourced by every tests/smoke/test_usN.sh. Each caller is responsible
# for `set -euo pipefail`; this file deliberately does NOT set shell
# options on behalf of the caller.
#
# Contract for callers:
#   - Set LOG_TAG (e.g. LOG_TAG=us1) BEFORE sourcing so log()/fail()
#     emit the right prefix.
#   - To extend cleanup beyond the compose teardown, define your own
#     trap that calls cleanup_compose plus whatever else is needed.

# Shared compose plumbing.
: "${COMPOSE:=docker compose}"
SVC=kroclaude
# Pin the project name so volume names are deterministic regardless of
# the cwd basename. Harmless for tests that don't touch volumes.
export COMPOSE_PROJECT_NAME=kroclaude

# Default tag if a caller forgot to set one.
: "${LOG_TAG:=smoke}"

# Color-free logging helpers. fail() dumps compose logs + ps to give
# the operator something to grep through, then exits 1.
log()  { printf '\n[%s] %s\n' "$LOG_TAG" "$*"; }
fail() {
    printf '[%s] FAIL: %s\n' "$LOG_TAG" "$*" >&2
    $COMPOSE logs --no-color $SVC || true
    $COMPOSE ps || true
    exit 1
}

# Poll the container's health status. Optional first arg overrides the
# service/container name (defaults to $SVC).
wait_healthy() {
    local svc=${1:-$SVC}
    local i s
    for i in $(seq 1 60); do
        s=$(docker inspect --format '{{.State.Health.Status}}' "$svc" 2>/dev/null || echo starting)
        [ "$s" = "healthy" ] && return 0
        sleep 1
    done
    fail "container $svc did not reach healthy in 60s"
}

# Best-effort full teardown: stop the stack and remove volumes +
# orphans. Safe to call from a trap: never errors out.
cleanup_compose() {
    $COMPOSE down --remove-orphans -v >/dev/null 2>&1 || true
}
