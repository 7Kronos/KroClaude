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

### User Story 3 — Get Notified When Claude Finishes or Fails (Priority: P2)

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

### Edge Cases

- **First boot vs. subsequent boots**: the very first start with empty
  volumes must seed defaults; later starts must not overwrite user changes.
- **Image rebuild with existing volumes**: a newer image must coexist with
  pre-existing user state without prompting destructive migrations.
- **Missing API key**: the container must still start (so the user can fix
  it from inside), but `claude` use must surface a clear error.
- **Concurrent containers sharing a volume**: out of scope for v1; document
  as unsupported.
- **Build behind a corporate proxy / restricted network**: out of scope for
  v1; document as a known gap if it surfaces.
- **Process supervision failure**: if a supervised background process dies,
  the container must remain usable as a shell — the user can always exec in
  and continue.

## Clarifications

### Session 2026-04-27

- Q: Which AI CLIs ship in the image alongside Claude Code? → A: Claude
  Code CLI + the Codex CLI + the Gemini CLI (the three first-party
  "big lab" assistant CLIs). Cursor, Junie, and OpenCode are excluded.
- Q: Should the image support headless browser automation (Playwright /
  Puppeteer / Chromium)? → A: Yes — full headless-Chromium support with
  an Xvfb display server is in scope, and the additional Linux
  capabilities (`SYS_ADMIN`, `SYS_PTRACE`) plus `seccomp=unconfined`
  required by Chromium are accepted as a documented tradeoff.
- Q: How is the user's `/workspace` data stored — bind-mount, named
  volume, or both? → A: Named Docker volume only. Host bind-mounts are
  out of scope; `PUID`/`PGID` runtime-remap is not implemented; the
  HolyClaude `entrypoint.sh` UID/GID logic is dropped. Users who want
  to view workspace files from a host editor attach to the running
  container (e.g., VS Code Dev Containers over the Docker socket).
- Q: Should the image have a profile system (minimal vs full), or a single
  curated set? → A: Single curated set. There is exactly one curated tool
  list and one image; the minimal/full profile system, the `VARIANT` build
  arg, and the variant-aware bootstrap fork are all out of scope.
- Q: Approve the curated tool set? → A: Adopt the recommended baseline plus
  three additions: `ffmpeg` (apt), `lighthouse` (npm global), and
  `xlsxwriter` (pip). All other "full"-only extras from HolyClaude
  (Azure CLI, pandoc, libvips, wrangler/vercel/netlify-cli, pm2, prisma,
  drizzle-kit, eas-cli, sharp-cli, json-server, http-server, marp,
  cf-next-on-pages, reportlab/weasyprint/cairosvg/fpdf2/PyMuPDF/pdfkit/
  img2pdf, xlrd, matplotlib, seaborn, python-pptx, fastapi, uvicorn,
  httpie, task-master-ai) are excluded.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST be deployable as a docker-compose stack on
  Coolify with no host-side patches and no `privileged: true` requirement.
  Granular Linux capabilities (`cap_add`) and seccomp profile relaxation
  declared in the compose file are permitted where justified by an FR
  (see FR-003b for the browser-automation case) and MUST be enumerated
  explicitly — never as a blanket privileged-mode shortcut.
- **FR-002**: The image MUST include the Claude Code CLI at a pinned version
  and make it available on the in-container user's `PATH`.
- **FR-003**: The image MUST include exactly the following curated tool
  set, at pinned or otherwise reproducibly resolvable versions, and no
  other developer tools without an amendment to this spec:
  - **Shell core (apt)**: `git`, `curl`, `wget`, `jq`, `ripgrep`,
    `fd-find`, `unzip`, `zip`, `tree`, `tmux`, `fzf`, `bat`, `sudo`.
  - **Build & language toolchain**: Node.js 22 (from base image),
    `build-essential`, `pkg-config`, `python3`, `python3-pip`,
    `python3-venv`.
  - **Browser automation stack (per FR-003b)**: `chromium`, `xvfb`,
    `fonts-liberation2`, `fonts-dejavu-core`, `fonts-noto-core`,
    `fonts-noto-color-emoji`.
  - **Locale**: `locales` configured for `en_US.UTF-8`.
  - **Debugging**: `strace`, `lsof`, `iproute2`, `procps`, `htop`.
  - **Database clients**: `postgresql-client`, `redis-tools`, `sqlite3`.
  - **Network/SSH**: `openssh-client` (client only — no SSH server).
  - **Media**: `imagemagick`, `ffmpeg`.
  - **Sandbox helper**: `bubblewrap` (setuid; required by Codex CLI).
  - **GitHub**: `gh` (GitHub CLI).
  - **AI CLIs (per FR-003a)**: `@google/gemini-cli`, `@openai/codex`.
  - **npm globals**: `typescript`, `tsx`, `pnpm`, `vite`, `esbuild`,
    `eslint`, `prettier`, `serve`, `nodemon`, `concurrently`,
    `dotenv-cli`, `lighthouse`.
  - **Python packages (pip)**: `requests`, `httpx`, `beautifulsoup4`,
    `lxml`, `Pillow`, `pandas`, `numpy`, `openpyxl`, `python-docx`,
    `jinja2`, `pyyaml`, `python-dotenv`, `markdown`, `rich`, `click`,
    `tqdm`, `playwright`, `apprise`, `xlsxwriter`.
