# Implementation Plan: Claude Code Shell Base Image

**Branch**: `001-claude-shell-base` | **Date**: 2026-04-27 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from [spec.md](spec.md)

## Summary

Reproduce the HolyClaude environment as a stripped-down, Coolify-deployable
docker-compose stack. The deliverable is a single container image carrying the
Claude Code CLI, the Codex and Gemini CLIs, a curated developer toolchain, and
headless-Chromium support — built on `node:22-bookworm-slim` with `s6-overlay`
v3 supervising the Xvfb display server. The CloudCLI web UI, manuals, two-tier
profile system, and runtime UID/GID remap (`PUID`/`PGID`) are all out. State
lives exclusively in two named Docker volumes (`kroclaude-config` and
`kroclaude-workspace`); the entrypoint shrinks to ~30 lines (first-boot seed +
PID-1 handoff to s6); the user gets an interactive shell via `docker exec`.

**Per user directive (`/speckit-plan keep s6-overlay`)**: s6-overlay v3 is
retained as the process supervisor even though only one long-running service
(Xvfb) survives the CloudCLI exclusion. This is captured in Complexity Tracking
below as a justified deviation from FR-014's "challenge sh scripts" baseline
preference for a single-process container.

## Technical Context

**Language/Version**: Dockerfile (BuildKit-compatible), Bash 5.x (Debian
Bookworm), Python 3.11 (only used by `scripts/notify.py`)
**Primary Dependencies**: Docker Engine 24+, Docker Compose v2, `node:22-bookworm-slim`
base image (pinned by digest at release), s6-overlay v3.2.0.2, Chromium (apt),
Apprise (pip), Claude Code CLI (native installer), Codex CLI (`@openai/codex`
npm), Gemini CLI (`@google/gemini-cli` npm)
**Storage**: two named Docker volumes — `kroclaude-config` mounted at
`/home/claude/.claude` (Claude/Codex/Gemini configs, credentials, shell history),
`kroclaude-workspace` mounted at `/workspace` (user project files). No bind
mounts (per Q3 clarification).
**Testing**: smoke-test script run in CI against the built image — verifies
`claude --version`, all FR-003 tools on PATH, non-root user, healthcheck OK,
volume persistence across `docker compose down -v` followed by `up`. Trivy
vulnerability scan on every release tag (Constitution §Security & Secrets).
**Target Platform**: Linux Docker host (workstation, VPS, or Coolify-managed
node). Multi-arch images: `linux/amd64` and `linux/arm64`. Chromium ships in
Debian Bookworm for both arches; s6-overlay handles arch via the
`TARGETARCH`-driven download in the Dockerfile.
**Project Type**: deployment artifact (Dockerfile + compose stack) — NOT a
library/CLI/web-service codebase. No `src/`, no application source tree. Code
is the Dockerfile, the compose file, the entrypoint, the supervisor manifest,
and a small Python notification helper.
**Performance Goals**: image build under 10 min on a typical CI runner (cold
cache); first-boot bootstrap under 15 s (SC-003); image pull (compressed) under
3 GB; healthcheck reaches steady state within 30 s of `docker compose up`.
**Constraints**: no `privileged: true`; only `cap_add: SYS_ADMIN, SYS_PTRACE`
and `security_opt: seccomp=unconfined` declared in the compose file (each with
an inline rationale tying back to FR-003b); no credentials in image layers,
build args, or repo; non-root in-container user (`claude`, fixed UID 1000 from
the base image); named volumes only; no inbound port published in v1
(interactive access is `docker exec`).
**Scale/Scope**: single-tenant per container; one developer per container;
not designed for multi-user, multi-tenant, or daemon-mode workloads.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Walking each principle from [`.specify/memory/constitution.md`](../../.specify/memory/constitution.md)
v1.0.0:

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Reproducible Builds (NON-NEGOTIABLE) | ✅ | Base image pinned by digest at release; s6-overlay version + tarball checksums verified at build; tool versions pinned via apt + npm `@version` + pip pinning where reproducible; `docker compose build --no-cache` runs in CI on every PR per Build & Release section. |
| II. Container-First Delivery | ✅ | Dockerfile + `docker-compose.yaml` are the only deployment surface; configuration is env-vars (`ANTHROPIC_API_KEY`, `NOTIFY_URLS`, `TZ`, `GIT_USER_NAME`, `GIT_USER_EMAIL`); persistence is two named volumes; healthcheck declared. |
| III. Curated Tooling, Lean Image | ✅ | FR-003 enumerates the exact tool set; `lighthouse`, `ffmpeg`, `xlsxwriter` additions justified in clarifications; image-size tracking added to CI. No two-tools-doing-the-same-job overlap. |
| IV. Coolify-Native Deployment | ⚠ Justified | FR-003b requires `cap_add: SYS_ADMIN, SYS_PTRACE` + `seccomp=unconfined`. Constitution forbids `privileged: true`, NOT granular caps — caps are a Coolify-supported compose primitive. Tradeoff documented in Complexity Tracking and FR-003b. Volumes are named (no bind mounts to Coolify-managed paths) ✅. |
| V. Stateless Container, Explicit Persistence | ✅ | Two distinct named volumes (config vs workspace). Empty-volume first-boot is the entrypoint's responsibility; idempotent on subsequent boots via sentinel file. No process writes critical state outside a declared volume. |
| Security & Secrets | ✅ | Non-root by default; `ANTHROPIC_API_KEY` and `NOTIFY_*` injected at runtime; `.env.example` only (real `.env` gitignored); Trivy scan on release; only declared compose ports (none in v1); cap/seccomp relaxations explicitly enumerated. |
| Build, Release & Workflow | ✅ | Image semver tagging; `main` always buildable; PR smoke check (build → boot → `claude --version` + tool inventory); `BREAKING:` changelog convention; HolyClaude attribution preserved (`THIRD-PARTY-NOTICES` carried forward, license preserved per its terms). |

