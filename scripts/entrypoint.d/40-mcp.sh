#!/bin/bash
# Stage 40 — user-scope MCP server registration (claude AND codex).
# `claude mcp add` / `codex mcp add` are LOCAL config writes (no
# network) — the servers themselves are spawned lazily by the CLIs
# later. Remove + re-add so the command line and env vars always
# reflect the current deployment (env-var swaps take effect next
# restart). Per-item failure is non-fatal (FR-009).
#
# Codex gets the same servers claude does; coolify — which claude
# receives via the config/mcp-servers.d/ fragment merge instead — is
# registered here for codex because codex config is TOML, not covered
# by the jq fragment pipeline.
set -euo pipefail
. /etc/kroclaude/entrypoint-lib.sh

for name in context7 filesystem serena exa github; do
    runuser -u claude -- claude mcp remove "$name" >/dev/null 2>&1 || true
done

runuser -u claude -- claude mcp add --scope user context7 -- \
    npx -y @upstash/context7-mcp \
    || warn "failed to add context7 MCP"
runuser -u claude -- claude mcp add --scope user filesystem -- \
    npx -y @modelcontextprotocol/server-filesystem /workspace \
    || warn "failed to add filesystem MCP"
# Contexts per Serena's client docs; --project-from-cwd activates the
# project from wherever the CLI is launched.
runuser -u claude -- claude mcp add --scope user serena -- \
    serena start-mcp-server --context claude-code --project-from-cwd \
    || warn "failed to add serena MCP"

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

# ---------- codex ----------
for name in context7 filesystem serena exa github coolify; do
    runuser -u claude -- codex mcp remove "$name" >/dev/null 2>&1 || true
done

runuser -u claude -- codex mcp add context7 -- \
    npx -y @upstash/context7-mcp \
    || warn "failed to add context7 MCP (codex)"
runuser -u claude -- codex mcp add filesystem -- \
    npx -y @modelcontextprotocol/server-filesystem /workspace \
    || warn "failed to add filesystem MCP (codex)"
# Serena's docs suggest startup_timeout_sec = 15 for codex (first spawn
# may download a language server); `codex mcp add` can't set it — bump
# it in ~/.codex/config.toml if the default ever proves too tight.
runuser -u claude -- codex mcp add serena -- \
    serena start-mcp-server --context codex --project-from-cwd \
    || warn "failed to add serena MCP (codex)"

if [ -n "${EXA_API_KEY:-}" ]; then
    runuser -u claude -- codex mcp add exa --env "EXA_API_KEY=$EXA_API_KEY" -- \
        npx -y exa-mcp-server \
        || warn "failed to add exa MCP (codex)"
fi
if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
    runuser -u claude -- codex mcp add github \
        --env "GITHUB_PERSONAL_ACCESS_TOKEN=$GITHUB_PERSONAL_ACCESS_TOKEN" -- \
        docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN \
        ghcr.io/github/github-mcp-server \
        || warn "failed to add github MCP (codex)"
fi
if [ -n "${COOLIFY_ACCESS_TOKEN:-}" ] && [ -n "${COOLIFY_BASE_URL:-}" ]; then
    runuser -u claude -- codex mcp add coolify \
        --env "COOLIFY_ACCESS_TOKEN=$COOLIFY_ACCESS_TOKEN" \
        --env "COOLIFY_BASE_URL=$COOLIFY_BASE_URL" -- \
        npx -y @masonator/coolify-mcp@latest \
        || warn "failed to add coolify MCP (codex)"
fi
