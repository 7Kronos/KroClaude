# Feature Specification: Docker Container Spawning from KroClaude

**Feature Branch**: `004-docker-spawning`
**Created**: 2026-04-28
**Status**: Draft
**Input**: User description: "what would be the best way to add docker
capabilities so we can launch containers from the kroclaude container?
For now we have this container in a coolify deployment that already
has docker capabilities. We have ssh access to that container (port
2221). I am wondering about the developer experience when a container
is up with a port with an app we want to test remotely. I would love
a smooth experience."

## Clarifications

### Session 2026-04-28

- Q: What host should `kc-forward` print in its `ssh -N -L … claude@<host>` output?
  → A: New env var `KROCLAUDE_PUBLIC_HOST`; when unset, fall back to literal
  `<host>` placeholder with a one-line warning suggesting the operator set it.
- Q: Should `kc-run` defensively block dangerous flags
  (`--privileged`, `-v /:/host`, `--pid=host`, `--cap-add=SYS_ADMIN`, etc.)?
  → A: Yes — hard-block by default. Allow opt-out via a single `--unsafe`
  flag that bypasses all blocks and emits a single audit log line.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Spawn a Sibling Container from Inside KroClaude (Priority: P1)

A developer (or Claude Code itself) inside the KroClaude container
needs to launch an arbitrary container — typically an application
image they are about to test or iterate on — without leaving the
KroClaude shell. They run a single helper command, name the container
or accept a generated name, and get back a running sibling container
that is reachable from inside KroClaude by name.

**Why this priority**: this is the core capability that everything
else in the feature depends on. With it, KroClaude becomes a true
ephemeral-container playground; without it, the developer has to
shell back to the host and break their flow.

**Independent Test**: from inside the KroClaude container, run
`kc-run -d --name demo nginx:alpine`, then `curl http://demo/` from
the same shell. Verify the curl returns the nginx welcome page.

**Acceptance Scenarios**:

1. **Given** the KroClaude container is running with the host Docker
   socket mounted, **When** the `claude` user runs `kc-run -d --name
   demo nginx:alpine`, **Then** a sibling container named `demo` is
   started, attached to the shared Docker network, and labeled as
   KroClaude-managed.
2. **Given** the sibling container `demo` is running, **When** the
   `claude` user runs `curl http://demo/` from inside KroClaude,
   **Then** the request reaches the sibling and returns successfully
   (HTTP 200).
3. **Given** the `claude` user runs `kc-run` without `--name`,
   **When** the container starts, **Then** an auto-generated name
   prefixed with `kc-` is assigned and printed.
4. **Given** the user attempts `kc-run -p 8080:80 nginx:alpine`,
   **When** the helper runs, **Then** the publish flag is rejected
   with a one-line message pointing at `kc-forward` as the supported
   alternative.
5. **Given** the user attempts `kc-run --privileged some/image`,
   **When** the helper runs, **Then** the request is refused with a
   one-line message naming the blocked flag and pointing at
   `--unsafe` as the documented escape hatch.
6. **Given** the user runs `kc-run --unsafe --privileged
   some/image`, **When** the helper runs, **Then** the container
   starts with the requested privileged capability and the helper
   emits a single audit-log line recording the unsafe invocation
   (container name, user, blocked flags allowed).

---

### User Story 2 — Reach a Spawned Container's App Port from a Laptop (Priority: P1)

A developer working from their laptop wants to open the web app
running inside a container they just spawned in KroClaude — for
example, a dev server on port 3000 — at `http://localhost:3000` in
their laptop browser, without configuring DNS, reverse proxies, or
public exposure of the host. They ask the helper for the right SSH
incantation, paste it into a terminal on the laptop, and the app is
reachable.

**Why this priority**: this is the "smooth developer experience" the
user explicitly asked for. Spawning a container is only useful if
testing it remotely is frictionless. Without this story, the user is
stuck reaching apps via raw `docker exec` curls or ad-hoc port
publishing on the host.

**Independent Test**: with `demo` running in KroClaude on port 80,
run `kc-forward demo 80 8080` inside KroClaude. Copy the printed
`ssh -L …` command, run it on a laptop, then open
`http://localhost:8080` in a browser and verify the nginx page
loads.

**Acceptance Scenarios**:

1. **Given** a sibling container `demo` reachable from KroClaude
   and `KROCLAUDE_PUBLIC_HOST=kroclaude.example.com` set in the
   environment, **When** the user runs `kc-forward demo 80 8080`,
   **Then** the helper prints exactly one line of the form
   `ssh -N -L 8080:demo:80 -p <host-ssh-port>
   claude@kroclaude.example.com` ready to paste into a laptop
   terminal.
