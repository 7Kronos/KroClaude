---
description: "Drive an end-to-end Spec Kit feature implementation by delegating each phase to a dedicated subagent. Mandatory subagent fan-out, fixed model per phase, severity-triaged clarifications, commits gated behind the PR keyword."
argument-hint: "[PR] <feature description>"
---

# /tt-feature

You orchestrate a full Spec Kit feature: parse args, delegate each
phase to a subagent, triage clarifications, and relay only what the
user must decide. Keep your context lean — no subagent dumps full
artifacts back.

## Argument parsing

Raw arguments:

```text
$ARGUMENTS
```

Apply in order:

1. If `$ARGUMENTS` is empty → ask the user for a feature description
   and stop. Do not invent a feature.
2. If the first whitespace-delimited token equals `PR`
   (case-insensitive) → set `COMMIT_MODE=pr` and treat the remainder
   as the feature description.
3. Otherwise → set `COMMIT_MODE=dry`. The full `$ARGUMENTS` is the
   feature description.

Echo the resolved `COMMIT_MODE` and feature description back to the
user in one line before phase 1.

## Hard rules (non-negotiable)

1. **Subagent for every phase.** Each speckit phase runs inside one
   subagent spawned via `Agent`. The orchestrator never invokes a
   `/speckit-*` skill itself.
2. **Exact speckit command, no paraphrasing.** The subagent is told
   to invoke the exact `/speckit-<phase>` slash command via the Skill
   tool. No reinterpreting, no reimplementing, no path enumeration,
   no goal restatement — the speckit skill owns all of that.
3. **Phase order is fixed.**
   `1-Specify → 2-Clarify → 3-Plan → 4-Tasks → 5-Analyze → 6-Implement`.
   No skipping, no reordering, no running two phases concurrently.
   Phase 6 MAY fan out across independent slices (frontend / backend /
   infra / data / tests / docs) in a single message; phases 1–5 are
   strictly single-subagent.
4. **Model per phase is fixed** — pass as `model:` to `Agent`:

   | Phase | Model | ID |
   |---|---|---|
   | 1. Specify | Opus 4.7 | `opus` |
   | 2. Clarify | Opus 4.7 | `opus` |
   | 3. Plan | Opus 4.7 | `opus` |
   | 4. Tasks | Sonnet 4.6 | `sonnet` |
   | 5. Analyze | Opus 4.7 | `opus` |
   | 6. Implement | Sonnet 4.6 | `sonnet` |

   Escalate a single phase-6 slice to `opus` only when it is
   architecturally tricky (concurrency, security, data integrity).
   Haiku is FORBIDDEN for phases 1–5; allowed inside phase 6 only
   for trivial formatting passes.
5. **No phase 6 until phase 5 is clean.** `/speckit-analyze` must
   report zero critical inconsistencies before `/speckit-implement`
   runs.
6. **Lean context.** Subagents return only the structured report
   below. They never paste file bodies, diffs, or transcripts. If you
   need to verify something, `Read` with a tight line range — never
   spawn another subagent to dump artifacts.
7. **Critical clarifications win.** Anything tagged `critical` halts
   the pipeline and goes verbatim to the user via `AskUserQuestion`.
   The user's choice always wins.
8. **Commit gate.** In `COMMIT_MODE=dry` (default), `git commit`,
   `git push`, and `/speckit-git-commit` are FORBIDDEN. Writing under
   `specs/<feature>/` is fine — not a commit. In `COMMIT_MODE=pr`,
   make exactly ONE commit at the end of phase 6 covering all
   artifacts and code, then push and open a PR.

## Pipeline artifacts

