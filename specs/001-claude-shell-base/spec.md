# Feature Specification: Claude Code Shell Base Image

**Feature Branch**: `001-claude-shell-base`
**Created**: 2026-04-27
**Status**: Draft
**Input**: User description: "reproduce the holyclaude setup, I want to select
the tools during the clarification phase, you can copy everything we need from
the repo cloned in /home/krs/Repos/HolyClaude. We don't need manual and
documentations for now. Important: I don't want CloudCLI so don't copy what
relates to it. I want you to challenge sh scripts."

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Spin Up a Reproducible Claude Code Shell (Priority: P1)

A developer pulls the project, sets their Anthropic API key in an environment
variable, and runs the docker-compose stack on either their laptop or a
Coolify-managed server. Within minutes they get an interactive shell inside
the container with the Claude Code CLI installed and ready to use, and with
the project's curated developer toolchain pre-installed at known versions.

**Why this priority**: this is the core reason the project exists. Without a
working "deploy → use Claude" path, nothing else in the project matters.

**Independent Test**: from a clean checkout on a host that only has Docker and
a valid API key, running the documented start command produces a running
container exposing an interactive shell where `claude --version` succeeds,
`git --version` succeeds, and the curated tools are available on `PATH`.

**Acceptance Scenarios**:

1. **Given** a clean host with Docker installed and `ANTHROPIC_API_KEY` set,
   **When** the user starts the stack, **Then** the container reaches a
   healthy state and an interactive shell is accessible.
2. **Given** a running container, **When** the user runs `claude` inside it,
   **Then** the CLI launches and authenticates with the supplied API key.
3. **Given** a Coolify-managed server, **When** the user deploys the project
   as a Coolify docker-compose application, **Then** the deployment succeeds
   without manual host-side commands or privileged-mode workarounds.

---

### User Story 2 — Survive Restarts and Image Rebuilds Without Losing Work (Priority: P1)

A user has been working in the container for several days: their Claude Code
authentication, their per-tool configuration, and their project files all
exist inside the container. They restart the host, pull a newer image tag,
and bring the stack back up. Nothing is lost — credentials, settings, shell
history, and project files are all there.

**Why this priority**: a Claude shell that loses state on every redeploy is
unusable as a daily driver. This is the second non-negotiable.

**Independent Test**: authenticate Claude inside the container, create a file
in the workspace, stop the stack, rebuild the image, restart the stack, and
verify both the authentication and the file are still present.

**Acceptance Scenarios**:

1. **Given** an authenticated Claude session and files in the workspace,
   **When** the container is recreated from a fresh image, **Then** the user
   does not need to re-authenticate and the workspace files are intact.
2. **Given** persistent state on disk, **When** the user wipes only the
   workspace volume, **Then** Claude credentials remain intact (state
   categories are isolated).
3. **Given** a first-ever boot with empty volumes, **When** the container
   starts, **Then** it self-initializes default configuration without
   requiring host-side preparation.

---

### User Story 3 — Files Created Inside the Container Have Correct Host Ownership (Priority: P2)

A user runs the stack on Linux where the container's internal user must match
the host user that owns the bind-mounted directories. They configure the host
UID/GID via environment variables, and any file the container creates in the
workspace ends up owned by that host user — no `sudo chown` dance after
the fact.

**Why this priority**: ownership mismatch is the most common friction for
Linux users of bind-mounted Docker dev environments. Solving it once at boot
avoids recurring permission grief.

**Independent Test**: set `PUID`/`PGID` to a non-default value, start the
stack with a bind-mounted workspace, create a file from inside the container,
and verify on the host that the file is owned by the configured UID:GID.

**Acceptance Scenarios**:

1. **Given** the host user is UID 1001, **When** the container starts with
   `PUID=1001`, **Then** files created in the bind-mounted workspace are
   owned by 1001 on the host.
2. **Given** no `PUID`/`PGID` is provided, **When** the container starts,
   **Then** it falls back to a sensible default and still functions.

---

### User Story 4 — Get Notified When Claude Finishes or Fails (Priority: P2)

