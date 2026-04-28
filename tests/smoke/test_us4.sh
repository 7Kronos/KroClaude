#!/bin/bash
# tests/smoke/test_us4.sh — feature 003-ssh-access US1+US2+US3.
# Run from repo root.
#
# Asserts:
#   US1 — public key in env → `ssh -p 2221 claude@127.0.0.1` works,
#         lands in /workspace as the `claude` user, can run `claude`.
#   US2 — rotating the env to a different key invalidates the old key
#         and accepts the new one; multi-key (newline-separated) works;
#         no key body appears in `docker history`.
#   US3 — password auth, root login, and wrong-key all rejected.
set -euo pipefail

: "${COMPOSE:=docker compose}"
SVC=kroclaude
export COMPOSE_PROJECT_NAME=kroclaude

TMP_DIR=$(mktemp -d)

log()  { printf '\n[us4] %s\n' "$*"; }
fail() { printf '[us4] FAIL: %s\n' "$*" >&2; $COMPOSE logs --no-color $SVC || true; exit 1; }

wait_healthy() {
    for i in $(seq 1 60); do
        s=$(docker inspect --format '{{.State.Health.Status}}' "$SVC" 2>/dev/null || echo starting)
        [ "$s" = "healthy" ] && return 0
        sleep 1
    done
    fail "container did not reach healthy in 60s"
}

# Wrapper around ssh with smoke-friendly options. Args: <key-path> <port> <remote-cmd>
ssh_test() {
    local key=$1 port=$2; shift 2
    ssh -i "$key" -p "$port" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        claude@127.0.0.1 "$@"
}

cleanup() {
    $COMPOSE down --remove-orphans -v >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Generate the first throwaway keypair that will be the initial authorized key.
ssh-keygen -t ed25519 -N '' -f "$TMP_DIR/id_test1" -q

# ============================================================================
# Phase 3 — US1: SSH in and use Claude Code
# ============================================================================

log "Scenario US1 — bring stack up with key in env, ssh in, run claude"
KROCLAUDE_SSH_AUTHORIZED_KEY="$(cat "$TMP_DIR/id_test1.pub")" \
    $COMPOSE up -d --force-recreate
wait_healthy

# Positive auth: claude --version
ssh_test "$TMP_DIR/id_test1" 2221 'claude --version' >"$TMP_DIR/us4_claude_version" 2>&1 \
    || fail "ssh + claude --version failed"
grep -qE 'Claude Code|^[0-9]+\.[0-9]+\.[0-9]+' "$TMP_DIR/us4_claude_version" \
    || fail "claude version output unexpected: $(cat "$TMP_DIR/us4_claude_version")"

# Working directory is /workspace per data-model.
pwd_out=$(ssh_test "$TMP_DIR/id_test1" 2221 'pwd')
[ "$pwd_out" = "/workspace" ] \
    || fail "ssh login working dir is '$pwd_out', expected '/workspace'"

# User is claude per FR-005.
user_out=$(ssh_test "$TMP_DIR/id_test1" 2221 'id -un')
[ "$user_out" = "claude" ] \
    || fail "ssh login user is '$user_out', expected 'claude'"

# ============================================================================
# Phase 4 — US2: Configure SSH access from env
# ============================================================================

# Key rotation — new key in, old key out.
log "Scenario US2 — rotate key in env, old key MUST fail, new key MUST work"
ssh-keygen -t ed25519 -N '' -f "$TMP_DIR/id_test2" -q
KROCLAUDE_SSH_AUTHORIZED_KEY="$(cat "$TMP_DIR/id_test2.pub")" \
    $COMPOSE up -d --force-recreate
wait_healthy
ssh_test "$TMP_DIR/id_test2" 2221 'true' \
    || fail "rotated key (id_test2) was rejected"
if ssh_test "$TMP_DIR/id_test1" 2221 'true' 2>/dev/null; then
    fail "old key (id_test1) still accepted after rotation — latest env should win"
fi

# Multi-key — both keys in env, both work.
log "Scenario US2 — multi-key: both authorized keys MUST work"
KROCLAUDE_SSH_AUTHORIZED_KEY="$(cat "$TMP_DIR/id_test1.pub")"$'\n'"$(cat "$TMP_DIR/id_test2.pub")" \
    $COMPOSE up -d --force-recreate
wait_healthy
ssh_test "$TMP_DIR/id_test1" 2221 'true' \
    || fail "multi-key: id_test1 rejected"
ssh_test "$TMP_DIR/id_test2" 2221 'true' \
    || fail "multi-key: id_test2 rejected"

# Env-secret hygiene: no key body should appear in `docker history` (FR-012 / SC-005).
log "Scenario US2 — assert no SSH public-key body in docker history (FR-012)"
key_body=$(awk '{print $2}' "$TMP_DIR/id_test1.pub")
if docker history --no-trunc --format '{{.CreatedBy}}' kroclaude:dev | grep -qF "$key_body"; then
    fail "SSH public-key material leaked into docker history (FR-012 violation)"
fi

# ============================================================================
# Phase 5 — US3: Refuse password / root / wrong key
# ============================================================================

log "Scenario US3 — password auth MUST be refused with no prompt"
set +e
ssh -p 2221 \
    -o PreferredAuthentications=password \
    -o NumberOfPasswordPrompts=0 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    -o BatchMode=yes \
    claude@127.0.0.1 'true' >"$TMP_DIR/us4_pw.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "password-only ssh attempt unexpectedly succeeded"
if grep -qi 'password:' "$TMP_DIR/us4_pw.log"; then
    fail "password prompt appeared (sshd misconfigured)"
fi

log "Scenario US3 — root login MUST be refused"
set +e
ssh -i "$TMP_DIR/id_test1" -p 2221 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    -o BatchMode=yes \
    root@127.0.0.1 'true' >"$TMP_DIR/us4_root.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "root login unexpectedly succeeded"

log "Scenario US3 — wrong key MUST be refused"
ssh-keygen -t ed25519 -N '' -f "$TMP_DIR/id_test3" -q
set +e
ssh_test "$TMP_DIR/id_test3" 2221 'true' >"$TMP_DIR/us4_wrongkey.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "wrong key (id_test3) unexpectedly accepted"
grep -q 'Permission denied (publickey)' "$TMP_DIR/us4_wrongkey.log" \
    || fail "wrong-key rejection did not surface 'Permission denied (publickey)'"

log "PASS"
