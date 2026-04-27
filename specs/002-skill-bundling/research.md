# Phase 0 Research: Bundled Skills, User Skills Preserved

**Branch**: `002-skill-bundling` | **Date**: 2026-04-28

This document records the technical decisions for the implementation
plan. The feature is small; six decisions cover the entire surface.

## R1 — Bundled skill source location in the image

- **Decision**: bundled skills are installed at
  `/usr/local/share/kroclaude/skills/` in the image, one subdirectory
  per skill (matching the layout under `skills/` in the source repo).
- **Rationale**: this path mirrors the convention feature 001
  established for default config seeds
  (`/usr/local/share/kroclaude/{settings.json,CLAUDE.md}`). Keeping all
  bake-into-volume sources under a single directory makes the
  entrypoint's reflection logic uniform.
- **Alternatives considered**:
  - `/opt/kroclaude/skills` — non-standard; we already use
    `/usr/local/share/kroclaude` for sibling files.
  - `/home/claude/.kroclaude-skills/` — no, the persistent volume mount
    point lives under `/home/claude/.claude`; a sibling dir under
    `/home/claude` would not be persistent and would confuse the
    "user owns ~/.claude" mental model.

## R2 — Reflection target on the volume

- **Decision**: copy bundled skills into
  `/home/claude/.claude/skills/<skill-name>/`, the standard Claude
  Code user-level skills location. This directory lives inside the
  `kroclaude-config` named volume from feature 001.
- **Rationale**: matches the user's stated requirement ("global claude
  directory"). Skills installed there are immediately discoverable by
  the `claude` CLI.
- **Alternatives considered**:
  - `/etc/claude/skills/` (system-wide) — Claude Code reads user-level
    skills from the user's home; system-wide would either be invisible
    or require a second discovery mechanism. Rejected.

## R3 — Reflection mechanism

- **Decision**: per bundled skill `S`, do `rm -rf $DEST/$S` followed by
  `cp -r $SRC/$S $DEST/$S`, then `chown -R claude:claude $DEST/$S`.
  Iterate over `find $SRC -mindepth 1 -maxdepth 1 -type d`. The loop
  runs unconditionally on every container start (NOT inside the
  sentinel-guarded first-boot block).
- **Rationale**:
  - `rm -rf` + `cp -r` is atomic at the per-skill level — either the
    skill ends up as the new bundled version, or the prior content
    survives a partial failure (the in-flight skill might be missing
    files briefly, but the entrypoint is `set -euo pipefail`, so any
    failure halts the container start and Coolify/Docker restart-policy
    handles the retry).
  - `chown -R` afterwards ensures the in-volume copy is owned by
    `claude` regardless of how the source layer was built.
  - Running on every boot (not gated by the sentinel) is what the spec
    requires (FR-002): "On every container start...".
  - Touching only directories whose name appears in `$SRC` automatically
    satisfies FR-003 (no other directory is touched).
- **Alternatives considered**:
  - `rsync -a --delete $SRC/$S/ $DEST/$S/` — more elegant for
    incremental sync, but `rsync` is not in the FR-003 curated tool
    set. Adding it just for this would violate Principle III.
  - `cp -r --update` — keeps newer destination files, which is the
    OPPOSITE of what the spec wants (the bundled version is
    authoritative for its own path).
  - `tar -C $SRC -cf - $S | tar -C $DEST -xf -` — equivalent to cp
    here; no advantage on a same-host copy.

## R4 — Position in the entrypoint flow

- **Decision**: place the reflection stanza AFTER the existing
  sentinel-guarded first-boot block (so `~/.claude/skills/` exists if
  it was just created), but BEFORE `exec /init`. The stanza is its
  own block, `set -e`-aware, with a guard that no-ops if the source
  directory is missing or empty.
- **Rationale**: keeps the entrypoint single-purpose-per-block,
  matches the existing flow pattern, and ensures the destination dir
  hierarchy is set up before we copy into it.
- **Alternatives considered**:
  - Run before the sentinel block — would race with the first-boot
    `mkdir -p ~/.claude` call. Rejected.
  - Run as the last line of the sentinel block — would only fire on
    first boot, not on subsequent boots. Violates FR-002. Rejected.

## R5 — Failure handling

- **Decision**: the reflection stanza inherits the entrypoint's
  `set -euo pipefail`. Any `cp` or `chown` failure halts the
  entrypoint, and Docker's `restart: unless-stopped` policy in
  [docker-compose.yaml](../../docker-compose.yaml) takes over. The
  source-missing case (`[ ! -d "$SKILLS_SRC" ]`) is handled with a
  silent skip (FR-004 — image with zero bundled skills must boot).
- **Rationale**: consistent with feature 001's existing failure model
  (FR-010 mandates the same posture as feature 001's first-boot
  block). Halt-loud is correct for a deployment-time bug; silent
  skip is correct for the "no skills bundled in this image" case.
- **Alternatives considered**:
  - Best-effort with logged warnings — would mask broken images. The
    constitution's Reproducible Builds principle prefers loud failures
    in CI to silent drift in production.

## R6 — Versioning policy for bundled skills

- **Decision**: the bundled skill set is part of the image's semver.
  - **PATCH**: text/wording fix inside an existing bundled skill.
  - **MINOR**: adding a new bundled skill, or adding files to an
    existing one without removing or renaming anything users may rely
    on.
  - **MAJOR**: removing a bundled skill, renaming a bundled skill, or
    a contract-breaking change to an existing skill (e.g., the
    SKILL.md format changing in a way that older Claude clients
    can't parse). Requires a `BREAKING:` CHANGELOG entry per the
    constitution's Build, Release & Workflow section.
- **Rationale**: makes the bundled skill set a first-class concern of
  the release process, not an afterthought. Users who pin a specific
  image tag get a deterministic skill set.
- **Alternatives considered**:
  - Independent versioning per skill — overkill for v1 with ≤20
    skills; can be reintroduced later without breaking compatibility
    by adding a manifest file.
  - Skipping skill changes from semver entirely — would mean two
    deployments at the same image tag could behave differently.
    Violates Principle I.

## Open items deferred to `/speckit-tasks`

- The exact list of v1 bundled skills — content selection is a
  separate decision; v1 ships with the placeholder
  [`skills/.gitkeep`](../../skills/.gitkeep) so the build is valid
  from day one even if the bundled set is empty. Concrete skills can
  be added in subsequent PRs without touching this spec.
- Whether to add a CI guard that fails when total bundled skills
  exceed 10 MB or 20 entries — a budget-tracking job similar to the
  image-size one in feature 001's CI.