2. **Given** the user runs the printed `ssh -L` command on their
   laptop, **When** they open `http://localhost:8080`, **Then** the
   request is forwarded through the SSH tunnel to KroClaude, then to
   the sibling container, and returns the app's response.
3. **Given** the user requests forwarding for a container that is
   not on the shared Docker network (or does not exist), **When**
   `kc-forward` runs, **Then** it fails fast with a one-line
   actionable error before printing any `ssh` command.
4. **Given** the operator has overridden the host SSH port via the
   existing `KROCLAUDE_SSH_HOST_PORT` env var, **When** `kc-forward`
   runs, **Then** the printed command uses that overridden port.
5. **Given** `KROCLAUDE_PUBLIC_HOST` is unset, **When** the user
   runs `kc-forward demo 80 8080`, **Then** the helper still prints
   a usable command with the literal placeholder `<host>` for the
   user to substitute, prefixed by a one-line warning recommending
   the operator set `KROCLAUDE_PUBLIC_HOST`.

---

### User Story 3 — Inventory and Clean Up Spawned Containers (Priority: P2)

After a few iterations the developer has several KroClaude-spawned
containers running and wants to see only their own KroClaude-managed
containers (not unrelated containers on the host) and stop a
specific one when done.

**Why this priority**: keeps the host tidy and prevents the
developer from accidentally interacting with unrelated containers
managed by Coolify or other tenants on the same host.

**Independent Test**: spawn three named containers via `kc-run`,
then run `kc-ps` and confirm only those three appear. Run `kc-stop
<name>` and confirm the container is stopped/removed and disappears
from `kc-ps`.

**Acceptance Scenarios**:

1. **Given** three KroClaude-managed containers and one unrelated
   host container exist, **When** the user runs `kc-ps`, **Then**
   only the three KroClaude-managed containers are listed.
2. **Given** a KroClaude-managed container `demo` is running,
   **When** the user runs `kc-stop demo`, **Then** the container is
   stopped and (by default) removed.
3. **Given** an unrelated host container `coolify-redis` exists,
   **When** the user runs `kc-stop coolify-redis`, **Then** the
   helper refuses with a one-line message and does not touch the
   container.

---

### User Story 4 — Graceful Behavior When Docker Is Not Available (Priority: P2)

A user (or operator) brings up KroClaude in an environment where the
host Docker socket is intentionally not mounted — for example, on a
local laptop running just `docker compose up` without the socket
mount, or on a host with no Docker at all. The container must still
boot fully and offer its existing functionality (Claude Code shell,
SSH access, browser automation) — and the `kc-*` helpers must
explain why they cannot work, rather than crashing.

**Why this priority**: KroClaude has three other features
(`001-claude-shell-base`, `002-skill-bundling`, `003-ssh-access`)
that must keep working unchanged when this feature's optional
dependency is absent.

**Independent Test**: bring up the stack with the
`/var/run/docker.sock` bind-mount removed; SSH in; run `kc-run
hello-world` and observe the actionable error; run `claude
--version` and verify it still works.

**Acceptance Scenarios**:

1. **Given** KroClaude is started without the docker socket
   mounted, **When** the container boots, **Then** the entrypoint
   logs a single warning and the supervisor starts sshd normally.
2. **Given** the same conditions, **When** the user runs `kc-run`,
   `kc-ps`, `kc-stop`, or `kc-forward`, **Then** each helper prints
   one actionable line explaining the socket is missing and exits
   non-zero, with no stack trace.
3. **Given** the same conditions, **When** the user uses Claude
   Code, SSH, or the browser automation stack, **Then** all of them
   work exactly as in feature 003.

---

### Edge Cases

- The host's docker group GID does not match any in-container
  group: a new group is created at runtime to match.
- The host's docker group GID collides with an existing in-container
  group (e.g. GID 999 is `systemd-journal`): the `claude` user is
  added to whatever group already owns that GID; no duplicate group
  is created. Cosmetic side effect only.
- The shared Docker network does not exist when KroClaude starts:
  attaching the service fails fast at compose time with a clear
  message, prompting the operator to run the documented one-time
  network-create command.
- A spawned container with an explicit `--name` collides with an
  existing container of the same name: Docker's native error is
  surfaced verbatim — `kc-run` does not silently overwrite.
- The user passes `-p`/`--publish` to `kc-run`: the flag is rejected
  before the container is created.
- The user passes a hard-blocked dangerous flag (`--privileged`,
  `-v /:/host` and similar host-path mounts, `--pid=host`,
  `--network=host`, `--ipc=host`, `--uts=host`, `--userns=host`,
  `--cap-add=SYS_ADMIN`, etc.): `kc-run` refuses with a one-line
  message naming the offending flag and pointing at `--unsafe`.
