# Changelog

All notable changes to KroClaude will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Image tag versions are independent of the project constitution version.

## [1.0.0] — Unreleased (target)

### Added

- Initial Coolify-deployable Docker image based on `node:24-bookworm-slim`.
- Claude Code CLI installed via the official native installer.
- Codex CLI (`@openai/codex`) and Gemini CLI (`@google/gemini-cli`).
- Curated apt + npm + pip toolchain (see
  [`specs/001-claude-shell-base/spec.md`](specs/001-claude-shell-base/spec.md)
  FR-003 for the canonical inventory).
- Headless Chromium support with `Xvfb` supervised by `s6-overlay` v3.
- Two named Docker volumes (`kroclaude-config`, `kroclaude-workspace`)
  for separable persistence of credentials and project files.
- First-boot config seeding via a sentinel-guarded entrypoint stanza
  (no separate `bootstrap.sh`).
- Opt-in Apprise-based notifications via `scripts/notify.py`,
  double-gated on a sentinel file and the presence of `NOTIFY_*` env vars.
- CI: build + smoke (US1 / US2 / US3), Trivy scan, image-size budget,
  secrets-in-history check, and tag-driven multi-arch publish.

### Excluded vs. HolyClaude reference

- The `@siteboon/claude-code-ui` web UI ("CloudCLI"), its plugins, and
  all WebSocket / Shell-scroll / model patches against it (FR-004).
- Cursor CLI, Junie CLI, OpenCode CLI, `task-master-ai` (Q1 clarification).
- The `slim` / `full` profile system and the `VARIANT` build arg
  (Q4 clarification).
- `PUID` / `PGID` runtime UID/GID remapping and the corresponding
  entrypoint logic (Q3 clarification).
- `~/.claude.json` 60-second background copy loop (research R11).
- Azure CLI and various vendor deploy CLIs (Wrangler, Vercel, Netlify,
  PM2, Prisma, Drizzle, eas-cli, etc.) — see
  [`specs/001-claude-shell-base/spec.md`](specs/001-claude-shell-base/spec.md)
  Clarifications session for the full list.

### Attribution

KroClaude is inspired by HolyClaude
(<https://github.com/CoderLuii/HolyClaude>); see
[`THIRD-PARTY-NOTICES`](THIRD-PARTY-NOTICES) for the upstream license
and credit.
