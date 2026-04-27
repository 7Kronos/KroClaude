# Contract: Healthcheck

**Branch**: `001-claude-shell-base` | **Date**: 2026-04-27

The compose service declares a Docker healthcheck so that
`docker compose ps`, `docker inspect`, and Coolify's UI can show a
meaningful status.

## Canonical form

```yaml
services:
  kroclaude:
    # ...
    healthcheck:
      test: ["CMD-SHELL", "pgrep -x Xvfb >/dev/null && command -v claude >/dev/null"]
      interval: 30s
      timeout: 5s
      start_period: 30s
      retries: 3
```

## Semantics

- **Healthy**: Xvfb supervised process is running AND the `claude` binary
  is on `PATH`. This is the minimum signal that "the image started, the
  user can `docker exec` in and run Claude, and headless Chromium has its
  display server".
- **Starting**: during the 30 s `start_period`, failures do not flip the
  service to unhealthy. This covers the first-boot bootstrap window
  (SC-003 budgets <15 s; we double it for safety).
- **Unhealthy**: Xvfb has died and not been restarted by s6-overlay, OR
  the `claude` CLI was somehow removed from `PATH`. Both are bug
  conditions worth surfacing.

## Out of scope (deliberately)

- HTTP probe — there is no inbound port (CloudCLI is excluded per FR-004).
- `claude --version` — would shell out and add latency every 30 s; the
  binary's existence on PATH is sufficient.
- Notification stack health — notifications are silent-failure by design
  (FR-010); their state is not part of "container healthy".

## CI verification

The smoke test asserts that `docker inspect --format '{{.State.Health.Status}}' kroclaude` reaches `healthy` within 60 s of `docker compose up -d`.
