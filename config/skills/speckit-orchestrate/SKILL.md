---
name: speckit-orchestrate
description: Drive an end-to-end Spec Kit feature from natural-language description to merged implementation by calling the /speckit-* skills in order. Recommends a model per phase and enforces relaying clarification choices to the user.
---

# Spec Kit end-to-end orchestration

Use this skill when the user wants to take a feature from "I want X" to
a merged implementation by walking through the full Spec Kit workflow.
The skill is a runbook over the existing `/speckit-*` slash commands,
plus model-selection guidance for each phase.

## When to use

- The user describes a feature and wants the full Spec Kit treatment.
- The user is mid-feature and wants a hand through the remaining phases.
- The user asks "what's next?" on a feature branch with a partial
  `specs/<feature>/` directory.

If the user only wants ONE phase (just a spec, just a plan), invoke
the matching `/speckit-*` skill directly. This orchestrator is for
the full pipeline.

## Pipeline

| Phase | Command | What it produces |
|---|---|---|
| 1. Specify | `/speckit-specify <description>` | `specs/<feat>/spec.md` + quality checklist |
| 2. Clarify | `/speckit-clarify` | Up to 5 Q&As folded into the spec |
| 3. Plan | `/speckit-plan` | `plan.md`, `data-model.md`, `contracts/`, `research.md`, `quickstart.md` |
| 4. Tasks | `/speckit-tasks` | `tasks.md` (dependency-ordered) |
| 5. Analyze | `/speckit-analyze` | Cross-artifact consistency report |
| 6. Implement | `/speckit-implement` | Code + tests against `tasks.md` |

Each phase reads artifacts from prior phases. Don't skip ahead.

## Recommended model per phase

Switch with `/model <id>` before starting the phase, or pass the model
when launching `claude`.

| Phase | Recommended | Model ID | Why |
|---|---|---|---|
| 1. Specify | Opus 4.7 | `claude-opus-4-7` | Drafting requirements from ambiguous prose needs breadth and nuance. |
| 2. Clarify | Opus 4.7 | `claude-opus-4-7` | Spotting subtle gaps and framing high-leverage questions is reasoning-heavy. |
| 3. Plan | Opus 4.7 | `claude-opus-4-7` | Architectural choices, cross-cutting trade-offs, contract design. |
| 4. Tasks | Sonnet 4.6 | `claude-sonnet-4-6` | Mechanical decomposition into ordered tasks; Opus is overkill. |
| 5. Analyze | Opus 4.7 | `claude-opus-4-7` | Catching cross-artifact drift rewards careful reasoning. |
| 6. Implement | Sonnet 4.6 | `claude-sonnet-4-6` | High-volume edit loop. Escalate to Opus 4.7 for any task that turns out to be architecturally tricky (concurrency, security, data integrity). |

Haiku 4.5 (`claude-haiku-4-5-20251001`) is too small for spec drafting
or analysis. Use it only for trivial follow-up edits and formatting
passes during implementation — never for phases 1–5.

## Clarification phase: relay every choice to the user

**This is non-negotiable.** During phase 2 — and during phase 1's
quality check whenever `[NEEDS CLARIFICATION]` markers remain —
the underlying skill emits up to 3–5 questions, each with suggested
options in a table. As the orchestrator you MUST:

1. Show every question and every option to the user verbatim.
2. NEVER pick on the user's behalf, even if one option looks obvious.
3. Wait for an explicit per-question answer before updating any
   artifact.
4. Echo the chosen answers back into the spec exactly as selected,
   and record any custom answers under the spec's Assumptions
   section.

The reason: clarifications shape feature scope, and the choice
silently propagates through plan, tasks, and code. The round trip
with the user is cheap; rework after a wrong autopilot pick is not.

If the spec has zero `[NEEDS CLARIFICATION]` markers and the user
has not asked to clarify, you MAY skip phase 2 — but say so out
loud before moving on so the user can override.

## Walking through a feature

1. **Confirm scope.** Restate the user's feature in 1–2 sentences
   and ask for confirmation before running `/speckit-specify`. Catches
   misunderstandings before the spec is written.
2. **Phase 1 (Opus 4.7) — Specify.** `/speckit-specify <description>`.
   If the spec quality check surfaces `[NEEDS CLARIFICATION]`, treat
   it like phase 2 (relay options to the user).
3. **Phase 2 (Opus 4.7) — Clarify.** `/speckit-clarify`. Relay every
   option (see above). Do not proceed until every question has an
   explicit answer.
4. **Phase 3 (Opus 4.7) — Plan.** `/speckit-plan`. Read `plan.md` and
   `contracts/` to confirm the design matches the spec; surface
   concerns to the user before phase 4.
5. **Phase 4 (Sonnet 4.6) — Tasks.** `/speckit-tasks`. Skim `tasks.md`
   for obviously missing or duplicated work; have the user confirm
   scope.
6. **Phase 5 (Opus 4.7) — Analyze.** `/speckit-analyze`. Resolve every
   flagged inconsistency before phase 6 — going into implementation
   with a known-broken plan wastes the most expensive step.
7. **Phase 6 (Sonnet 4.6) — Implement.** `/speckit-implement`. Commit
   at meaningful checkpoints. Switch to Opus 4.7 for any single task
   that turns out to be architecturally tricky.
8. **Wrap up.** Run the project's smoke / test suite. Use
   `/speckit-git-commit` for the implementation commit, or a manual
   commit matching the project's existing style (e.g.
   `[Spec Kit] Implementation complete for <feature>`).

## Git scaffolding (optional, per project)

Projects with a `before_specify` hook get a feature branch
auto-created at phase 1. Otherwise:

- `/speckit-git-feature <name>` — create the feature branch.
- `/speckit-git-validate` — confirm branch naming.
- `/speckit-git-commit` — commit at phase boundaries (after each
  phase produces stable artifacts, not after every edit).

## Anti-patterns to avoid

- Running `/speckit-implement` before `/speckit-analyze`. Skipping
  analyze means hitting inconsistencies mid-implementation when
  they're far more expensive to fix.
- Auto-answering clarification questions. See the dedicated section.
- Editing earlier-phase artifacts without re-running downstream
  phases. If `spec.md` changes, `plan.md` / `tasks.md` may be stale;
  re-run from the earliest changed phase.
- Skipping the spec quality checklist. It's part of phase 1's
  output; a failing checklist is a phase 1 failure.
- Using Haiku for spec drafting or analyze. Spec quality compounds
  through every later phase.
