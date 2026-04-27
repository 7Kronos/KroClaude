# Contract: Notifications

**Branch**: `001-claude-shell-base` | **Date**: 2026-04-27

The container can deliver "Claude task complete" and "Claude tool error"
notifications to user-configured channels via [Apprise](https://github.com/caronc/apprise).
The capability is **off by default** and requires a deliberate two-step
opt-in.

## Opt-in mechanism

The notification dispatcher (`/usr/local/bin/notify.py`) sends a
notification only when BOTH of the following are true:

1. The sentinel file `/home/claude/.claude/notify-on` exists. The user
   creates it once, from inside the container:
   ```sh
   touch /home/claude/.claude/notify-on
   ```
2. At least one environment variable matching `NOTIFY_*` is set and
   non-empty. `NOTIFY_URLS` (comma-separated) and any other
   `NOTIFY_<NAME>` (single URL) are both supported.

If either gate is missing, `notify.py` exits silently with status 0.

## Events

| Event | Source | Trigger | Title | Body |
|-------|--------|---------|-------|------|
| `stop` | Claude Code (`Stop` hook), Codex (`Stop` hook), Gemini (`SessionEnd` hook) | a session ends successfully | "KroClaude — Task Complete" | "Claude has finished the current task." |
| `error` | Claude Code (`PostToolUseFailure` hook) | a tool invocation fails | "KroClaude — Something Went Wrong" | "A tool use failure occurred. Check the session for details." |

The event names map to `notify.py <event>` invocation:

```sh
/usr/local/bin/notify.py stop
/usr/local/bin/notify.py error
```

Unknown event names produce a generic notification (title:
"KroClaude — Notification", body: "Event: <event>").

## Failure handling (FR-010)

`notify.py` wraps the Apprise call in a broad try/except. Any
exception — DNS failure, malformed URL, provider 5xx, missing apprise
package, anything — is swallowed and the script exits 0. The Claude
session never sees a failure.

## Forbidden

- Logging the `NOTIFY_*` URLs (they typically embed bearer tokens).
- Persisting `NOTIFY_*` values to disk inside the container.
- Bundling a notification "relay" or "broker" service inside the image.
  Apprise targets external services; KroClaude does not host any of
  them.

## Hook wiring

In `config/settings.json` (Claude Code's seed file), the hooks block
points to `/usr/local/bin/notify.py`:

```json
"hooks": {
  "Stop": [{ "hooks": [{ "type": "command", "command": "/usr/local/bin/notify.py stop" }] }],
  "PostToolUseFailure": [{ "hooks": [{ "type": "command", "command": "/usr/local/bin/notify.py error" }] }]
}
```

Codex and Gemini equivalents are seeded by the entrypoint on first boot
(see [research.md R7](../research.md)).