- The user passes `--unsafe` along with one or more dangerous
  flags: the container starts and the helper writes a single
  audit line capturing the invocation.
- The host SSH port has been remapped (operator set
  `KROCLAUDE_SSH_HOST_PORT=2222` or similar): `kc-forward` reflects
  the override.
- `KROCLAUDE_PUBLIC_HOST` is unset: `kc-forward` falls back to the
  literal `<host>` placeholder and emits one warning line.
- The `claude` user is in the host docker group but the socket is
  unreachable (e.g. permissions misconfiguration): `kc-*` helpers
  fall back to `sudo docker` (NOPASSWD already configured) so the
  workflow still works.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The image MUST include a Docker client capable of
  managing containers, builds, and compose stacks against an
  externally-provided Docker daemon. No daemon runs inside the
  container.
- **FR-002**: The runtime entrypoint MUST detect the group ID of
  the mounted Docker socket and grant the `claude` user membership
  in a matching group **before** the SSH server begins accepting
  connections, so SSH sessions inherit the correct group on first
  login.
- **FR-003**: The container orchestration definition (compose) MUST
  bind-mount the host Docker socket at `/var/run/docker.sock` and
  attach the KroClaude service to a dedicated shared Docker network
  named `kroclaude-apps`, in addition to the default network.
- **FR-004**: The shared `kroclaude-apps` network MUST be declared
  as externally-managed so it survives `docker compose down -v` and
  does not collide with networks managed by Coolify itself.
- **FR-005**: A helper command `kc-run` MUST wrap container creation
  such that, by default, every spawned container is attached to
  `kroclaude-apps` and is labeled `kroclaude.managed=true` and
  `kroclaude.created=<RFC3339 timestamp>`. When no name is given,
  an auto-generated `kc-<slug>-<rand>` name MUST be assigned and
  printed.
- **FR-006**: `kc-run` MUST reject `-p` and `--publish` flags with
  a single guidance line directing the user to `kc-forward` as the
  supported access pattern.
- **FR-006a**: `kc-run` MUST hard-block dangerous Docker flags by
  default and refuse to invoke `docker run` when any are present.
  The minimum blocked set is: `--privileged`, host-path bind mounts
  via `-v` / `--mount` (any source path beginning with `/` outside
  `/home/claude`, `/workspace`, `/tmp`), `--network=host`,
  `--pid=host`, `--ipc=host`, `--uts=host`, `--userns=host`, and
  `--cap-add=SYS_ADMIN`. Refusal output MUST be a single line
  naming the offending flag and pointing at `--unsafe`.
- **FR-006b**: `kc-run` MUST accept a single `--unsafe` flag that
  bypasses every block introduced by FR-006a. When `--unsafe` is
  used, the helper MUST emit exactly one audit-log line to stderr
  recording: timestamp (RFC3339), invoking user, container name,
  and the list of dangerous flags that were allowed.
- **FR-007**: A helper command `kc-ps` MUST list only containers
  carrying the `kroclaude.managed=true` label.
- **FR-008**: A helper command `kc-stop` MUST refuse to operate on
  any container that does not carry the `kroclaude.managed=true`
  label, and MUST stop and (by default) remove the target.
- **FR-009**: A helper command `kc-forward` MUST verify the target
  container is resolvable by the in-container DNS resolver before
  printing anything, and MUST print exactly one line of the form
  `ssh -N -L <local>:<container>:<port> -p
  <KROCLAUDE_SSH_HOST_PORT> claude@<KROCLAUDE_PUBLIC_HOST>`. The
  host SSH port MUST default to `2221` and MUST honor the existing
  `KROCLAUDE_SSH_HOST_PORT` env var. The remote host MUST be read
  from a new `KROCLAUDE_PUBLIC_HOST` env var (see FR-009a).
- **FR-009a**: A new optional env var `KROCLAUDE_PUBLIC_HOST` MUST
  be plumbed through compose into the container environment, used
  exclusively to populate the `<host>` portion of `kc-forward`
  output. When the var is unset or empty, `kc-forward` MUST emit
  the literal placeholder `<host>` in the printed `ssh` command and
  precede it with a single warning line of the form
  `[kc-forward] KROCLAUDE_PUBLIC_HOST is unset; substitute <host>
  with your deployment URL or set the env var`.
- **FR-010**: All `kc-*` helpers MUST preflight-check Docker
  reachability and emit a single actionable line if the socket is
  unavailable, exiting non-zero. They MUST NOT print stack traces
  or partial multi-line errors.
- **FR-011**: If the Docker socket is not mounted at boot, the
  entrypoint MUST log a single warning and continue. SSH and all
  other supervised services MUST start normally. The
  `set -euo pipefail` posture of the entrypoint MUST be preserved.
