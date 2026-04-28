# Contract: Entrypoint Socket-Group Bootstrap

**Feature**: 004-docker-spawning
**Spec**: [../spec.md](../spec.md) · **Plan**: [../plan.md](../plan.md)

This is the authoritative contract for the new stanza added to
[`scripts/entrypoint.sh`](../../../scripts/entrypoint.sh). It
implements spec FR-002, FR-011 and the lifecycle diagram in
[../data-model.md](../data-model.md).

---

## Placement requirement

The stanza MUST be inserted **before** the existing SSH host-keys
block (around `scripts/entrypoint.sh:109`) and **after** the bundled-
skills block (around `scripts/entrypoint.sh:107`).

**Why placement matters**: `usermod -aG` only affects future logins.
sshd is started as part of `exec /init` at the bottom of the
entrypoint. If the stanza ran AFTER sshd started, the very first SSH
session of the boot would be missing the `docker` group. The placement
guarantees the group is in place before any process group can claim a
socket on port 2221.

---

## Stanza contract

### Pseudocode

```bash
DOCKER_SOCK=/var/run/docker.sock
if [ -S "$DOCKER_SOCK" ]; then
    SOCK_GID=$(stat -c '%g' "$DOCKER_SOCK")
    if ! getent group "$SOCK_GID" >/dev/null; then
        groupadd -g "$SOCK_GID" docker_host || true
    fi
    GRP_NAME=$(getent group "$SOCK_GID" | cut -d: -f1)
    if ! id -nG claude | tr ' ' '\n' | grep -qx "$GRP_NAME"; then
        usermod -aG "$GRP_NAME" claude
        echo "[entrypoint] claude added to group $GRP_NAME (gid $SOCK_GID) for docker.sock"
    fi
else
    echo "[entrypoint] docker.sock not mounted — kc-* helpers will warn at runtime" >&2
fi
```

### Invariants

| Invariant | How verified |
|-----------|--------------|
| MUST run under existing `set -euo pipefail` without aborting when socket is absent | `[ -S "$DOCKER_SOCK" ]` short-circuits; `groupadd … \|\| true` is the only failable side-step |
| MUST NOT create a new group if one already owns the target GID | `getent group "$SOCK_GID"` check |
| MUST NOT add `claude` to a group it's already in | `id -nG claude \| grep -qx` check |
| MUST emit exactly one log line per state change (added/skipped) | echo lines above |
| MUST execute before sshd's first listen | placement before SSH host-keys block |

---

## Test surface

The smoke test
[`tests/smoke/test_us5.sh`](../../../tests/smoke/test_us5.sh) MUST
verify both happy and degraded paths:

1. **Happy path**: bring up the stack with the socket bind-mount.
   Assert `docker exec -u claude kroclaude docker version` exits 0
   without `sudo` (proves group membership took effect for the SSH/
   exec session, which is what users hit).
2. **Degraded path**: bring up the stack with the socket bind-mount
   removed (override compose). Assert the entrypoint log contains
   the `docker.sock not mounted` warning, sshd still binds 2221,
   `claude --version` still works.

---

## What this contract does NOT cover

- The `kc-*` helpers' preflight is in
  [contracts/kc-helpers.md](kc-helpers.md). The entrypoint is only
  responsible for setting up group membership; if the socket is
  technically reachable but the GID doesn't match (or is in a group
  named differently than expected), the helpers' `sudo -n docker`
  fallback handles it.
- Image-build-time docker installation is in
  [the Dockerfile install block](../../../Dockerfile) and the
  R1 decision in [../research.md](../research.md). It is a separate
  contract from this runtime stanza.
