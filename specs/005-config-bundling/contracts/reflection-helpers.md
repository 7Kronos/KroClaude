# Contract: Reflection Helper Functions

**Feature**: 005-config-bundling
**Spec**: [../spec.md](../spec.md) · **Plan**: [../plan.md](../plan.md)

This document is the authoritative contract for the three bash helper
functions added to [`scripts/entrypoint.sh`](../../../scripts/entrypoint.sh)
by this feature. Any change to the surface described here is a breaking
change and MUST be reflected in the smoke test
([`tests/smoke/test_us6.sh`](../../../tests/smoke/test_us6.sh)).

---

## Common contract (all three helpers)

| Property | Value |
|----------|-------|
| Location | Inline functions in `scripts/entrypoint.sh` (not separate files) |
| Source file | [`scripts/entrypoint.sh`](../../../scripts/entrypoint.sh) |
| Owner / mode | Inherited from `entrypoint.sh`: `root:root` `0755` |
| Shell | `bash 5.x`, under the existing `set -euo pipefail` at the top of `entrypoint.sh` |
| External deps | `find`, `sort`, `rm`, `cp`, `chown`, `mkdir`, `jq`, `mv` — all already in image |
| Error model | Per-item failure only: `op_a && op_b && op_c \|\| { echo "[entrypoint] WARN: …" >&2; continue; }`. A failing item is logged and skipped; the loop continues with the next item. The function does NOT exit non-zero on per-item failure. |
| Subshell policy | NO subshells. All iteration is done with `while` loops inside the function body. This is required for `set -euo pipefail` compatibility and for the `continue` statement to work in the outer loop. |
| Ownership target | `claude:claude` — UID 1000, GID 1000 (from feature 001's user setup) |
| No-op condition | If `<src>` or `<src_dir>` does not exist OR is empty (no matching children), the helper returns immediately without touching `<dest>` or the target file. |
| Placement | All three function definitions appear together in `entrypoint.sh` before the first call site. The seven call sites appear in a single contiguous stanza after the existing first-boot seed logic. |

---

## `reflect_dir_of_dirs <src> <dest>`

Reflects each immediate subdirectory of `<src>` into `<dest>/` with
an atomic rm-then-cp-then-chown pattern.

**Implements**: FR-003 (skills, agents, plugins), FR-005, FR-009.

### Arguments

| Argument | Description |
|----------|-------------|
| `<src>` | Absolute path to the source type directory, e.g. `/usr/local/share/kroclaude/config/skills` |
| `<dest>` | Absolute path to the destination type directory, e.g. `/home/claude/.claude/skills` |

### Pseudocode

```bash
reflect_dir_of_dirs() {
    local src="$1" dest="$2"
    # No-op if source doesn't exist or has no subdirectories
    [ -d "$src" ] || return 0
    local found=0
    while IFS= read -r -d '' item; do
        found=1
        local name
        name=$(basename "$item")
        rm -rf "${dest:?}/$name" \
            && cp -r "$item" "$dest/$name" \
            && chown -R claude:claude "$dest/$name" \
            || { echo "[entrypoint] WARN: failed to reflect $item → $dest/$name" >&2; continue; }
    done < <(find "$src" -mindepth 1 -maxdepth 1 -type d -print0)
    [ "$found" -eq 1 ] || return 0
}
```

### Invariants

| Invariant | How verified |
|-----------|--------------|
| Only immediate subdirectories of `<src>` are reflected | `find -mindepth 1 -maxdepth 1 -type d` |
| Each reflection is atomic at the item level | `rm -rf` completes before `cp -r` starts; no partial state visible to Claude Code if `cp` fails (the old copy was already removed — warning is logged) |
| Destination is owned `claude:claude` after reflection | `chown -R claude:claude "$dest/$name"` |
| User-installed items in `<dest>` whose names are NOT in `<src>` are untouched | The helper only touches `$dest/$name` for names it finds in `$src` |
| Missing or empty `<src>` is a no-op | `[ -d "$src" ] \|\| return 0`; the `found` flag guards against an empty directory |
| A failing item does not abort the loop | `\|\| { warn; continue; }` pattern |

### What it skips

- Files in `<src>` (not directories). Only `type d` items are
  reflected. A stray file like `config/skills/README.md` is silently
  ignored (it is not a skill).
- Empty string `<src>` (guarded by the `[ -d ]` check).
- The `<dest>` directory itself does not need to pre-exist — `cp -r`
  will create `$dest/$name` but the parent `$dest` MUST exist. The
  entrypoint creates parent directories as part of the first-boot
  setup that predates this helper.

### Plugin call-site addition

When `reflect_dir_of_dirs` is called for the `plugins` type, the
call site (not the helper itself) adds a pre-flight manifest check:

```bash
# At the plugins call site only:
if [ ! -f "$src/$name/.claude-plugin/plugin.json" ]; then
    echo "[entrypoint] WARN: skipping plugin '$name' — .claude-plugin/plugin.json not found" >&2
    continue
fi
```

This guard runs BEFORE the `rm -rf / cp -r / chown` chain.

---

## `reflect_dir_of_files <src> <dest> <ext>`

Reflects each file with the given extension in `<src>` into `<dest>/`
with a per-file rm-then-cp-then-chown pattern.

**Implements**: FR-004 (commands, output-styles), FR-005, FR-009.

### Arguments

| Argument | Description |
|----------|-------------|
| `<src>` | Absolute path to the source type directory, e.g. `/usr/local/share/kroclaude/config/commands` |
| `<dest>` | Absolute path to the destination type directory, e.g. `/home/claude/.claude/commands` |
| `<ext>` | File extension to match, WITHOUT the leading dot, e.g. `md` |

### Pseudocode

```bash
reflect_dir_of_files() {
    local src="$1" dest="$2" ext="$3"
    [ -d "$src" ] || return 0
    local found=0
    while IFS= read -r -d '' item; do
        found=1
        local name
        name=$(basename "$item")
        rm -f "${dest:?}/$name" \
            && cp "$item" "$dest/$name" \
            && chown claude:claude "$dest/$name" \
            || { echo "[entrypoint] WARN: failed to reflect $item → $dest/$name" >&2; continue; }
    done < <(find "$src" -mindepth 1 -maxdepth 1 -type f -name "*.$ext" -print0)
    [ "$found" -eq 1 ] || return 0
}
```

### Invariants

| Invariant | How verified |
|-----------|--------------|
| Only files matching `*.<ext>` in `<src>` are reflected | `find -type f -name "*.$ext"` |
| Subdirectories of `<src>` are ignored | `-type f` filter |
| Destination is owned `claude:claude` after reflection | `chown claude:claude "$dest/$name"` |
| User-installed files in `<dest>` whose names are NOT in `<src>` are untouched | Helper only touches `$dest/$name` for names it finds in `$src` |
| Missing or empty `<src>` is a no-op | `[ -d "$src" ] \|\| return 0` |
| A failing file does not abort the loop | `\|\| { warn; continue; }` pattern |

### Difference from `reflect_dir_of_dirs`

- Uses `rm -f` (not `rm -rf`) because the unit is a single file.
- Uses `cp` (not `cp -r`) for the same reason.
- Adds `-name "*.$ext"` to `find` to filter by extension.
- Does NOT recurse: only immediate children of `<src>` are reflected.

---

## `merge_fragments <src_dir> <target_file> <jq_filter_var_name> <default_target_json>`

Folds all valid JSON fragment files in `<src_dir>` into a single
bundle object, then merges the bundle into `<target_file>` using the
named jq filter variable.

**Implements**: FR-006, FR-007, FR-008, FR-009.

### Arguments

| Argument | Description |
|----------|-------------|
| `<src_dir>` | Absolute path to the fragment type directory, e.g. `/usr/local/share/kroclaude/config/hooks.d` |
| `<target_file>` | Absolute path to the JSON file to merge into, e.g. `/home/claude/.claude/settings.json` |
| `<jq_filter_var_name>` | Name of a bash variable holding the jq filter string to apply at merge time (e.g. `HOOKS_MERGE_FILTER`) |
| `<default_target_json>` | JSON string to use as the target file's starting content when the target file does not yet exist (e.g. `'{}'` or `'{"mcpServers":{}}'`) |

The jq filter string referenced by `<jq_filter_var_name>` is defined
as a bash variable before the helper is called. See
[merge-filters.md](merge-filters.md) for the authoritative filter
text for each type.

### Pseudocode

```bash
merge_fragments() {
    local src_dir="$1"
    local target_file="$2"
    local jq_filter_var="$3"
    local default_target="$4"
    local jq_filter="${!jq_filter_var}"   # indirect variable expansion

    # No-op if source directory doesn't exist or has no *.json files
    [ -d "$src_dir" ] || return 0

    # --- FOLD PHASE: reduce all valid fragments into one bundle object ---
    local bundle='{}'
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        # Validate JSON before attempting merge
        if ! jq empty "$f" >/dev/null 2>&1; then
            echo "[entrypoint] WARN: skipping malformed fragment $f" >&2
            continue
        fi
        bundle=$(jq -s '.[0] * .[1]' <(printf '%s' "$bundle") "$f") \
            || { echo "[entrypoint] WARN: fold failed on $f" >&2; continue; }
    done < <(LC_ALL=C find "$src_dir" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)

    # If no fragments were found or all failed, bundle remains '{}'
    # Skip the merge step to avoid unnecessarily rewriting the target
    [ "$bundle" != '{}' ] || return 0

    # --- MERGE PHASE: apply bundle onto target file ---
    local current_target="$default_target"
    if [ -f "$target_file" ]; then
        current_target=$(cat "$target_file")
    fi

    local tmp_file
    tmp_file=$(mktemp)
    jq -n \
        --argjson bundle "$bundle" \
        --argjson target "$current_target" \
        "$jq_filter" > "$tmp_file" \
        || { echo "[entrypoint] WARN: merge step failed for $target_file" >&2; rm -f "$tmp_file"; return 0; }

    # --- WRITE PHASE: atomic replace ---
    mkdir -p "$(dirname "$target_file")"
    mv "$tmp_file" "$target_file"

    # --- CHOWN ---
    chown claude:claude "$target_file"
}
```

### Fold loop in detail

```bash
bundle='{}'
while IFS= read -r f; do
    [ -f "$f" ] || continue
    if ! jq empty "$f" >/dev/null 2>&1; then
        echo "[entrypoint] WARN: skipping malformed fragment $f" >&2
        continue
    fi
    bundle=$(jq -s '.[0] * .[1]' <(printf '%s' "$bundle") "$f") \
        || { echo "[entrypoint] WARN: fold failed on $f" >&2; continue; }
done < <(LC_ALL=C find "$src_dir" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
```

- `LC_ALL=C find … | LC_ALL=C sort` — deterministic byte-order sort
  of filenames; later filename wins on key collision (FR-008a).
- `jq -s '.[0] * .[1]'` — folds two JSON objects with `jq`'s `*`
  operator (right-key-wins on collision). Fragment `b.json` beats
  `a.json` because it is processed after `a.json` and becomes `.[1]`.
- `<(printf '%s' "$bundle")` — process substitution avoids writing
  the accumulated bundle to disk for each fragment.
- On `jq` failure for a single fragment: `continue` advances to the
  next fragment; `bundle` retains the value it had before the
  failing fold. The merge proceeds with whatever was successfully
  folded.

### Exit-code semantics

| Situation | Effect |
|-----------|--------|
| Source directory absent or empty (no `*.json`) | Return 0; target file unchanged |
| All fragments malformed | `bundle` stays `'{}'`; merge skipped; target file unchanged; warnings logged |
| Partial fragment failure | Successfully folded fragments are merged; failed fragments logged and skipped |
| Merge step `jq` failure | Warning logged; temp file removed; target file unchanged; function returns 0 (container still boots) |
| Success | Target file rewritten with merged content; owned `claude:claude` |

The function NEVER returns non-zero. All failures are handled
internally with per-item warnings. This is the FR-009 contract:
any failure logs a warning, does not abort reflection of other
types, and does not prevent the container from booting.

### Idempotency invariant

Given identical fragment files and identical starting `target_file`
content:

1. The fold loop processes fragments in the same `LC_ALL=C` lex order.
2. `jq -s '.[0] * .[1]'` is a pure function with no side effects.
3. The jq merge filter (provided by the caller) is a pure function.
4. The `mv` overwrites the target file with the same content.

Therefore two successive runs produce byte-identical `target_file`
content (FR-007). The idempotency holds across reboots as long as the
fragments and the non-bundled portion of the target file are unchanged.

### What the helper does NOT do

- It does not create or seed the target file from scratch. If the
  target file does not exist, it uses `<default_target_json>` as
  the starting document — but if the merge jq filter references keys
  that do not exist in that default, the filter's own `// {}` fallbacks
  handle it.
- It does not validate the schema of the merged output (e.g., it
  does not check that the merged `settings.json` conforms to Claude
  Code's expected shape). Schema validation is out of scope for this
  feature.
- It does not remove bundled-contributed keys from the target file
  when a fragment is removed from a future image build. Orphaned keys
  persist, matching the dir-of-dirs orphan behavior.
