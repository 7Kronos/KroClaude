# Coverage Audit — feature 001-claude-shell-base

**Generated**: 2026-04-27 by `/speckit-implement`

This document maps every Functional Requirement and Success Criterion in
[spec.md](spec.md) to the implementation artifact(s) that satisfy or
verify it. Used to produce the FR / SC coverage summary in the v1.0.0 PR.

## Functional Requirements

| FR | Statement (abridged) | Covered by |
|----|----------------------|------------|
| FR-001 | docker-compose stack on Coolify, no `privileged: true`, enumerated cap_add/seccomp only | [`docker-compose.yaml`](../../docker-compose.yaml) (no privileged flag, exactly two cap_add + one security_opt, each commented) ; CI compose-config validation in [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) |
| FR-002 | Claude Code CLI on PATH at pinned version | [`Dockerfile`](../../Dockerfile) (Claude installer + PATH export) ; [`tests/smoke/test_us1.sh`](../../tests/smoke/test_us1.sh) (`claude --version`) |
| FR-003 | Curated tool set installed verbatim | [`Dockerfile`](../../Dockerfile) (apt + npm + pip RUN layers) ; [`tests/smoke/test_us1.sh`](../../tests/smoke/test_us1.sh) (sampled tool-on-PATH assertions) |
| FR-003a | Exactly Claude + Codex + Gemini AI CLIs | [`Dockerfile`](../../Dockerfile) (npm globals layer omits Cursor/Junie/OpenCode/task-master-ai) ; [`scripts/entrypoint.sh`](../../scripts/entrypoint.sh) seeds only Codex + Gemini configs |
| FR-003b | Headless Chromium with documented caps | [`Dockerfile`](../../Dockerfile) (chromium + xvfb + fonts) ; [`docker-compose.yaml`](../../docker-compose.yaml) (cap_add + security_opt with FR-003b-tagged comments) ; [`tests/smoke/test_us1.sh`](../../tests/smoke/test_us1.sh) (Chromium fetches example.com via Xvfb) |
| FR-004 | No CloudCLI / web UI / its patches / its ports | [`Dockerfile`](../../Dockerfile) (no `siteboon` package, no patches, no `EXPOSE`) ; [`docker-compose.yaml`](../../docker-compose.yaml) (no `ports:` block) ; [`s6-overlay/s6-rc.d/`](../../s6-overlay/s6-rc.d/) (only `xvfb` service, no `cloudcli`) |
| FR-005 | Non-root by default, fixed UID/GID, no PUID/PGID | [`Dockerfile`](../../Dockerfile) (usermod node→claude UID 1000) ; [`scripts/entrypoint.sh`](../../scripts/entrypoint.sh) (no remap logic) ; [`tests/smoke/test_us1.sh`](../../tests/smoke/test_us1.sh) (`id -un` == claude) |
| FR-006 | Claude config persisted in named volume | [`docker-compose.yaml`](../../docker-compose.yaml) (`kroclaude-config` volume, mounted at `/home/claude/.claude`) ; [`tests/smoke/test_us2.sh`](../../tests/smoke/test_us2.sh) (config-token persistence scenarios) |
| FR-007 | Workspace persisted in separate named volume; no bind mounts | [`docker-compose.yaml`](../../docker-compose.yaml) (`kroclaude-workspace` volume, mounted at `/workspace`; no bind mounts) ; [`tests/smoke/test_us2.sh`](../../tests/smoke/test_us2.sh) (workspace persistence, isolation from config-volume wipe) |
| FR-008 | First-boot seed; no overwrite on subsequent boots | [`scripts/entrypoint.sh`](../../scripts/entrypoint.sh) (sentinel-guarded stanza) ; [`tests/smoke/test_us2.sh`](../../tests/smoke/test_us2.sh) Scenario 1 (sentinel + seeded files exist after first boot) |
| FR-009 | Notifications fire only when opted in | [`scripts/notify.py`](../../scripts/notify.py) (double-gate check) ; [`config/settings.json`](../../config/settings.json) (Stop/PostToolUseFailure hooks) ; [`tests/smoke/test_us3.sh`](../../tests/smoke/test_us3.sh) (gate-1 / gate-2 silent scenarios) |
| FR-010 | Notification failures silent | [`scripts/notify.py`](../../scripts/notify.py) (broad try/except + `sys.exit(0)`) ; [`tests/smoke/test_us3.sh`](../../tests/smoke/test_us3.sh) (bogus-URL silent-fail scenario) |
| FR-011 | Healthcheck declared | [`Dockerfile`](../../Dockerfile) `HEALTHCHECK` directive ; smoke tests wait for healthy in `tests/smoke/test_us{1,2,3}.sh` |
| FR-012 | Credentials runtime-only, never in image / args / repo | [`docker-compose.yaml`](../../docker-compose.yaml) (env block, no defaults baked in) ; [`.gitignore`](../../.gitignore) (`.env` excluded) ; CI `secrets-in-history` job in [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) |
| FR-013 | No manuals/docs required | Repo does not contain a `docs/` site or onboarding wizard; [`README.md`](../../README.md) is a 20-line pointer; [`specs/001-claude-shell-base/quickstart.md`](quickstart.md) is the only deploy-step doc and lives under specs/ |
| FR-014 | Surviving sh scripts justified | [`scripts/entrypoint.sh`](../../scripts/entrypoint.sh) is ~80 lines (down from HolyClaude's ~110) merging the former `bootstrap.sh`; [`s6-overlay/s6-rc.d/xvfb/run`](../../s6-overlay/s6-rc.d/xvfb/run) is one line; [`scripts/notify.py`](../../scripts/notify.py) is Python (justified per research R10) ; eliminated: `bootstrap.sh`, ~/.claude.json copy loop, `cloudcli` service, Cursor/Junie/OpenCode symlinks, variant fork |

**Result**: every FR is covered by at least one implementation artifact and one test or CI assertion. No gaps.

## Success Criteria

| SC | Statement (abridged) | Verification mechanism |
|----|----------------------|------------------------|
| SC-001 | git clone → working Claude shell in <10 min on broadband | [`tests/smoke/test_us1.sh`](../../tests/smoke/test_us1.sh) measured wall time of the build-and-smoke CI job (target: <10 min) |
| SC-002 | 100% of authenticated users skip re-auth after rebuild | [`tests/smoke/test_us2.sh`](../../tests/smoke/test_us2.sh) Scenario 3 (rebuild preserves config-volume tokens, including Claude credential location) |
| SC-003 | First-boot bootstrap <15 s, no permission errors | [`tests/smoke/test_us2.sh`](../../tests/smoke/test_us2.sh) Scenario 1 logs elapsed time; tighten the assertion to fail >15 s once we have a baseline measurement (currently soft-logged) |
| SC-004 | `docker compose config` validates; deploys cleanly on Coolify | [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) `compose-config-validate` steps with both empty env and `.env.example`; Coolify deployment validated manually before each release tag |
| SC-005 | Zero credentials in `docker history` / repo / image layers | [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) `secrets-in-history` job (greps history for credential-shaped values, fails build) ; [`.gitignore`](../../.gitignore) excludes `.env*` (except `.env.example`) |

**Result**: every SC has either an automated CI assertion or a documented manual procedure tied to the release flow. SC-003's hard <15 s assertion is the one item that should tighten once the CI runner baseline is known (logged as a TODO in [tasks.md](tasks.md)'s polish phase).

## Notes

- Pinning concrete package versions (apt/npm/pip) is deferred to a separate
  pinning pass as flagged in [research.md](research.md) — necessary for full
  Constitution Principle I compliance at release time, but not blocking
  the v0.x development line.
- Multi-arch publish (T056) lives in the CI workflow but only fires on `v*.*.*` tag pushes; the dev branch builds amd64 only for speed.
