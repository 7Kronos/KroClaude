# Phase 1 Data Model: Bundled Skills, User Skills Preserved

**Branch**: `002-skill-bundling` | **Date**: 2026-04-28

## Entity: Bundled Skill Set

| Field | Value / Constraint |
|-------|--------------------|
| Source location (repo) | `skills/` at repo root, one subdirectory per bundled skill |
| Image location (read-only) | `/usr/local/share/kroclaude/skills/<skill-name>/` |
| Reflected location (volume) | `/home/claude/.claude/skills/<skill-name>/` (in `kroclaude-config` named volume) |
| Cardinality | 0 to 20 in v1 (FR-005 budget) |
| Total size cap (uncompressed) | 10 MB in v1 (FR-005 budget) |
| Update cadence | every container start (FR-002) |
| Authority | image-time content is authoritative; per-skill `rm -rf` + `cp -r` overwrites the in-volume copy |
| Permissions in the volume | files owned by `claude:claude` after reflection (FR-008) |

## Entity: Skill Directory

| Field | Value / Constraint |
|-------|--------------------|
| Identifier | the directory's basename (must be a valid POSIX filename, no slashes) |
| Required contents | `SKILL.md` at the directory root |
| Optional contents | scripts, templates, assets, subdirectories — all reflected verbatim |
| Architecture | text-only and architecture-neutral (no per-arch artifacts in v1) |
| Encoding | UTF-8 |

## Entity: User Skill

| Field | Value / Constraint |
|-------|--------------------|
| Definition | any directory under `~/.claude/skills/` whose basename is NOT in the current Bundled Skill Set |
| How it gets there | manual `cp` / `git clone` / drag from host / installed via tooling outside KroClaude |
| Reflection-stanza behaviour | NEVER read, modified, moved, or deleted (FR-003) |

## Entity: Reflection Run

A single execution of the entrypoint's bundled-skill reflection stanza.

| Property | Value |
|----------|-------|
| Trigger | container start (every start, not gated by the first-boot sentinel) |
| Inputs | `/usr/local/share/kroclaude/skills/` (read-only) |
| Outputs | `/home/claude/.claude/skills/<bundled-name>/` directories (created or replaced) |
| Idempotence | running twice in immediate succession produces the same byte-level state (FR-002) |
| Failure mode | non-zero exit on copy failure → entrypoint halts → Docker restart policy handles retry (per [research R5](research.md)) |
| No-op condition | source directory missing or empty → skip silently, container continues to boot (FR-004) |

There are no relationships to model beyond "Bundled Skill Set contains
zero or more Skill Directories" and "User Skill is the negation, in the
runtime volume, of Bundled Skill Set".
