#!/bin/bash
# Stage 60 — /etc/environment propagation.
# sshd does NOT inherit PID 1's environment — each login session is built
# from /etc/environment (via pam_env, UsePAM yes), /etc/profile, and the
# user's shell rc files. To make compose-supplied runtime vars visible to
# SSH login shells, regenerate /etc/environment on every boot from the
# single-source manifest under config/environment.d/:
#   static.env        — deployment-independent vars, prepended verbatim
#   passthrough.list  — allowlisted var NAMES copied from the container
#                       env when non-empty (incl. the rationale for the
#                       deliberate ANTHROPIC_API_KEY / GH_TOKEN exclusions)
# /etc/environment is mode 0644 (world-readable) by pam_env requirement —
# acceptable in this single-user container, but do not list vars that
# must be hidden from non-claude processes.
set -euo pipefail
. /etc/kroclaude/entrypoint-lib.sh

STATIC_ENV="$SOURCE_DIR/environment.d/static.env"
PASSTHROUGH="$SOURCE_DIR/environment.d/passthrough.list"

{
    grep -v '^\s*#' "$STATIC_ENV" | grep -v '^\s*$'
    while IFS= read -r var; do
        var="${var%%#*}"
        var="${var//[[:space:]]/}"
        [ -n "$var" ] || continue
        val="${!var:-}"
        [ -n "$val" ] || continue
        printf '%s="%s"\n' "$var" "${val//\"/\\\"}"
    done < "$PASSTHROUGH"
} > /etc/environment
chmod 0644 /etc/environment