A user kicks off a long-running Claude task and walks away. When Claude
finishes the task or hits a tool failure, the user receives a notification
on the channel they configured (e.g., a chat service, email, mobile push).
Notifications are off by default and only fire when the user has explicitly
opted in.

**Why this priority**: long-running agent tasks are a common Claude Code use
case, and unattended notifications meaningfully improve workflow ergonomics.
Not blocking, but high value.

**Independent Test**: configure a notification destination, opt in, run a
short Claude task, and observe a "task complete" notification on that
destination.

**Acceptance Scenarios**:

1. **Given** the user has not opted in to notifications, **When** Claude
   finishes a task, **Then** no notification is sent.
2. **Given** the user has opted in and configured at least one notification
   destination, **When** Claude finishes a task, **Then** a "task complete"
   notification arrives on that destination.
3. **Given** notifications are misconfigured (unreachable destination),
   **When** an event fires, **Then** the failure is silent and does not
   disrupt the running session.

---

### User Story 5 — Choose a Tool Profile at Build Time (Priority: P3)

A user who only needs the bare minimum (small image, short pull time) builds
the image with a "minimal" tool profile; a user who wants the full curated
set builds with the "full" profile. The default profile is the one most
representative of typical Claude Code workflows.

**Why this priority**: useful for resource-constrained Coolify nodes and CI
runners, but a single well-chosen default already covers most users.

**Independent Test**: build the image with the minimal profile, verify the
expected tool subset is present and the unwanted ones are absent, then build
with the full profile and verify the superset is present.

**Acceptance Scenarios**:

1. **Given** a build with the minimal profile, **When** the user inspects the
   image, **Then** only the documented minimal tool list is installed.
2. **Given** a build with the full profile, **When** the user inspects the
   image, **Then** the full curated tool list is installed.

---

### Edge Cases

- **First boot vs. subsequent boots**: the very first start with empty
  volumes must seed defaults; later starts must not overwrite user changes.
- **Image rebuild with existing volumes**: a newer image must coexist with
  pre-existing user state without prompting destructive migrations.
- **Missing API key**: the container must still start (so the user can fix
  it from inside), but `claude` use must surface a clear error.
- **Bind-mount created by Docker as root**: the entrypoint must repair
  ownership at startup so the in-container user can write to it.
- **Concurrent containers sharing a volume**: out of scope for v1; document
  as unsupported.
- **Build behind a corporate proxy / restricted network**: out of scope for
  v1; document as a known gap if it surfaces.
- **Process supervision failure**: if a supervised background process dies,
  the container must remain usable as a shell — the user can always exec in
  and continue.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST be deployable as a docker-compose stack on
  Coolify with no host-side patches and no privileged-mode requirements.
- **FR-002**: The image MUST include the Claude Code CLI at a pinned version
  and make it available on the in-container user's `PATH`.
- **FR-003**: The image MUST include a curated set of common developer tools
  at pinned or otherwise reproducibly resolvable versions.
  [NEEDS CLARIFICATION: exact tool inventory — to be selected during the
  clarification phase per the user's explicit instruction. Inputs include the
  HolyClaude reference set (excluding CloudCLI / web UI / its plugins, and
  excluding manuals/documentation tooling) and the categories the user wants
  to keep, drop, or add.]
- **FR-004**: The image MUST NOT include the HolyClaude web UI ("CloudCLI",
  i.e. `@siteboon/claude-code-ui`), its plugins, the WebSocket / Shell /
  model patches that target it, or any port or healthcheck wired
  specifically to it.
- **FR-005**: The container MUST run application processes as a non-root
  user by default; root-only operations MUST happen at build time, not at
  runtime.
- **FR-006**: The system MUST allow the in-container user's UID and GID to
  be aligned with the host user's UID/GID via configuration, so bind-mounted
  files have correct host ownership.
- **FR-007**: The system MUST persist Claude Code configuration and
  credentials across container recreation and image rebuilds.
- **FR-008**: The system MUST persist user project / workspace data across
  container recreation and image rebuilds, in a volume separate from the
  Claude configuration volume.
