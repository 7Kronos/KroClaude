# Phase 0 Research: Claude Code Shell Base Image

**Branch**: `001-claude-shell-base` | **Date**: 2026-04-27

This document consolidates the technical decisions that resolve the
Technical Context entries in [plan.md](plan.md). Each item lists the
**Decision**, **Rationale**, and **Alternatives considered**. Where the
HolyClaude reference (`/home/krs/Repos/HolyClaude`) already implements a
choice, we either adopt or explicitly diverge with reasons.

## R1 — Process supervisor: s6-overlay v3

- **Decision**: keep s6-overlay v3 (version pinned to `3.2.0.2` matching the
  HolyClaude reference). One service definition: `xvfb`. The CloudCLI
  service definition is removed.
- **Rationale**: explicit user directive (`/speckit-plan keep s6-overlay`).
  s6-overlay also gives us correct PID-1 behavior (zombie reaping, signal
  forwarding, graceful shutdown) without us writing a custom supervisor.
- **Alternatives considered**:
  - **Single-process container** (run Xvfb as PID 1 directly, then have the
    user `docker exec` for shells) — rejected: Xvfb has no UX for being the
    interactive face of the container, and we lose the option to add
    further long-running services (e.g., a future agent daemon) without a
    rewrite.
  - **`tini` + `Xvfb &` in entrypoint** — rejected: `tini` only handles
    PID-1 reaping; we'd still need to write our own restart-on-crash and
    signal-forwarding logic for Xvfb. That pushes shell complexity *up*, not
    down — the opposite of FR-014's intent.
  - **`supervisord`** — rejected: heavier (Python runtime), historically
    flakier signal handling, and we already get s6-overlay's binary
    distribution from the same source HolyClaude uses.

## R2 — How does the user get an interactive shell?

- **Decision**: shell access is via `docker exec -it kroclaude bash`. The
  container does NOT publish a port for SSH or an in-container web TTY,
  and the compose service does NOT run with `tty: true`/`stdin_open: true`
  (the long-running PID 1 is s6 + Xvfb, not a shell).
