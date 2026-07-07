#!/bin/bash
# Stage 40 — user-scope MCP server registration.
# `claude mcp add` is a LOCAL config write (no network) — the servers
# themselves are spawned lazily by claude-code later. Remove + re-add so
# the command line and env vars always reflect the current deployment
# (env-var swaps take effect next restart). Per-item failure is
# non-fatal (FR-009).
set -euo pipefail
. /etc/kroclaude/entrypoint-lib.sh

for name in context7 filesystem exa github; do
    runuser -u claude -- claude mcp remove "$name" >/dev/null 2>&1 || true
done

runuser -u claude -- claude mcp add --scope user context7 -- \
    npx -y @upstash/context7-mcp \
    || warn "failed to add context7 MCP"
runuser -u claude -- claude mcp add --scope user filesystem -- \
    npx -y @modelcontextprotocol/server-filesystem /workspace \
    || warn "failed to add filesystem MCP"

if [ -n "${EXA_API_KEY:-}" ]; then
    runuser -u claude -- claude mcp add --scope user -e "EXA_API_KEY=$EXA_API_KEY" exa -- \
        npx -y exa-mcp-server \
        || warn "failed to add exa MCP"
fi
if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
    runuser -u claude -- claude mcp add --scope user \
        -e "GITHUB_PERSONAL_ACCESS_TOKEN=$GITHUB_PERSONAL_ACCESS_TOKEN" github -- \
        docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN \
        ghcr.io/github/github-mcp-server \
        || warn "failed to add github MCP"
fi
