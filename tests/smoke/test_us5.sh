#!/bin/bash
# tests/smoke/test_us5.sh — feature 004-docker-spawning US1+US2+US3+US4.
# Run from repo root.
#
# Asserts:
#   US1 — kc-run spawns a sibling on kroclaude-apps; KroClaude can curl
#         it by name; -p / dangerous flags refused; --unsafe bypass works
#         and emits the audit log line.
#   US2 — kc-forward prints the documented `ssh -L` line, with and
#         without KROCLAUDE_PUBLIC_HOST; non-resolvable target rejected.
#   US3 — kc-ps lists ONLY managed containers; kc-stop refuses unlabeled
#         and is idempotent on already-removed targets.
#   US4 — graceful degrade: stack without socket bind-mount still boots,
#         sshd works, claude works, kc-* helpers exit 2 with one-line
#         error.
set -euo pipefail

: "${COMPOSE:=docker compose}"
SVC=kroclaude
export COMPOSE_PROJECT_NAME=kroclaude

NET=kroclaude-apps
NOSOCK_PROJECT=kroclaude-nosock
NOSOCK_SVC=kroclaude-nosock

TMP_DIR=$(mktemp -d)

log()  { printf '\n[us5] %s\n' "$*"; }
fail() { printf '[us5] FAIL: %s\n' "$*" >&2; $COMPOSE logs --no-color $SVC || true; exit 1; }

wait_healthy() {
    local svc=${1:-$SVC}
    for i in $(seq 1 60); do
        s=$(docker inspect --format '{{.State.Health.Status}}' "$svc" 2>/dev/null || echo starting)
        [ "$s" = "healthy" ] && return 0
        sleep 1
    done
    fail "container $svc did not reach healthy in 60s"
}

