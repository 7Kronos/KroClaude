---

description: "Task list template for feature implementation"
---

# Tasks: Unified Claude Code Customization Bundle

**Input**: Design documents from `/specs/005-config-bundling/`
**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/](contracts/)

**Tests**: Spec FR-014 explicitly requires an end-to-end smoke test
(`tests/smoke/test_us6.sh`) covering all seven types, so test tasks
ARE included below. The test is a single bash script built
incrementally — Foundational creates the scaffold, each user-story
phase appends its own assertion block.

**Organization**: Tasks are grouped by user story to enable
independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US8)
- All file paths are relative to repo root: `/home/krs/Repos/KroClaude/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the empty per-type subdirectories under `/config/`
so the Dockerfile `COPY config/` picks them up even when no items are
bundled yet. Each directory gets a `.gitkeep` so git tracks the
empty tree.

- [X] T001 [P] Create the seven new bundling subdirectories under `config/` with `.gitkeep` placeholders: `config/skills/.gitkeep`, `config/commands/.gitkeep`, `config/agents/.gitkeep`, `config/output-styles/.gitkeep`, `config/hooks.d/.gitkeep`, `config/mcp-servers.d/.gitkeep`, `config/plugins/.gitkeep`. The pre-existing `config/settings.json` and `config/CLAUDE.md` are untouched.

---

## Phase 2: Foundational (Blocking Prerequisites — corresponds to migration commits 1 & 2)

**Purpose**: The image-time and entrypoint plumbing that EVERY user
story depends on. Without these, no helper can be called and no
type can be reflected. Implements migration commit 1 (relocate
skills + Dockerfile refactor) and commit 2 (helper definitions).

**⚠️ CRITICAL**: No user-story work can begin until this phase is complete.

- [X] T002 In `Dockerfile`, replace the granular `COPY config/settings.json …` and `COPY config/CLAUDE.md …` and `COPY skills/ /usr/local/share/kroclaude/skills/` lines with a single `COPY config/ /usr/local/share/kroclaude/config/`. Verify with `grep -n COPY Dockerfile` that the three old COPYs are gone and the new one is present. See [contracts/bundle-layout.md](contracts/bundle-layout.md) for the destination shape.
- [X] T003 Delete the now-empty legacy `skills/` directory tree at the repo root (`git rm -r skills/`). Confirm `ls skills/ 2>/dev/null` is empty after.
- [X] T004 In `scripts/entrypoint.sh`, **define** the three reflection helper functions exactly per [contracts/reflection-helpers.md](contracts/reflection-helpers.md): `reflect_dir_of_dirs`, `reflect_dir_of_files`, `merge_fragments`. Place them as a new section AFTER the existing first-boot-seed block (around line 88) and BEFORE the existing skills-reflection block. Each helper must satisfy the per-item-failure-isolation invariant (FR-009: `op_a && op_b && op_c || { warn; continue; }`, no subshells). Helpers MUST be no-ops when source is missing/empty.
- [X] T005 In `scripts/entrypoint.sh`, **define** the two jq filter constants exactly per [contracts/merge-filters.md](contracts/merge-filters.md): `MCP_MERGE_FILTER` (one-liner `.mcpServers = ((.mcpServers // {}) * $bundle)`) and `HOOKS_MERGE_FILTER` (the multi-line `def merge_hooks_event(...) ... .hooks = (...)` filter). Place them as bash variables next to the helper definitions for locality.
- [X] T006 In `scripts/entrypoint.sh`, **update the existing skills paths** so the three first-boot-seed copies (`settings.json`, `CLAUDE.md`, codex/gemini config seeding) all read from `/usr/local/share/kroclaude/config/` instead of `/usr/local/share/kroclaude/`. Mechanical search-and-replace; no behavior change. Confirm with `grep -n /usr/local/share/kroclaude scripts/entrypoint.sh` that every reference points at the new prefix.
- [X] T007 In `scripts/entrypoint.sh`, **remove the existing skills-reflection block** (around lines 88–107, the for-loop over `$SKILLS_SRC`/*/) and **replace** it with a single call to `reflect_dir_of_dirs /usr/local/share/kroclaude/config/skills /home/claude/.claude/skills`. This is the proof that the new helper covers the existing skill case (US1). Confirm by inspection that no per-item rm/cp loop for skills remains.
- [X] T008 [P] Create `tests/smoke/test_us6.sh` skeleton modeled on [`tests/smoke/test_us5.sh`](../../tests/smoke/test_us5.sh): same `COMPOSE`, `wait_healthy`, `cleanup` trap, `log`/`fail` helpers. The skeleton MUST: (a) snapshot the current `/config/` tree to `$TMP_DIR/config-backup/` so the cleanup trap can restore it; (b) define a `place_fixture <type> <name>` shell function that copies `tests/smoke/fixtures/005/<type>/<name>/...` into `/config/<type>/`; (c) bring the stack up with an injected `KROCLAUDE_SSH_AUTHORIZED_KEY` (reuse the US4/US5 keygen pattern). Each user-story phase appends its own assertion block to this file.
- [X] T009 [P] Create the seven fixture trees under `tests/smoke/fixtures/005/`: `skills/hello/SKILL.md` (minimal valid SKILL.md), `commands/triage.md` (minimal slash-command), `agents/db-reviewer/agent.md` (minimal sub-agent), `output-styles/brief.md` (minimal output style), `hooks.d/lint.json` (one PostToolUse entry), `mcp-servers.d/postgres.json` (one MCP server entry), `plugins/sample-plugin/.claude-plugin/plugin.json` (minimal plugin manifest). Refer to [quickstart.md](quickstart.md) for example shapes.

**Checkpoint**: Image builds, container boots, the existing skill reflection still works (now via the helper), and the test scaffold runs end-to-end with zero assertions. User-story phases can now begin.

---

## Phase 3: User Story 1 — Drop a Skill into the Bundle (Priority: P1) 🎯 MVP

**Goal**: A maintainer drops a folder under `config/skills/<name>/`, rebuilds, restarts, and the skill is present at `~/.claude/skills/<name>/SKILL.md`.

**Independent Test**: place fixture `tests/smoke/fixtures/005/skills/hello/SKILL.md` into `/config/skills/`, build & start, then `docker exec -u claude kroclaude ls /home/claude/.claude/skills/hello/SKILL.md` exits 0.

### Implementation for User Story 1

- [X] T010 [US1] **Verify** that T007's single-line replacement (`reflect_dir_of_dirs … skills …`) is in place in `scripts/entrypoint.sh` and is the ONLY skills-reflection code path. No additional implementation work needed for this story — the helper IS the implementation.
- [X] T011 [US1] In `tests/smoke/test_us6.sh`, append the US1 assertion block: (a) `place_fixture skills hello`; (b) bring stack up; (c) assert `/home/claude/.claude/skills/hello/SKILL.md` exists; (d) assert ownership is `claude:claude`; (e) assert byte content matches the fixture; (f) place a `~/.claude/skills/private-user-skill/SKILL.md` directly via `docker exec` BEFORE restart; restart; assert `private-user-skill` survives untouched (FR-005 user-immunity for skills).

**Checkpoint**: User Story 1 is functional. Skills work via the new helper just as they did via the old block.

---

## Phase 4: User Story 2 — Drop a Slash Command into the Bundle (Priority: P1)

**Goal**: A maintainer drops `config/commands/<name>.md`, and the command appears at `~/.claude/commands/<name>.md`.

**Independent Test**: place `tests/smoke/fixtures/005/commands/triage.md` into `/config/commands/`, build & start, then assert `/home/claude/.claude/commands/triage.md` exists.

### Implementation for User Story 2

- [X] T012 [US2] In `scripts/entrypoint.sh`, **add a call site** at the bottom of the new helper-call section: `reflect_dir_of_files /usr/local/share/kroclaude/config/commands /home/claude/.claude/commands md`. One line. Per [contracts/reflection-helpers.md](contracts/reflection-helpers.md) §`reflect_dir_of_files`.
- [X] T013 [US2] In `tests/smoke/test_us6.sh`, append the US2 assertion block: (a) `place_fixture commands triage`; (b) bring stack up (or reuse the running stack from US1); (c) assert `/home/claude/.claude/commands/triage.md` exists; (d) assert ownership is `claude:claude`; (e) place `~/.claude/commands/local-only.md` directly via `docker exec`; restart; assert `local-only.md` survives (FR-005 for commands).

**Checkpoint**: Skills + commands both work.

---

## Phase 5: User Story 3 — Drop a Sub-Agent Definition (Priority: P1)

**Goal**: A maintainer drops `config/agents/<name>/agent.md`, and the sub-agent appears at `~/.claude/agents/<name>/agent.md`.

**Independent Test**: place `tests/smoke/fixtures/005/agents/db-reviewer/agent.md`, build & start, then assert `/home/claude/.claude/agents/db-reviewer/agent.md` exists.

### Implementation for User Story 3

- [X] T014 [US3] In `scripts/entrypoint.sh`, **add a call site** for agents: `reflect_dir_of_dirs /usr/local/share/kroclaude/config/agents /home/claude/.claude/agents`. One line.
- [X] T015 [US3] In `tests/smoke/test_us6.sh`, append the US3 assertion block: (a) `place_fixture agents db-reviewer`; (b) restart container; (c) assert `/home/claude/.claude/agents/db-reviewer/agent.md` exists; (d) assert ownership; (e) place `~/.claude/agents/private/agent.md` via `docker exec`; restart; assert `private` survives (FR-005 for agents).

**Checkpoint**: All three P1 stories functional. MVP-shippable.

---

## Phase 6: User Story 4 — Drop an Output Style (Priority: P2)

**Goal**: A maintainer drops `config/output-styles/<name>.md`, and the style appears at `~/.claude/output-styles/<name>.md`.

### Implementation for User Story 4

- [X] T016 [US4] In `scripts/entrypoint.sh`, **add a call site**: `reflect_dir_of_files /usr/local/share/kroclaude/config/output-styles /home/claude/.claude/output-styles md`. One line.
- [X] T017 [US4] In `tests/smoke/test_us6.sh`, append the US4 assertion block: (a) `place_fixture output-styles brief`; (b) restart; (c) assert `/home/claude/.claude/output-styles/brief.md` exists; (d) ownership check; (e) user-installed `~/.claude/output-styles/my-mood.md` survives.

---

## Phase 7: User Story 5 — Drop a Hook Fragment (Priority: P2)

**Goal**: A maintainer drops `config/hooks.d/<name>.json`, and the hook is merged into `~/.claude/settings.json`'s `.hooks` key without clobbering unrelated keys (Stop/PostToolUseFailure notify hooks must survive).

### Implementation for User Story 5

- [X] T018 [US5] In `scripts/entrypoint.sh`, **add a call site**: `merge_fragments /usr/local/share/kroclaude/config/hooks.d /home/claude/.claude/settings.json HOOKS_MERGE_FILTER '{}'`. One line. Per [contracts/reflection-helpers.md](contracts/reflection-helpers.md) §`merge_fragments`.
- [X] T019 [US5] In `tests/smoke/test_us6.sh`, append the US5 assertion block: (a) snapshot `/home/claude/.claude/settings.json` BEFORE placing the fixture (it has Stop+PostToolUseFailure notify hooks from feature 001); (b) `place_fixture hooks.d lint` (a single `PostToolUse` entry); (c) restart; (d) assert merged settings.json contains BOTH the original Stop/PostToolUseFailure entries AND the new PostToolUse entry — none clobbered; (e) test fragment-precedence: place `00-base.json` and `99-override.json` both setting the same `PostToolUse` matcher; assert `99-override` wins (lex-order-last-wins, clarification Q1); (f) test re-run idempotency: restart twice, assert byte-identical settings.json; (g) **failure-isolation test (FR-009 / SC-004)**: place a `00-malformed.json` (literal text `not json at all`) alongside the valid `lint.json`; restart; assert (i) entrypoint logs contain `WARN: skipping malformed fragment` naming the offending file, (ii) the valid `lint.json` entry still appears in merged settings.json, (iii) container reaches healthy.

---

## Phase 8: User Story 6 — Drop an MCP Server Fragment (Priority: P2)

**Goal**: A maintainer drops `config/mcp-servers.d/<name>.json`, and the entry is merged into `~/.claude/.mcp.json`'s `.mcpServers` key.

### Implementation for User Story 6

- [X] T020 [US6] In `scripts/entrypoint.sh`, **add a call site**: `merge_fragments /usr/local/share/kroclaude/config/mcp-servers.d /home/claude/.claude/.mcp.json MCP_MERGE_FILTER '{"mcpServers":{}}'`. One line.
- [X] T021 [US6] In `tests/smoke/test_us6.sh`, append the US6 assertion block: (a) `place_fixture mcp-servers.d postgres`; (b) restart; (c) assert `/home/claude/.claude/.mcp.json` contains `"postgres"` under `mcpServers`; (d) place `~/.claude/.mcp.json` with a hand-added `"local-only"` server BEFORE restart; restart; assert `local-only` survives alongside `postgres` (bundled-wins-over-user only on collision; non-colliding user keys always survive); (e) **failure-isolation test (FR-009 / SC-004)**: place a `00-malformed.json` (literal text `{not valid json`) alongside the valid `postgres.json`; restart; assert (i) entrypoint logs contain `WARN: skipping malformed fragment` naming the offending file, (ii) the valid `postgres` entry still appears in `.mcp.json`, (iii) container reaches healthy.

---

## Phase 9: User Story 7 — Drop a Claude Code Plugin (Priority: P2)

**Goal**: A maintainer drops a self-contained plugin tree at `config/plugins/<name>/`, and the entire tree is reflected into `~/.claude/plugins/<name>/`.

### Implementation for User Story 7

- [X] T022 [US7] In `scripts/entrypoint.sh`, **add a call site**: `reflect_dir_of_dirs /usr/local/share/kroclaude/config/plugins /home/claude/.claude/plugins`. One line. Same helper as skills/agents — the deeper subtree is just a `cp -r` away.
- [X] T023 [US7] In `tests/smoke/test_us6.sh`, append the US7 assertion block: (a) `place_fixture plugins sample-plugin` (which has the nested `.claude-plugin/plugin.json` plus a nested `skills/hello/SKILL.md`); (b) restart; (c) assert `/home/claude/.claude/plugins/sample-plugin/.claude-plugin/plugin.json` exists; (d) assert the nested `/home/claude/.claude/plugins/sample-plugin/skills/hello/SKILL.md` exists too (whole-tree reflection); (e) ownership check on a deeply nested file; (f) user-installed `~/.claude/plugins/private/.claude-plugin/plugin.json` survives.

**Checkpoint**: All four P2 stories functional. All seven types working end-to-end.

---

## Phase 10: User Story 8 — Existing settings.json + CLAUDE.md Behavior Unchanged (Priority: P3)

**Goal**: Regression check that feature 001's sentinel-gated first-boot-only seed of `config/settings.json` and `config/CLAUDE.md` still works exactly as before.

### Implementation for User Story 8

- [X] T024 [US8] In `tests/smoke/test_us6.sh`, append the US8 assertion block: (a) edit `/home/claude/.claude/CLAUDE.md` inside the running container via `docker exec` (e.g. append a marker line); (b) restart container WITHOUT wiping the volume (`docker compose restart`); (c) assert `/home/claude/.claude/CLAUDE.md` STILL contains the marker (sentinel-gated, NOT overwritten — proves the first-boot seed is sentinel-protected as feature 001 specifies); (d) wipe the volume (`docker compose down -v`); (e) bring stack up fresh; (f) assert `/home/claude/.claude/CLAUDE.md` matches the source `config/CLAUDE.md` byte-for-byte (proves the seed runs on first boot of a fresh volume).

**Checkpoint**: All eight user stories functional. Feature spec satisfied end-to-end.

---

## Phase 11: Polish & Cross-Cutting Concerns

**Purpose**: Wire CI, build the image, run the full smoke test, ratify the constitution check.

- [X] T025 In `.github/workflows/ci.yml`, register `tests/smoke/test_us6.sh` next to the existing `test_us{1..5}.sh` invocations under the "Smoke — US5 (Docker container spawning)" step.
- [X] T026 [P] Run `docker compose build --no-cache` locally and confirm the image builds cleanly. The new `COPY config/` line should be visible in the build log.
- [X] T027 [P] Run `docker compose config` to verify compose still validates (no compose changes in this feature, but cheap belt-and-suspenders).
- [X] T028 Run `bash tests/smoke/test_us6.sh` end-to-end locally and confirm ALL eight US assertion blocks PASS.
- [X] T029 Re-run constitution check after implementation: walk each principle in [`.specify/memory/constitution.md`](../../.specify/memory/constitution.md) v1.0.0 and verify the implemented changes still PASS each gate (matches the table in [plan.md](plan.md) §Constitution Check).
- [X] T030 [P] Update `config/CLAUDE.md`: change any reference to `/skills/` (the legacy path) to `/config/skills/` so the in-container Claude's documentation matches the new layout.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1, T001)**: no dependencies — can start immediately.
- **Foundational (Phase 2, T002–T009)**: depends on Setup. BLOCKS all user stories.
  - T002, T003 are sequential within the Dockerfile/legacy-skills-tree migration.
  - T004, T005 both edit `scripts/entrypoint.sh` — sequential.
  - T006, T007 also edit `scripts/entrypoint.sh` — sequential after T004/T005.
  - T008 (smoke scaffold) and T009 (fixture trees) are independent files — `[P]` marked.
- **User Stories (Phase 3–10)**: all depend on Foundational completion.
  - Each story is two tasks: one helper-call-site edit in `scripts/entrypoint.sh` + one smoke-test assertion-block append in `tests/smoke/test_us6.sh`. Within a story, sequential.
  - Across stories: helper-call-site edits all touch the same file (`scripts/entrypoint.sh`) — sequential. Smoke-test edits all touch the same file (`tests/smoke/test_us6.sh`) — sequential. So in practice the user-story phases run sequentially in numbered order.
- **Polish (Phase 11)**: depends on all desired user stories.

### User Story Dependencies

- **US1 (skills)**: only "implementation" task is T010 = verify Phase 2's T007 placed the skills helper call. No new code beyond Phase 2.
- **US2 (commands)**: independent of US1.
- **US3 (agents)**: independent of US1, US2.
- **US4 (output-styles)**: independent.
- **US5 (hooks)**: depends on `merge_fragments` helper (T004) and `HOOKS_MERGE_FILTER` (T005). Both are Foundational.
- **US6 (MCP)**: depends on `merge_fragments` and `MCP_MERGE_FILTER`. Same as US5.
- **US7 (plugins)**: independent.
- **US8 (regression)**: only smoke-test work (T024); no new code. Can run any time after Phase 2.

### Parallel Opportunities

- T008 ‖ T009 (Foundational, distinct files: smoke scaffold vs fixture tree).
- T026 ‖ T027 ‖ T030 (Polish, distinct files/commands).

After Phase 2 completes, with multiple developers each US (helper-call edit + smoke append) could be staffed in parallel — BUT both edits target the same two files (`entrypoint.sh` and `test_us6.sh`), so the parallelism is bottlenecked by file-merge coordination. In practice a single developer goes US1 → US8 in numbered order over a single session.

---

## Parallel Example: Foundational Phase

```bash
# After T001 (Setup), the Phase-2 tasks must be sequential per file
# but file-distinct ones can parallelize:

# Sequential within Dockerfile / legacy tree:
T002 (Dockerfile COPY refactor) → T003 (delete legacy /skills/)

# Sequential within scripts/entrypoint.sh:
T004 (define helpers) → T005 (define jq filters) → T006 (path refactor) → T007 (replace skills block)

# Independent, runnable in parallel:
T008 (smoke scaffold)  ‖  T009 (fixture trees)
```

---

## Implementation Strategy

### MVP First (P1 stories only — US1, US2, US3)

1. T001 (Setup).
2. T002–T009 (Foundational) — Dockerfile, helpers, jq filters, smoke scaffold, fixtures.
3. T010, T011 (US1 — skills).
4. T012, T013 (US2 — commands).
5. T014, T015 (US3 — agents).
6. **STOP and VALIDATE**: run `tests/smoke/test_us6.sh` and confirm US1–US3 assertion blocks pass.
7. Demo: maintainers can ship the three most-used types via `/config/`.

### Incremental Delivery

1. MVP (US1–US3) → Test → Demo.
2. Add US4 (output-styles) → Test.
3. Add US5 (hooks) → Test. (First merge_fragments user — proves the jq machinery.)
4. Add US6 (MCP) → Test. (Second merge_fragments user — proves the helper generalizes.)
5. Add US7 (plugins) → Test.
6. Add US8 (regression) → Test.
7. Polish: CI wiring + image build + constitution recheck → Merge.

### Three-Commit Migration Boundary (per plan.md)

The 30 tasks group into the three independent bisectable commits already documented in [plan.md](plan.md) §Three-Commit Migration Shape:

- **Commit 1 — `refactor: relocate bundled skills under config/`**: T001, T002, T003, T006. Behavior unchanged. All existing smoke tests still pass.
- **Commit 2 — `feat: add reflection helpers + six new types`**: T004, T005, T007, T010, T012, T014, T016, T018, T020, T022. Adds the three helpers and the seven call sites.
- **Commit 3 — `test: smoke-test all seven bundled types`**: T008, T009, T011, T013, T015, T017, T019, T021, T023, T024, T025–T030. The smoke test, fixtures, CI wiring, and validation.

The single-developer flow ignores the commit boundaries and goes T001 → T030 in numbered order, then breaks the result into three commits at the end if reviewers prefer the bisectable history.

---

## Notes

- [P] tasks = different files, no dependencies. Within a single file
  (Dockerfile, entrypoint.sh, test_us6.sh), tasks editing the same
  file are sequential even if they touch distinct sections.
- [Story] label maps task to a spec.md user story for traceability.
- Each user story is independently completable and testable; the
  smoke test is one file but its assertion blocks are gated by
  comment headers so partial completions still run cleanly.
- Verify each smoke phase passes before moving to the next story.
- The Constitution Check in [plan.md](plan.md) is currently PASSING;
  T029 re-verifies after implementation.
- Avoid: defining new helpers per type (the whole point is the
  three-helper API stays fixed; new types reuse existing helpers).
