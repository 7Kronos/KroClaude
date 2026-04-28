# Research: Docker Container Spawning from KroClaude

**Feature**: 004-docker-spawning
**Date**: 2026-04-28
**Spec**: [spec.md](spec.md)

This document records the technology and pattern choices made for this
feature. Decisions already locked by the user during planning
(DooD over DinD, SSH local port-forward, `--unsafe` flag posture,
`KROCLAUDE_PUBLIC_HOST` env var) are referenced briefly but not
re-litigated.

---

## R1 — Docker client install: official apt repo vs. Debian's `docker.io`

**Decision**: install `docker-ce-cli`, `docker-buildx-plugin`,
`docker-compose-plugin` from `download.docker.com/linux/debian`
(trixie channel), using the same keyring-then-apt block style used
for GitHub CLI in [Dockerfile:57-63](../../Dockerfile#L57-L63).

**Rationale**:

- Docker's official packages are versioned and signed by Docker Inc.,
  matching what Coolify itself uses — guarantees client/server
  compatibility against the host daemon.
- `docker-buildx-plugin` and `docker-compose-plugin` are first-class
  packages from the same repo; no separate install paths.
- The `docker.io` package from Debian main pulls the daemon
  (`containerd`, `runc`) as dependencies even when only the CLI is
  wanted. Debian also lags upstream by months.

**Alternatives considered**:

- `docker.io` (Debian main) — rejected: pulls unwanted daemon deps,
  outdated.
- Static binary download from `download.docker.com/linux/static/` —
  rejected: harder to verify (no signed apt metadata), no buildx
  plugin convenience.

---

## R2 — Granting `claude` access to the host Docker socket

**Decision**: detect the GID of `/var/run/docker.sock` at runtime in
`scripts/entrypoint.sh`. If a group with that GID does not exist in
the container, create one named `docker_host`. Add the `claude` user
to whatever group owns that GID (`usermod -aG`). This MUST run
before s6-overlay starts sshd, because `usermod -aG` only takes
effect for **future** logins.

**Rationale**:

- The host's `docker` group GID varies (Coolify hosts commonly use
  GID 999 or 998; some hosts use 281 or higher numbers). Hardcoding
  a GID into the image breaks portability.
- Detecting the GID at runtime, then mapping `claude` into it, is
  the canonical pattern used by official Docker-in-Docker images
  and most CI runners.
- Placing the stanza before sshd start is critical — SSH sessions
  read group membership at login, not at session use. If sshd starts
  first, the first SSH login won't see the new group until logout/
  re-login.

**Fallback**: the `claude` user already has NOPASSWD sudo (from
feature 001), so `sudo docker …` works as a safety net if group
membership somehow fails. The `kc-*` helpers' preflight check
covers both paths.

**Alternatives considered**:

- Static `groupadd -g 999 docker` at build time — rejected: GID
  collision risk on hosts where 999 is a different group.
- Always run helpers under `sudo docker` — rejected: noisier output,
  unnecessary `sudo` invocation per call, and breaks `docker compose`
  which expects a writable `~/.docker/`.

---

## R3 — Shared network strategy for sibling resolution

**Decision**: declare a user-defined bridge network named
`kroclaude-apps` as `external: true` in compose. The operator
creates it once with `docker network create kroclaude-apps` (a
documented Coolify post-deployment command). KroClaude attaches to
it (in addition to the default network) so the in-container Docker
DNS resolver can resolve sibling container names. Helpers default
spawned containers to the same network.

**Rationale**:

- SSH local-forward (`ssh -L localport:remotehost:remoteport
  user@server`) resolves `remotehost` on the SERVER side — i.e.,
  inside the KroClaude container. So KroClaude itself MUST be on the
  same Docker network as the target sibling, otherwise
  `<container-name>` won't resolve.
- `external: true` keeps the network alive across `docker compose
  down -v`, preventing accidental orphan-sibling situations.
- Using a dedicated network (instead of joining Coolify's `coolify`
  network) avoids collision with Coolify's service mesh and respects
  the constitution's tenant boundary.

**Alternatives considered**:

- Compose-managed (non-external) network — rejected: `compose down
  -v` deletes it, breaking spawned siblings.
- Join Coolify's existing network — rejected: couples this feature
  to Coolify-internal naming, breaks portability to bare Docker.
- Run spawned containers on `--network host` — rejected: defeats DNS-
  by-name and bypasses isolation entirely.

---

## R4 — Helper-script language and packaging

**Decision**: four POSIX-bash scripts in `scripts/kc-*`, copied to
`/usr/local/bin/` by Dockerfile `COPY scripts/kc-* /usr/local/bin/`,
made executable in the same `RUN chmod +x` block that already
handles `entrypoint.sh` and `notify.py`.

