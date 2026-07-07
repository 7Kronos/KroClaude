#!/bin/bash
# Stage 70 — ownership sweep.
# Everything earlier stages wrote as root becomes claude-owned before s6
# takes over. Scoped to the paths the stages actually touch — a
# recursive chown of the entire home volume (which includes
# ~/.vscode-server and other large trees) would slow every boot.
# /workspace is intentionally NOT swept — it's never written-to during
# docker build, the WORKDIR is chowned in the Dockerfile, and Docker's
# named-volume mount inherits ownership from the claude-owned target.
set -euo pipefail
. /etc/kroclaude/entrypoint-lib.sh

chown claude:claude "$CLAUDE_HOME" "$CLAUDE_HOME/.claude.json"
[ -f "$CLAUDE_HOME/.gitconfig" ] && chown claude:claude "$CLAUDE_HOME/.gitconfig"
chown -R claude:claude "$CONFIG_DIR" \
    "$CLAUDE_HOME/.codex" "$CLAUDE_HOME/.gemini" "$CLAUDE_HOME/.agents" \
    "$CLAUDE_HOME/.config" "$CLAUDE_HOME/.ssh"