| Phase | Skill | Produces |
|---|---|---|
| 1. Specify | `/speckit-specify <description>` | `specs/<feat>/spec.md` + quality checklist |
| 2. Clarify | `/speckit-clarify` | Up to 5 Q&As folded into the spec |
| 3. Plan | `/speckit-plan` | `plan.md`, `data-model.md`, `contracts/`, `research.md`, `quickstart.md` |
| 4. Tasks | `/speckit-tasks` | `tasks.md` (dependency-ordered) |
| 5. Analyze | `/speckit-analyze` | Cross-artifact consistency report |
| 6. Implement | `/speckit-implement` | Code + tests against `tasks.md` |

## Per-phase delegation protocol

For each phase:

1. **Track.** Update `TodoWrite` so exactly one phase is `in_progress`.
2. **Spawn one subagent** with the model from Hard Rule 4. Use
   `subagent_type: general-purpose` (or a more specific installed
   agent if one obviously fits a phase 6 slice). The prompt contains
   only:
   - "Invoke `/speckit-<phase>` via the Skill tool. Do not reinterpret
     or reimplement it. Pass the user's feature description as-is when
     the skill requires it."
   - The return contract below.
   - For phase 1: the feature description string.
   - For phase 6 slices: the slice name (e.g. "backend", "frontend").
3. **Act on the report:**
   - `STATUS: ok` → 1–2 sentence summary to the user, mark todo done.
   - `STATUS: needs_clarification` → run severity triage.
   - `STATUS: failed` → relay reason, stop the pipeline. No auto-retry
     of destructive failures.

### Subagent return contract

The subagent MUST return ≤200 words with exactly these fields:

- `STATUS`: `ok` | `needs_clarification` | `failed`
- `ARTIFACTS`: bullet list of paths written or changed (paths only)
- `CLARIFICATIONS`: list of `{severity, question, options}` where
  `severity` is `critical` | `medium` | `low`. Empty if none.
- `NOTES`: ≤3 bullets of next-step info (≤1 line each)

## Severity triage

**critical** — relay verbatim via `AskUserQuestion` and halt until
every critical question has an explicit answer. Triggers:

- Affects feature scope or user-visible behavior.
- Security, auth, permissions, or privacy choice.
- Data integrity, schema, migration, or persistence semantics.
- External contract (API shape, protocol, wire format).
- Cost, performance SLO, or availability target.
- The orchestrator genuinely cannot infer the answer from the spec
  or codebase.
- **When in doubt, OR whenever the choice could dramatically change
  the outcome of the feature** → critical.

**medium / low** — orchestrator auto-resolves. Triggers:

- Naming, formatting, or file-layout choices internal to the feature.
- Defaults that match an obvious project convention (verify with
  `Read` / `rg`).
- Test framework or fixture choices when the project already has one.
- Phrasing of internal log messages, comments, or doc strings.

On auto-resolution: record the decision + one-line rationale and
instruct the next phase's subagent to fold it into the spec's
`Assumptions` section (don't edit the spec yourself). Mention it in
the phase summary so the user can object before the pipeline moves on.

Mis-classifying a critical item is the failure mode this command is
designed to prevent. Bias toward critical.

## Toolkit survey (between phases 3 and 4)

After phase 3 reports `STATUS: ok` and before spawning phase 4, do a
one-shot inventory in the orchestrator (not via a subagent):

- `ls ~/.claude/agents/` plus any plugin-bundled agents.
- `ls ~/.claude/skills/` plus user-invocable skills in system reminders.

Present a short table: slice → recommended agent → fallback. Wait for
the user to confirm before phase 4. This informs phase 6 fan-out.

## Wrap-up

After phase 6 reports `STATUS: ok` for every slice:

1. Run the project's smoke / test suite (required in dry mode too).
   If anything fails, report and stop — do not commit.
2. If `COMMIT_MODE=pr`:
   - Stage and create exactly ONE commit covering the whole feature.
     Match the project's commit style (check `git log` first).
   - `git push -u origin <branch>`.
   - Open a PR via `mcp__github__create_pull_request` (ready for
     review, not draft).
3. If `COMMIT_MODE=dry`: print a one-paragraph summary of what was
   produced and explicitly state nothing was committed.
