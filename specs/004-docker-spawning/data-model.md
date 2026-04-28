# Data Model: Docker Container Spawning from KroClaude

**Feature**: 004-docker-spawning
**Date**: 2026-04-28
**Spec**: [spec.md](spec.md)

This feature has no application data model in the conventional sense
(no records, no schema migrations). The "entities" below are
runtime resources whose identity, ownership, and lifecycle this
feature must manage.

---

## Entities

### `kroclaude-apps` Docker network

The shared user-defined bridge network that lets KroClaude resolve
spawned siblings by container name.

| Attribute | Value |
|-----------|-------|
| Name | `kroclaude-apps` (literal, hardcoded in compose and helpers) |
| Driver | `bridge` (default for `docker network create`) |
| Lifecycle owner | Operator (created once with `docker network create kroclaude-apps`; never destroyed by KroClaude). |
| Scope | Single Docker host. Not a swarm overlay. |
| Compose declaration | `external: true` in `docker-compose.yaml`. |
| First failure mode | If absent at compose-up time, `docker compose up` fails with `network kroclaude-apps declared as external, but could not be found` — surfaces the prerequisite cleanly. |

**Members**:

- KroClaude itself (attached via compose `networks: [default, kroclaude-apps]`).
- Every container spawned by `kc-run` (auto-attached by helper).

---

### Spawned sibling container

A Docker container created via `kc-run`. Identical to any
host-Docker container except for the labels and network membership
this feature enforces.

| Attribute | Value | Source |
|-----------|-------|--------|
| Name | User-supplied via `--name`, or auto-generated `kc-<slug>-<rand6>` | `kc-run` |
| Network | `kroclaude-apps` (default; `--network` overrides only with `--unsafe`) | `kc-run` |
| Label `kroclaude.managed` | `true` | `kc-run` |
| Label `kroclaude.created` | RFC3339 timestamp at spawn time | `kc-run` |
| Owner | The host's Docker daemon (visible to all daemon clients including Coolify) | host Docker |
| Lifecycle | Stopped & removed by `kc-stop`, by `--rm` exit, or by the operator out-of-band | mixed |

**Identity rule**: `kc-ps` and `kc-stop` filter strictly on
`label=kroclaude.managed=true`. A container without the label is
invisible to `kc-ps` and refused by `kc-stop`. This is the safety
boundary against operating on Coolify-managed or unrelated
containers.

---

### Docker socket bind-mount

| Attribute | Value |
|-----------|-------|
| Host path | `/var/run/docker.sock` |
| Container path | `/var/run/docker.sock` |
| Mode | rw (default) |
| Lifecycle | Compose-managed bind-mount; vanishes when container stops |
| GID source | Host filesystem (`stat -c %g /var/run/docker.sock` at entrypoint time) |

**Effect on container state**: at entrypoint, the GID owning this
socket determines which group `claude` is added to. See
[contracts/socket-group.md](contracts/socket-group.md).

---

## Environment variables

| Var | Purpose | Default | Set by | Read by |
|-----|---------|---------|--------|---------|
| `KROCLAUDE_PUBLIC_HOST` | Host portion of `kc-forward`'s printed `ssh -L … claude@<host>` command | (unset → literal `<host>` placeholder + warning) | Operator (`.env` or Coolify secret) | `kc-forward` |
| `KROCLAUDE_SSH_HOST_PORT` | Host port published for sshd (existing from feature 003) | `2221` | Operator | compose, `kc-forward` |

**No new secrets** are introduced. Both env vars are non-sensitive
deployment metadata.

---

## State transitions

### Spawned-sibling lifecycle

```text
                       ┌───────────────────┐
                       │   (no container)  │
                       └─────────┬─────────┘
                                 │ kc-run
                                 ▼
                       ┌───────────────────┐
                ┌──────│    Created+Run    │◄─────┐
                │      └─────────┬─────────┘      │
       kc-stop  │                │ exit (with --rm)
                │                ▼                │
                │      ┌───────────────────┐      │
                │      │      Removed      │──────┘
                │      └───────────────────┘
                │                ▲
                ▼                │ docker stop && docker rm
       ┌───────────────────┐    │
       │      Stopped      │────┘
       └───────────────────┘
```

`kc-stop` performs `docker stop` followed by `docker rm` (unless
`--keep` is passed). All transitions are idempotent — a second
`kc-stop` against an already-removed container is a no-op with
exit 0 and a single info line.

### Socket-group bootstrap (entrypoint)

```text
boot
  │
  ▼
[ /var/run/docker.sock present? ]──no──► log "[entrypoint] docker.sock not mounted"; continue
  │ yes
  ▼
SOCK_GID = stat -c %g /var/run/docker.sock
  │
  ▼
[ getent group $SOCK_GID exists? ]──no──► groupadd -g $SOCK_GID docker_host
  │ yes (group exists with that GID)
  ▼
GRP_NAME = name of group at SOCK_GID
  │
  ▼
[ claude already in $GRP_NAME? ]──yes──► (no-op)
  │ no
  ▼
usermod -aG $GRP_NAME claude
log "[entrypoint] claude added to group $GRP_NAME (gid $SOCK_GID)"
  │
  ▼
exec /init  (s6-overlay starts sshd, which sees fresh group membership)
```

---

## Validation rules

These translate spec FRs into invariants the helpers MUST enforce
at runtime.

| Rule | Helper(s) | Spec FR |
|------|-----------|---------|
| Spawned containers MUST carry `kroclaude.managed=true` | `kc-run` | FR-005 |
| Spawned containers MUST be on `kroclaude-apps` (unless `--unsafe --network=…`) | `kc-run` | FR-005 |
| `-p` / `--publish` flags refused before `docker run` | `kc-run` | FR-006 |
| Dangerous flags refused unless `--unsafe` | `kc-run` | FR-006a |
| `--unsafe` invocation MUST emit one stderr audit line | `kc-run` | FR-006b |
| `kc-ps` MUST filter strictly on `kroclaude.managed=true` | `kc-ps` | FR-007 |
| `kc-stop` MUST refuse unlabeled containers | `kc-stop` | FR-008 |
| `kc-forward` MUST verify resolution before printing | `kc-forward` | FR-009 |
| Socket-unreachable preflight MUST exit non-zero with one line | all `kc-*` | FR-010 |

---

## Out of model

- No persistent state owned by this feature. Helpers are stateless;
  the only persistent surface is the host Docker daemon's container
  list, which is accessed via labels (above).
- No data flow between sibling containers and KroClaude beyond
  ordinary Docker networking. No shared volumes, no IPC.