- **FR-003a**: The image MUST include exactly three AI assistant CLIs:
  Claude Code (per FR-002), the Codex CLI (`@openai/codex`), and the
  Gemini CLI (`@google/gemini-cli`). Cursor CLI, Junie CLI, and OpenCode
  CLI MUST NOT be installed. Any HolyClaude entrypoint or bootstrap glue
  that exists solely for an excluded CLI (e.g., per-CLI config-directory
  symlinks) MUST be dropped accordingly.
- **FR-003b**: The image MUST support running a headless Chromium-based
  browser for Playwright/Puppeteer workflows. To make this work, the
  image MUST install Chromium and the fonts it needs, and the runtime
  MUST provide an Xvfb virtual display. The compose file MUST declare
  exactly these capability and security relaxations and no others:
  `cap_add: SYS_ADMIN, SYS_PTRACE` and `security_opt: seccomp=unconfined`.
  Each addition MUST be commented in the compose file with a one-line
  rationale tying it back to this FR. Persistent processes required for
  this capability (only Xvfb, after CloudCLI exclusion) MAY justify a
  process supervisor; that decision is made at planning time per FR-014.
- **FR-004**: The image MUST NOT include the HolyClaude web UI ("CloudCLI",
  i.e. `@siteboon/claude-code-ui`), its plugins, the WebSocket / Shell /
  model patches that target it, or any port or healthcheck wired
  specifically to it.
- **FR-005**: The container MUST run application processes as a non-root
  user by default; root-only operations MUST happen at build time, not at
  runtime. The in-container user's UID/GID is fixed at image build time;
  no runtime UID/GID remapping (`PUID`/`PGID`) is supported.
- **FR-006**: The system MUST persist Claude Code configuration and
  credentials in a named Docker volume that survives container recreation
  and image rebuilds.
- **FR-007**: The system MUST persist user project / workspace data in a
  named Docker volume separate from the Claude configuration volume; both
  volumes are independently wipeable, backupable by Coolify, and survive
  container recreation. Host bind-mounts to `/workspace` are out of scope.
- **FR-008**: On first boot with empty volumes, the system MUST seed
  default configuration without manual intervention; on subsequent boots
  it MUST NOT overwrite user-modified configuration.
- **FR-009**: The system MUST emit a notification when Claude Code finishes
  a task or surfaces a tool failure, but ONLY when the user has explicitly
  opted in and provided at least one notification destination.
- **FR-010**: Notification failures (unreachable destination, malformed URL)
  MUST NOT crash or disrupt the running session.
- **FR-011**: The container MUST expose a meaningful health signal that
  Coolify and `docker compose` can use to determine readiness.
- **FR-012**: All credentials (API keys, notification URLs, git identity)
  MUST be injectable at runtime via environment variables; they MUST NOT be
  baked into the image, present in build args, or committed to the repo.
- **FR-013**: The system MUST NOT require any manual or documentation
  artifacts to be functional; producing user-facing manuals/docs is
  explicitly out of scope for this feature.
- **FR-014**: Any shell-script glue code carried over from the HolyClaude
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
- **Configuration Volume**: a named Docker volume holding Claude Code
  credentials, per-tool configuration, and shell history; survives
  container recreation and image rebuilds.
- **Workspace Volume**: a named Docker volume holding the user's project
  files; survives container recreation, is independently wipeable, and is
  not host-bind-mountable in v1.
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
- **SC-003**: The image's first-boot bootstrap completes in under 15
  seconds on a typical machine and produces no permission errors visible to
  the user.
- **SC-004**: The compose file passes `docker compose config` validation and
  deploys cleanly on Coolify's docker-compose application type with zero
  host-side intervention.
- **SC-005**: Zero credentials (API keys, notification URLs) appear in
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
- The project ships exactly one curated tool set in v1 (no minimal/full
  variants). Future variants, if needed, can be introduced via Dockerfile
  build args without breaking v1 deployments.
- Notifications integrate with whatever destination URLs the user already
  uses; the project does not host a notification relay.
