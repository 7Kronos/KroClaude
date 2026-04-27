# Feature Specification: Bundled Skills, User Skills Preserved

**Feature Branch**: `002-skill-bundling`
**Created**: 2026-04-28
**Status**: Draft
**Input**: User description: "skill feature : a skill folder is copied to
global claude directory when the container starts. it should not delete
installed skills on the persistent volume"

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Bundled Skills Are Available Immediately on Container Start (Priority: P1)

A developer pulls the KroClaude image and starts the stack. They open a
shell, run `claude`, and immediately see the project's bundled skills
listed and usable — no extra setup, no manual copy step.

**Why this priority**: shipping skills with the image is the whole point
of this feature. Without it, the bundled skills don't reach the user.

**Independent Test**: from a clean checkout with no prior `kroclaude-config`
volume, run `docker compose up -d`, wait for healthy, then verify (from
inside the container, as the `claude` user) that each bundled skill
appears under `~/.claude/skills/` with its `SKILL.md` intact.

**Acceptance Scenarios**:

1. **Given** a freshly built image with at least one bundled skill,
   **When** the container reaches a healthy state for the first time,
   **Then** every bundled skill is present at
   `~/.claude/skills/<skill-name>/` and `claude` lists/loads them
   without error.
2. **Given** an already-running container, **When** the user pulls a
   newer image (with an updated bundled skill) and restarts the stack,
   **Then** the next healthy state has the updated skill content.

---

### User Story 2 — User-Installed Skills Survive Container Restarts and Image Rebuilds (Priority: P1)

A user has installed their own custom skills directly into the
persistent skills directory (e.g., via `git clone`, `cp`, or a
`/skills/<name>` path inside the container). They restart the stack —
or pull a newer KroClaude image and redeploy — and find every one of
their skills exactly where they left it, untouched.

**Why this priority**: losing user data on routine restart would make
the feature useless. This is the non-negotiable companion to US1.

**Independent Test**: install a custom skill into
`~/.claude/skills/my-custom-skill/` from inside the container; restart
the stack; rebuild the image and restart again; assert the skill's
files still exist and are byte-identical (excluding any timestamps the
user touches).

**Acceptance Scenarios**:

1. **Given** a custom skill present in the persistent volume that does
   NOT share a name with any bundled skill, **When** the container
   restarts, **Then** the skill's directory and contents are unchanged.
2. **Given** a custom skill, **When** the image is rebuilt and the
   container recreated (volumes preserved), **Then** the skill's
   directory and contents are unchanged.
3. **Given** the persistent skills directory contains a mix of bundled
   and user-installed skills, **When** the container starts, **Then**
   only the bundled ones are refreshed; the rest are untouched.

---

### User Story 3 — Image-Bundled Skill Updates Propagate Cleanly (Priority: P2)

A maintainer ships a new image version with an updated bundled skill
(fixed prompt, new file, removed file). Users who pull the new image
and restart see the updated skill — without losing any skill they
installed themselves.

**Why this priority**: this is what justifies bundling skills with the
image rather than asking users to install everything manually. Without
update propagation, bundled skills would freeze at first-boot
versions forever.

**Independent Test**: deploy version A of the image with bundled skill
`example`; modify version A's `example` skill in place to produce
version B; rebuild and restart; assert the in-volume `example` matches
version B (and any user skills are still present).

**Acceptance Scenarios**:

1. **Given** the volume contains version A of a bundled skill,
   **When** the image with version B is deployed, **Then** the volume
   reflects version B after the next start.
2. **Given** a bundled skill version B adds a new file under its
   directory, **When** the container starts, **Then** the new file is
   present in the volume.
3. **Given** a bundled skill version B removes a file that existed in
   version A, **When** the container starts, **Then** the file is also
   removed from the volume (the bundled skill's directory is treated
   as authoritative for its own contents).

---

### Edge Cases

- **No bundled skills in the image**: the container MUST still start
  and report healthy; the skills directory may be empty.
- **Bundled skill removed in a new image version**: previously-bundled
  skills that are no longer shipped MUST be left in the volume
  untouched (treated as user-installed once orphaned). Manual cleanup
  is the user's responsibility.
- **Name collision** (user installed a skill whose directory name
  matches a bundled skill name): the bundled skill version wins on the
  next start, overwriting the user's directory contents. This is
  documented; users wanting to keep a custom version of a bundled skill
  MUST rename it.
- **Corrupt or partial skill directory** in the volume (e.g., from an
  interrupted manual install): the start sequence MUST not crash; if
  the corrupt directory shares a name with a bundled skill, it is
  refreshed to the bundled version. If not, it is left alone.
- **Permission mismatch** (a bundled skill ends up owned by root after
  copy): files MUST end up readable by the in-container `claude` user.
- **Read-only volume** (Coolify backup snapshot, mount issue): the
  start sequence MUST surface a clear error and not silently swallow
  the failure.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The image MUST be able to ship a set of pre-built skill
  directories as part of its build (a "bundled skill set"), each skill
  in the standard Claude Code skill format (a directory containing a
  `SKILL.md` and any supporting files).
