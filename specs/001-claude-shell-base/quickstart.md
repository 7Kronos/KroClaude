# Quickstart: Claude Code Shell Base Image

**Branch**: `001-claude-shell-base` | **Date**: 2026-04-27

This is the minimum path from a clean checkout to a working Claude shell.
It is NOT a manual (FR-013 keeps user-facing manuals out of scope); it is
the smallest doc the build/CI/release flow can reference.

## Prerequisites

- Docker Engine 24+ and Docker Compose v2 installed
- An Anthropic API key

## Steps

1. **Clone and configure**:
   ```sh
   git clone <repo-url> kroclaude
   cd kroclaude
   cp .env.example .env
   $EDITOR .env   # set ANTHROPIC_API_KEY at minimum
   ```

2. **Bring the stack up**:
   ```sh
   docker compose up -d
   ```
   The image pulls (or builds) and starts. First-boot bootstrap takes
   under 15 s (SC-003).

3. **Open an interactive shell**:
   ```sh
   docker exec -it kroclaude bash
   ```
   You are now `claude@kroclaude:/workspace`. Run `claude` to start a
   Claude Code session. The curated tool set (per FR-003) is on `PATH`.

4. **Verify health** (any of the below):
   ```sh
   docker compose ps                 # STATE: running, HEALTH: healthy
   docker inspect --format '{{.State.Health.Status}}' kroclaude
   ```

## Coolify deployment

1. Create a new application of type "Docker Compose".
2. Point it at this repository; Coolify reads `docker-compose.yaml`
   directly.
3. Set `ANTHROPIC_API_KEY` (and any optional `NOTIFY_*` URLs) as
   Coolify secrets.
4. Deploy. The two named volumes (`kroclaude-config`,
   `kroclaude-workspace`) are managed by Coolify and survive redeploys.
5. To open a shell on a Coolify-managed instance, use the Coolify
   terminal UI — it runs `docker exec` under the hood, matching local
   usage.

## Opt in to notifications (optional)

```sh
docker exec -it kroclaude bash
touch /home/claude/.claude/notify-on
exit
```

Then set at least one `NOTIFY_*` env var in `.env` (or Coolify secret).
See [contracts/notifications.md](contracts/notifications.md) for the
event/URL contract.

## Reset state

- **Forget Claude credentials**: `docker volume rm kroclaude-config` (then `docker compose up -d` to re-seed defaults).
- **Wipe workspace files**: `docker volume rm kroclaude-workspace` (credentials remain).
- **Re-seed default config without losing credentials**: from inside the
  container, `rm /home/claude/.claude/.kroclaude-bootstrapped` and
  restart.

## Troubleshooting (terse)

| Symptom | First check |
|---------|-------------|
| `claude` says "no API key" | `.env` has `ANTHROPIC_API_KEY=...` and you ran `docker compose up -d` (not `start`) after editing it |
| Container is `unhealthy` | `docker logs kroclaude` — look for Xvfb crash; `cap_add` settings might be missing |
| Playwright/Puppeteer fails launching Chromium | confirm compose file still has `cap_add: SYS_ADMIN, SYS_PTRACE` and `security_opt: seccomp=unconfined` (FR-003b) |
| Files I created are gone after redeploy | the file was outside `/workspace` or `/home/claude/.claude` — those are the only persistent paths |
