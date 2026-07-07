#!/bin/bash
# migrate-volumes.sh — one-time HOST-side migration from the old
# multi-volume layout (kroclaude-config / -gh / -codex / -gemini /
# -vscode) to the single kroclaude-home volume.
#
# Usage:
#   docker compose down                     # stop the stack first
#   scripts/migrate-volumes.sh [prefix]     # default prefix: kroclaude
#   docker compose up -d
#
# `prefix` is the compose project name that namespaces your volumes —
# check `docker volume ls`. Coolify deployments generate their own
# prefix. Old volumes are read-only during migration and NOT deleted;
# remove them manually once you've verified the new layout.
#
# In-container path adoption (old ~/.claude/kube, helm-config, k9s, …
# moving to their natural dotdir locations) happens automatically in
# the entrypoint on the next boot — this script only moves volume
# contents into the new home volume.
set -euo pipefail

PREFIX="${1:-kroclaude}"
NEW_VOL="${PREFIX}_kroclaude-home"

copy() { # copy <old-volume-suffix> <dest-subpath-under-/home/claude>
    local vol="${PREFIX}_$1" dest="$2"
    if ! docker volume inspect "$vol" >/dev/null 2>&1; then
        echo "skip: volume $vol not found"
        return 0
    fi
    echo "migrating $vol -> /home/claude/$dest"
    docker run --rm \
        -v "$vol":/src:ro \
        -v "$NEW_VOL":/home/claude \
        busybox sh -c "mkdir -p '/home/claude/$dest' \
            && cp -a /src/. '/home/claude/$dest/' \
            && chown -R 1000:1000 '/home/claude/$dest'"
}

docker volume create "$NEW_VOL" >/dev/null
copy kroclaude-config .claude
copy kroclaude-gh     .config/gh
copy kroclaude-codex  .codex
copy kroclaude-gemini .gemini
copy kroclaude-vscode .vscode-server

echo
echo "Migration complete. Old volumes were left untouched — delete them"
echo "after verifying the new deployment:"
echo "  docker volume rm ${PREFIX}_kroclaude-config ${PREFIX}_kroclaude-gh \\"
echo "    ${PREFIX}_kroclaude-codex ${PREFIX}_kroclaude-gemini ${PREFIX}_kroclaude-vscode"
