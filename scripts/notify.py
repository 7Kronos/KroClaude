#!/usr/bin/env python3
"""KroClaude — Apprise notification dispatcher.

Usage: notify.py <event>

Events: "stop" (task complete), "error" (tool failure). Unknown events
produce a generic notification.

Sends only when BOTH gates are satisfied:
  1. /home/claude/.claude/notify-on exists, AND
  2. at least one NOTIFY_* env var is set and non-empty.

All exceptions are swallowed; the script always exits 0 so that a
misbehaving notification stack never disrupts the running session.

Contract: specs/001-claude-shell-base/contracts/notifications.md
"""

import os
import sys

FLAG_FILE = "/home/claude/.claude/notify-on"

EVENTS = {
    "stop":  ("KroClaude — Task Complete",       "Claude has finished the current task.",                    "info"),
    "error": ("KroClaude — Something Went Wrong", "A tool use failure occurred. Check the session for details.", "warning"),
}


def collect_urls():
    urls = []
    for key, value in os.environ.items():
        if not key.startswith("NOTIFY_"):
            continue
        if not value or not value.strip():
            continue
        if key == "NOTIFY_URLS":
            urls.extend(u.strip() for u in value.split(",") if u.strip())
        else:
            urls.append(value.strip())
    return urls


def main():
    if not os.path.isfile(FLAG_FILE):
        sys.exit(0)

    urls = collect_urls()
    if not urls:
        sys.exit(0)

    event = sys.argv[1] if len(sys.argv) > 1 else "unknown"
    title, body, notify_type = EVENTS.get(
        event,
        ("KroClaude — Notification", f"Event: {event}", "info"),
    )

    try:
        import apprise
        ap = apprise.Apprise()
        for url in urls:
            ap.add(url)
        ap.notify(title=title, body=body, notify_type=notify_type)
    except Exception:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