- **FR-012**: A smoke test (`tests/smoke/test_us5.sh`, named to
  match the existing US-numbered test suite) MUST verify, end-to-
  end: docker CLI is callable as `claude` without sudo, a sibling
  container can be spawned via `kc-run`, the sibling is reachable
  by name from KroClaude over HTTP, `kc-forward` produces the
  documented output (with and without `KROCLAUDE_PUBLIC_HOST`
  set), and `kc-run --privileged` is refused by default but
  allowed under `--unsafe`. The smoke test MUST be wired into the
  CI workflow alongside the existing US1–US4 smoke tests.
- **FR-013**: The one-time `docker network create kroclaude-apps`
  prerequisite MUST be documented in `.env.example` and the
  feature's quickstart, sufficient for an operator to set up a
  fresh Coolify deployment without reading the spec. The optional
  `KROCLAUDE_PUBLIC_HOST` env var (FR-009a) MUST also be documented
  in `.env.example` near the SSH section.
- **FR-014**: The security trade-off — that mounting the host
  Docker socket grants effective host-root to anyone able to write
  to it, and that combined with the existing NOPASSWD sudo this
  makes the `claude` user host-root-equivalent — MUST be stated
  prominently in the spec and surfaced in `.env.example`.

### Key Entities

- **Spawned container (`kc-run` output)**: A sibling container on
  the host's Docker daemon. Always carries the
  `kroclaude.managed=true` and `kroclaude.created=<RFC3339>` labels.
  Always attached to the `kroclaude-apps` network. Owned by the
  same Docker daemon as KroClaude itself; visible to host operators
  via standard `docker` commands.
- **`kroclaude-apps` network**: A user-defined bridge network shared
  by KroClaude and every container spawned via `kc-run`. Its
  lifecycle is owned by the operator (created once, never
  destroyed by `compose down`).
- **Docker socket bind-mount**: The `/var/run/docker.sock` UNIX
  socket from the host, mounted read-write into KroClaude. Its
  group ownership at runtime determines which in-container group
  the `claude` user is added to at entrypoint time.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From inside KroClaude, a developer can spawn a sibling
  container, reach its app port from their laptop browser, and tear
  it down using only commands shipped in this feature — in under 60
  seconds end-to-end on a typical Coolify host.
- **SC-002**: 100% of containers spawned via `kc-run` are visible
  to `kc-ps` and 0% of unrelated host containers (Coolify-managed,
  test fixtures, etc.) appear in `kc-ps` output.
- **SC-003**: When the Docker socket is not mounted, all four
  `kc-*` helpers exit non-zero with a single-line actionable error,
  and 100% of pre-existing functionality (Claude Code, SSH,
  browser automation, skills) continues to work as in feature 003.
- **SC-004**: A new operator can complete the one-time `kroclaude-
  apps` network setup using only the `.env.example` and quickstart,
  without consulting the full spec.
- **SC-005**: The end-to-end smoke test (`test_us5.sh`) runs in
  CI on every change to the Dockerfile, entrypoint, compose file,
  or `kc-*` helpers, and is gating on PR merges. Runtime is
  observational, not budgeted.

## Assumptions

- The deployment target host (Coolify or any other) already has a
  working Docker daemon with the standard UNIX socket at
  `/var/run/docker.sock`.
- The operator has shell access to the host once, sufficient to run
  `docker network create kroclaude-apps` (or has Coolify configured
  to run that as a post-deploy command). The lifecycle of that
  network is operator-owned, not KroClaude-owned.
- The `claude` user's existing NOPASSWD sudo posture (from feature
  001) is acceptable as a fallback path for `kc-*` helpers when
  group-based socket access fails. This is consistent with the
  project's existing security model.
- SSH access (feature 003) is the only intended remote interaction
  point. No new public ports are added by this feature.
- `KROCLAUDE_PUBLIC_HOST` is operator-supplied (the deployment URL
  used to reach KroClaude over SSH from a developer laptop). It is
  optional; when absent, `kc-forward` degrades gracefully.
- Spawned sibling containers are intended to be ephemeral developer
  workloads. Long-running production workloads, multi-tenant
  isolation between siblings, and orchestration concerns
  (auto-restart, health gating, log aggregation) are out of scope.
- True nested Docker-in-Docker (running a daemon inside KroClaude
  with `--privileged`) is explicitly out of scope. Coolify's host-
  level Docker daemon is reused via the socket mount.
- Coolify Traefik label automation, Cloudflare/ngrok tunnels, and
  any host-port publishing workflow are out of scope. SSH local
  port-forwarding is the single supported access pattern.
