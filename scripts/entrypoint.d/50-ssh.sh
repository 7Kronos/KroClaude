#!/bin/bash
# Stage 50 — SSH host keys + authorized_keys (feature 003-ssh-access).
# Host keys are generated ONCE (FR-009 fingerprint stability) inside the
# persistent volume so they survive container recreation.
# authorized_keys is reseeded from KROCLAUDE_SSH_AUTHORIZED_KEY on EVERY
# boot (FR-007 — latest env wins; NOT sentinel-guarded).
set -euo pipefail
. /etc/kroclaude/entrypoint-lib.sh

SSH_HOST_KEY_DIR="$CONFIG_DIR/.ssh-host-keys"
install -d -m 0700 -o claude -g claude "$SSH_HOST_KEY_DIR"
for spec in "ed25519" "rsa -b 3072"; do
    name=ssh_host_${spec%% *}_key
    if [ ! -f "$SSH_HOST_KEY_DIR/$name" ]; then
        ssh-keygen -t $spec -N '' -f "$SSH_HOST_KEY_DIR/$name" >/dev/null
        chmod 0600 "$SSH_HOST_KEY_DIR/$name"
        chmod 0644 "$SSH_HOST_KEY_DIR/$name.pub"
    fi
done

install -d -m 0700 -o claude -g claude "$CLAUDE_HOME/.ssh"
printf '%s\n' "${KROCLAUDE_SSH_AUTHORIZED_KEY:-}" > "$CLAUDE_HOME/.ssh/authorized_keys"
chmod 0600 "$CLAUDE_HOME/.ssh/authorized_keys"
