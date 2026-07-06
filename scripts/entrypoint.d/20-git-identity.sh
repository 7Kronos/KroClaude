#!/bin/bash
# Stage 20 — git identity + safe.directory.
# ~/.gitconfig is a plain file on the persistent home volume, so
# identity and manual `git config` edits survive redeploys.
# Precedence: GIT_USER_* env wins when set (latest deploy wins); else
# keep an existing persisted value; else seed a default.
set -euo pipefail
. /etc/kroclaude/entrypoint-lib.sh

# Migration: adopt a pre-home-volume ~/.claude/.gitconfig if present.
[ -L "$CLAUDE_HOME/.gitconfig" ] && rm -f "$CLAUDE_HOME/.gitconfig"
if [ ! -f "$CLAUDE_HOME/.gitconfig" ] && [ -f "$CONFIG_DIR/.gitconfig" ]; then
    mv "$CONFIG_DIR/.gitconfig" "$CLAUDE_HOME/.gitconfig"
    chown claude:claude "$CLAUDE_HOME/.gitconfig"
fi

runuser -u claude -- git config --global --get-all safe.directory 2>/dev/null | grep -qxF /workspace \
    || runuser -u claude -- git config --global --add safe.directory /workspace
if [ -n "${GIT_USER_NAME:-}" ]; then
    runuser -u claude -- git config --global user.name "$GIT_USER_NAME"
elif [ -z "$(runuser -u claude -- git config --global user.name 2>/dev/null)" ]; then
    runuser -u claude -- git config --global user.name "KroClaude User"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    runuser -u claude -- git config --global user.email "$GIT_USER_EMAIL"
elif [ -z "$(runuser -u claude -- git config --global user.email 2>/dev/null)" ]; then
    runuser -u claude -- git config --global user.email "noreply@kroclaude.local"
fi
