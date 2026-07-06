#!/bin/bash
# KroClaude — container entrypoint driver.
#
# Runs each boot stage under /etc/kroclaude/entrypoint.d/ in lex order,
# then hands off to s6-overlay (PID 1). Stages are separate files so
# each concern is independently readable and testable; all run as root
# with `set -euo pipefail` and source the shared entrypoint-lib.sh.
#
# The boot path is OFFLINE-SAFE by design: nothing here requires the
# network. Plugin/marketplace sync is backgrounded by stage 80 (see
# kroclaude-sync) and cannot block or fail the boot.
#
# Per FR-014: no PUID/PGID remap, no variant-aware fork.
set -euo pipefail

for stage in /etc/kroclaude/entrypoint.d/*.sh; do
    echo "[entrypoint] stage $(basename "$stage")"
    bash "$stage"
done

export DISPLAY=:99

exec /init "$@"
