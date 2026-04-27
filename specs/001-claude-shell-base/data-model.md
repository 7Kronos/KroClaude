# Phase 1 Data Model: Claude Code Shell Base Image

**Branch**: `001-claude-shell-base` | **Date**: 2026-04-27

This feature has no application data model. The "entities" are the
infrastructure objects that the deployment artifact creates and contracts
about. They are documented here for traceability and to drive the contracts
in [contracts/](contracts/).

## Entity: Container Image

| Field | Value / Constraint |
|-------|--------------------|
| Name (registry) | `ghcr.io/<owner>/kroclaude` (final org TBD at release) |
| Base | `node:22-bookworm-slim` (pinned by digest at release) |
| Architectures | `linux/amd64`, `linux/arm64` |
| Tagging | semver: `1.0.0`, `1.0`, `1`, `latest` for stable; `main-<sha>` for development builds |
| Default user (runtime) | `claude` (UID 1000, GID 1000 — fixed at build time) |
| Default workdir | `/workspace` |
| Entrypoint | `/usr/local/bin/entrypoint.sh` → `exec /init` (s6-overlay) |
| Env exposed at runtime | `ANTHROPIC_API_KEY` (required), `NOTIFY_*` (optional), `TZ`, `GIT_USER_NAME`, `GIT_USER_EMAIL` |
| Healthcheck | per [contracts/healthcheck.md](contracts/healthcheck.md) |
| Inbound ports | none in v1 |

Lifecycle: built in CI on PR (smoke-validated, not pushed); built and
pushed on tag (semver-validated, scanned by Trivy, manifest list for
multi-arch).

## Entity: Configuration Volume (`kroclaude-config`)

| Field | Value / Constraint |
|-------|--------------------|
| Mount point | `/home/claude/.claude` |
| Driver | Docker `local` (default named volume) |
| Initial state | empty on first deploy; entrypoint seeds defaults |
| Contents (after first boot) | `settings.json`, `CLAUDE.md`, `.codex/{config.toml,hooks.json}`, `.gemini/settings.json`, `.bash_history`, `.kroclaude-bootstrapped` (sentinel), Claude credentials cache |
| Backup expectation | Coolify volume backup includes this volume; restore restores credentials and config |
| Survives | container recreation, image rebuild, host reboot |
| Wipeable independently | yes (does not affect workspace) |

## Entity: Workspace Volume (`kroclaude-workspace`)

| Field | Value / Constraint |
|-------|--------------------|
| Mount point | `/workspace` |
| Driver | Docker `local` (default named volume) |
| Initial state | empty on first deploy; no seeding |
| Contents | user project files (anything created/cloned inside `/workspace`) |
| Backup expectation | Coolify volume backup includes this volume; users may exclude if too large |
| Survives | container recreation, image rebuild, host reboot |
| Wipeable independently | yes (does not affect Claude credentials) |
| Bind-mounted in v1 | NO (per Q3 clarification — named volume only) |

## Entity: Notification Channel

| Field | Value / Constraint |
|-------|--------------------|
| Source | one or more `NOTIFY_*` env vars (Apprise-compatible URLs, e.g., `tgram://…`, `discord://…`, `mailto://…`) |
| Activation | requires sentinel file `/home/claude/.claude/notify-on` AND at least one non-empty `NOTIFY_*` env var |
| Events fired | `Stop` (Claude task complete), `PostToolUseFailure` (tool error) — wired in `config/settings.json`'s hooks |
| Failure mode | silent — `notify.py` exits 0 on any exception; the running Claude session is never disrupted (FR-010) |
| Owner of credentials | the user — `NOTIFY_*` URLs typically embed tokens; never logged, never written to disk by KroClaude |

## Entity: First-Boot Sentinel

| Field | Value / Constraint |
|-------|--------------------|
| Path | `/home/claude/.claude/.kroclaude-bootstrapped` |
| Created by | `entrypoint.sh` after the first-boot seeding stanza succeeds |
| Effect when present | entrypoint skips re-seeding on subsequent boots (FR-008) |
| Effect when absent (manual delete) | next boot re-seeds defaults; useful for resetting config |
| Stored in | the Configuration Volume — survives container recreation by design |

## Entity: s6-overlay Service Bundle

| Field | Value / Constraint |
|-------|--------------------|
| Bundle root | `/etc/s6-overlay/s6-rc.d/` |
| Services declared | `xvfb` only (CloudCLI service from HolyClaude removed) |
| `xvfb` type | `longrun` |
| `xvfb` run command | `exec Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp` |
| Activation | symlink in `/etc/s6-overlay/s6-rc.d/user/contents.d/xvfb` |
| Restart policy | s6 default (restart-on-exit) |

There are no relationships in the relational sense; the entities form a
simple containment hierarchy: Container Image runs from a host, mounts
both volumes, exposes the Notification Channel, and runs the s6-overlay
Service Bundle as PID 1.