**Result**: PASS with one justified deviation (cap_add/seccomp for FR-003b)
and one user-directed deviation (keep s6-overlay despite single-service post-
CloudCLI removal — see Complexity Tracking).

### Post-Phase-1 Re-Check

Re-walked all principles after writing [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), and
[quickstart.md](quickstart.md). No new violations. Specifically:

- **Reproducible Builds**: research R5 (Claude installer) and R8
  (multi-arch `TARGETARCH`) align with Principle I; no design choice
  requires unpinned network fetches.
- **Container-First Delivery**: every user-tunable knob is enumerated
  in [contracts/compose-environment.md](contracts/compose-environment.md);
  no out-of-band setup steps.
- **Curated Tooling**: no design step added a tool not already in FR-003.
- **Coolify-Native**: healthcheck contract gives Coolify a meaningful
  status; volumes contract uses named volumes only.
- **Stateless Container**: volumes contract makes the persistence
  boundaries explicit and lists invariants for first-boot, recreate,
  rebuild, and category-wipe.
- **FR-014 (challenge sh scripts)**: research R1, R4, R10, R11
  collectively reduce the surviving shell-script footprint to a slim
  `entrypoint.sh` (~30 LOC, bootstrap merged in), one-line
  `xvfb/run`, and `notify.py` (Python, justified). The HolyClaude
  `bootstrap.sh`, `~/.claude.json` 60-second copy loop, the
  Cursor/Junie/OpenCode symlink stanzas, the `cloudcli` s6 service, and
  the variant-aware bootstrap fork are all eliminated.

## Project Structure

### Documentation (this feature)

```text
specs/001-claude-shell-base/
├── plan.md              # This file
├── research.md          # Phase 0 — decisions and rationales
├── data-model.md        # Phase 1 — infrastructure entities
├── quickstart.md        # Phase 1 — minimal deploy/use steps
├── contracts/           # Phase 1 — env-var, volume, healthcheck, notification contracts
│   ├── compose-environment.md
│   ├── volumes.md
│   ├── healthcheck.md
│   └── notifications.md
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks command — NOT created here)
```

### Source Code (repository root)

This feature ships a deployment artifact, not application code. No `src/`
or `tests/` tree. Layout:

```text
KroClaude/
├── Dockerfile
├── docker-compose.yaml
├── .env.example                    # documented env vars; real .env is gitignored
├── .dockerignore
├── .gitignore
├── scripts/
│   ├── entrypoint.sh               # PID-1 handoff to s6; first-boot seed; ~30 LOC after FR-014 prune
│   └── notify.py                   # Apprise notification dispatcher; Stop/Error events
├── s6-overlay/
│   └── s6-rc.d/
│       └── xvfb/
│           ├── type                # "longrun"
│           └── run                 # one-line: exec Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp
├── config/
│   ├── settings.json               # Claude Code default settings; Stop/Error hooks → notify.py
│   └── CLAUDE.md                   # in-container default memory; concise, no docs site
├── tests/
│   └── smoke/
│       └── smoke.sh                # CI smoke test: claude/tools/non-root/healthcheck/volume-persist
├── .github/
│   └── workflows/
│       └── ci.yml                  # build → smoke → trivy on PR; release tag publishes image
└── specs/                          # Spec Kit artifacts (already present)
```

**Structure Decision**: deployment-artifact layout. Reasons: (1) no application
code is being written — the deliverable is the image and the compose contract;
(2) the surviving file inventory is small enough that a flat `scripts/` +
`config/` + `s6-overlay/` layout is more legible than nested module trees;
(3) the layout matches HolyClaude's structure (lower diff risk when porting),
minus the `vendor/`, `assets/`, `docs/`, and `.github/` website directories
that fall under FR-013 (no manuals/docs).

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| s6-overlay v3 retained as process supervisor for a single long-running service (Xvfb) — formally a deviation from FR-014's preference for a single-process container | (1) **User directive** in `/speckit-plan keep s6-overlay`. (2) Xvfb is required (FR-003b) and must run alongside an interactive shell session. (3) s6-overlay handles PID-1 duties (signal forwarding, zombie reaping, graceful shutdown) that any alternative would have to reinvent. | A bare entrypoint that backgrounds Xvfb (`Xvfb :99 & exec sleep infinity`) would lose restart-on-crash and signal handling — and writing those properly is *more* shell code than the one-line s6 run script. `tini` + a custom supervisor script gets us most of the way to s6 with worse correctness guarantees. The user has explicitly opted into s6's complexity. |
| `cap_add: SYS_ADMIN, SYS_PTRACE` + `security_opt: seccomp=unconfined` declared in the compose file | Required by Chromium's namespace/sandbox model for headless rendering (FR-003b). | Running Chromium with `--no-sandbox` only is fragile across Chromium upgrades and breaks under restrictive seccomp profiles. The constitution permits enumerated caps + seccomp relaxations as long as `privileged: true` is not used; both are commented inline tying to FR-003b. |
