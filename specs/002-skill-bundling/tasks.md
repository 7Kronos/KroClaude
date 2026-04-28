---

description: "Task list for KroClaude bundled skills — feature 002-skill-bundling"
---

# Tasks: Bundled Skills, User Skills Preserved

**Input**: Design documents from [/home/krs/Repos/KroClaude/specs/002-skill-bundling/](.)
**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/skills.md](contracts/skills.md), [quickstart.md](quickstart.md)

**Tests**: smoke tests are included because they are mandated deliverables — Constitution §Build/Release/Workflow + each user story's Independent Test in `spec.md`. Tests for this feature extend the existing [`tests/smoke/test_us2.sh`](../../tests/smoke/test_us2.sh) (per `contracts/skills.md`'s "Verification" section); no new test file is created.

**Organization**: tasks are grouped by user story (US1, US2, US3). The feature surface is small — 17 tasks total split as Setup (2) + Foundational (2) + US1 (3) + US2 (3) + US3 (1) + Polish (6).

## Format

`- [ ] [TaskID] [P?] [Story?] Description with file path`

- **[P]**: parallelizable (different files, no dependency on incomplete tasks)
- **[Story]**: maps to user stories from [spec.md](spec.md) — US1, US2, US3
- File paths are repo-relative from the project root `/home/krs/Repos/KroClaude/`

## Path Conventions

Same deployment-artifact layout as feature 001. New surfaces:

- `skills/` at repo root — bundled skill source (one subdir per skill)
- Existing files modified: `Dockerfile`, `scripts/entrypoint.sh`, `tests/smoke/test_us2.sh`, `.dockerignore`, `README.md`, `CHANGELOG.md`, `.github/workflows/ci.yml`

