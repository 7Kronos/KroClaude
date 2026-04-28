# Implementation Plan: Docker Container Spawning from KroClaude

**Branch**: `004-docker-spawning` | **Date**: 2026-04-28 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from [spec.md](spec.md)

## Summary

Add Docker-out-of-Docker (DooD) capability to the KroClaude image so the
`claude` user can launch sibling containers on the host's Docker daemon
from inside KroClaude. Three moving parts:

1. **Image**: install Docker's official client (`docker-ce-cli`,
   `docker-buildx-plugin`, `docker-compose-plugin`) from the
   `download.docker.com` Trixie repo. No daemon. Same keyring/apt
   pattern used for `gh` in feature 001.
2. **Runtime**: at entrypoint, before sshd starts, detect the GID of
   the bind-mounted `/var/run/docker.sock` and add `claude` to a
   matching group so SSH sessions inherit Docker access on first
   login. Compose bind-mounts the host socket and attaches the
   service to a dedicated external user-defined network
   `kroclaude-apps`.
3. **DX**: four short bash helpers in `/usr/local/bin/`: `kc-run`,
   `kc-ps`, `kc-stop`, `kc-forward`. They wrap `docker` with sane
   defaults (auto-attach to `kroclaude-apps`, `kroclaude.managed=true`
   labeling), block dangerous flags by default with a single
   `--unsafe` escape hatch (audit-logged), and produce ready-to-paste
   `ssh -L` commands using `KROCLAUDE_PUBLIC_HOST` (with graceful
   fallback when unset).

This feature **explicitly amends one prior decision** (feature 001
constitution principle "no privileged mode" still holds — DooD via
socket mount is NOT `privileged: true`, but the security trade-off
that the socket grants effective host-root is documented in spec
FR-014 and surfaced in `.env.example`).

## Technical Context