**Rationale**:

- The existing `entrypoint.sh` and `notify.py` set the precedent —
  small, focused scripts in `scripts/`, copied to `/usr/local/bin`.
- Bash has zero install footprint (already in the image), zero
  runtime startup cost, and is trivially auditable in a security-
  sensitive helper.
- `/usr/local/bin` is on PATH for SSH sessions
  ([Dockerfile:87](../../Dockerfile#L87)) so helpers are picked up
  without extra wiring.

**Alternatives considered**:

- Python — rejected: heavier startup, more dependencies to mock for
  the smoke test, no benefit for these short scripts.
- Single multi-command binary (Cobra-style) — rejected:
  over-engineered for four ~50-line scripts.

---

## R5 — `kc-run` flag-blocking implementation

**Decision** (implements spec FR-006a/FR-006b): parse `kc-run`'s
argv with a small bash loop. Maintain an explicit blocklist of
argument patterns:

```text
--privileged
--network=host        --network host
--pid=host            --pid host
--ipc=host            --ipc host
--uts=host            --uts host
--userns=host         --userns host
--cap-add=SYS_ADMIN   --cap-add SYS_ADMIN
-v <host-path>:…      --mount type=bind,source=<host-path>,…
                      (where <host-path> starts with `/` and is
                       NOT under /home/claude, /workspace, /tmp)
```

If `--unsafe` is present anywhere on the command line, the helper
strips it from argv, sets a `WAS_UNSAFE=1` flag, and skips the
blocklist check. Before `exec docker run …`, if `WAS_UNSAFE=1`,
emit a single audit line to stderr:

```text
[kc-run UNSAFE] 2026-04-28T14:23:11Z user=claude name=<name> allowed=<comma-list-of-blocked-flags>
```

**Rationale**:

- A bash-side blocklist is shallow but explicit. Deeper enforcement
  (seccomp profiles, OCI hooks) belongs at the daemon layer, not in
  a CLI wrapper.
- The blocklist is hand-curated and will not catch every footgun
  (e.g., `--device /dev/mem`). FR-014 already documents that the
  socket itself grants effective host-root, so this is defense-in-
  depth, not a security boundary.
- `--unsafe` as a single boolean keeps the API tiny and matches the
  precedent of `bwrap`'s `--no-int-fs-deny` style escape — clear
  opt-out, audit-logged.

**Alternatives considered**:

- Per-flag opt-ins (`--allow-privileged`, `--allow-host-mount`) —
  rejected during clarification: more API surface, no real safety
  benefit because the user is already host-root-equivalent.
- No blocking, document-only — rejected: leaves Claude Code able to
  trivially `kc-run --privileged` from a single misread instruction.

---

## R6 — `kc-forward` host-resolution flow

**Decision** (implements spec FR-009/FR-009a): `kc-forward
<container> <port> [local-port]` reads:

1. `KROCLAUDE_SSH_HOST_PORT` env var (default `2221`) — already
   plumbed by feature 003's compose.
2. `KROCLAUDE_PUBLIC_HOST` env var (no default) — new, plumbed by
   this feature's compose change.

If `KROCLAUDE_PUBLIC_HOST` is empty/unset, helper emits a warning
line to stderr then falls back to the literal `<host>` placeholder
in the printed command. Either way, before printing anything the
helper runs `getent hosts <container> >/dev/null` to verify in-
container DNS resolution; on failure it exits non-zero with a one-
line message.

**Rationale**:

- `KROCLAUDE_PUBLIC_HOST` is operator-supplied (the deployment URL).
  It cannot be auto-detected from inside the container reliably:
  `SSH_CLIENT` gives the user's IP, not the host's; `hostname` gives
  the container name; environment-supplied is the only honest source.
- Graceful fallback (per clarification) keeps the helper useful
  in fresh deployments where the operator hasn't set the var yet.

---

## R7 — Smoke-test integration approach

**Decision**: new file `tests/smoke/test_us5.sh` modeled on
[`tests/smoke/test_us4.sh`](../../tests/smoke/test_us4.sh) — same
`COMPOSE`, `wait_healthy`, `cleanup` trap, `log`/`fail` helpers.
Pre-create the `kroclaude-apps` network (idempotent), bring up the
stack, run the seven assertion phases listed in plan §Testing,
register cleanup of both the network and the spawned sibling.
Wire into `.github/workflows/ci.yml` next to the existing US1–US4
invocations.

**Rationale**: matches the precedent set by 001/002/003. Each
`test_usN.sh` corresponds to that feature's user stories. CI gating
on every Dockerfile/compose/entrypoint/script change is the
constitution's Build, Release & Workflow requirement.
