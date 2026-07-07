#!/bin/bash
# Stage 80 — background plugin/marketplace sync (the ONLY network user).
# The boot path stays offline-safe: kroclaude-sync runs detached, logs
# to ~/.claude/logs/kroclaude-sync.log, and any failure is invisible to
# container health. Set KROCLAUDE_SYNC_ON_BOOT=0 to skip; run
# `kroclaude-sync` any time (as claude) to sync on demand.
set -euo pipefail
. /etc/kroclaude/entrypoint-lib.sh

if [ "${KROCLAUDE_SYNC_ON_BOOT:-1}" != "1" ]; then
    echo "[entrypoint] sync-on-boot disabled (KROCLAUDE_SYNC_ON_BOOT=${KROCLAUDE_SYNC_ON_BOOT})"
    exit 0
fi

install -d -o claude -g claude "$CONFIG_DIR/logs"
# Detach fully (setsid + &) so s6 startup never waits on the network.
# runuser resets HOME/USER to claude but preserves the rest of the env,
# so GITHUB_PERSONAL_ACCESS_TOKEN from compose reaches the sync.
setsid runuser -u claude -- /usr/local/bin/kroclaude-sync \
    >> "$CONFIG_DIR/logs/kroclaude-sync.log" 2>&1 < /dev/null &
echo "[entrypoint] kroclaude-sync started in background (log: ~/.claude/logs/kroclaude-sync.log)"
