---

description: "Task list for KroClaude base image — feature 001-claude-shell-base"
---

# Tasks: Claude Code Shell Base Image

**Input**: Design documents from [/home/krs/Repos/KroClaude/specs/001-claude-shell-base/](.)
**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: smoke tests are included because they are mandated deliverables — Constitution §Build/Release/Workflow + each user story's Independent Test. They are **not** TDD-style contract or unit tests; the spec did not request those.

**Organization**: tasks are grouped by user story (US1, US2, US3) so each story can be implemented and validated independently. US1 alone is the MVP.

## Format

`- [ ] [TaskID] [P?] [Story?] Description with file path`

- **[P]**: parallelizable (different files, no dependency on incomplete tasks)
- **[Story]**: maps to user stories from [spec.md](spec.md) — US1, US2, US3
- File paths are absolute or repo-relative from the project root `/home/krs/Repos/KroClaude/`

## Path Conventions

Deployment-artifact layout per the plan's Structure Decision:

- `Dockerfile`, `docker-compose.yaml`, `.env.example`, `.dockerignore`, `.gitignore` at repo root
- `scripts/` — `entrypoint.sh`, `notify.py`
- `s6-overlay/s6-rc.d/xvfb/` — `type`, `run`
- `config/` — `settings.json`, `CLAUDE.md` (the in-container default, NOT the repo's CLAUDE.md)
- `tests/smoke/` — smoke test shell scripts
- `.github/workflows/` — CI

There is no `src/`, no `backend/`, no `frontend/`. This is a deployment artifact, not application code.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: scaffold the repo so foundational and story-phase tasks have somewhere to write files.

- [x] T001 Create directory layout per [plan.md §Project Structure](plan.md): `scripts/`, `s6-overlay/s6-rc.d/xvfb/`, `s6-overlay/s6-rc.d/user/contents.d/`, `config/`, `tests/smoke/`, `.github/workflows/` at repo root
- [x] T002 [P] Write `.gitignore` covering `.env`, `credentials*`, `node_modules/`, `__pycache__/`, `*.swp`, `.DS_Store`, `data/`, `docker-compose.override.y*ml`
- [x] T003 [P] Write `.dockerignore` covering `.git/`, `.github/`, `README.md`, `LICENSE`, `specs/`, `tests/`, `.env`, `data/`, `.idea/`, `.vscode/`, `*.swp`, `.DS_Store`
- [x] T004 [P] Write `.env.example` documenting only the variables in [contracts/compose-environment.md](contracts/compose-environment.md): `ANTHROPIC_API_KEY=` (required, no value), `TZ=UTC`, `GIT_USER_NAME=`, `GIT_USER_EMAIL=`, `NODE_OPTIONS=`, `NOTIFY_URLS=`. **Do NOT include** `PUID`, `PGID`, `VARIANT`, `HOLYCLAUDE_*` (per Q3, Q4 clarifications and FR-004)
- [x] T005 [P] Write minimal `README.md` at repo root: project name, one-paragraph description, link to [specs/001-claude-shell-base/quickstart.md](specs/001-claude-shell-base/quickstart.md), HolyClaude attribution (per Constitution §Build/Release/Workflow). Do not document features (FR-013 keeps manuals out of scope)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Dockerfile, compose file, entrypoint, supervisor service, default config, notification helper. Every user story phase depends on this phase.

**⚠️ CRITICAL**: No US task can begin until this phase is complete.

### Dockerfile core

- [x] T006 In `Dockerfile`: `FROM node:22-bookworm-slim`, set `ARG S6_OVERLAY_VERSION=3.2.0.2`, `ARG TARGETARCH`, `LABEL org.opencontainers.image.source=...`, set `ENV DEBIAN_FRONTEND=noninteractive LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DISPLAY=:99 DBUS_SESSION_BUS_ADDRESS=disabled: CHROMIUM_FLAGS="--no-sandbox --disable-gpu --disable-dev-shm-usage" CHROME_PATH=/usr/bin/chromium PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium`. Pin base by digest at release time (research R5)
- [x] T007 In `Dockerfile`: install s6-overlay v3 with checksum-verified tarballs, multi-arch via `TARGETARCH` (research R8). Install `xz-utils`, `curl`, `ca-certificates` first; download and extract noarch + arch-specific tarballs; rm tarballs
- [x] T008 In `Dockerfile`: install all FR-003 apt packages in one `apt-get install` layer — shell core (`git curl wget jq ripgrep fd-find unzip zip tree tmux fzf bat sudo bubblewrap`), build & language (`build-essential pkg-config python3 python3-pip python3-venv`), browser stack (`chromium xvfb fonts-liberation2 fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji`), locale (`locales`), debugging (`strace lsof iproute2 procps htop`), DB clients (`postgresql-client redis-tools sqlite3`), media (`imagemagick ffmpeg`), SSH client (`openssh-client`); `chmod u+s /usr/bin/bwrap` for Codex sandbox; `rm -rf /var/lib/apt/lists/*`
- [x] T009 In `Dockerfile`: install GitHub CLI from `cli.github.com` keyring (matches HolyClaude lines 82–86)
- [x] T010 In `Dockerfile`: symlink `/usr/bin/batcat` → `/usr/local/bin/bat`; run `sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen`
- [x] T011 In `Dockerfile`: rename base-image `node` user → `claude` at UID/GID 1000 (`usermod -l claude -d /home/claude -m node && groupmod -n claude node`); add NOPASSWD sudoers line for `claude`; `WORKDIR /workspace` and `chown` it to `claude`
- [x] T012 In `Dockerfile`: install Claude Code CLI (FR-002) — `USER claude`, `RUN curl -fsSL https://claude.ai/install.sh | bash`, `USER root`, `ENV PATH="/home/claude/.local/bin:${PATH}"` (research R5)
- [x] T013 [P] In `Dockerfile`: install npm globals per FR-003 — `npm i -g typescript tsx pnpm vite esbuild eslint prettier serve nodemon concurrently dotenv-cli lighthouse @google/gemini-cli @openai/codex` (FR-003 + FR-003a; explicit non-inclusion of `task-master-ai`, `cursor`, `junie`, `opencode-ai`, `wrangler`, `vercel`, `netlify-cli`, `pm2`, `prisma`, `drizzle-kit`, `eas-cli`, `@lhci/cli`, `sharp-cli`, `json-server`, `http-server`, `@marp-team/marp-cli`, `@cloudflare/next-on-pages`)
- [x] T014 [P] In `Dockerfile`: install pip packages with `--break-system-packages` per FR-003 — `requests httpx beautifulsoup4 lxml Pillow pandas numpy openpyxl python-docx jinja2 pyyaml python-dotenv markdown rich click tqdm playwright apprise xlsxwriter` (explicit non-inclusion of `reportlab weasyprint cairosvg fpdf2 PyMuPDF pdfkit img2pdf xlrd matplotlib seaborn python-pptx fastapi uvicorn httpie`)

### s6-overlay service

- [x] T015 [P] Write `s6-overlay/s6-rc.d/xvfb/type` containing exactly `longrun` (per [data-model.md §s6-overlay](data-model.md))
- [x] T016 [P] Write `s6-overlay/s6-rc.d/xvfb/run` with `#!/bin/sh` shebang and the body `exec Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp` (matches HolyClaude one-line script)
- [x] T017 In `Dockerfile`: `COPY s6-overlay/s6-rc.d/xvfb/type /etc/s6-overlay/s6-rc.d/xvfb/type`, `COPY s6-overlay/s6-rc.d/xvfb/run /etc/s6-overlay/s6-rc.d/xvfb/run`, `chmod +x /etc/s6-overlay/s6-rc.d/xvfb/run`, `touch /etc/s6-overlay/s6-rc.d/user/contents.d/xvfb`. Do NOT add a `cloudcli` service (FR-004)

### In-image config & helper scripts

- [x] T018 [P] Write `config/settings.json` per [contracts/notifications.md §Hook wiring](contracts/notifications.md): `permissions.defaultMode = "acceptEdits"`, `env.DISABLE_AUTOUPDATER = "1"`, `model = "sonnet"`, hooks for `Stop` → `/usr/local/bin/notify.py stop` and `PostToolUseFailure` → `/usr/local/bin/notify.py error`
- [x] T019 [P] Write `config/CLAUDE.md` — concise in-container default memory (NOT the repo CLAUDE.md). Cover: working dir is `/workspace`, persistent dirs are `/workspace` and `~/.claude`, available tools (one-line summary), git is preconfigured, notifications opt-in via `~/.claude/notify-on`. Keep under 80 lines (FR-013 — no manuals)
- [x] T020 [P] Write `scripts/notify.py` — Apprise dispatcher per [contracts/notifications.md](contracts/notifications.md): exit silently if `/home/claude/.claude/notify-on` missing OR no `NOTIFY_*` env var set; collect URLs from `NOTIFY_URLS` (comma-split) and any other `NOTIFY_*` (single URL each); map event arg (`stop`/`error`) to title/body; wrap Apprise call in broad try/except, exit 0 on any exception (FR-010). Shebang `#!/usr/bin/env python3`. ≤ 60 LOC

### Entrypoint (slim, FR-014)

- [x] T021 Write `scripts/entrypoint.sh` — ~30 LOC bash script per [research.md §R4, R7, R11](research.md). Responsibilities: (a) detect first boot via sentinel `/home/claude/.claude/.kroclaude-bootstrapped`; (b) if first boot, copy `/usr/local/share/kroclaude/{settings.json,CLAUDE.md}` → `/home/claude/.claude/`, seed Codex `/home/claude/.codex/{config.toml,hooks.json}` per research R7 (`approval_policy = "on-request"`, `sandbox_mode = "workspace-write"`, `[features] codex_hooks = true`, Stop hook → `notify.py stop`), seed Gemini `/home/claude/.gemini/settings.json` (SessionEnd hook → `notify.py stop`), run `git config --global` for user.name/email/safe.directory using `${GIT_USER_NAME:-KroClaude User}` / `${GIT_USER_EMAIL:-noreply@kroclaude.local}`, create `/home/claude/.claude.json` symlink → `/home/claude/.claude/.claude.json` (research R11), touch sentinel; (c) `export DISPLAY=:99`; (d) `exec /init "$@"` to hand off to s6-overlay PID 1. **Explicitly NO**: PUID/PGID remap, `~/.claude.json` background copy loop, Cursor/Junie/OpenCode symlinks, variant-aware fork

### Dockerfile finalization

- [x] T022 In `Dockerfile`: `COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh`, `COPY scripts/notify.py /usr/local/bin/notify.py`, `COPY config/settings.json /usr/local/share/kroclaude/settings.json`, `COPY config/CLAUDE.md /usr/local/share/kroclaude/CLAUDE.md`, `chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/notify.py`. Pre-create `/home/claude/.claude` and chown to claude
- [x] T023 In `Dockerfile`: set `WORKDIR /workspace`, `HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD pgrep -x Xvfb >/dev/null && command -v claude >/dev/null` per [contracts/healthcheck.md](contracts/healthcheck.md), `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`. **No `EXPOSE` directive** (FR-004; no inbound port in v1)

### Compose

- [x] T024 Write `docker-compose.yaml` per [contracts/](contracts/): single `kroclaude` service, `container_name: kroclaude`, `hostname: kroclaude`, `restart: unless-stopped`, `shm_size: 2g`, `cap_add: [SYS_ADMIN, SYS_PTRACE]` with one-line comment tying to FR-003b, `security_opt: [seccomp=unconfined]` with one-line comment tying to FR-003b, `environment` block listing only the variables in [contracts/compose-environment.md](contracts/compose-environment.md), `volumes:` mapping `kroclaude-config:/home/claude/.claude` and `kroclaude-workspace:/workspace`, top-level `volumes:` declaring `kroclaude-config:` and `kroclaude-workspace:` with no driver overrides. **No `ports:` block** (FR-004). **No `cap_add` or `security_opt` entries beyond the two pairs above** (FR-003b)

**Checkpoint**: foundation ready — Phase 3+ user-story work can begin.

---

## Phase 3: User Story 1 — Spin Up a Reproducible Claude Code Shell (Priority: P1) 🎯 MVP

**Goal**: from a clean checkout with Docker installed and an Anthropic API key, `docker compose up -d` produces a healthy container with `claude` and the curated tool set on PATH.

**Independent Test**: per [spec.md US1 Independent Test](spec.md). Smoke test asserts `claude --version` and a sample of FR-003 tools work.

### Smoke test

- [x] T025 [US1] Write `tests/smoke/test_us1.sh` shebang + setup: `set -euo pipefail`; expects working directory at repo root; uses `docker compose` v2; defines helpers for `assert_in_container` (runs `docker exec kroclaude bash -c "$1"`)
- [x] T026 [US1] In `tests/smoke/test_us1.sh`: bring stack up (`docker compose up -d --build`), wait up to 60 s for `docker inspect --format '{{.State.Health.Status}}' kroclaude` to equal `healthy`; fail with `docker logs kroclaude` dump on timeout (US1 acc 1)
- [x] T027 [US1] In `tests/smoke/test_us1.sh`: assert `docker exec kroclaude claude --version` exit 0 (US1 acc 2)
- [x] T028 [US1] In `tests/smoke/test_us1.sh`: assert sampled FR-003 tools resolve on PATH inside container — `gh`, `jq`, `rg`, `fd`, `tmux`, `bat`, `chromium`, `Xvfb`, `psql`, `redis-cli`, `sqlite3`, `ffmpeg`, `imagemagick` (`which $tool` exits 0 for each)
- [x] T029 [US1] In `tests/smoke/test_us1.sh`: assert `docker exec kroclaude id -un` returns `claude` (FR-005)
- [x] T030 [US1] In `tests/smoke/test_us1.sh`: assert `docker exec kroclaude bash -c 'DISPLAY=:99 chromium --headless --no-sandbox --dump-dom https://example.com'` returns HTML containing `Example Domain` (validates FR-003b end-to-end: Xvfb up + Chromium + caps right)
- [x] T031 [US1] In `tests/smoke/test_us1.sh`: teardown — `docker compose down` (volumes preserved); print PASS marker

### CI for US1

- [x] T032 [P] [US1] Write `.github/workflows/ci.yml` skeleton: triggers on `pull_request` and `push` to `main`; one job `build-and-smoke` running on `ubuntu-latest`; checkout, set up Docker Buildx, build image (`docker compose build --no-cache`), run `tests/smoke/test_us1.sh`, on failure upload `docker logs kroclaude` and `docker compose ps` as artifacts
- [x] T033 [P] [US1] In `.github/workflows/ci.yml`: add a `compose-config-validate` step running `docker compose --env-file .env.example config` and `docker compose --env-file /dev/null config` (per [contracts/compose-environment.md §Validation](contracts/compose-environment.md))

**Checkpoint**: User Story 1 is fully functional and testable independently — this is the MVP. Stop here to demo if the team wants.

---

## Phase 4: User Story 2 — Survive Restarts and Image Rebuilds Without Losing Work (Priority: P1)

**Goal**: persistent state (Claude credentials, project files) survives container recreation and image rebuilds; first-boot bootstrap seeds defaults idempotently.

**Independent Test**: per [spec.md US2 Independent Test](spec.md). Smoke test exercises the full down/rebuild/up cycle.

### Implementation note

Most US2 implementation lives in T021's first-boot stanza of `entrypoint.sh`. The tasks below add the test surface and the rebuild scenarios.

- [x] T034 [US2] Verify `scripts/entrypoint.sh` (from T021) implements the sentinel-guarded seeding correctly: re-read T021 against [contracts/volumes.md §Lifecycle invariants](contracts/volumes.md). Confirm idempotence (second boot is a no-op over user-modified files)
- [x] T035 [US2] Write `tests/smoke/test_us2.sh` shebang + helpers (similar to T025)
- [x] T036 [US2] In `tests/smoke/test_us2.sh`: empty-volume first-boot scenario — `docker compose down -v && docker compose up -d`; assert healthy within 60 s; assert `/home/claude/.claude/.kroclaude-bootstrapped` and `/home/claude/.claude/settings.json` exist; measure first-boot time and assert under 15 s (SC-003)
- [x] T037 [US2] In `tests/smoke/test_us2.sh`: workspace persistence scenario — `docker exec kroclaude bash -c 'echo persist-token > /workspace/.us2-token'`; `docker compose down`; `docker compose up -d`; wait healthy; assert `cat /workspace/.us2-token` returns `persist-token` (US2 acc 1)
- [x] T038 [US2] In `tests/smoke/test_us2.sh`: config persistence scenario — write `/home/claude/.claude/.us2-config-token`; recreate container; assert file persists
- [x] T039 [US2] In `tests/smoke/test_us2.sh`: rebuild scenario — `docker compose down`, `docker compose build --no-cache`, `docker compose up -d`; assert previously persisted files still exist (US2 acc 1, rebuild path)
- [x] T040 [US2] In `tests/smoke/test_us2.sh`: workspace-only wipe scenario — `docker compose down`, `docker volume rm kroclaude-workspace`, `docker compose up -d`; assert workspace is empty AND config volume is intact (US2 acc 2)
- [x] T041 [P] [US2] In `.github/workflows/ci.yml`: add `tests/smoke/test_us2.sh` to the `build-and-smoke` job after T032's US1 step

**Checkpoint**: US1 and US2 both work independently.

---

## Phase 5: User Story 3 — Get Notified When Claude Finishes or Fails (Priority: P2)

**Goal**: opt-in notifications fire on `Stop`/`PostToolUseFailure` for Claude, `Stop` for Codex, and `SessionEnd` for Gemini, via Apprise; stay silent when not opted in; never crash on misconfiguration.

**Independent Test**: per [spec.md US3 Independent Test](spec.md). Smoke test verifies the dispatcher's gate behavior end-to-end without sending real network notifications.

### Implementation tasks

- [x] T042 [US3] Verify `scripts/notify.py` (from T020) matches [contracts/notifications.md §Failure handling](contracts/notifications.md): no exception escapes `main()`; exit 0 on apprise import failure
- [x] T043 [US3] Verify `config/settings.json` (from T018) hooks block matches [contracts/notifications.md §Hook wiring](contracts/notifications.md) verbatim
- [x] T044 [US3] Verify `scripts/entrypoint.sh` (from T021) seeds Codex `~/.codex/hooks.json` with `Stop → notify.py stop` and Gemini `~/.gemini/settings.json` with `SessionEnd → notify.py stop` per [research.md R7](research.md)

### Smoke test

- [x] T045 [US3] Write `tests/smoke/test_us3.sh` shebang + helpers
- [x] T046 [US3] In `tests/smoke/test_us3.sh`: assert `/usr/local/bin/notify.py` exists, is executable, and `python3 -c 'import apprise'` succeeds inside the container
- [x] T047 [US3] In `tests/smoke/test_us3.sh`: gate-1 silent — without sentinel `notify-on` and without any `NOTIFY_*`, run `notify.py stop`; assert exit 0 and empty stdout/stderr
- [x] T048 [US3] In `tests/smoke/test_us3.sh`: gate-2 silent — touch `notify-on`, set `NOTIFY_URLS=` (empty), run `notify.py stop`; assert exit 0 and empty stdout/stderr (no destination)
- [x] T049 [US3] In `tests/smoke/test_us3.sh`: silent-fail — touch `notify-on`, set `NOTIFY_URLS=tgram://invalid_token`, run `notify.py stop`; assert exit 0 and no traceback in stderr (FR-010)
- [x] T050 [US3] In `tests/smoke/test_us3.sh`: assert seeded Codex `~/.codex/hooks.json` and Gemini `~/.gemini/settings.json` reference `/usr/local/bin/notify.py stop`
- [x] T051 [US3] In `tests/smoke/test_us3.sh`: cleanup — remove `notify-on` sentinel; teardown
- [x] T052 [P] [US3] In `.github/workflows/ci.yml`: add `tests/smoke/test_us3.sh` to the `build-and-smoke` job after T041's US2 step

**Checkpoint**: all three user stories independently functional.

---

## Phase 6 (Final): Polish & Cross-Cutting Concerns

**Purpose**: enforce constitutional non-negotiables (security scan, image-size budget, secrets check, multi-arch, attribution).

- [x] T053 [P] In `.github/workflows/ci.yml`: add `trivy-scan` job — `aquasecurity/trivy-action@master` with `severity: HIGH,CRITICAL` and `exit-code: 1`. Reads optional `.trivyignore` (do NOT create it preemptively per [research.md §Open items](research.md))
- [x] T054 [P] In `.github/workflows/ci.yml`: add `image-size-budget` job — measure compressed image size, compare against a stored baseline (start with no baseline; baseline established on first merge to main; PRs >10% over baseline fail per Constitution Principle III)
- [x] T055 [P] In `.github/workflows/ci.yml`: add `secrets-in-history` job — `docker history --no-trunc kroclaude:ci | grep -E 'ANTHROPIC_API_KEY=|NOTIFY_[A-Z_]+=' && exit 1 || exit 0` (SC-005)
- [x] T056 [P] In `.github/workflows/ci.yml`: add `multi-arch-release` job — runs only on `push` of a `v*.*.*` tag; uses `docker buildx build --push --platform linux/amd64,linux/arm64` to the registry (registry/owner TBD before the first release tag — leave as `${{ vars.REGISTRY }}/${{ vars.IMAGE_NAME }}` placeholder per research R8)
- [x] T057 [P] Write `CHANGELOG.md` at repo root with initial v1.0.0 entry summarizing what's in scope vs HolyClaude (CloudCLI excluded, profile system removed, named volumes only, slim entrypoint, three AI CLIs)
- [x] T058 [P] Write `THIRD-PARTY-NOTICES` at repo root attributing HolyClaude (`https://github.com/CoderLuii/HolyClaude`) and preserving its license per the constitution's Build/Release/Workflow section. Note Apprise (Python), s6-overlay (BSD-style), Chromium (BSD), and the AI CLI npm packages
- [x] T059 FR coverage audit: walk every FR in [spec.md](spec.md) (FR-001 through FR-014, plus FR-003a, FR-003b) and confirm each is exercised by at least one task above — produce a short table in PR description; flag any uncovered FR before declaring v1 done
- [x] T060 SC coverage audit: walk every SC in [spec.md](spec.md) (SC-001 through SC-005) and confirm each is enforceable by a CI step or manual procedure documented in [quickstart.md](quickstart.md); flag any uncovered SC

---

## Dependencies & Execution Order

### Phase dependencies

- **Phase 1 (Setup)**: no dependencies — can start immediately
- **Phase 2 (Foundational)**: depends on Phase 1 — BLOCKS all user-story phases
- **Phase 3 (US1, MVP)**: depends on Phase 2 only
- **Phase 4 (US2)**: depends on Phase 2; can run in parallel with Phase 3 (different smoke files, but the entrypoint logic from T021 must already be present)
- **Phase 5 (US3)**: depends on Phase 2 (notify.py from T020, settings.json from T018, entrypoint seeds from T021); can run in parallel with Phase 4
- **Phase 6 (Polish)**: depends on at least Phase 3 having a passing CI workflow file to extend

### Within Phase 2 (Foundational)

- T006 → T007 → T008 → T009 → T010 → T011 → T012 are sequential Dockerfile layers (each depends on the previous)
- T013 (npm globals) and T014 (pip packages) can run in parallel (different RUN layers in the Dockerfile, no shared state)
- T015, T016, T018, T019, T020 can all run in parallel (different files: `s6-overlay/...`, `config/...`, `scripts/notify.py`)
- T017 depends on T015 + T016 (Dockerfile COPY)
- T021 (entrypoint.sh) can run in parallel with T013–T020 (different file)
- T022, T023 (Dockerfile COPY + finalize) depend on T015–T021
- T024 (compose) is independent of the Dockerfile but cannot be smoke-tested until T023 lands

### Within each user story

- Smoke tests can be drafted in parallel with implementation (different files), but only run green after the implementation tasks they depend on land
- Within a single test file, the steps inside the file are sequential by nature
- Different user stories can be picked up by different developers in parallel after Phase 2

### Parallel opportunities

- All of Phase 1 except T001: T002, T003, T004, T005 in parallel
- Within Phase 2: T013, T014, T015, T016, T018, T019, T020, T021 in parallel
- Phase 4 and Phase 5 in parallel after Phase 2
- All Phase 6 tasks (T053–T058) in parallel

---

## Parallel Example: Phase 2 burst

```bash
# Once T006–T012 are committed, fan out:
Task: "T013 — install npm globals (Dockerfile RUN layer)"
Task: "T014 — install pip packages (Dockerfile RUN layer)"
Task: "T015 — write s6-overlay/s6-rc.d/xvfb/type"
Task: "T016 — write s6-overlay/s6-rc.d/xvfb/run"
Task: "T018 — write config/settings.json"
Task: "T019 — write config/CLAUDE.md"
Task: "T020 — write scripts/notify.py"
Task: "T021 — write scripts/entrypoint.sh"
# Then converge on T022, T023 (Dockerfile finalize), T024 (compose)
```

---

## Implementation Strategy

### MVP first (User Story 1 only)

1. Phase 1 (Setup) — scaffold the repo
2. Phase 2 (Foundational) — Dockerfile + compose + entrypoint + s6 + notify.py
3. Phase 3 (US1) — smoke + CI
4. **STOP and validate**: `docker compose up -d` produces a healthy container, `claude --version` works, tools are present
5. Tag `v0.1.0` (pre-release MVP) and demo

### Incremental delivery

1. Setup + Foundational → no user-visible change yet
2. + US1 → MVP (working Claude shell) — `v0.1.0`
3. + US2 → daily-driver-grade (state survives) — `v0.2.0`
4. + US3 → polished (notifications) — `v0.3.0`
5. + Phase 6 (Polish) → release candidate — `v1.0.0-rc.1`
6. Trivy clean + image-size baseline locked + multi-arch built and pushed → `v1.0.0`

### Parallel team strategy

After Phase 2 completes:

- Developer A: Phase 3 (US1 smoke + CI)
- Developer B: Phase 4 (US2 smoke + entrypoint refinements)
- Developer C: Phase 5 (US3 smoke + helper polish)

Phase 6 polish can be split task-by-task across the team (each task is `[P]`).

---

## Notes

- `[P]` = different files, no dependency on incomplete tasks
- `[US#]` maps to a user story in [spec.md](spec.md) for traceability
- Each user story is independently testable via its `tests/smoke/test_us#.sh`
- Smoke tests are mandated deliverables (Constitution §Build/Release/Workflow + each user story's Independent Test), not TDD contract/unit tests
- Avoid: re-introducing CloudCLI artifacts (FR-004), `PUID`/`PGID` (Q3), `VARIANT` build arg (Q4), Cursor/Junie/OpenCode CLIs (Q1), HolyClaude `bootstrap.sh` as a separate file (research R4 merges it into entrypoint), or the 60-second `~/.claude.json` copy loop (research R11)
- Commit after each task or logical group; the project uses `[Spec Kit] ...` style commit messages where appropriate
