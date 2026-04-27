# Implementation Plan: Bundled Skills, User Skills Preserved

**Branch**: `002-skill-bundling` | **Date**: 2026-04-28 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from [spec.md](spec.md)

## Summary

Ship Claude Code skills inside the KroClaude image at a known build-time
path, and have the entrypoint reflect them into the persistent
`~/.claude/skills/` directory on every container start. The reflection
is per-skill: each bundled skill's directory is recreated atomically;
any other directory in `~/.claude/skills/` (i.e., user-installed
skills) is left strictly untouched. The change is one new repo
directory (`skills/`), one new `COPY` layer in the Dockerfile, and one
new ~12-line stanza in `scripts/entrypoint.sh`.

No new processes, no new s6 services, no new env vars, no new packages.

## Technical Context

**Language/Version**: Bash 5.x (a stanza added to the existing
[`scripts/entrypoint.sh`](../../scripts/entrypoint.sh) from feature 001).
**Primary Dependencies**: none new — uses `cp` (coreutils, in the base
image already), `find` / `basename` (already available).
**Storage**: re-uses the existing `kroclaude-config` named volume from
feature 001. No new volume.
**Testing**: smoke-test extension — adds two new scenarios to
[`tests/smoke/test_us2.sh`](../../tests/smoke/test_us2.sh) verifying
(a) bundled skills appear in the volume on first boot, and
(b) user-installed skills survive a restart with a mutated bundled
skill set.
**Target Platform**: same as feature 001 — Linux Docker host, multi-arch
linux/amd64 + linux/arm64. Skills are text-only and architecture-neutral.
**Project Type**: extension to the existing deployment artifact. Not a
new codebase; no new top-level layout.
**Performance Goals**: per FR-005 the refresh step adds ≤2 s to the
existing first-boot bootstrap budget (15 s overall per feature 001
SC-003). For ≤20 bundled skills totalling ≤10 MB uncompressed,
`cp -r` per skill dir should complete well under that.
**Constraints**: no new long-running processes (FR-009); no new s6
service; the stanza must be idempotent (FR-002); user-installed skills
MUST never be touched (FR-003).
**Scale/Scope**: single-tenant per container; ≤20 bundled skills in v1
(spec FR-005 budget). User-installed skills not bounded but realistically
≤50.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Walking each principle from
[`.specify/memory/constitution.md`](../../.specify/memory/constitution.md)
v1.0.0:

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Reproducible Builds (NON-NEGOTIABLE) | ✅ | Bundled skills are content-addressed via the source repo; `COPY skills/` into the image is deterministic. No network fetch at runtime. |
| II. Container-First Delivery | ✅ | No new env vars, no new ports, no new mounts. Same compose surface as feature 001. |
| III. Curated Tooling, Lean Image | ✅ | No new packages. Bundled skill content is text-only and capped at 10 MB uncompressed in v1; image-size budget unaffected in any meaningful way. |
| IV. Coolify-Native Deployment | ✅ | No new caps, no new security_opt, no new ports, no host-side prep. Coolify deploys are unchanged. |
| V. Stateless Container, Explicit Persistence | ✅ | Bundled skills land in the existing `kroclaude-config` named volume, mounted at `/home/claude/.claude`. The `~/.claude/skills/` subdirectory is the natural extension of that volume's "Claude Code config" category. |
| Security & Secrets | ✅ | Skills are non-credential text shipped in the image. No secret handling added. The reflection step runs as root (entrypoint context) and chowns to `claude:claude`. |
| Build, Release & Workflow | ✅ | The bundled skill set becomes part of the image semver: a content change to any bundled skill is at least a PATCH bump; adding/removing a bundled skill is a MINOR bump; renaming or breaking-changing a bundled skill is a MAJOR bump and a `BREAKING:` CHANGELOG entry. Codified in [research R6](research.md). |
| FR-014 (challenge sh scripts) | ⚠ Justified | This feature ADDS a ~12-line stanza to `scripts/entrypoint.sh`. Justification in Complexity Tracking. |

**Result**: PASS with one justified deviation (the entrypoint stanza
addition is the simplest correct mechanism — see Complexity Tracking).

### Post-Phase-1 Re-Check

Re-walked all principles after writing [research.md](research.md),
[data-model.md](data-model.md),
[contracts/skills.md](contracts/skills.md), and
[quickstart.md](quickstart.md). No new violations. The reflection
stanza, the `skills/` source dir, and the Dockerfile `COPY` layer are
the only three new surfaces — each maps to exactly one FR.

## Project Structure

### Documentation (this feature)

```text
specs/002-skill-bundling/
├── plan.md              # This file
├── research.md          # Phase 0 — decisions and rationales
├── data-model.md        # Phase 1 — entities (Bundled Skill Set, Skill Directory, ...)
├── quickstart.md        # Phase 1 — how to add a bundled skill, how to test
├── contracts/
│   └── skills.md        # Phase 1 — skill format + reflection contract
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks command — NOT created here)
```

### Source Code (repository root)

Adds exactly one new source directory and modifies three existing files:

```text
KroClaude/
├── skills/                            # NEW — bundled skill set, one subdir per skill
│   └── <skill-name>/
│       ├── SKILL.md                   # required: the skill manifest
│       └── ...                        # optional: scripts, templates, refs
├── Dockerfile                         # MODIFIED — one new COPY layer for skills
├── scripts/entrypoint.sh              # MODIFIED — one new reflection stanza
├── tests/smoke/test_us2.sh            # MODIFIED — adds skill-bundling assertions
└── specs/002-skill-bundling/          # this feature's spec dir
```

**Structure Decision**: extension to feature 001's layout. The new
`skills/` directory at repo root mirrors the existing `config/` and
`scripts/` siblings — one source-of-truth directory per layer of the
runtime image. No new top-level dirs are required.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| New ~12-line shell-script stanza in `scripts/entrypoint.sh` (touches FR-014) | The reflection MUST happen at runtime, AFTER the named volume is mounted. A Dockerfile-time `COPY skills/ /home/claude/.claude/skills/` is shadowed by the volume mount and never visible in the running container. There is no "compose-level config" primitive for "merge files into a named volume on start". | (a) An init container would be heavier and brittle; entrypoint is already the right place. (b) A standalone `bootstrap-skills.sh` script would re-introduce the multi-script complexity feature 001 deliberately removed by merging `bootstrap.sh` into entrypoint. (c) An s6 oneshot service would require a new service definition and a manifest entry — strictly more code than 12 lines of bash. |
