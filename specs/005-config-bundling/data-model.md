# Data Model: Unified Claude Code Customization Bundle

**Feature**: 005-config-bundling
**Date**: 2026-04-28
**Spec**: [spec.md](spec.md)

This feature introduces no application records and no schema
migrations. The "entities" below are filesystem resources and
runtime transformations whose identity, ownership, and lifecycle
this feature must manage.

---

## Entities

### Bundled item

A unit of Claude Code customization that ships in the image,
originating from a subdirectory of the repo's `/config/` tree.

| Attribute | Value |
|-----------|-------|
| Identity | `(type, name)` — type is one of the seven supported types; name is the stem of the path under that type's directory |
| Image-time location | `/usr/local/share/kroclaude/config/<type>/<name>` (read-only in the running container) |
| Runtime destination | `/home/claude/.claude/<type>/<name>` (or merged into a target file for fragment types) |
| Lifecycle owner | Image build — present from the first boot of any container built from the image |
| Overwrite behavior | Reflected on every boot; replaces same-named user-installed item if names collide |
| Orphan behavior | If removed from a future image rebuild, the in-container copy is orphaned (not garbage-collected) — matches feature 002 FR-007 |

---

### User-installed item

A unit of Claude Code customization written into `~/.claude/<type>/`
by the user or another process, outside the bundled set.

| Attribute | Value |
|-----------|-------|
| Identity | `(type, name)` |
| Location | `/home/claude/.claude/<type>/<name>` (inside the `kroclaude-config` named volume) |
| Lifecycle owner | User (or external process) — persists across container restarts in the named volume |
| Collision behavior | If a bundled item of the same `(type, name)` exists, the bundled item overwrites on boot (FR-008b, FR-005) |
| Preservation guarantee | Items whose name is NOT in the current bundled set are never touched by the reflection pipeline (FR-005) |

---

### Fragment

A JSON file under `config/hooks.d/` or `config/mcp-servers.d/` that
contributes a partial structure to a shared target file. Fragments are
not standalone customizations — they have no runtime identity in
`~/.claude/` of their own.

| Attribute | Value |
|-----------|-------|
| Identity | `(frag_type, filename)` — filename is the `*.json` basename including numeric prefix if any |
| Image-time location | `/usr/local/share/kroclaude/config/<frag_type>/<filename>.json` |
| Runtime destination | Merged (not copied) into either `~/.claude/settings.json` or `~/.claude/.mcp.json` |
| Merge unit | The entire fragment file; the file's top-level keys are folded into the bundle accumulator |
| Ordering | `LC_ALL=C` lexicographic sort of filenames; later filename wins on key collision within bundle |
| Validation pre-step | `jq empty "$f"` — malformed files are skipped with a named-file warning (FR-009) |

---

### Reflection target

The destination path or file inside `~/.claude/` for a given type.
There is one reflection target per type.

| Type | Reflection target | Target shape |
|------|-------------------|--------------|
| skills | `~/.claude/skills/<name>/` | Directory subtree |
| agents | `~/.claude/agents/<name>/` | Directory subtree |
| plugins | `~/.claude/plugins/<name>/` | Directory subtree (deep; may contain nested `.claude-plugin/plugin.json`) |
| commands | `~/.claude/commands/<name>.md` | Single file |
| output-styles | `~/.claude/output-styles/<name>.md` | Single file |
| hooks.d | `~/.claude/settings.json` (`.hooks` key) | Merged into existing JSON file |
| mcp-servers.d | `~/.claude/.mcp.json` (`.mcpServers` key) | Merged into existing JSON file |

---

## The seven types

| Type | Source path under `/config/` | Reflection target | Pattern | Spec FRs |
|------|------------------------------|-------------------|---------|----------|
| skills | `skills/<name>/` | `~/.claude/skills/<name>/` | dir-of-dirs | FR-003, FR-005, FR-012 |
| agents | `agents/<name>/` | `~/.claude/agents/<name>/` | dir-of-dirs | FR-003, FR-005 |
| plugins | `plugins/<name>/` | `~/.claude/plugins/<name>/` | dir-of-dirs (+ manifest check) | FR-003, FR-005 |
| commands | `commands/<name>.md` | `~/.claude/commands/<name>.md` | dir-of-files (.md) | FR-004, FR-005 |
| output-styles | `output-styles/<name>.md` | `~/.claude/output-styles/<name>.md` | dir-of-files (.md) | FR-004, FR-005 |
| hooks.d | `hooks.d/<name>.json` | `~/.claude/settings.json` `.hooks` | fragment-merge | FR-006, FR-007, FR-008 |
| mcp-servers.d | `mcp-servers.d/<name>.json` | `~/.claude/.mcp.json` `.mcpServers` | fragment-merge | FR-006, FR-007, FR-008 |

---

## The three reflection patterns