cleanup() {
    docker rm -f kc-smoke-nginx kc-smoke-priv kc-us3-a kc-us3-b kc-us3-foreign kc-autoname >/dev/null 2>&1 || true
    $COMPOSE down --remove-orphans -v >/dev/null 2>&1 || true
    COMPOSE_PROJECT_NAME=$NOSOCK_PROJECT \
        $COMPOSE -f docker-compose.yaml -f tests/smoke/no-socket.override.yaml \
        down --remove-orphans -v >/dev/null 2>&1 || true
    # kroclaude-apps is an operator-managed external network shared with
    # downstream smokes (US6 etc.); leave it in place.
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Pre-create the shared external network (idempotent).
log "Pre-creating Docker network $NET"
docker network create "$NET" >/dev/null 2>&1 || true

# Reuse the US4 keygen pattern for SSH access (the entrypoint requires
# at least one valid key for sshd to be useful, though we don't ssh in
# this test — docker exec is enough).
ssh-keygen -t ed25519 -N '' -f "$TMP_DIR/id_us5" -q

# ============================================================================
# Phase 0 — Bring the stack up with the socket mounted.
# ============================================================================

log "Bringing stack up (with /var/run/docker.sock bind-mount)"
KROCLAUDE_SSH_AUTHORIZED_KEY="$(cat "$TMP_DIR/id_us5.pub")" \
    $COMPOSE up -d --build --force-recreate
wait_healthy

# ============================================================================
# Phase 1 — US1: spawn sibling, label, network, cross-network HTTP reach
# ============================================================================

log "Scenario US1 — docker CLI works as claude WITHOUT sudo (entrypoint group bootstrap)"
docker exec -u claude $SVC docker version --format '{{.Client.Version}}' >/dev/null \
    || fail "claude cannot run docker without sudo — entrypoint GID bootstrap broken"

log "Scenario US1 — kc-run spawns labeled container on kroclaude-apps"
docker exec -u claude $SVC kc-run -d --rm --name kc-smoke-nginx nginx:alpine >/dev/null \
    || fail "kc-run failed to spawn kc-smoke-nginx"

managed=$(docker inspect --format '{{ index .Config.Labels "kroclaude.managed" }}' kc-smoke-nginx)
[ "$managed" = "true" ] \
    || fail "kc-smoke-nginx missing kroclaude.managed=true label (got '$managed')"

nets=$(docker inspect --format '{{ json .NetworkSettings.Networks }}' kc-smoke-nginx)
echo "$nets" | grep -q 'kroclaude-apps' \
    || fail "kc-smoke-nginx not attached to kroclaude-apps (networks: $nets)"

# Allow nginx a brief moment to start listening.
for i in $(seq 1 10); do
    if docker exec -u claude $SVC curl -fsS http://kc-smoke-nginx/ >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
docker exec -u claude $SVC curl -fsS http://kc-smoke-nginx/ \
    | head -1 | grep -q '<!DOCTYPE html>' \
    || fail "KroClaude could not reach kc-smoke-nginx by name on kroclaude-apps"

log "Scenario US1 — kc-run auto-generates kc-<slug>-<rand6> name when --name omitted"
auto_out=$(docker exec -u claude $SVC kc-run -d --rm nginx:alpine 2>&1)
auto_name=$(printf '%s' "$auto_out" | grep -oE 'kc-[a-z]+-[a-f0-9]{6}' | head -1)
[ -n "$auto_name" ] \
    || fail "kc-run did not print an auto-generated name; output: $auto_out"
docker exec -u claude $SVC kc-stop "$auto_name" >/dev/null 2>&1 || \
    docker rm -f "$auto_name" >/dev/null 2>&1 || true

log "Scenario US1 — kc-run rejects -p / --publish (FR-006)"
set +e
docker exec -u claude $SVC kc-run -p 8080:80 nginx:alpine >"$TMP_DIR/us1_p.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "kc-run -p exit code was $rc, expected 3"
grep -q 'kc-forward' "$TMP_DIR/us1_p.log" \
    || fail "kc-run -p refusal did not point at kc-forward (got: $(cat "$TMP_DIR/us1_p.log"))"

log "Scenario US1 — kc-run hard-blocks --privileged without --unsafe (FR-006a)"
set +e
docker exec -u claude $SVC kc-run --privileged nginx:alpine >"$TMP_DIR/us1_priv.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "kc-run --privileged exit code was $rc, expected 3"
grep -q 'unsafe' "$TMP_DIR/us1_priv.log" \
    || fail "kc-run --privileged refusal did not mention --unsafe (got: $(cat "$TMP_DIR/us1_priv.log"))"

log "Scenario US1 — kc-run --unsafe --privileged succeeds and emits audit line (FR-006b)"
docker exec -u claude $SVC kc-run --unsafe --privileged -d --rm --name kc-smoke-priv nginx:alpine \
    >"$TMP_DIR/us1_unsafe.out" 2>"$TMP_DIR/us1_unsafe.err" \
    || fail "kc-run --unsafe --privileged failed unexpectedly"
grep -q '\[kc-run UNSAFE\]' "$TMP_DIR/us1_unsafe.err" \
    || fail "kc-run --unsafe did not emit audit line (stderr: $(cat "$TMP_DIR/us1_unsafe.err"))"
docker rm -f kc-smoke-priv >/dev/null 2>&1 || true

# Leave kc-smoke-nginx running for US2 (kc-forward needs a resolvable target).

log "US1 PASS"

# ============================================================================
# Phase 2 — US2: kc-forward output shape (with and without KROCLAUDE_PUBLIC_HOST)
# ============================================================================

log "Scenario US2 — kc-forward without KROCLAUDE_PUBLIC_HOST emits warning + <host> placeholder"
docker exec -u claude $SVC kc-forward kc-smoke-nginx 80 8080 \
    >"$TMP_DIR/us2_unset.out" 2>"$TMP_DIR/us2_unset.err" \
    || fail "kc-forward (unset host) returned non-zero unexpectedly"
grep -q 'KROCLAUDE_PUBLIC_HOST is unset' "$TMP_DIR/us2_unset.err" \
    || fail "kc-forward (unset host) missing warning (stderr: $(cat "$TMP_DIR/us2_unset.err"))"
grep -qE '^ssh -N -L 8080:kc-smoke-nginx:80 -p 2221 claude@<host>$' "$TMP_DIR/us2_unset.out" \
    || fail "kc-forward (unset host) stdout malformed: $(cat "$TMP_DIR/us2_unset.out")"

log "Scenario US2 — kc-forward with KROCLAUDE_PUBLIC_HOST set produces clean output"
docker exec -u claude -e KROCLAUDE_PUBLIC_HOST=kroclaude.example.test $SVC \
    kc-forward kc-smoke-nginx 80 8080 \
    >"$TMP_DIR/us2_set.out" 2>"$TMP_DIR/us2_set.err" \
    || fail "kc-forward (set host) returned non-zero unexpectedly"
[ ! -s "$TMP_DIR/us2_set.err" ] \
    || fail "kc-forward (set host) emitted unexpected stderr: $(cat "$TMP_DIR/us2_set.err")"
grep -qE '^ssh -N -L 8080:kc-smoke-nginx:80 -p 2221 claude@kroclaude\.example\.test$' \
    "$TMP_DIR/us2_set.out" \
    || fail "kc-forward (set host) stdout malformed: $(cat "$TMP_DIR/us2_set.out")"

log "Scenario US2 — kc-forward refuses unresolvable container (FR-009)"
set +e
docker exec -u claude $SVC kc-forward nonexistent-container 80 \
    >"$TMP_DIR/us2_bad.out" 2>"$TMP_DIR/us2_bad.err"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "kc-forward unresolvable exit code was $rc, expected 3"
grep -q 'cannot resolve container' "$TMP_DIR/us2_bad.err" \
    || fail "kc-forward unresolvable did not emit cannot-resolve message (stderr: $(cat "$TMP_DIR/us2_bad.err"))"

log "Scenario US2 — kc-forward honors KROCLAUDE_SSH_HOST_PORT override"
docker exec -u claude -e KROCLAUDE_SSH_HOST_PORT=2222 -e KROCLAUDE_PUBLIC_HOST=h $SVC \
    kc-forward kc-smoke-nginx 80 8080 >"$TMP_DIR/us2_port.out" 2>/dev/null
grep -qE '^ssh -N -L 8080:kc-smoke-nginx:80 -p 2222 claude@h$' "$TMP_DIR/us2_port.out" \
    || fail "kc-forward did not honor KROCLAUDE_SSH_HOST_PORT (got: $(cat "$TMP_DIR/us2_port.out"))"

# Cleanup the US1/US2 shared fixture.
docker rm -f kc-smoke-nginx >/dev/null 2>&1 || true

log "US2 PASS"

# ============================================================================
# Phase 3 — US3: kc-ps label-only filter, kc-stop label refusal + idempotency
# ============================================================================

log "Scenario US3 — spawn two managed siblings + one unlabeled sibling"
docker exec -u claude $SVC kc-run -d --rm --name kc-us3-a nginx:alpine >/dev/null
docker exec -u claude $SVC kc-run -d --rm --name kc-us3-b nginx:alpine >/dev/null
docker run -d --rm --network kroclaude-apps --name kc-us3-foreign nginx:alpine >/dev/null

log "Scenario US3 — kc-ps lists ONLY KroClaude-managed containers (FR-007)"
ps_out=$(docker exec -u claude $SVC kc-ps)
echo "$ps_out" | grep -q kc-us3-a   || fail "kc-ps missing kc-us3-a (got: $ps_out)"
echo "$ps_out" | grep -q kc-us3-b   || fail "kc-ps missing kc-us3-b (got: $ps_out)"
if echo "$ps_out" | grep -q kc-us3-foreign; then
    fail "kc-ps included unlabeled container kc-us3-foreign (got: $ps_out)"
fi

log "Scenario US3 — kc-stop refuses unlabeled container (FR-008)"
set +e
docker exec -u claude $SVC kc-stop kc-us3-foreign >"$TMP_DIR/us3_foreign.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "kc-stop on unlabeled container exit was $rc, expected 3"
grep -q 'not a KroClaude-managed container' "$TMP_DIR/us3_foreign.log" \
    || fail "kc-stop refusal message wrong (got: $(cat "$TMP_DIR/us3_foreign.log"))"

log "Scenario US3 — kc-stop on managed container succeeds"
docker exec -u claude $SVC kc-stop kc-us3-a >/dev/null \
    || fail "kc-stop kc-us3-a failed unexpectedly"

log "Scenario US3 — kc-stop is idempotent on already-removed targets"
docker exec -u claude $SVC kc-stop kc-us3-a >"$TMP_DIR/us3_idem.log" 2>&1 \
    || fail "second kc-stop kc-us3-a failed (should be idempotent)"
grep -q 'already removed' "$TMP_DIR/us3_idem.log" \
    || fail "second kc-stop did not report 'already removed' (got: $(cat "$TMP_DIR/us3_idem.log"))"

# Manual cleanup of remaining containers (raw docker for the unlabeled one).
docker rm -f kc-us3-b kc-us3-foreign >/dev/null 2>&1 || true

log "US3 PASS"

# ============================================================================
# Phase 4 — US4: graceful degrade when /var/run/docker.sock is NOT mounted
# ============================================================================

log "Scenario US4 — bring up parallel 'nosock' stack without the docker socket"
COMPOSE_PROJECT_NAME=$NOSOCK_PROJECT \
KROCLAUDE_SSH_AUTHORIZED_KEY="$(cat "$TMP_DIR/id_us5.pub")" \
    $COMPOSE -f docker-compose.yaml -f tests/smoke/no-socket.override.yaml \
    up -d --force-recreate

# wait_healthy targets the main $SVC by default; pass the nosock name.
wait_healthy "$NOSOCK_SVC"

log "Scenario US4 — entrypoint logged the 'docker.sock not mounted' warning"
docker logs "$NOSOCK_SVC" 2>&1 | grep -q 'docker.sock not mounted' \
    || fail "entrypoint warning missing in $NOSOCK_SVC logs"

log "Scenario US4 — kc-run exits 2 with one-line socket-unavailable error"
set +e
docker exec -u claude "$NOSOCK_SVC" kc-run hello-world >"$TMP_DIR/us4_kc.out" 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "kc-run on nosock exit was $rc, expected 2"
grep -q 'docker.sock not available' "$TMP_DIR/us4_kc.out" \
    || fail "kc-run nosock error message wrong (got: $(cat "$TMP_DIR/us4_kc.out"))"
[ "$(wc -l < "$TMP_DIR/us4_kc.out")" -le 1 ] \
    || fail "kc-run nosock printed more than one line (got $(wc -l < "$TMP_DIR/us4_kc.out"))"

log "Scenario US4 — claude --version still works in the degraded stack"
docker exec -u claude "$NOSOCK_SVC" claude --version >/dev/null \
    || fail "claude --version failed in nosock stack — feature 003 regressed"

log "Scenario US4 — ssh client still present (proves SSH stack intact)"
docker exec -u claude "$NOSOCK_SVC" ssh -V >/dev/null 2>&1 \
    || fail "ssh -V failed in nosock stack"

log "US4 PASS"

log "ALL PHASES PASS"
