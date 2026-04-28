# Research: Unified Claude Code Customization Bundle

**Feature**: 005-config-bundling
**Date**: 2026-04-28
**Spec**: [spec.md](spec.md)

This document records the technology and pattern choices made for this
feature. Decisions already locked by the user during planning
(single `/config/` root, `jq` for fragment merge, three-pattern
helper model, lex-order-last-wins precedence, bundled-wins-over-user
override, plugins via dir-of-dirs) are referenced briefly but not
re-litigated.

---

## R1 — One `/config/` root instead of seven sibling directories

**Decision**: all seven customization types live under a single repo
directory `/config/` as type-named subdirectories (`skills/`,
`commands/`, `agents/`, `output-styles/`, `hooks.d/`,
`mcp-servers.d/`, `plugins/`). The Dockerfile ships this entire tree
into one image-time read-only path:
`/usr/local/share/kroclaude/config/`.

**Rationale**:

- **Maintainability**: a maintainer adding a second MCP server changes
  exactly one file (`config/mcp-servers.d/<name>.json`) and does not
  touch the entrypoint, the Dockerfile, or any other configuration
  surface. The single-root layout makes the "drop a file" workflow
  self-evident.
- **Single bundling root**: the Dockerfile `COPY` for all seven types
  collapses to one line (`COPY config/
  /usr/local/share/kroclaude/config/`), replacing the current
  patchwork of individual `COPY skills/`, `COPY config/settings.json`,
  `COPY config/CLAUDE.md` lines. One `COPY`, one image-time path,
  one entrypoint stanza.
- **Mirrors Claude Code's own layout**: Claude Code groups its own
  user-editable customizations under `~/.claude/` with the same
  type-named subpaths (`skills/`, `commands/`, `agents/`, etc.).
  The `/config/` shape is intentionally isomorphic to that layout —
  someone who knows Claude Code already knows where to put things.
- **Feature 002 precedent**: the existing `/skills/` top-level
  directory was already a step toward this model; `/config/skills/`
  simply relocates it under the new roof (FR-012) without changing
  any runtime behavior.

**Alternatives considered**:

- **Seven sibling directories at the repo root** (`/skills/`,
  `/commands/`, `/agents/`, …) — rejected: seven separate `COPY`
  lines in Dockerfile, seven separately discoverable paths for new
  contributors, no single "add something here" mental model.
- **Single flat `/bundle/` with a manifest file** listing items and
  types — rejected: requires a manifest editor step for every new
  item, defeating the "drop and rebuild" maintainability goal. Also
  requires a manifest parser — extra complexity for zero runtime
  benefit.
- **Per-type environment variables** pointing to arbitrary host paths
  — rejected: breaks Principle II (Container-First Delivery) and
  the reproducible-builds guarantee (Principle I).

---

## R2 — `jq` for fragment merge

