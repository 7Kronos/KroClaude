#!/bin/bash
# bump-tools.sh — refresh every version pin in config/tools.json from upstream.
#
# One command instead of visiting a dozen release pages:
#   scripts/bump-tools.sh              # updates config/tools.json in place
#   scripts/bump-tools.sh --check      # report only, do not rewrite the file
#
# Version sources, per tool entry:
#   version_url — plain-text endpoint returning the version (e.g. dl.k8s.io)
#   repo        — GitHub releases/latest tag_name
# A tool's `tag_prefix` (e.g. bun's "bun-") and a leading "v" are stripped;
# URL templates in tools.json re-add them where needed.
#
# Set GITHUB_TOKEN to raise the GitHub API rate limit (the weekly
# .github/workflows/bump-tools.yml job passes the Actions token).
set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; shift; fi
MANIFEST="${1:-$(dirname "$0")/../config/tools.json}"

AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")

changes=0
failures=0
for tool in $(jq -r '.tools | keys_unsorted[]' "$MANIFEST"); do
    spec=$(jq --arg t "$tool" '.tools[$t]' "$MANIFEST")
    current=$(jq -r '.version // ""' <<<"$spec")
    version_url=$(jq -r '.version_url // ""' <<<"$spec")
    repo=$(jq -r '.repo // ""' <<<"$spec")

    if [ -n "$version_url" ]; then
        latest=$(curl -fsSL --retry 3 "$version_url" || true)
    elif [ -n "$repo" ]; then
        latest=$(curl -fsSL --retry 3 "${AUTH[@]}" \
            "https://api.github.com/repos/$repo/releases/latest" \
            | jq -r '.tag_name // ""' || true)
    else
        printf '%-12s SKIP (no repo/version_url)\n' "$tool"
        continue
    fi
    tag_prefix=$(jq -r '.tag_prefix // ""' <<<"$spec")
    [ -n "$tag_prefix" ] && latest=${latest#"$tag_prefix"}
    latest=${latest#v}

    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        printf '%-12s WARN could not resolve latest (keeping %s)\n' "$tool" "${current:-<unset>}"
        failures=$((failures + 1))
        continue
    fi

    if [ "$latest" = "$current" ]; then
        printf '%-12s %s (up to date)\n' "$tool" "$current"
        continue
    fi

    printf '%-12s %s -> %s\n' "$tool" "${current:-<unset>}" "$latest"
    changes=$((changes + 1))
    if [ "$CHECK_ONLY" -eq 0 ]; then
        tmp=$(mktemp)
        jq --arg t "$tool" --arg v "$latest" '.tools[$t].version = $v' "$MANIFEST" > "$tmp"
        mv "$tmp" "$MANIFEST"
    fi
done

echo
echo "$changes pin(s) updated, $failures unresolved."
# Unresolved lookups are non-fatal (rate limits happen) but a run that
# resolved nothing at all is suspicious enough to fail loudly.
[ "$failures" -gt 0 ] && [ "$changes" -eq 0 ] && exit 1
exit 0
