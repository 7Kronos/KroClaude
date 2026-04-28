# Contract: Compose Environment Diff

**Feature**: 004-docker-spawning
**Spec**: [../spec.md](../spec.md) · **Plan**: [../plan.md](../plan.md)

This is the authoritative diff that `docker-compose.yaml` and
`.env.example` MUST satisfy after this feature lands. It builds on
[feature 001's compose-environment contract](../../001-claude-shell-base/contracts/compose-environment.md)
and feature 003's SSH additions.

---

## `docker-compose.yaml` additions

### 1. New volume mount (under `services.kroclaude.volumes`)

```yaml
- /var/run/docker.sock:/var/run/docker.sock
```

- Source path: literal `/var/run/docker.sock` on the host.
- Target path: literal `/var/run/docker.sock` in the container.
- Mode: read-write (default). Read-only is INSUFFICIENT — `docker
  run` writes to the socket.

### 2. New environment variable (under `services.kroclaude.environment`)

```yaml
KROCLAUDE_PUBLIC_HOST: "${KROCLAUDE_PUBLIC_HOST:-}"
```

Empty string when unset is the documented graceful-degrade signal
for `kc-forward` (see contracts/kc-helpers.md).

### 3. Network attachment (under `services.kroclaude`)

```yaml
networks:
  - default
  - kroclaude-apps
```

The `default` entry preserves the implicit network from before this
feature. `kroclaude-apps` is the new shared network.

### 4. Top-level `networks:` block

```yaml
networks:
  kroclaude-apps:
    name: kroclaude-apps
    external: true
```

`external: true` requires the operator to pre-create the network
once with `docker network create kroclaude-apps`. This is documented
in the quickstart and `.env.example`.

---

## `.env.example` additions

Append after the SSH section added by feature 003:

```dotenv
# === Feature 004 — Docker container spawning ===========================
# Public hostname used by `kc-forward` to print a ready-to-paste
# `ssh -L` command. Optional. When unset, `kc-forward` substitutes
# the literal placeholder `<host>` and prints a one-line warning.
# KROCLAUDE_PUBLIC_HOST=kroclaude.example.com
#
# PREREQUISITE (one-time, on the host):
#   docker network create kroclaude-apps
# This network is declared `external: true` in docker-compose.yaml so
# that `docker compose down -v` does not delete it and orphan any
# spawned sibling containers.
#
# SECURITY: bind-mounting /var/run/docker.sock grants effective
# host-root to anyone who can write to it. Combined with feature 001's
# NOPASSWD sudo for the `claude` user, this means SSH-authorized
# users are host-root-equivalent. Mitigation: SSH is key-only and
# claude-only (feature 003).
```

---

## What this feature does NOT change

- No new published port. Spawned siblings are reached via SSH local
  port-forward through the existing `2221` (feature 003).
- No new persistent volume. Docker client config rebuilds on demand.
- No `cap_add`, `security_opt`, or `privileged` changes. Existing
  feature 001 set is sufficient.
- The healthcheck from feature 001/003 is unchanged. It does NOT
  probe Docker availability — Docker is an optional capability.

---

## Validation

`docker compose config` MUST succeed. The smoke test
[`tests/smoke/test_us5.sh`](../../../tests/smoke/test_us5.sh) MUST
fail loudly if any of the four additions above is missing.