**Decision**: use `jq` (already installed in the image at
[Dockerfile:36](../../../Dockerfile#L36)) as the sole tool for
merging `hooks.d/` and `mcp-servers.d/` JSON fragments into their
target files. No Python, no `node`, no custom parser.

**Rationale**:

- **Already in image**: `jq` is a curated dependency from feature 001.
  Using it for JSON merge costs zero new image bytes, zero new
  Dockerfile lines, and zero new package pinning entries. This is the
  lowest-cost choice available.
- **Deterministic output**: `jq` produces byte-identical output for
  identical inputs on all supported architectures (`linux/amd64` +
  `linux/arm64`). The idempotency requirement (FR-007) is satisfied
  structurally: same fragments → same fold → same merge → same output.
  No floating-point, no hash-order sensitivity.
- **Standard JSON deep-merge semantics**: `jq`'s `*` operator
  performs a recursive object merge, which is exactly the semantics
  required for `mcpServers` (flat key collision) and `hooks` event
  arrays (per-event-type concatenation then group-by-matcher
  deduplication). Both patterns fit naturally into jq filter
  expressions without imperative loops.
- **Auditable**: the two filters (the MCP filter and the hooks filter)
  are short enough to read in full in a single screen. Any future
  maintainer can validate their behavior by running `echo '{}' | jq
  -n --argjson bundle '{}' '<filter>'` without needing a test
  harness. See [contracts/merge-filters.md](contracts/merge-filters.md)
  for the authoritative filter texts.
- **Availability in `set -euo pipefail`**: `jq` exits non-zero on
  malformed input, which integrates cleanly with the entrypoint's
  existing error posture. The `merge_fragments` helper uses `jq
  empty "$f"` as a pre-validation step (distinct from the merge
  call) to emit a named-file warning before skipping.

**Alternatives considered**:

- **Python `json` module via `python3 -c`**: also already in the
  image. Rejected because a multi-line Python one-liner for deep merge
  is harder to read than the equivalent jq filter, and the startup
  overhead (≥50 ms per invocation) compounds across multiple fragment
  files.
- **`node -e` with `JSON.parse`**: not curated; would require adding
  Node to the image, violating Principle III.
- **Hand-rolled bash JSON merge with `sed`/`awk`**: fragile, not
  correct for nested objects, unacceptable for a merge that must
  satisfy idempotency invariants.

---

## R3 — Three reflection patterns instead of seven specialized helpers

**Decision**: implement exactly three bash helper functions in
[`scripts/entrypoint.sh`](../../../scripts/entrypoint.sh):

```bash
reflect_dir_of_dirs  <src> <dest>
reflect_dir_of_files <src> <dest> <ext>
merge_fragments      <src_dir> <target_file> <jq_filter_var_name> <default_target_json>
```

Each of the seven types maps to exactly one of these three patterns.
No seventh helper, no per-type function.

**Rationale**:

- **The types naturally partition into three behavioral groups**: the
  key distinction is not between "skills" and "agents" or between
  "hooks" and "MCP servers" — it is between (a) types where the unit
  is a subdirectory tree, (b) types where the unit is a single file
  with a specific extension, and (c) types where the unit is a JSON
  fragment that does not stand alone but is folded into a shared target
  file. This tripartite structure maps cleanly to three helpers.
- **SC-003 compliance**: the success criterion requires that adding an
  8th type in the future requires fewer than 20 lines of entrypoint
  code. With three generic helpers that is trivially achievable: one
  new call site (one line) plus one new call to the appropriate
  pre-existing helper. With seven specialized helpers a new type
  would likely require a new helper.
- **No subshells**: all three helpers operate via in-process `while`
  loops, avoiding the subshell-per-item overhead and keeping the
  helpers compatible with `set -euo pipefail` (subshells swallow
  the `e` flag). The per-item error pattern
  `op_a && op_b && op_c || { warn; continue; }` works only inside
  a loop, not inside a subshell pipeline.
- **Symmetry aids review**: a future maintainer reading the entrypoint
  sees seven call sites, each one line, each invoking one of three
  well-named helpers. The cognitive load is bounded.

**Alternatives considered**:

- **One generic helper with a `--mode` flag** — rejected: the three
  modes are different enough (dir vs. file vs. merge) that a flag-
  dispatched single function is harder to read than three named
  functions. Named functions are also individually unit-testable.
- **Seven per-type functions** — rejected: violates SC-003; seven
  functions means code duplication (the dir-of-dirs iteration logic
  appears in four places), and any bug fix must be applied four times.
- **Two helpers (collapsing dir-of-dirs and dir-of-files into one)**
  — considered: `reflect_dir_of_dirs` and `reflect_dir_of_files`
  differ only in whether the unit is a directory or a file with an
  extension check. Collapsing them into one helper with an optional
  `<ext>` arg would be reasonable but makes the call sites slightly
  less self-documenting. Keeping them separate was chosen for clarity.

---

## R4 — Lex-order-last-wins precedence within bundle

**Decision** (implements FR-008a): when multiple fragments in
`config/hooks.d/` or `config/mcp-servers.d/` define the same key,
the fragment with the lexicographically later filename wins. Iteration
order is produced by `LC_ALL=C find … | LC_ALL=C sort` so the order
is byte-order of ASCII filenames — platform-independent and
reproducible.

**Rationale**:

- **Explicit naming convention**: an operator controls precedence by
  prefixing fragment filenames with a two-digit numeric prefix:
  `00-base.json` is always applied first and can be overridden by
  `99-override.json`. This is the exact pattern used by `apt`'s
  `sources.list.d/`, `logrotate.d/`, `sudoers.d/`, and `udev` rules
  — it is familiar to any Linux operator.
- **Determinism**: `LC_ALL=C` ensures byte-order sort regardless of
  the container's locale setting (which may vary across architectures
  or base-image versions). The sort result is identical on
  `linux/amd64` and `linux/arm64` for any ASCII filename.
- **Idempotency**: the same files in the same `find`+`sort` order
  produce the same fold output every boot (FR-007). There is no
  timestamp, no nonce, no hash involved in the ordering.
- **No registry, no manifest**: determining which fragment "wins"
  requires no metadata file — the filename itself encodes the
  operator's intent. This is consistent with the "drop a file"
  philosophy of the feature (SC-001).

**Operator convention**:

| Filename | Applied | Precedence |
|----------|---------|------------|
| `00-base.json` | first | lowest (overridable) |
| `50-team.json` | middle | middle |
| `99-override.json` | last | highest |

**Alternatives considered**:

- **First-file-wins** — rejected during clarification. First-wins
  means later-added files silently lose; last-wins means an operator
  intentionally placed `99-` prefix wins, which is a clearer contract.
- **Explicit ordering manifest** (`order.txt` listing fragment names)
  — rejected: requires an extra file that must be kept in sync; "drop
  a file" is broken if you must also edit a manifest.
- **Alphabetical with uppercase-before-lowercase (ASCII default)**
  — this IS what `LC_ALL=C` sort gives for ASCII filenames. No
  additional configuration required.

---

## R5 — Bundled-wins-over-user at merge time

**Decision** (implements FR-008b): when the merged bundle's key
collides with an existing key in `~/.claude/settings.json` (`.hooks`)
or `~/.claude/.mcp.json` (`.mcpServers`), the bundled value wins.
User-edited keys NOT in the bundle are preserved untouched.

**Rationale**:

- **Consistency with feature 002 FR-003**: the skill reflection rule
  already says "bundled item overwrites same-named user item on every
  boot." Applying the same rule to hooks and MCP keys gives a single
  mental model: "the bundle is authoritative for what it ships; it
  never touches what it doesn't ship."
- **Predictability for maintainers**: a maintainer who ships a
  `hooks.d/lint.json` fragment knows exactly what the container will
  run — they do not need to audit what a particular user may have
  hand-edited. The bundle is the single source of truth for bundled
  content.
- **User escape hatch is preserved**: keys the user adds themselves
  (MCP servers, hooks) under names NOT in the bundle are untouched.
  The bundle only asserts ownership over its own named keys.
- **jq implementation is clean**: the MCP filter `(.mcpServers // {})
  * $bundle` uses jq's left-priority `*` in a `<existing> *
  <bundle>` ordering. Because `jq`'s `*` is right-key-wins, the
  bundle (on the right) wins on collision. The hooks filter's
  `group_by`+`reduce` achieves the same semantics per matcher key.

**Alternatives considered**:

- **User-wins-over-bundle** — rejected during clarification. Would
  mean a user can silently shadow a security-relevant hook or MCP
  config shipped by the maintainer. Undesirable for a managed image.
- **Last-write-wins with no clear rule** — rejected: non-deterministic
  across reboots if the user edits between boots.
- **Per-key merge policy in a manifest** — rejected: overengineered;
  the two-rule model (within-bundle = lex-last, vs-user = bundle-wins)
  is sufficient and requires no per-key configuration.

---

## R6 — Plugin handling via the same `reflect_dir_of_dirs` helper

**Decision**: plugins are reflected using the same `reflect_dir_of_dirs`
helper as skills and agents. The plugin's deep tree (`.claude-plugin/
plugin.json` manifest plus nested `skills/`, `commands/`, etc.) is
treated as one indivisible per-item `cp -r` unit. One extra validation
step checks for the manifest's presence and logs a warning + skip if
missing (FR-007 edge case in spec; see also US7 AC3 in the spec).

**Rationale**:

- **The deep tree is just a `cp -r`**: `reflect_dir_of_dirs` already
  performs `rm -rf dest/<name> && cp -r src/<name> dest/<name> &&
  chown -R claude:claude dest/<name>` for each item. This is
  identical to what a plugin needs. The fact that a plugin contains
  a nested `.claude-plugin/` subdirectory and further nested type
  directories is irrelevant to the copy step — `cp -r` handles
  arbitrary depth.
- **One code path, not four**: a plugin bundles its own skills,
  commands, agents, and hooks — but the plugin directory itself is
  the unit of reflection, not its constituent types. Recursively
  calling the other helpers for each plugin's internals would
  produce duplicates in `~/.claude/skills/` etc. The correct behavior
  is to copy the plugin tree verbatim under `~/.claude/plugins/`
  and let Claude Code's own plugin runtime handle its internals.
- **Manifest validation is additive**: the one-extra check
  (`[ -f "$src/$name/.claude-plugin/plugin.json" ]`) is a guard
  against accidentally bundling a half-formed plugin directory. It
  does not change the core reflection loop — it is a `continue`
  guard inside the same per-item iteration the helper already runs.
- **No separate plugin-only helper**: adding a fourth helper for
  plugins would violate the three-pattern model (R3) for a single
  type. The manifest check is the only plugin-specific logic; it
  belongs at the call site, not in a new helper.

**Alternatives considered**:

- **Dedicated `reflect_plugin` helper** — rejected: the only plugin-
  specific logic (manifest presence check) is two lines; a full
  helper function is disproportionate.
- **Recursive call into `reflect_dir_of_dirs`/`reflect_dir_of_files`
  for each plugin's internals** — rejected: produces incorrect
  reflection (plugin internals should live under
  `~/.claude/plugins/<name>/` not under `~/.claude/skills/`).
- **Plugin-only type skipped in v1** — considered (low cost); rejected
  because the spec clarification (Q3) explicitly includes plugins in
  v1 and the implementation cost is minimal given the shared helper.
