# Implementation Plan: Unified Claude Code Customization Bundle

**Branch**: `005-config-bundling` | **Date**: 2026-04-28 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from [spec.md](spec.md)

## Summary

Generalize KroClaude's image-time customization surface so a maintainer
can drop ANY of seven Claude Code customization types (skills, commands,
agents, output-styles, hooks fragments, MCP server fragments, plugins)
into per-element subfolders under repo `/config/` and have them
reflected into `~/.claude/` on every container boot.

This is a structural restructure of features 001 (settings/CLAUDE.md
seed) and 002 (skill reflection): all bundled content moves under one
roof (`/config/`), and the entrypoint gains three small bash helpers
that handle the three distinct reflection patterns:

- **Directory-of-directories** (skills, agents, plugins): per-item
  rm-then-cp-then-chown atomic overwrite.
- **Directory-of-files** (commands `.md`, output-styles `.md`):
  per-file overwrite.
- **Fragment-merge-into-target** (hooks fragments → settings.json's
  `hooks` key, MCP fragments → `.mcp.json`'s `mcpServers` key):
  jq-based fold-then-merge with documented lex-order-last-wins
  precedence between fragments and bundled-wins-over-user precedence
  at the final overlay.

User-installed customizations under `~/.claude/<type>/` whose names do
not collide with bundled names are preserved on every boot (FR-005,
generalizing feature 002 FR-003). Failure of one fragment or item
logs a warning and skips that item without aborting reflection of
unrelated items (FR-009). The container always boots.

This feature **explicitly amends** feature 002's source-path FR
(skills bundling source moves from repo `/skills/` to `/config/skills/`)
without changing any of its runtime behavior FRs.

## Technical Context

**Language/Version**: Bash 5.x (entrypoint additions; three new
helper functions inline in `scripts/entrypoint.sh`); jq filter text
(merge filters for hooks and MCP fragments).
**Primary Dependencies**: `jq` (already in image, see
[Dockerfile:36](../../Dockerfile#L36)). Everything else reuses
features 001/002 machinery: the existing `scripts/entrypoint.sh`
under `set -euo pipefail`, the `kroclaude-config` named volume
(`/home/claude/.claude`), the `claude:claude` UID/GID 1000
ownership contract.
**Storage**: re-uses the existing `kroclaude-config` volume.
Bundled content lives **read-only** at image-time path
`/usr/local/share/kroclaude/config/<type>/`; reflected content
lives under `/home/claude/.claude/<type>/` (within the persistent
volume). No new persistence boundary.
**Testing**: a new `tests/smoke/test_us6.sh` exercises all seven
types end-to-end with one fixture per type under
`tests/smoke/fixtures/005/<type>/<name>/`. Fixtures are copied into
`/config/` at test-time only and torn down via the cleanup trap;
the default repo bundle stays empty (operator chooses content).
**Target Platform**: same as features 001/002/003/004 — Linux
Docker host, multi-arch `linux/amd64` + `linux/arm64`.
**Project Type**: extension to the existing deployment artifact.
**Performance Goals**: total reflection across all seven types in
under 2 seconds with the bundle budget (≤20 items per type, ≤10 MB
per type). First-boot bootstrap budget from feature 001 (SC-003:
≤15 s) MUST still hold with this feature added (SC-005).
**Constraints**: no new s6 services; no new processes; no new env
vars; no new published ports. Helpers MUST work under the existing
`set -euo pipefail` posture without aborting on a single bad
fragment (FR-009).
**Scale/Scope**: per-type budget mirrors feature 002's skill budget
(≤20 items, ≤10 MB). Total seven-type bundle is bounded by 7×those
limits; in practice expected to be small.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Walking each principle from
[`.specify/memory/constitution.md`](../../.specify/memory/constitution.md)
v1.0.0:

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Reproducible Builds (NON-NEGOTIABLE) | ✅ | jq is a pinned apt package (Dockerfile:36). All bundled content is checked in. Helpers use `LC_ALL=C` for deterministic sort and `find` for reproducible iteration. Merge output is byte-identical for identical inputs (FR-007). |
| II. Container-First Delivery | ✅ | Zero new env vars. Zero new mounts. Zero new ports. The bundling source `/config/` and the reflection target `~/.claude/` are both already container-internal paths declared by features 001/002. Operator drops a file in repo, rebuilds — no host-side prep. |
| III. Curated Tooling, Lean Image | ✅ | Zero new packages. jq is already curated. Image-size delta is whatever the maintainer chooses to bundle, controlled per-content. No tool overlap. |
| IV. Coolify-Native Deployment | ✅ | No compose changes. No `cap_add`/`security_opt`/`privileged` changes. Existing healthcheck unchanged. |
| V. Stateless Container, Explicit Persistence | ✅ | Bundled content lives image-time at `/usr/local/share/kroclaude/config/`; reflected content lives in the existing `kroclaude-config` named volume. Reflection is per-bundled-item-only — user-installed items in the same volume survive (FR-005). |

**Result: PASS** — no Complexity Tracking entries needed.

Re-check after Phase 1 design: artifacts in `contracts/` ratify the
above choices without altering them. **Still PASS.**

## Project Structure

### Documentation (this feature)

```text
specs/005-config-bundling/
├── plan.md              # This file
├── research.md          # Phase 0 — reflection patterns, jq filters, lex order
├── data-model.md        # Phase 1 — seven types, three reflection patterns
├── quickstart.md        # Phase 1 — operator workflow ("drop a folder")
├── contracts/
│   ├── reflection-helpers.md      # The three bash helper signatures
│   ├── merge-filters.md           # The jq filters for hooks & MCP merging
│   └── bundle-layout.md           # /config/ subdirectory shape per type
├── checklists/
│   └── requirements.md  # Already created by /speckit-specify
└── tasks.md             # Phase 2 output (/speckit-tasks)
```

### Source Code (repository root)

```text
config/                                   # The bundling root (existing dir, expanded)
├── settings.json                         # Existing — first-boot seed (FR-013)
├── CLAUDE.md                             # Existing — first-boot seed (FR-013)
├── skills/                               # NEW — relocated from /skills/ (FR-012)
├── commands/                             # NEW — drop *.md per command
├── agents/                               # NEW — drop <name>/agent.md per agent
├── output-styles/                        # NEW — drop *.md per style
├── hooks.d/                              # NEW — drop *.json fragments
├── mcp-servers.d/                        # NEW — drop *.json fragments
└── plugins/                              # NEW — drop full plugin trees

scripts/entrypoint.sh                     # +3 helper functions, +7 call sites,
                                          # -existing skills reflection block (replaced)
Dockerfile                                # +COPY config/ /usr/local/share/kroclaude/config/
                                          # -COPY skills/ /usr/local/share/kroclaude/skills/
                                          # (settings.json / CLAUDE.md COPYs fold into the
                                          #  new directory copy)
skills/                                   # REMOVED (legacy — relocated under config/)
tests/smoke/
├── test_us6.sh                           # NEW — exercises all seven types
└── fixtures/005/                         # NEW — fixtures per type
    ├── skills/hello/SKILL.md
    ├── commands/triage.md
    ├── agents/db-reviewer/agent.md
    ├── output-styles/brief.md
    ├── hooks.d/lint.json
    ├── mcp-servers.d/postgres.json
    └── plugins/sample/.claude-plugin/plugin.json
.github/workflows/ci.yml                  # +invoke tests/smoke/test_us6.sh
CLAUDE.md                                 # +pointer to specs/005-config-bundling/plan.md
config/CLAUDE.md                          # update path references skills/→config/skills/
```

**Structure Decision**: same single-artifact deployment shape as
features 001/002/003/004. No new top-level directories beyond the
new subdirectories under `/config/`. The legacy `/skills/` is
removed in the same commit boundary that introduces `/config/skills/`.

## Implementation Sketch

The full design memo (the design-agent output that fed this plan)
lives outside spec-kit, but the load-bearing pieces are pinned here
for traceability. See [contracts/](contracts/) for the
authoritative shapes.

### The three reflection helpers (inline in `scripts/entrypoint.sh`)

```bash
reflect_dir_of_dirs <src> <dest>                     # skills, agents, plugins
reflect_dir_of_files <src> <dest> <ext>              # commands (md), output-styles (md)
merge_fragments <src_dir> <target_file> <jq_filter>  # hooks.d, mcp-servers.d
```

Each helper is a no-op when the source is missing or empty.
Per-item failure: `op_a && op_b && op_c || { warn; continue; }`
chains. NO subshells. The seven call sites at the bottom of the
stanza are one line apiece.

### The two jq merge filters

**MCP servers** (flat-map deep-merge):

```jq
.mcpServers = ((.mcpServers // {}) * $bundle)
```

**Hooks** (group_by-then-reduce on the deeper `{event: [{matcher,
hooks}]}` shape):

```jq
def merge_hooks_event(existing; bundled):
  ((existing // []) + (bundled // []))
  | group_by(.matcher // "")
  | map(reduce .[] as $x ({}; . * $x));

.hooks = (
  (.hooks // {}) as $cur
  | reduce ($bundle | to_entries[]) as $e
      ($cur; .[$e.key] = merge_hooks_event(.[$e.key]; $e.value))
)
```

The fold step (folding multiple bundled fragments into one bundle
JSON) uses `jq -s '.[0] * .[1]'` per fragment in lex order. This
is the lex-order-last-wins rule from clarification Q1. The merge
step (above) is the bundled-wins-over-user rule from clarification
Q2.

### Test scaffolding

`tests/smoke/test_us6.sh` follows the
[`tests/smoke/test_us4.sh`](../../tests/smoke/test_us4.sh) and
[`tests/smoke/test_us5.sh`](../../tests/smoke/test_us5.sh) skeleton
(`COMPOSE`, `wait_healthy`, `cleanup` trap, `log`/`fail` helpers).
For each of the seven types it copies one fixture from
`tests/smoke/fixtures/005/<type>/<name>/` into `/config/<type>/`,
brings the stack up, asserts the reflected file is present at the
expected `~/.claude/<type>/` path with `claude:claude` ownership,
and (for hooks/MCP) asserts the merged target file contains both
the bundled fragment AND any pre-existing first-boot-seeded keys.

The cleanup trap restores `/config/` to its pre-test state.

## Three-Commit Migration Shape

Per the design memo, the implementation lands in three independently
bisectable commits:

1. **`refactor: relocate bundled skills under config/`** — moves
   `/skills/` content (today: empty save for `.gitkeep`) under
   `/config/skills/`, replaces the granular Dockerfile COPY lines
   with `COPY config/ /usr/local/share/kroclaude/config/`, updates
   the existing entrypoint reflection block to read the new source
   path. **Behavior unchanged.** All existing smoke tests still pass.
2. **`feat: add reflection helpers + six new types`** — defines the
   three helpers in `scripts/entrypoint.sh`, adds the seven call
   sites (skills now via the helper too — old code path removed),
   creates the empty type subdirectories under `/config/` with
   `.gitkeep` files.
3. **`test: smoke-test all seven bundled types`** —
   `tests/smoke/test_us6.sh` + the `fixtures/005/` tree + CI wiring.

## Complexity Tracking

> No Constitution Check violations — section intentionally empty.