| Pattern | Helper signature | Unit of atomicity | Error handling |
|---------|-----------------|-------------------|----------------|
| dir-of-dirs | `reflect_dir_of_dirs <src> <dest>` | One `<name>/` subdirectory: rm → cp -r → chown | Per-item warn + continue |
| dir-of-files | `reflect_dir_of_files <src> <dest> <ext>` | One `<name>.<ext>` file: rm → cp → chown | Per-item warn + continue |
| fragment-merge | `merge_fragments <src_dir> <target_file> <jq_filter_var> <default_target_json>` | Entire bundle folded then merged once into target file | Per-fragment warn + continue; merge step runs on whatever folded successfully |

All three helpers are:

- No-ops when `<src>` or `<src_dir>` is missing or empty.
- Inline functions in [`scripts/entrypoint.sh`](../../../scripts/entrypoint.sh).
- Run under the existing `set -euo pipefail` posture. Per-item failure
  chains use `op_a && op_b && op_c || { warn; continue; }` to avoid
  aborting the loop on a single bad item.
- No subshells. Ownership fixed to `claude:claude` (UID/GID 1000).

---

## State transitions for `merge_fragments`

The fragment-merge helper is the most complex of the three because
it operates in two distinct phases — fold and merge — before writing.

```text
boot
  │
  ▼
[ src_dir present and non-empty? ] ──no──► (no-op; target file unchanged)
  │ yes
  ▼
FOLD PHASE: iterate fragments in LC_ALL=C lex order
  │
  ├── for each <name>.json:
  │     [ is a regular file? ] ──no──► skip (no warn; find result only)
  │     [ jq empty "$f" succeeds? ] ──no──► WARN: "skipping malformed fragment $f" → continue
  │     bundle = jq -s '.[0] * .[1]' <(printf '%s' "$bundle") "$f"
  │     [ jq exit 0? ] ──no──► WARN: "fold failed on $f" → continue
  │     (bundle accumulates)
  │
  ▼
bundle = folded JSON of all valid fragments (may be '{}' if all skipped)
  │
  ▼
MERGE PHASE:
  [ target_file exists? ] ──no──► current_target = <default_target_json>
  │ yes
  ▼
current_target = contents of target_file
  │
  ▼
merged = jq -n --argjson bundle "$bundle" \
             --argjson target "$current_target" \
             '<jq_filter>'
  │
  ▼
WRITE PHASE:
  write merged JSON to target_file (atomic via temp file + mv)
  │
  ▼
CHOWN:
  chown claude:claude target_file
  │
  ▼
done
```

**Idempotency invariant**: given identical fragments and identical
starting `target_file` content, two successive runs produce identical
`target_file` content (FR-007). The fold step is deterministic
(lex-sort); the merge step is a pure jq function.

---

## Validation rules

These translate spec FRs into invariants the entrypoint helpers
MUST enforce at runtime.

| Rule | Helper(s) | Spec FR |
|------|-----------|---------|
| Every bundled item MUST be owned `claude:claude` (UID/GID 1000) after reflection | all three | FR-003, FR-004 |
| A per-item failure MUST log exactly one warning line naming the offending path | all three | FR-009 |
| A per-item failure MUST NOT abort reflection of unrelated items or types | all three | FR-009 |
| An empty or missing source directory MUST be a no-op (not an error) | all three | FR-009 |
| Fragment merge order MUST be `LC_ALL=C` lexicographic; later filename wins on collision | `merge_fragments` | FR-008a |
| Bundled keys MUST overwrite same-named existing keys in target file | `merge_fragments` | FR-008b |
| User keys NOT in the bundle MUST be preserved untouched | `merge_fragments` | FR-005, FR-008b |
| A malformed JSON fragment MUST be skipped with a named-file warning | `merge_fragments` | FR-009 |
| The plugin manifest `<name>/.claude-plugin/plugin.json` MUST be present; missing manifest = warn + skip | `reflect_dir_of_dirs` (plugins call site) | US7 AC3 |
| `config/settings.json` and `config/CLAUDE.md` MUST NOT be touched by the reflection helpers | entrypoint sentinel logic (existing) | FR-013 |
| Adding an 8th type MUST require fewer than 20 new lines of entrypoint code | entrypoint structure | SC-003 |

---

## Out of model

- No new persistent volumes. Bundled content lives image-time at
  `/usr/local/share/kroclaude/config/`; reflected content lives in
  the existing `kroclaude-config` named volume (`/home/claude/.claude/`).
  This feature introduces no new persistence boundary.
- No new environment variables. All configuration is implicit in the
  `/config/` tree structure.
- No new Docker compose changes. No new published ports. No new
  bind-mounts. No new services.
- Fragment target files (`settings.json`, `.mcp.json`) are not
  themselves entities of this feature — they are shared with the
  existing first-boot seed logic (FR-013). The merge helpers append
  to whatever the seed logic wrote; they do not own the file's
  full content.
- Garbage collection of orphaned items (removed from a future bundle
  but still present in the named volume) is out of scope, matching
  feature 002 FR-007.