- **Rationale**: aligns with Coolify's standard "open a terminal" UX
  (Coolify's UI uses `docker exec` under the hood); avoids running an SSH
  daemon (extra daemon, extra creds story, extra attack surface); FR-004
  excludes the web TTY.
- **Alternatives considered**:
  - **SSH server inside the container** — rejected: violates "non-root
    services" (sshd as a daemon), inflates the threat model with a second
    auth surface, and Coolify offers terminal access natively.
  - **`compose run -it kroclaude bash`** — works but creates a new ephemeral
    container each invocation; doesn't share the long-running Xvfb session.

## R3 — Healthcheck strategy

- **Decision**: healthcheck command is `pgrep -x Xvfb >/dev/null && command -v claude >/dev/null` (or equivalent inline check). Interval 30 s,
  timeout 5 s, start-period 30 s, retries 3 — matching HolyClaude's
  cadence but with a non-CloudCLI command.
- **Rationale**: HolyClaude's healthcheck (`curl http://localhost:3001/`)
  is CloudCLI-specific and goes away with FR-004. The replacement must
  signal "image started, supervised process up, Claude CLI present" without
  exposing a network port. `pgrep` is in `procps` (already in FR-003);
  `command -v` is a bash builtin.
- **Alternatives considered**:
  - **`claude --version`** alone — rejected: doesn't confirm Xvfb is alive,
    so a Chromium-using session could fail despite a "healthy" status.
  - **No healthcheck** — rejected: violates Constitution Principle IV
    ("Health checks (`healthcheck:`) MUST be defined for every long-running
    service so Coolify's status indicator is meaningful").
  - **`s6-rc -a list`** — rejected: requires running inside the s6 user
    bundle, brittle when the bundle structure changes.

## R4 — First-boot initialization: image-time vs. runtime

- **Decision**: configuration files (Claude `settings.json`, the in-image
  `CLAUDE.md`, default Codex `config.toml` + hooks, default Gemini hooks)
  are baked under `/usr/local/share/kroclaude/` at image build time. The
  entrypoint copies them to `/home/claude/.claude/...` only when a sentinel
  file (`/home/claude/.claude/.kroclaude-bootstrapped`) is absent — i.e.,
  on first boot with an empty named volume — then writes the sentinel.
  Subsequent boots are no-ops over user-modified config.
- **Rationale**: FR-008 requires both first-boot seeding and idempotent
  subsequent boots. Image-time-only seeding doesn't work because the
  named volume is empty at first start (the volume mount shadows
  whatever was baked into the image at that path). Runtime-only seeding
  is the only correct approach. Merging this logic into the entrypoint
  (vs. HolyClaude's separate `bootstrap.sh`) drops one shell script
  outright (FR-014 win) without losing capability.
- **Alternatives considered**:
  - **HolyClaude split (entrypoint + bootstrap.sh)** — rejected as
    unnecessary indirection; both run as bash, both are <50 lines,
    inlining is simpler.
  - **Use Docker's `--mount type=volume,source=...,destination=...,
    volume-nocopy=false`** to seed from image — rejected: `nocopy=false`
    is opt-out behavior tied to the *first* mount only and surprising
    when users wipe and re-create the volume.

## R5 — Claude Code CLI install

- **Decision**: install via the official native installer at image build
  time, run AS the `claude` user (not root): `curl -fsSL https://claude.ai/install.sh | bash`. The installer drops a binary into
  `/home/claude/.local/bin`. Add `/home/claude/.local/bin` to the image
  `PATH`. Pin the installed version by capturing the resolved version in
  the image label and asserting `claude --version` in the smoke test.
- **Rationale**: matches HolyClaude's working approach (line 105 of the
  HolyClaude Dockerfile). The native installer is the supported channel
  for Claude Code. Running as the `claude` user is required ("WORKDIR
  must be non-root-owned or the installer hangs", per the comment in
  HolyClaude's Dockerfile).
- **Alternatives considered**:
  - **`npm i -g @anthropic-ai/claude-code`** — partially supported but
    historically lags the native installer; the native installer is what
    Anthropic publishes as the canonical channel.
  - **Pinning to a specific version via the installer** — the installer
    does not currently expose a version flag. We accept "latest at
    build time" and pin by digest (image tag captures it).

## R6 — `ANTHROPIC_API_KEY` surface

- **Decision**: `ANTHROPIC_API_KEY` is read from the process environment
  by the Claude CLI directly. The compose file declares it under
  `environment:` with no default; users source it from their `.env` file
  or, on Coolify, from a Coolify-managed secret. We do NOT write it into
  `~/.claude.json` or any other on-disk file.
- **Rationale**: env-only is the simplest, most auditable secret path
  (FR-013, Constitution §Security). On-disk persistence creates a second
  copy that can leak via volume backups; in-process env is wiped at
  container teardown.
- **Alternatives considered**:
  - **Persist a hashed/encrypted token** — over-engineered for v1.
  - **Initialize via `claude /login` interactive** — works but requires a
    TTY at first start; the env-var path covers headless deployments.

## R7 — Codex / Gemini default configuration

- **Decision**: bake default Codex (`config.toml`, `hooks.json`) and Gemini
  (`settings.json`) configs into `/usr/local/share/kroclaude/` and seed
  them into the config volume on first boot via the entrypoint. Codex
  defaults: `approval_policy = "on-request"`, `sandbox_mode =
  "workspace-write"`, `[features] codex_hooks = true`. Both Codex and
  Gemini have a Stop/SessionEnd hook firing `notify.py stop`.
- **Rationale**: matches HolyClaude semantics for the two AI CLIs we're
  keeping (per Q1). The auth steps (Codex/Gemini OAuth) remain a manual
  user action per their respective vendor flows; we do not attempt to
  pre-seed credentials.
- **Alternatives considered**:
  - **No default config** — rejected: leaves Codex with permissive
    defaults the constitution would not endorse (no approval policy).

## R8 — Multi-arch (`amd64` + `arm64`)

- **Decision**: build with `docker buildx build --platform linux/amd64,linux/arm64`. The Dockerfile uses `TARGETARCH` to pick the
  correct s6-overlay tarball (HolyClaude already does this). All apt
  packages in FR-003 (notably `chromium`) are available for both arches
  on Debian Bookworm. The official Anthropic installer ships both
  binaries.
- **Rationale**: Coolify nodes are commonly arm64 (Ampere, AWS Graviton);
  developer laptops are commonly amd64 or Apple Silicon (arm64).
  Excluding either arch fragments the user base.
- **Alternatives considered**:
  - **`amd64` only** — rejected: leaves Apple Silicon and Graviton on
    emulation, which is slow and breaks Chromium.

## R9 — In-container default shell

- **Decision**: bash 5.x (Debian default), with no zsh/oh-my-zsh layer.
  Shell history is persisted to the config volume via
  `HISTFILE=/home/claude/.claude/.bash_history` (set in
  `/home/claude/.bashrc` baked at build time).
- **Rationale**: bash is the Debian default; adding zsh costs install
  time and surface area for marginal UX gain. History persistence
  satisfies the spec's mention of "shell history" as part of
  Configuration Volume contents.
- **Alternatives considered**:
  - **zsh + oh-my-zsh** — rejected: violates Principle III (no clear
    Claude Code workflow tie-in justifying the size and surface).

## R10 — Notification helper language: Python vs shell

- **Decision**: keep `scripts/notify.py` as Python (HolyClaude's choice).
  It uses `apprise` (already in FR-003 pip list) to dispatch to ~80
  notification channels.
- **Rationale**: the alternative is N curl one-liners, one per provider,
  reinventing Apprise badly. Python is in the image regardless (FR-003
  build toolchain). One ~50-line auditable Python file with no external
  network calls beyond Apprise's targets is acceptable per FR-014's
  exception (b) — there is no simpler declarative alternative.
- **Alternatives considered**:
  - **Inline shell with `curl`** — rejected: each provider has its own
    auth/format; the maintenance cost dwarfs the simplicity gain.
  - **Drop notifications entirely** — rejected: US3/FR-009/FR-010 are in
    scope.

## R11 — `~/.claude.json` persistence

- **Decision**: drop the HolyClaude background loop that copies
  `~/.claude.json` to the bind-mount every 60 s. With named volumes
  (Q3 clarification), `/home/claude/.claude` is itself the persistent
  volume, so any file Claude writes there is already persistent. The
  `~/.claude.json` file lives at `/home/claude/.claude.json` (one level
  above), so the entrypoint creates a one-time symlink
  `/home/claude/.claude.json` → `/home/claude/.claude/.claude.json` on
  first boot, and Claude's writes follow the symlink into the volume.
- **Rationale**: the 60-second copy loop in HolyClaude exists because
  Claude Code overwrites symlinks (per the comment in
  `entrypoint.sh:75`). We test the symlink approach during smoke; if
  Claude still overwrites it, fall back to a sentinel-based
  copy-on-boot (still a one-shot, not a 60 s loop). Either way, the
  background process goes away — major FR-014 win.
- **Alternatives considered**:
  - **Keep the 60 s loop** — rejected: it's a background bash process
    with no supervision, no exit handling, fires 1440 times/day for no
    benefit on a named-volume setup. Pure waste.

## R12 — Secrets in image layers (negative requirement)

- **Decision**: enforce SC-005 ("zero credentials in `docker history` /
  repo / image layers") in CI: a job greps `docker history --no-trunc`
  output for the literal `ANTHROPIC_API_KEY=`, `NOTIFY_`, etc., and
  fails the build if any matches. `.env` is gitignored from day one.
- **Rationale**: SC-005 is a measurable outcome that needs a programmatic
  check or it will silently regress.
- **Alternatives considered**:
  - **Manual review** — rejected: not measurable, not enforceable.

## Open items deferred to `/speckit-tasks`

- Concrete pinned package versions for apt/npm/pip — captured at task
  authoring time (one task per category) so the lock can be regenerated
  cleanly; not a research question, just a mechanical pinning step.
- The exact `bashrc` contents (PS1, aliases, env exports) — minor UX,
  defer to implementation.
- Trivy scan policy file (`.trivyignore`) — start without one; add only
  if a known-and-accepted finding shows up.
