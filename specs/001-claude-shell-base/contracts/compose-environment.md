# Contract: Compose Environment Variables

**Branch**: `001-claude-shell-base` | **Date**: 2026-04-27

This is the user-facing contract for environment variables read by the
container at runtime. The compose file (`docker-compose.yaml`) and the
`.env.example` file MUST stay in sync with this contract.

## Required

| Variable | Purpose | Where read | Notes |
|----------|---------|------------|-------|
| `ANTHROPIC_API_KEY` | authenticates the Claude Code CLI | Claude CLI process env | No default. If missing, the container still starts (so the user can fix it from inside) but `claude` use surfaces a clear error per the Edge Cases section of [spec.md](../spec.md). MUST never be written to disk or baked into the image. |

## Optional — runtime configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `TZ` | `UTC` | container timezone |
| `GIT_USER_NAME` | `KroClaude User` | seeded into `git config --global user.name` on first boot |
| `GIT_USER_EMAIL` | `noreply@kroclaude.local` | seeded into `git config --global user.email` on first boot |
| `NODE_OPTIONS` | unset | passed through to Node-based CLIs; `--max-old-space-size=4096` is a common override |

## Optional — notifications (per [contracts/notifications.md](notifications.md))

| Variable | Default | Purpose |
|----------|---------|---------|
| `NOTIFY_URLS` | unset | comma-separated list of Apprise URLs |
| `NOTIFY_TELEGRAM` / `NOTIFY_DISCORD` / `NOTIFY_SLACK` / `NOTIFY_<...>` | unset | individual Apprise URLs; any env var beginning with `NOTIFY_` (other than `NOTIFY_URLS`) is treated as a single URL |

Notifications also require the sentinel file `/home/claude/.claude/notify-on` to exist (created by the user explicitly — `touch /home/claude/.claude/notify-on` from inside the container). This dual-gate (env var + sentinel) prevents accidental notifications on first deploy.

## Forbidden

The following MUST NOT appear as environment variables in the compose file:

- Any value that looks like a credential (API key, token, password) — must
  come from a secret store or the user's `.env` file, never committed.
- Any HolyClaude-era variables tied to CloudCLI: `HOLYCLAUDE_HOST_PORT`,
  references to port 3001, etc.
- `PUID` / `PGID` — runtime UID/GID remap is not supported (per Q3
  clarification). The compose file MUST NOT document or read these.
- `VARIANT` — the profile system is removed (per Q4 clarification).

## Validation

CI runs `docker compose --env-file /dev/null config` to confirm the
compose file is parseable without any user-supplied env values, and
`docker compose --env-file .env.example config` to confirm the
documented example produces a valid configuration.