- **FR-009**: On first boot with empty volumes, the system MUST seed default
  configuration without manual intervention; on subsequent boots it MUST NOT
  overwrite user-modified configuration.
- **FR-010**: The image MUST be buildable in two reproducible modes (a
  smaller "minimal" profile and a larger "full" profile), with the default
  profile clearly documented.
- **FR-011**: The system MUST emit a notification when Claude Code finishes
  a task or surfaces a tool failure, but ONLY when the user has explicitly
  opted in and provided at least one notification destination.
- **FR-012**: Notification failures (unreachable destination, malformed URL)
  MUST NOT crash or disrupt the running session.
- **FR-013**: The container MUST expose a meaningful health signal that
  Coolify and `docker compose` can use to determine readiness.
- **FR-014**: All credentials (API keys, notification URLs, git identity)
  MUST be injectable at runtime via environment variables; they MUST NOT be
  baked into the image, present in build args, or committed to the repo.
- **FR-015**: The system MUST NOT require any manual or documentation
  artifacts to be functional; producing user-facing manuals/docs is
  explicitly out of scope for this feature.
- **FR-016**: Any shell-script glue code carried over from the HolyClaude
  reference (entrypoint, bootstrap, supervisor run scripts) MUST be
  re-evaluated rather than copied verbatim. Each such script that survives
  into KroClaude MUST be justified during planning by either (a) a
  capability that genuinely requires shell scripting at that lifecycle
  stage, or (b) the absence of a simpler declarative alternative
  (compose-level config, single-process container, image-time setup).
  Scripts that fail this gate MUST be replaced with the simpler alternative.

### Key Entities

- **Container Image**: the buildable artifact carrying the Claude Code CLI
  and the curated tool set; tagged by semantic version.
- **Configuration Volume**: persistent storage for Claude Code credentials,
  per-tool configuration, and shell history; survives container recreation.
- **Workspace Volume**: persistent storage for the user's project files;
  survives container recreation and is independently wipeable.
- **Tool Profile**: a named subset of the curated toolchain selected at
  build time (e.g., "minimal", "full"); determines image size and contents.
- **Notification Channel**: a user-supplied destination URL the system uses
  to deliver task-complete and error events when opted in.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A new user with Docker installed and an Anthropic API key can
  go from `git clone` to a working Claude shell inside the container in
  under 10 minutes on a typical broadband connection (build + first start).
- **SC-002**: After a full container teardown and image rebuild, 100% of
  authenticated users no longer need to re-authenticate Claude Code on the
  next start.
- **SC-003**: On a Linux host with matching `PUID`/`PGID`, 100% of files
  created inside the container appear on the host owned by the configured
  user without manual `chown`.
- **SC-004**: The image's first-boot bootstrap completes in under 15
  seconds on a typical machine and produces no permission errors visible to
  the user.
- **SC-005**: The "minimal" profile produces an image at least 30% smaller
  (compressed) than the "full" profile.
- **SC-006**: The compose file passes `docker compose config` validation and
  deploys cleanly on Coolify's docker-compose application type with zero
  host-side intervention.
- **SC-007**: Zero credentials (API keys, notification URLs) appear in
  `docker history`, the committed repository, or any image layer.

## Assumptions

- The deployment target is a Linux host (the user's workstation, a VPS, or
  a Coolify-managed server). macOS and Windows are best-effort, not
  first-class.
- The user supplies their own Anthropic API key; key provisioning is out of
  scope.
- The HolyClaude repository at `/home/krs/Repos/HolyClaude` is the
  reference implementation. Where its choices conflict with the KroClaude
  constitution (CloudCLI exclusion, shell-script minimalism, declarative
  compose contract), the constitution wins.
- Web UIs, browser-driven UIs, and any port-3001-style "Claude in the
  browser" surfaces are explicitly out of scope for this feature.
- User-facing manuals, documentation sites, and onboarding wizards are
  explicitly out of scope for this feature; only a minimal `.env.example`
  and the compose file itself are required for someone familiar with the
  domain to deploy the stack.
- The project will offer at most two build profiles in v1 (minimal vs full).
- Notifications integrate with whatever destination URLs the user already
  uses; the project does not host a notification relay.
