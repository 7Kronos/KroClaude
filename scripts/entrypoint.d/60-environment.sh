#!/bin/bash
# Stage 60 — /etc/environment propagation.
# sshd does NOT inherit PID 1's environment — each login session is built
# from /etc/environment (via pam_env, UsePAM yes), /etc/profile, and the
# user's shell rc files. To make compose-supplied runtime vars visible to
# SSH login shells, regenerate /etc/environment from an explicit allowlist
# on every boot. The list is a SUBSET of docker-compose.yaml `environment:`
# minus secrets-with-precedence-traps — see DELIBERATELY EXCLUDED below.
# Empty values are skipped so unset vars don't show up as empty strings.
# /etc/environment is mode 0644 (world-readable) by pam_env requirement —
# acceptable in this single-user container, but do not add vars here that
# must be hidden from non-claude processes.
#
# DELIBERATELY EXCLUDED:
#   - ANTHROPIC_API_KEY: claude-code treats this env var as overriding
#     the persisted OAuth login (~/.claude/.credentials.json).
#     Propagating it to SSH login shells made `claude login` appear not
#     to persist across restarts. PID 1 still has it (compose
#     environment), so `claude` started under s6 or via `docker exec`
#     still falls back to it when no OAuth login is persisted.
#   - GH_TOKEN: gh gives an env token precedence over the persisted
#     `gh auth login` in hosts.yml — a stale PAT would shadow a working
#     login in every SSH shell (same trap as above).
#
# Other secrets STAY in the list because MCP server fragments under
# config/mcp-servers.d/ reference them as ${VAR} placeholders that
# claude-code expands from the shell env at MCP-spawn time.
set -euo pipefail
. /etc/kroclaude/entrypoint-lib.sh

{
    printf 'PATH="/home/claude/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n'
    printf 'DOCKER_HOST="tcp://localhost:2375"\n'
    printf 'DISPLAY=":99"\n'
    for var in TZ GIT_USER_NAME GIT_USER_EMAIL \
               NODE_OPTIONS NOTIFY_URLS \
               EXA_API_KEY GITHUB_PERSONAL_ACCESS_TOKEN \
               COOLIFY_ACCESS_TOKEN COOLIFY_BASE_URL \
               NUGET_REGISTRY_USER NUGET_REGISTRY_TOKEN; do
        val="${!var:-}"
        [ -n "$val" ] || continue
        printf '%s="%s"\n' "$var" "${val//\"/\\\"}"
    done
} > /etc/environment
chmod 0644 /etc/environment