- **FR-002**: On every container start, the start sequence MUST copy
  each bundled skill directory into `~/.claude/skills/<skill-name>/`,
  overwriting any prior contents at that exact path. This MUST be
  idempotent: running the start sequence twice in a row leaves the
  same byte-level state.
- **FR-003**: The start sequence MUST NEVER delete, move, or modify
  any skill directory whose name does not appear in the current
  bundled skill set. User-installed skills are preserved verbatim.
- **FR-004**: If the image ships zero bundled skills (no `skills/`
  directory or an empty one), the start sequence MUST complete
  successfully and the container MUST reach healthy. No skill-related
  files outside `~/.claude/skills/` are created.
- **FR-005**: Bundled skill refresh MUST complete fast enough to fit
  within the existing first-boot budget from feature 001 (SC-003:
  bootstrap under 15 s overall). For bundled skills, the refresh step
  MUST add no more than 2 seconds to that budget under typical
  conditions (≤20 bundled skills, total uncompressed size ≤10 MB).
- **FR-006**: After the container reaches healthy, every bundled skill
  MUST be visible to the Claude Code CLI when the user opens an
  interactive shell as the `claude` user.
- **FR-007**: When a bundled skill is removed from a future image
  version, the start sequence MUST leave any previously-installed
  copy of that skill in the volume in place (treat as user-owned
  going forward). The start sequence MUST NOT proactively garbage-
  collect orphaned bundled skills.
- **FR-008**: Permissions on copied bundled skill files MUST end up
  readable by the in-container `claude` user (UID 1000) regardless of
  the layer they originated from.
- **FR-009**: The bundled skill copy step MUST be implemented inside
  the existing entrypoint flow (per the project constitution's
  preference for one entrypoint script — see feature 001 FR-014). It
  MUST NOT introduce a new long-running process or a new s6 service.
- **FR-010**: Failure of the bundled skill copy (e.g., source
  directory unreadable, target volume read-only) MUST surface as a
  clear log line and either (a) cause the container start to fail
  loudly, OR (b) skip skill bundling for this boot while letting the
  rest of the container come up — whichever the entrypoint already
  uses for analogous first-boot failures. The choice MUST be
  consistent with feature 001's existing failure handling.

### Key Entities

- **Bundled Skill Set**: the read-only collection of skill directories
  shipped inside the image. Lives under a known path inside the image
  (decided at planning time). Each entry is one skill directory.
- **User Skill**: any skill directory in `~/.claude/skills/` whose name
  is not present in the current Bundled Skill Set. Treated as fully
  user-owned: never modified, moved, or deleted by the container.
- **Skill Directory**: a single skill, defined as a directory
  containing at minimum a `SKILL.md` file. May also contain scripts,
  templates, and other supporting files. Identified by its directory
  name.
- **Bundled Skill Manifest** (implicit): the set of directory names
  present under the image's bundled skills source path. Determined at
  start time by listing that directory; no separate manifest file is
  required.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From a clean state (no `kroclaude-config` volume), 100%
  of skills present in the image's bundled skill set are visible at
  `~/.claude/skills/<name>/` within 15 seconds of `docker compose up
  -d`.
- **SC-002**: After three consecutive `docker compose down && up`
  cycles, 100% of user-installed skills (skills with names not in the
  current bundled set) are byte-identical to their pre-cycle state.
- **SC-003**: After an image rebuild that updates a bundled skill's
  contents, the in-volume copy of that skill matches the new image's
  contents on the next healthy state, while user-installed skills
  remain byte-identical.
- **SC-004**: Bundled skill refresh adds no more than 2 seconds to the
  first-boot bootstrap time measured by the existing US2 smoke
  scenario in feature 001 (with up to 20 bundled skills totalling no
  more than 10 MB uncompressed).
- **SC-005**: Zero user-installed skills are deleted, moved, or
  truncated by the start sequence across 100 consecutive automated
  restart cycles.

## Assumptions

- "Global claude directory" is interpreted as the user-level Claude
  Code skills directory: `~/.claude/skills/` for the in-container
  `claude` user. This directory lives in the persistent
  `kroclaude-config` named volume from feature 001
  ([specs/001-claude-shell-base/contracts/volumes.md](../001-claude-shell-base/contracts/volumes.md)),
  so skills installed there already survive container recreation.
- Skills are Claude Code skill directories per the standard
  convention: a folder containing at minimum a `SKILL.md` file.
- The image source location for bundled skills (the build-time path
  populated by the repository's `skills/` directory or equivalent) is
  decided at planning time. This spec does not pin a path.
- Bundled skills are file-based, text-only, and architecture-neutral
  (no per-arch build artifacts, no compiled binaries inside skill
  directories).
- Collision behavior (bundled vs. user-installed skill of the same
  name) is "bundled wins" — documented as the trade-off for keeping
  the model simple. Users who want to customise a bundled skill
  install it under a different directory name.
- This feature does NOT add a way to opt out of skill bundling, a
  user-facing manifest, or selective bundling. Those can be
  introduced later without breaking v1 deployments.
- "Installed skills on the persistent volume" in the user's request
  is taken to mean any skill directory under `~/.claude/skills/` that
  is not part of the current bundled set, regardless of how it got
  there (manually copied, `git clone`d, downloaded by another tool,
  etc.).
