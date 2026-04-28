# Feature Specification: Unified Claude Code Customization Bundle

**Feature Branch**: `005-config-bundling`
**Created**: 2026-04-28
**Status**: Draft
**Input**: User description: "in /config I want to be able to add
skills / commands / hooks / etc to claude. each element will have his
own subfolder. don't forget that we should ensure an easly maintainable
solution in the end."

## Clarifications

### Session 2026-04-28

- Q: When two `config/hooks.d/*.json` (or `config/mcp-servers.d/*.json`)
  fragments define the same key, which wins?
  → A: Lexicographic file order (`LC_ALL=C` sort), **later file
  wins** on key collision. Maintainers control precedence by
  prefixing filenames (`00-base.json`, `99-override.json`).
- Q: When a bundled hook/MCP key collides with a user-edited key in
  `~/.claude/settings.json` or `~/.claude/.mcp.json`, which wins?
  → A: **Bundled wins** — same rule as feature 002's skill collision
  behavior. Single "bundle is authoritative" rule across all types.
  User keys NOT in the bundle are preserved untouched.
- Q: Support Claude Code plugin packaging
  (`.claude-plugin/plugin.json`) as a 7th bundled type?
  → A: **Yes, include in v1.** Add `config/plugins/<name>/` as the
  seventh bundled type. Each plugin is a self-contained directory
  tree containing a `.claude-plugin/plugin.json` manifest plus its
  own nested skills/commands/agents/etc. Reflection target:
  `~/.claude/plugins/<name>/`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Drop a Skill into the Bundle (Priority: P1)

A KroClaude maintainer wants to add a new Claude Code skill (e.g., a
domain-specific helper for working with their database) so it ships
with every container. They create a folder `config/skills/<name>/`
in the repo containing the standard `SKILL.md` plus any helper
files, rebuild the image, and restart the container. The skill is
present in the running container's `~/.claude/skills/<name>/` and
Claude Code picks it up automatically. No edits to the entrypoint
or to any registry are needed.

**Why this priority**: skills are the single most-used Claude Code
extension surface and the existing feature (002) already proves
this works for them — but only from the legacy `/skills/` repo
root. Migrating skills under `/config/` is the headline change of
this feature and the unlocks-everything-else step.

**Independent Test**: drop a fixture skill `config/skills/hello/SKILL.md`
into the repo, `docker compose up -d --build`, then run
`docker exec -u claude kroclaude ls /home/claude/.claude/skills/hello/SKILL.md`
and confirm the file is present and owned by `claude:claude`.

**Acceptance Scenarios**:

1. **Given** a fresh repo with one skill at `config/skills/hello/SKILL.md`,
   **When** the operator builds and starts the container,
   **Then** `~/.claude/skills/hello/SKILL.md` exists, is owned by
   `claude:claude`, and matches the source byte-for-byte.
2. **Given** a running container with a bundled skill `hello`,
   **When** the operator updates `config/skills/hello/SKILL.md`,
   rebuilds, and restarts, **Then** the in-container copy reflects
   the new content (overwrite-on-boot).
3. **Given** a running container where the user has manually created
   `~/.claude/skills/my-private/SKILL.md` (not in the bundle),
   **When** the operator restarts the container, **Then** the
   `my-private` skill is preserved untouched.

---

### User Story 2 — Drop a Slash Command into the Bundle (Priority: P1)

A maintainer wants to ship a custom slash command (e.g., `/triage`)
so every container has it available out of the box. They drop a
file at `config/commands/<name>.md`, rebuild, restart. Inside the
container, typing `/<name>` in Claude Code invokes the command.

**Why this priority**: slash commands are the primary way users
script repeatable Claude workflows. Without this, the container
ships with no project-specific command vocabulary.

**Independent Test**: drop `config/commands/triage.md` with valid
frontmatter, build and start, then list `~/.claude/commands/`
inside the container and confirm `triage.md` is present.

**Acceptance Scenarios**:

1. **Given** `config/commands/triage.md` exists in the repo,
   **When** the container boots, **Then**
   `~/.claude/commands/triage.md` is present and matches the
   source.