**Language/Version**: Bash 5.x for the four helper scripts and the
new entrypoint stanza; static text for compose / sshd / Dockerfile
additions.
**Primary Dependencies**: `docker-ce-cli`, `docker-buildx-plugin`,
`docker-compose-plugin` from `download.docker.com/linux/debian`
(trixie channel) — three new apt packages added to feature 001's
curated set. No daemon (`docker-ce`, `containerd.io` are explicitly
NOT installed). Helpers depend only on `docker`, `bash`, `getent`,
`stat`, `printf`, `date` — all already in the image.
**Storage**: re-uses the existing `kroclaude-config` named volume.
Docker client config (`~/.docker/config.json`, buildx state) lives
under `/home/claude/.docker/` which falls inside `/home/claude/.claude`'s
sibling `~/.docker`. No new volume needed; client cache is rebuilt
on demand. The shared Docker network `kroclaude-apps` is operator-
created (`docker network create kroclaude-apps`) and persists at the
host-Docker level, outside any compose volume.
**Testing**: a new `tests/smoke/test_us5.sh` covers all four user
stories (US1 spawn + cross-network resolve, US2 `kc-forward` output
shape with and without `KROCLAUDE_PUBLIC_HOST`, US3 inventory +
labeled-only stop, US4 graceful degrade when socket missing). The
test pre-creates `kroclaude-apps`, brings the stack up with the
socket mounted and an injected `KROCLAUDE_SSH_AUTHORIZED_KEY` reused
from feature 003's keygen helper, then asserts via `docker exec -u
claude` invocations.
**Target Platform**: same as features 001/002/003 — Linux Docker
host, multi-arch `linux/amd64` + `linux/arm64`. Docker's apt repo
ships both arches for trixie.
**Project Type**: extension to the existing deployment artifact.
**Performance Goals**: `kc-run` overhead under 200 ms over a raw
`docker run` (it's a thin bash wrapper); `kc-forward` under 100 ms
(single `getent hosts` + `printf`); first-boot bootstrap budget
from feature 001 (SC-003: <15 s) MUST still hold with the new
entrypoint stanza added.
**Constraints**: no `privileged: true`; no new `cap_add` or
`security_opt` entries (the existing feature-001 set is sufficient);
the socket bind-mount is the only new privileged-equivalent surface
and is documented as such (FR-014). The entrypoint stanza must run
under the existing `set -euo pipefail` posture without aborting when
the socket is absent (FR-011).
**Scale/Scope**: single-tenant per container; expected sibling
container count per developer session is single-digit, not a
horizontally scaled fleet. Helpers operate one container at a time;
no batch operations, no daemonized state.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Walking each principle from
[`.specify/memory/constitution.md`](../../.specify/memory/constitution.md)
v1.0.0:

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Reproducible Builds (NON-NEGOTIABLE) | ✅ | `docker-ce-cli`, `docker-buildx-plugin`, `docker-compose-plugin` installed via Docker's signed apt repo (GPG keyring written from `download.docker.com/linux/debian/gpg`). All four helper scripts are checked in. No network fetch at runtime. |
| II. Container-First Delivery | ✅ | One new optional env var (`KROCLAUDE_PUBLIC_HOST`) declared in compose; one new bind-mount (`/var/run/docker.sock`); one new external network (`kroclaude-apps`) declared in compose with a one-line `.env.example`-documented prerequisite. No out-of-band setup steps for required functionality (helpers degrade gracefully without the socket). |
| III. Curated Tooling, Lean Image | ✅ | Three new apt packages, all from a single signed repo. Combined image-size impact ≈ 80 MB compressed (well under the 10% trigger that requires explicit constitutional approval). Each package is justified: `docker-ce-cli` for FR-001, `docker-buildx-plugin` for image builds Claude may need, `docker-compose-plugin` for spawning multi-container dev fixtures. No overlap with existing tools. |
| IV. Coolify-Native Deployment | ✅ | Compose validates with `docker compose config`; no privileged mode; bind-mounting the host Docker socket is a documented Coolify-supported pattern (Coolify's own services use it). The external network is created via a one-time host command, documented as a Coolify "post-deployment command" in the quickstart. Healthchecks unchanged. |
| V. Stateless Container, Explicit Persistence | ✅ | No new container-internal state. Docker client config rebuilds itself on demand. The shared network is host-Docker state, outside any container volume. Spawned siblings are explicitly ephemeral developer workloads (per spec assumptions). |

**Result: PASS** — no Complexity Tracking entries needed.

Re-check after Phase 1 design: artifacts in `contracts/` ratify the
above choices without altering them. **Still PASS.**

## Project Structure

### Documentation (this feature)

```text
specs/004-docker-spawning/
├── plan.md              # This file
├── research.md          # Phase 0 — Docker-CLI install path, GID detection
├── data-model.md        # Phase 1 — managed-container, network, env vars
├── quickstart.md        # Phase 1 — operator + developer paths
├── contracts/
│   ├── kc-helpers.md            # CLI contract for kc-run/kc-ps/kc-stop/kc-forward
│   ├── compose-environment.md   # Compose volumes/networks/env diff
│   └── socket-group.md          # Entrypoint GID-detection contract
├── checklists/
│   └── requirements.md  # Already created by /speckit-specify
└── tasks.md             # Phase 2 output (/speckit-tasks)
```

### Source Code (repository root)

```text
Dockerfile                                # +Docker CLI install block, +COPY scripts/kc-*
docker-compose.yaml                       # +socket bind-mount, +KROCLAUDE_PUBLIC_HOST env, +networks
.env.example                              # +KROCLAUDE_PUBLIC_HOST docs, +network prereq note
CLAUDE.md                                 # +pointer to specs/004-docker-spawning/plan.md
scripts/
├── entrypoint.sh                         # +socket-GID detection stanza (before SSH host-keys)
├── kc-run                                # NEW
├── kc-ps                                 # NEW
├── kc-stop                               # NEW
└── kc-forward                            # NEW
tests/smoke/
└── test_us5.sh                           # NEW — see plan §Testing
.github/workflows/ci.yml                  # +invoke test_us5.sh
```

**Structure Decision**: same single-artifact deployment shape as
features 001/002/003. No new top-level directory; helpers live next
to the existing `entrypoint.sh` and are copied to `/usr/local/bin/`
by the same Dockerfile COPY pattern.

## Complexity Tracking

> No Constitution Check violations — section intentionally empty.
