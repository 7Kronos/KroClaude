# Contract: Healthcheck (delta vs feature 001)

**Branch**: `003-ssh-access` | **Date**: 2026-04-28

This contract **replaces** feature 001's healthcheck command with an
extended version. Cadence (interval, timeout, start-period, retries)
is unchanged.

## New canonical form

```yaml
services:
  kroclaude:
    # ...
    healthcheck:
      test:
        - CMD-SHELL
        - >-
          pgrep -x Xvfb >/dev/null
          && command -v claude >/dev/null
          && bash -c '</dev/tcp/127.0.0.1/2221' 2>/dev/null
      interval: 30s
      timeout: 5s
      start_period: 30s
      retries: 3
```

The Dockerfile `HEALTHCHECK` directive must mirror this. Feature 001's
Dockerfile currently has:

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD pgrep -x Xvfb >/dev/null && command -v claude >/dev/null
```

It MUST be updated to:

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD pgrep -x Xvfb >/dev/null \
     && command -v claude >/dev/null \
     && bash -c '</dev/tcp/127.0.0.1/2221' 2>/dev/null
```

## Semantics

| State | Condition |
|-------|-----------|
| **Healthy** | Xvfb supervised process is running AND `claude` is on `PATH` AND sshd is listening on 2221 inside the container. |
| **Starting** | during the 30 s `start_period`, failures don't flip the service to unhealthy — covers first-boot host-key generation (~2 s) and sshd startup. |
| **Unhealthy** | any of the three checks fails, including a sshd crash that s6 hasn't restarted yet (3 × 30 s before flip = ~90 s window). |

## Why the bash TCP-builtin

- No new package needed (bash is the base shell).
- Faster than `nc` / `ss` invocations (no fork-exec of an external
  binary).
- Verifies the same property the feature cares about: "a TCP listener
  is on this port right now."

## Out of scope (deliberately)

- A full SSH-handshake probe — too heavy for a 30 s tick, generates
  spurious sshd log entries; auth is exercised by
  `tests/smoke/test_us4.sh`, not the healthcheck.
- Verifying SSH host keys' fingerprints from inside the healthcheck
  — orthogonal property, covered by the smoke test (SC-002).

## CI verification

The smoke test [`tests/smoke/test_us4.sh`](../../../tests/smoke/test_us4.sh)
asserts that:

1. `docker inspect --format '{{.State.Health.Status}}' kroclaude`
   reaches `healthy` within 60 s of `docker compose up -d` (matches
   feature 001's existing budget).
2. After deliberately killing sshd inside the container (`docker exec
   kroclaude pkill -9 sshd`), the container's status flips to
   `unhealthy` within 90 s (3 retries × 30 s).
3. After s6 restarts sshd, the status flips back to `healthy` within
   another two intervals.

Item 1 runs unconditionally in CI; items 2 and 3 are part of the same
smoke run since they exercise the supervisor path.