2. **Given** the user has hand-edited `~/.claude/commands/local-only.md`,
   **When** the container restarts, **Then** `local-only.md` is
   preserved untouched.

---

### User Story 3 — Drop a Sub-Agent Definition (Priority: P1)

A maintainer wants to ship a project-specific sub-agent (e.g.,
"db-migration-reviewer") that Claude can invoke via the Agent tool.
They create `config/agents/<name>/agent.md`, rebuild, restart.
Inside the container the agent is available as
`~/.claude/agents/<name>/`.

**Why this priority**: sub-agents are how a single Claude session
delegates work. A bundled set encodes the project's preferred
delegation patterns once for everyone using the image.

**Independent Test**: drop `config/agents/db-migration-reviewer/agent.md`,
build and start, then confirm
`~/.claude/agents/db-migration-reviewer/agent.md` exists.

**Acceptance Scenarios**:

1. **Given** `config/agents/db-migration-reviewer/agent.md` exists,
   **When** the container boots, **Then** the agent file is
   reflected and owned by `claude:claude`.
2. **Given** a hand-installed agent `~/.claude/agents/private/`,
   **When** the container restarts, **Then** `private` is
   preserved untouched.

---

### User Story 4 — Drop an Output Style (Priority: P2)

A maintainer wants to ship an output style (e.g., a "brief"
mode that constrains Claude's verbosity). They drop a file at
`config/output-styles/<name>.md`, rebuild, restart. Inside the
container the style is selectable.

**Why this priority**: output styles are a smaller user-facing
surface than skills/commands/agents and only some teams will
care, but the cost of supporting them is incremental once the
"directory-of-files" reflection pattern is in place.

**Independent Test**: drop `config/output-styles/brief.md`, build
and start, then confirm `~/.claude/output-styles/brief.md` exists.

**Acceptance Scenarios**:

1. **Given** `config/output-styles/brief.md` exists, **When** the
   container boots, **Then** the in-container file is present and
   owned by `claude:claude`.
2. **Given** a user-created `~/.claude/output-styles/my-mood.md`,
   **When** the container restarts, **Then** `my-mood.md` is
   preserved.

---

### User Story 5 — Drop a Hook Fragment (Priority: P2)

A maintainer wants to ship a project-specific Claude Code hook
(e.g., a `PostToolUse` block that lints generated code). They
drop a JSON fragment at `config/hooks.d/<name>.json` containing a
partial `hooks` object, rebuild, restart. The fragment is merged
into `~/.claude/settings.json`'s `hooks` block on boot.

**Why this priority**: hooks are powerful but the merging
requirement makes them strictly harder than the four "drop a
file" types above. Lower priority because the pattern can be
fully validated by US1–US4 first; once proven, hooks add the
same per-element ergonomics for a config-merge target.

**Independent Test**: drop `config/hooks.d/lint.json` with a
valid `PostToolUse` entry, build and start, then read
`~/.claude/settings.json` inside the container and confirm the
hook is present alongside the existing first-boot-seeded hooks
(notify.py wiring) without clobbering them.

**Acceptance Scenarios**:

1. **Given** an empty `config/hooks.d/` and the existing
   first-boot-seeded `~/.claude/settings.json` containing
   notify-related hooks, **When** the container boots, **Then**
   `~/.claude/settings.json` is unchanged.
2. **Given** `config/hooks.d/lint.json` containing a `PostToolUse`
   entry, **When** the container boots, **Then**
   `~/.claude/settings.json`'s `hooks.PostToolUse` array contains
   both the user's prior entries (if any) and the bundled entry,
   with no duplicates and no unrelated keys lost.
3. **Given** two fragments `config/hooks.d/a.json` and
   `config/hooks.d/b.json` both defining a `PostToolUse` matcher
   with the same `matcher`, **When** the container boots,
   **Then** the merge is deterministic and the precedence is
   documented and consistent across reboots.

---

### User Story 6 — Drop an MCP Server (Priority: P2)

A maintainer wants to ship a project-specific MCP server config
(e.g., a Postgres MCP server pointing at the team database). They
drop `config/mcp-servers.d/<name>.json` containing a single
server entry, rebuild, restart. The entry is merged into
`~/.claude/.mcp.json`'s `mcpServers` map on boot.

**Why this priority**: same shape as hooks, same merge complexity,
same priority. MCP servers are the second config-merge target.

**Independent Test**: drop `config/mcp-servers.d/postgres.json`,
build and start, then read `~/.claude/.mcp.json` and confirm the
`postgres` entry is present without disturbing other entries.

**Acceptance Scenarios**:

1. **Given** `config/mcp-servers.d/postgres.json` defining a
   `postgres` server, **When** the container boots, **Then**
   `~/.claude/.mcp.json`'s `mcpServers.postgres` matches the
   fragment exactly.
2. **Given** the user has hand-added an `mcpServers.local-only`
   entry to `~/.claude/.mcp.json`, **When** the container
   restarts, **Then** `local-only` is preserved.

---

### User Story 7 — Drop a Claude Code Plugin (Priority: P2)

A maintainer wants to ship a self-contained Claude Code plugin
(its own `.claude-plugin/plugin.json` manifest plus nested
skills, commands, agents, hooks, and `.mcp.json`). They drop the
entire plugin tree under `config/plugins/<name>/`, rebuild,
restart. The plugin tree appears at `~/.claude/plugins/<name>/`
inside the container with the same byte content and ownership.

**Why this priority**: plugins are Claude Code's official packaging
format for shipping a related set of customizations as one unit
(the same shape as `/config/` itself, but vendored from a third
party). Supporting them lets maintainers consume upstream plugin
bundles without exploding them across `/config/skills/`,
`/config/commands/`, etc.

**Independent Test**: drop a fixture
`config/plugins/sample-plugin/.claude-plugin/plugin.json` plus a
nested `skills/hello/SKILL.md`, build and start, then confirm
`~/.claude/plugins/sample-plugin/.claude-plugin/plugin.json` and
`~/.claude/plugins/sample-plugin/skills/hello/SKILL.md` both
exist with `claude:claude` ownership.

**Acceptance Scenarios**:

1. **Given** a plugin tree at
   `config/plugins/sample-plugin/` containing the manifest plus
   nested files, **When** the container boots, **Then** the
   entire tree is reflected verbatim under
   `~/.claude/plugins/sample-plugin/`.
2. **Given** a hand-installed plugin at
   `~/.claude/plugins/private/`, **When** the container restarts,
   **Then** `private` is preserved untouched.
3. **Given** a bundled plugin missing its
   `.claude-plugin/plugin.json` manifest, **When** the container
   boots, **Then** the entrypoint logs a one-line warning naming
   the offending plugin AND skips it AND continues reflecting
   the other types.

---

### User Story 8 — Existing settings.json + CLAUDE.md Behavior Unchanged (Priority: P3)

The existing first-boot-only seeding of `config/settings.json` and
`config/CLAUDE.md` (today's behavior) is unchanged. Operators
who edit either file see the change reflected only on a
fresh container (or after manually deleting the in-container
copy) — not on every boot.

**Why this priority**: regression check. Feature 005 must not
break the existing flow that 001 established.

**Independent Test**: edit `config/CLAUDE.md` in the repo,
rebuild and restart an existing container with a populated
`kroclaude-config` volume; confirm the in-container
`~/.claude/CLAUDE.md` is the OLD content (sentinel-gated, no
update). Then wipe the volume, restart, and confirm the new
content is now present.

---

### Edge Cases

- A fragment file is malformed JSON: the entrypoint logs a single
  line naming the offending file and skips it. Other fragments and
  other types still reflect successfully. Container still boots.
- A skill directory is empty (no SKILL.md): logged and skipped;
  reflection of other skills proceeds.
- A bundled item's name collides with an existing user-installed
  item of the same name: bundled wins (consistent with feature
  002 FR-003 collision behavior). User must rename their copy.
- A bundled item is removed from `/config/` in a future image:
  the in-container copy is orphaned (not garbage-collected). This
  matches feature 002 FR-007.
- A `config/hooks.d/<name>.json` fragment defines a hook event
  type the user has never seen before: it is added under that
  event-type key without disturbing other event types.
- The `~/.claude/settings.json` or `~/.claude/.mcp.json` target
  file does not exist yet (very fresh container): the merge step
  creates the file with the merged content as its first contents.
- The total reflection time exceeds the existing first-boot
  bootstrap budget: log a warning but do not abort. (See SC-005
  for the budget number.)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `/config/` MUST be the single canonical bundling
  source for all SEVEN supported customization types: skills,
  commands, agents, output-styles, hooks-d, mcp-servers-d, and
  plugins.
- **FR-002**: The image build MUST ship every subdirectory of
  `/config/` into a known image-time read-only path (separate
  from the runtime `~/.claude/` destination). Build-time copies
  MUST NOT install anything into the container's home directory.
- **FR-003**: For each "directory-of-items" type (skills,
  agents, plugins), the entrypoint MUST reflect each bundled
  `<name>/` into `~/.claude/<type>/<name>/` on every container
  boot using an atomic per-item rm-then-copy-then-chown pattern.
  For the `plugins` type the source tree may be deeper (each
  plugin has its own `.claude-plugin/plugin.json` manifest plus
  nested subdirectories) and the entire subtree under
  `<name>/` is treated as one indivisible reflection unit.
- **FR-004**: For each "file-of-items" type (commands,
  output-styles), the entrypoint MUST reflect each bundled
  `<name>.<ext>` into `~/.claude/<type>/<name>.<ext>` on every
  container boot, with the same per-item atomicity.
- **FR-005**: The entrypoint MUST NOT delete or modify any item
  under `~/.claude/<type>/` whose name is not in the current
  bundled set. (Generalizes feature 002 FR-003 across all six
  types.)
- **FR-006**: For "config-merge" types (`hooks.d/`,
  `mcp-servers.d/`), the entrypoint MUST merge each fragment into
  the appropriate target file (`~/.claude/settings.json`'s
  `hooks` key or `~/.claude/.mcp.json`'s `mcpServers` key) using
  a deterministic strategy that preserves all unrelated keys in
  the target file.
- **FR-007**: The merge strategy MUST be re-runnable: the merged
  output for a given set of fragments and a given starting
  target file MUST be byte-identical across reboots (idempotent).
- **FR-008**: Fragment merge precedence MUST be deterministic and
  follows TWO documented rules:
  (a) **Within the bundle**: fragment files are merged in
  `LC_ALL=C` lexicographic filename order; on key collision, the
  later file wins. Maintainers control precedence by prefixing
  filenames (`00-base.json`, `99-override.json`).
  (b) **Bundle vs. existing target file**: the merged bundle
  overlays the existing target file (`~/.claude/settings.json`
  or `~/.claude/.mcp.json`); on key collision the **bundled
  value wins**, matching feature 002 FR-003 collision semantics
  for the skill type. User-edited keys NOT in the bundle are
  preserved untouched.
- **FR-009**: A failure on any single item or fragment MUST log a
  one-line message naming the offending file and MUST NOT abort
  reflection of unrelated items. The container MUST still boot.
- **FR-010**: Reflection MUST run inside the existing
  `scripts/entrypoint.sh` under `set -euo pipefail`. No new s6
  services. No new background processes.
- **FR-011**: The per-type reflection logic MUST be implemented
  as a small set of shared helpers (one per of the three
  patterns: dir-of-dirs, dir-of-files, fragment-merge-into-target)
  so that adding a 7th type later requires touching at most one
  call site, not new logic per type.
- **FR-012**: The legacy repo-root `/skills/` directory MUST be
  moved into `/config/skills/` and the old top-level `/skills/`
  tree removed. Feature 002's existing reflection FRs (FR-001…
  FR-010) MUST continue to hold under the new source path —
  this is a structural restructure, not a behavior change for
  the skill type.
- **FR-013**: The existing first-boot-only seeding of
  `config/settings.json` and `config/CLAUDE.md` (sentinel-gated,
  unchanged from feature 001) MUST be preserved without
  alteration. Reflection (FR-003/004/006) does NOT touch these
  two files.
- **FR-014**: A smoke test MUST exercise all SEVEN types end-to-
  end with a representative fixture per type, verify each is
  present and correctly reflected, AND verify a user-installed
  same-type item with a different name is preserved.

### Key Entities

- **Bundled item**: a unit of Claude Code customization shipped
  in the image under one of the six `/config/` subdirectories.
  Identity = `(type, name)`. Reflected into `~/.claude/<type>/`
  on boot.
- **User-installed item**: a unit of Claude Code customization
  written by the user (or another process) directly into
  `~/.claude/<type>/`. Identity = `(type, name)`. The reflection
  pipeline never touches a user-installed item whose name does
  not collide with a bundled name.
- **Fragment** (hooks-d, mcp-servers-d only): a JSON file under
  `/config/<type>/<name>.json` containing a partial structure
  that is merged into a single config target file at boot. Not a
  standalone customization in itself.
- **Reflection target**: the destination path or file inside
  `~/.claude/` for a given type. Six destinations, one per type.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A maintainer can add a new bundled skill, command,
  agent, output-style, hook fragment, or MCP server fragment to
  the repo and have it active in a freshly rebuilt container in
  under 60 seconds of human work (write the file → rebuild →
  restart → verify), with no edits to scripts or documentation
  required.
- **SC-002**: 100% of user-installed items (items present in
  `~/.claude/<type>/` whose names do not match any bundled name)
  survive a container restart unchanged.
- **SC-003**: Adding an 8th customization type in the future
  (beyond the seven shipped here) requires editing fewer than 20
  lines of entrypoint code (a single new call into the existing
  per-pattern helpers).
- **SC-004**: When a single bundled item is malformed, all other
  bundled items of the same type AND all items of all other
  types still reflect correctly. The container still boots.
- **SC-005**: Total reflection time across all seven types stays
  inside the feature-001 first-boot bootstrap budget; no boot
  takes longer than 15 seconds attributable to bundling.
- **SC-006**: An existing operator who is currently using
  feature 002's `/skills/` directory can move their skills into
  `/config/skills/`, rebuild, and observe zero behavioral change
  in how their skills are presented to Claude Code.

## Assumptions

- The Coolify-managed deployment target ships with the same Docker
  daemon contract assumed by features 001–004; nothing new on
  the host side.
- The user-installed customizations under `~/.claude/` live in
  the existing `kroclaude-config` named volume (per feature 001),
  so they survive container recreation. This feature does not
  introduce a new persistence boundary.
- The total bundled customization payload across all six types
  remains modest (≤20 items per type, ≤10 MB per type — same
  budget as feature 002 for skills, applied per-type). Larger
  bundles are out of scope.
- The fragment formats for hooks and MCP servers are stable parts
  of Claude Code's public schema; the merge logic encodes the
  current shape of `settings.json.hooks` and `.mcp.json.mcpServers`
  and would need maintenance only if Claude Code changes those
  shapes.
- The `/config/CLAUDE.md` and `/config/settings.json` first-boot
  seed (today's behavior) is acceptable to keep — operators who
  want to "rotate" those files for an existing container do so by
  deleting the in-container copy or wiping the volume.
- "Each element has its own subfolder" is interpreted strictly
  for the directory-of-directories types (skills, agents,
  plugins) and loosely for the file-per-item types (commands,
  output-styles, hooks-d, mcp-servers-d) where one file per
  element is the natural granularity.
- For plugins, "reflection" means copying the entire bundled
  plugin tree verbatim into `~/.claude/plugins/<name>/`. This
  feature does NOT register plugins with Claude Code's CLI on
  the user's behalf — discovery/enabling of reflected plugins
  follows whatever mechanism Claude Code uses for plugins
  found under `~/.claude/plugins/` (e.g., automatic detection
  or operator-run `/plugin` command). The reflection contract
  is the only guarantee.