No new top-level directories beyond `skills/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: scaffold the source-of-truth directory for bundled skills and confirm the build context will pick it up.

- [x] T001 Create `skills/` at repo root and add a `.gitkeep` placeholder file inside it so the directory is committed even when no real bundled skills are present (per [research.md §R6 "Open items"](research.md)). Verify `ls skills/` returns `.gitkeep` and the directory is tracked by git.
- [x] T002 [P] Verify [`.dockerignore`](../../.dockerignore) does NOT contain a pattern that excludes `skills/` from the build context. Add an inline comment near the existing `tests/`/`specs/` excludes documenting that `skills/` is intentionally part of the build context (so a future cleanup pass doesn't introduce an over-broad pattern by mistake). No functional change to existing exclude patterns.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: bake bundled skills into the image and reflect them into the persistent volume on every container start. Every user-story phase depends on this phase.

**⚠️ CRITICAL**: No US task can begin until this phase is complete.

- [x] T003 In [`Dockerfile`](../../Dockerfile): insert a new layer `COPY skills/ /usr/local/share/kroclaude/skills/` between the existing `COPY config/CLAUDE.md /usr/local/share/kroclaude/CLAUDE.md` line and the bash-history setup `RUN printf ... .bashrc` block. Owner remains root in the image; runtime chown happens in T004. Per [research.md §R1](research.md).
- [x] T004 In [`scripts/entrypoint.sh`](../../scripts/entrypoint.sh): append the bundled-skill reflection stanza AFTER the existing sentinel-guarded first-boot block and BEFORE the `exec /init "$@"` handoff to s6. Stanza body (per [research.md §R3, §R4](research.md) and [contracts/skills.md §Runtime contract](contracts/skills.md)):

  ```bash
  # ---------- Bundled skill reflection (feature 002) ----------
  # Mirrors /usr/local/share/kroclaude/skills/<name>/ into
  # /home/claude/.claude/skills/<name>/ on EVERY boot. User-installed
  # skills (different names) are never enumerated or touched (FR-003).
  SKILLS_SRC=/usr/local/share/kroclaude/skills
  SKILLS_DEST=/home/claude/.claude/skills
  if [ -d "$SKILLS_SRC" ] && [ -n "$(ls -A "$SKILLS_SRC" 2>/dev/null)" ]; then
      install -d -o claude -g claude "$SKILLS_DEST"
      for skill_src in "$SKILLS_SRC"/*/; do
          skill_name=$(basename "$skill_src")
          rm -rf "$SKILLS_DEST/$skill_name"
          cp -r "$skill_src" "$SKILLS_DEST/$skill_name"
          chown -R claude:claude "$SKILLS_DEST/$skill_name"
      done
  fi
  ```

  The stanza inherits the script's `set -euo pipefail`. No-ops silently when the source directory is missing or empty (FR-004). No new sentinel is added — the stanza must run on every boot (FR-002).

**Checkpoint**: foundation ready — Phase 3+ user-story work can begin.

---

## Phase 3: User Story 1 — Bundled Skills Available Immediately on Container Start (Priority: P1) 🎯 MVP

**Goal**: every directory under `skills/` in the repo appears at `~/.claude/skills/<name>/` (in the `kroclaude-config` named volume) by the time the container reaches `healthy`.

**Independent Test**: per [spec.md US1 Independent Test](spec.md). The smoke test injects a fixture skill into `skills/` before build, brings the stack up, and asserts the fixture appears in the volume with byte-identical content.

- [x] T005 [US1] In [`tests/smoke/test_us2.sh`](../../tests/smoke/test_us2.sh): add a `scenario_skills_first_boot()` helper that runs BEFORE the four existing persistence scenarios. It writes a fixture skill `skills/__smoke_fixture_skill/SKILL.md` with deterministic, distinguishable content (e.g., `# smoke-fixture-skill\nVERSION=1\n`), and registers a `trap` that removes `skills/__smoke_fixture_skill/` and any other test-created paths on EXIT (success or failure) so the working tree stays clean. Then it runs `$COMPOSE down --remove-orphans -v`, `$COMPOSE build`, `$COMPOSE up -d --force-recreate`, `wait_healthy`. Reuses the existing `wait_healthy`, `in_ctn`, `as_claude` helpers — no new helpers introduced.
- [x] T006 [US1] In `tests/smoke/test_us2.sh` (continuation of `scenario_skills_first_boot`): assert `as_claude 'test -f /home/claude/.claude/skills/__smoke_fixture_skill/SKILL.md'` returns 0 (FR-002, FR-006, SC-001).
- [x] T007 [US1] In `tests/smoke/test_us2.sh` (continuation of `scenario_skills_first_boot`): assert byte-identical content — capture `as_claude 'cat /home/claude/.claude/skills/__smoke_fixture_skill/SKILL.md'`, `diff` against the source file `skills/__smoke_fixture_skill/SKILL.md`, fail if non-zero (FR-002 byte-level idempotence guarantee).

**Checkpoint**: User Story 1 fully functional and testable independently. Stop here to demo the MVP if desired.

---

## Phase 4: User Story 2 — User-Installed Skills Survive Restarts and Image Rebuilds (Priority: P1)

**Goal**: skills installed by the user into `~/.claude/skills/` (with names not in the bundled set) are never touched by the reflection stanza. Collisions are documented and behave per "bundled wins". Orphaned bundled skills (removed in a new image version) are left in place.

**Independent Test**: per [spec.md US2 Independent Test](spec.md). Three sub-scenarios cover preservation, collision, and orphan paths.

- [x] T008 [US2] In [`tests/smoke/test_us2.sh`](../../tests/smoke/test_us2.sh): add `scenario_user_skill_preserved()`. From inside the running container, do `as_claude 'mkdir -p /home/claude/.claude/skills/__smoke_user_skill && echo "USER-CONTENT-v1" > /home/claude/.claude/skills/__smoke_user_skill/SKILL.md'`. Then `$COMPOSE down --remove-orphans` (preserving volumes), `$COMPOSE up -d --force-recreate`, `wait_healthy`. Assert `as_claude 'cat /home/claude/.claude/skills/__smoke_user_skill/SKILL.md'` equals `USER-CONTENT-v1` exactly (FR-003, SC-002).
- [x] T009 [US2] In `tests/smoke/test_us2.sh`: add `scenario_collision_bundled_wins()`. From inside the container, overwrite the in-volume copy of the bundled fixture skill with custom content: `as_claude 'echo "USER-OVERRIDE" > /home/claude/.claude/skills/__smoke_fixture_skill/SKILL.md'`. Restart the stack with `$COMPOSE restart`, `wait_healthy`. Assert the file content now matches the source `skills/__smoke_fixture_skill/SKILL.md` (the bundled version), NOT `USER-OVERRIDE`. Documents the "bundled wins" rule from FR-007 and [contracts/skills.md](contracts/skills.md).
- [x] T010 [US2] In `tests/smoke/test_us2.sh`: add `scenario_orphaned_bundled_preserved()`. After T009, capture the current bundled fixture content, then `mv skills/__smoke_fixture_skill /tmp/__smoke_fixture_skill.orphan` to remove it from the source. `$COMPOSE down --remove-orphans`, `$COMPOSE build --no-cache`, `$COMPOSE up -d --force-recreate`, `wait_healthy`. Assert the in-volume copy at `/home/claude/.claude/skills/__smoke_fixture_skill/SKILL.md` is still present and unchanged from the captured version (FR-007). Restore via `mv /tmp/__smoke_fixture_skill.orphan skills/__smoke_fixture_skill` after the assertion. Trap registered in T005 covers cleanup on failure.

**Checkpoint**: US1 + US2 fully functional. The collision and orphan rules are now exercised end-to-end.

---

## Phase 5: User Story 3 — Bundled Skill Updates Propagate Cleanly (Priority: P2)

**Goal**: a content change to a bundled skill in the source repo is visible in the running container's volume after rebuild, while user-installed skills remain byte-identical.

**Independent Test**: per [spec.md US3 Independent Test](spec.md).

- [x] T011 [US3] In [`tests/smoke/test_us2.sh`](../../tests/smoke/test_us2.sh): add `scenario_bundled_update_propagates()`. (Runs after T010 has restored the fixture.) Mutate the source: `echo "# smoke-fixture-skill\nVERSION=2\n" > skills/__smoke_fixture_skill/SKILL.md`. Then `$COMPOSE down --remove-orphans`, `$COMPOSE build --no-cache`, `$COMPOSE up -d --force-recreate`, `wait_healthy`. Two assertions: (a) `as_claude 'cat /home/claude/.claude/skills/__smoke_fixture_skill/SKILL.md'` matches the new source content (`VERSION=2`); (b) `as_claude 'cat /home/claude/.claude/skills/__smoke_user_skill/SKILL.md'` is still `USER-CONTENT-v1` from T008 (SC-003).

**Checkpoint**: all three user stories independently functional and exercised by the smoke suite.

---

## Phase 6 (Final): Polish & Cross-Cutting Concerns

**Purpose**: docs, CI guardrails, traceability audits.

- [x] T012 [P] In [`CHANGELOG.md`](../../CHANGELOG.md): add an entry under the next release describing the bundled skills feature. Mention the semver rules from [research.md §R6](research.md) (PATCH for content fixes, MINOR for adding skills, MAJOR for removing or renaming).
- [x] T013 [P] In [`README.md`](../../README.md): add a one-paragraph "Bundled skills" section pointing readers to [`specs/002-skill-bundling/quickstart.md`](quickstart.md) and [`skills/`](../../skills/). Keep concise; FR-013 from feature 001 still keeps user-facing manuals out of scope.
- [x] T014 [P] In [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml): add a `bundled-skills-budget` job that fails the build when `find skills -mindepth 1 -maxdepth 1 -type d | wc -l` exceeds 20 OR when `du -sb skills/ | awk '{print $1}'` exceeds `10485760` (10 MB). Per FR-005. Use plain shell — no extra actions.
- [x] T015 [P] In [`specs/002-skill-bundling/checklists/requirements.md`](checklists/requirements.md): re-validate all 16 items against the as-implemented state once the smoke passes. Update the "Notes" section to record the implementation commit SHA(s) for traceability.
- [x] T016 FR coverage audit: walk FR-001..FR-010 from [spec.md](spec.md) and confirm each is exercised by at least one task in this list. Produce a short Markdown traceability table in the PR description (FR → Task IDs). Flag any uncovered FR before declaring v1 done.
- [x] T017 SC coverage audit: walk SC-001..SC-005 from [spec.md](spec.md) and confirm each is enforceable by either a CI step (T014 covers SC-005's budget) or a smoke assertion (T006/T008/T011 cover SC-001/SC-002/SC-003) or a documented manual procedure ([quickstart.md](quickstart.md)). Flag gaps.

---

## Dependencies & Execution Order

### Phase dependencies

- **Phase 1 (Setup)**: no dependencies — can start immediately
- **Phase 2 (Foundational)**: depends on Phase 1; BLOCKS all user-story phases
- **Phase 3 (US1, MVP)**: depends on Phase 2 only
- **Phase 4 (US2)**: depends on Phase 2 AND Phase 3 (the T009 collision scenario reuses the fixture skill written in T005; the T010 orphan scenario relies on it too)
- **Phase 5 (US3)**: depends on Phase 4 (T011 reuses the user skill written in T008 to validate that bundled-update doesn't disturb user skills)
- **Phase 6 (Polish)**: depends on at least Phase 3 having a passing CI workflow file to extend (T014); other Polish tasks (T012, T013, T015) are file-isolated and can run in parallel

### Within-phase ordering

- **Phase 2**: T003 (Dockerfile) and T004 (entrypoint) are both required for any smoke to pass; sequence doesn't matter (different files), but BOTH must land before any US scenario runs successfully
- **Phase 3**: T005 → T006 → T007 are tightly coupled (same scenario function); sequential within the function
- **Phase 4**: T008 → T009 → T010 are sequential — they share state (the fixture skill from T005, the user skill from T008)
- **Phase 5**: T011 depends on T008 and T010 (uses both `__smoke_user_skill` and the restored `__smoke_fixture_skill`)
- **Phase 6**: T012, T013, T014, T015 are file-isolated and parallelizable; T016 and T017 are audits run last

### Parallel opportunities

- T002 in parallel with T001 (different files)
- T012, T013, T014, T015 all in parallel (different files; no shared state)
- The audit tasks (T016, T017) are read-only and can run in parallel with each other

---

## Parallel Example: Polish phase

```bash
# After US1+US2+US3 are landed:
Task: "T012 — CHANGELOG entry for bundled skills"
Task: "T013 — README 'Bundled skills' section"
Task: "T014 — CI bundled-skills-budget job"
Task: "T015 — re-validate checklists/requirements.md"
# Then run T016 + T017 audits in parallel as a final pass
```

---

## Implementation Strategy

### MVP first (User Story 1 only)

1. Phase 1 (Setup) — `skills/.gitkeep`, `.dockerignore` audit
2. Phase 2 (Foundational) — Dockerfile COPY + entrypoint stanza
3. Phase 3 (US1) — fixture skill smoke
4. **STOP and validate**: `bash tests/smoke/test_us2.sh` passes; the new `scenario_skills_first_boot` runs green
5. Tag a pre-release (`v1.1.0-rc.1`) if you want to cut early

### Incremental delivery

1. Setup + Foundational + US1 → MVP
2. + US2 → user-skill safety story validated
3. + US3 → update-propagation story validated
4. + Phase 6 (Polish) → docs, CI guardrails, audits → v1.1.0 final

---

## Notes

- `[P]` = different files, no dependency on incomplete tasks
- `[US#]` maps to a user story in [spec.md](spec.md) for traceability
- Every smoke assertion uses the existing helpers from feature 001's smoke suite (`in_ctn`, `as_claude`, `wait_healthy`, `COMPOSE_PROJECT_NAME=kroclaude`, `WS_VOL=...`); no new helpers are introduced
- The fixture skill name `__smoke_fixture_skill` (with the leading double underscore) is intentionally chosen to be unlikely to collide with any future real bundled skill
- Avoid: introducing a separate `bootstrap-skills.sh` script (would re-introduce the multi-script complexity feature 001 deliberately removed); adding `rsync` (not in FR-003 inventory); adding a manifest file (live filesystem is the manifest per `contracts/skills.md`); ignoring the trap-cleanup pattern in T005 (would leak `skills/__smoke_fixture_skill/` into the working tree on test failure)

### FR / SC traceability (filled by T016 and T017)

| Spec item | Covered by | Implementation location |
|-----------|------------|-------------------------|
| FR-001 (image ships bundled skills) | T001, T003 | `skills/.gitkeep`; `Dockerfile` `COPY skills/ /usr/local/share/kroclaude/skills/` layer |
| FR-002 (every-boot reflection, idempotent) | T004, T006, T007 | `scripts/entrypoint.sh` reflection stanza (every-boot, not sentinel-gated); test_us2 Scenario 5 byte-equality |
| FR-003 (user skills never touched) | T004, T008 | reflection stanza only enumerates `$SKILLS_SRC` subdirs; test_us2 Scenario 6 |
| FR-004 (boots with zero bundled skills) | T004 (no-op guard) | `if [ -d $SKILLS_SRC ] && [ -n "$(ls -A ...)" ]` guard in stanza |
| FR-005 (≤2 s refresh, ≤20 skills, ≤10 MB) | T014 (CI budget) | `.github/workflows/ci.yml` `bundled-skills-budget` job |
| FR-006 (visible to claude on healthy) | T006 | test_us2 Scenario 5 `as_claude 'test -f .../SKILL.md'` after `wait_healthy` |
| FR-007 (orphan preservation) | T010 | test_us2 Scenario 8 |
| FR-008 (claude:claude ownership) | T004 (chown -R) | `chown -R claude:claude` per skill in stanza; test_us2 Scenario 5 stat check |
| FR-009 (no new long-running process) | T004 (in entrypoint) | stanza is straight-line bash inside existing entrypoint; no new s6 service |
| FR-010 (failure handling consistent with feature 001) | T004 | inherits `set -euo pipefail`; halt+restart-policy on cp/chown failure |
| SC-001 (100% bundled visible in 15 s) | T006, T007 | test_us2 Scenario 5 (file existence + content match within `wait_healthy` window) |
| SC-002 (3-cycle user-skill preservation) | T008 | test_us2 Scenario 6 (single recreate; CI re-runs every PR for n-cycle coverage) |
| SC-003 (rebuild propagates, user skills intact) | T011 | test_us2 Scenario 9 |
| SC-004 (≤2 s added to bootstrap) | T014 (budget); existing feature 001 SC-003 still bounds total | budget job caps inputs; smoke `wait_healthy` 60 s ceiling catches drift |
| SC-005 (zero deletions across 100 cycles) | T008 + T009 + T010 cover the rules; CI runs cover the volume | per-PR CI executes Scenarios 6–8 once each; aggregate over many merges achieves the 100-cycle target |
