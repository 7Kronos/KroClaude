#!/bin/bash
# install-tools.sh — install the pinned third-party binaries declared in
# config/tools.json. Runs once, in a single Dockerfile layer, replacing
# the previous eleven bespoke download/extract RUN blocks.
#
# Usage: install-tools.sh <manifest> [tool ...]
#   With no tool arguments, installs every entry in the manifest.
#
# Install kinds (see the "//" header in tools.json for the schema):
#   rootfs        extract tarball(s) at / (s6-overlay)
#   bin           raw binary -> /usr/local/bin/<tool>
#   archive-bin   extract `member` from zip/tar.gz -> /usr/local/bin/<tool>
#   archive-share extract whole tree -> /usr/local/share/<tool>, symlink `links`
# Any entry may declare `symlinks`: extra names in the bin dir pointing at
# the tool's binary (e.g. bunx -> bun).
#
# Test hook: KROCLAUDE_TOOLS_PREFIX relocates all install paths (and is
# where `rootfs` extracts), so the script can be exercised outside Docker.
set -euo pipefail

MANIFEST="${1:?usage: install-tools.sh <manifest> [tool ...]}"
shift
PREFIX="${KROCLAUDE_TOOLS_PREFIX:-}"
BIN_DIR="$PREFIX/usr/local/bin"
SHARE_DIR="$PREFIX/usr/local/share"
ARCH="${TARGETARCH:-$(dpkg --print-architecture)}"

TOOLS=("$@")
if [ ${#TOOLS[@]} -eq 0 ]; then
    mapfile -t TOOLS < <(jq -r '.tools | keys_unsorted[]' "$MANIFEST")
fi

render() { # render <template> <version> <arch>
    local s="$1"
    s=${s//\{version\}/$2}
    s=${s//\{arch\}/$3}
    printf '%s' "$s"
}

mkdir -p "$BIN_DIR" "$SHARE_DIR"

for tool in "${TOOLS[@]}"; do
    spec=$(jq -e --arg t "$tool" '.tools[$t]' "$MANIFEST") \
        || { echo "[install-tools] ERROR: no manifest entry for '$tool'" >&2; exit 1; }
    version=$(jq -r '.version // ""' <<<"$spec")
    if [ -z "$version" ]; then
        echo "[install-tools] ERROR: '$tool' has no pinned version — run scripts/bump-tools.sh" >&2
        exit 1
    fi
    tool_arch=$(jq -r --arg a "$ARCH" '.arch[$a] // $a' <<<"$spec")
    kind=$(jq -r '.install' <<<"$spec")

    tmp=$(mktemp -d)
    while IFS= read -r url_tmpl; do
        url=$(render "$url_tmpl" "$version" "$tool_arch")
        file="$tmp/$(basename "$url")"
        echo "[install-tools] $tool $version <- $url"
        curl -fsSL --retry 3 -o "$file" "$url"

        case "$kind" in
        rootfs)
            tar -C "${PREFIX:-/}" -Jxpf "$file"
            ;;
        bin)
            install -m 0755 "$file" "$BIN_DIR/$tool"
            ;;
        archive-bin)
            member=$(render "$(jq -r '.member' <<<"$spec")" "$version" "$tool_arch")
            mkdir -p "$tmp/x"
            case "$file" in
            *.zip) unzip -qo -j "$file" "$member" -d "$tmp/x" ;;
            *)     tar -xzf "$file" -C "$tmp/x" "$member" ;;
            esac
            bin_path=$(find "$tmp/x" -type f -name "$(basename "$member")" | head -n1)
            [ -n "$bin_path" ] \
                || { echo "[install-tools] ERROR: '$member' not found in $url" >&2; exit 1; }
            install -m 0755 "$bin_path" "$BIN_DIR/$tool"
            ;;
        archive-share)
            dest="$SHARE_DIR/$tool"
            rm -rf "$dest"
            mkdir -p "$dest"
            tar -xzf "$file" -C "$dest"
            while IFS=$'\t' read -r src link; do
                [ -n "$src" ] || continue
                chmod +x "$dest/$src"
                ln -sfn "$dest/$src" "$BIN_DIR/$link"
            done < <(jq -r '.links // {} | to_entries[] | "\(.key)\t\(.value)"' <<<"$spec")
            ;;
        *)
            echo "[install-tools] ERROR: unknown install kind '$kind' for '$tool'" >&2
            exit 1
            ;;
        esac
    done < <(jq -r '.urls[]' <<<"$spec")

    while IFS= read -r link; do
        [ -n "$link" ] || continue
        ln -sfn "$tool" "$BIN_DIR/$link"
    done < <(jq -r '.symlinks // [] | .[]' <<<"$spec")
    rm -rf "$tmp"
done

echo "[install-tools] done: ${TOOLS[*]}"
