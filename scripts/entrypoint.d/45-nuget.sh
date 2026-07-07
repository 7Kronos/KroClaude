#!/bin/bash
# Stage 45 — NuGet source for a private GitHub Packages feed (env-driven).
# When NUGET_REGISTRY_USER + NUGET_REGISTRY_TOKEN are set, (re)register a
# user-level NuGet source named "GitHub" for the claude user, so
# `dotnet restore` against the private feed works out of the box.
# remove+add (same shape as stage 40's MCP servers) so credential/URL
# swaps in the deployment take effect on the next boot. This is a LOCAL
# config write (~/.nuget/NuGet/NuGet.Config, on the home volume) — no
# network.
#
# This replaces the external `docker exec … dotnet nuget update source`
# post-deployment-hook pattern, which fails on every fresh container:
# `update source` throws "Object reference not set to an instance of an
# object" when the named source doesn't exist yet, and a root exec
# targets /root/.nuget (never persisted) rather than claude's config.
#
# Feed URL defaults to the user's own GitHub Packages feed; override
# with NUGET_REGISTRY_URL for an org feed or a different registry.
set -euo pipefail
. /etc/kroclaude/entrypoint-lib.sh

if [ -z "${NUGET_REGISTRY_USER:-}" ] || [ -z "${NUGET_REGISTRY_TOKEN:-}" ]; then
    exit 0
fi

NUGET_URL="${NUGET_REGISTRY_URL:-https://nuget.pkg.github.com/${NUGET_REGISTRY_USER}/index.json}"

runuser -u claude -- dotnet nuget remove source GitHub >/dev/null 2>&1 || true
runuser -u claude -- dotnet nuget add source "$NUGET_URL" \
    --name GitHub \
    --username "$NUGET_REGISTRY_USER" \
    --password "$NUGET_REGISTRY_TOKEN" \
    --store-password-in-clear-text >/dev/null \
    || warn "failed to register NuGet source 'GitHub' ($NUGET_URL)"
