---
description: "Drive an end-to-end Spec Kit feature implementation by delegating each phase to a dedicated subagent. Mandatory subagent fan-out, severity-triaged clarifications, commits gated behind the PR keyword."
argument-hint: "[PR] <feature description>"
---

# /tt-feature

You are the orchestrator for a full feature implementation. Your job is
narrow: parse arguments, delegate every speckit phase to a subagent,
keep an eagle eye on progress, triage clarifications by severity, and
relay only what the user needs to decide. **You do not run any
`/speckit-*` skill yourself.** You also keep your own context lean —
never let subagents dump full artifacts back into your conversation.

## Argument parsing

Raw arguments:

```text
$ARGUMENTS
```

Apply these rules in order, before doing anything else:

1. If `$ARGUMENTS` is empty → ask the user for a feature description
   and stop. Do not invent a feature.
2. If the first whitespace-delimited token equals `PR`
   (case-insensitive) → set `COMMIT_MODE=pr` and treat the remainder
   as the feature description.
3. Otherwise → set `COMMIT_MODE=dry`. The feature description is the
   full `$ARGUMENTS`.

State the resolved `COMMIT_MODE` and the feature description back to
the user in one line before starting phase 1.

## Hard rules (non-negotiable)

- **Mandatory subagents.** Every speckit phase runs inside a subagent
  spawned with the `Agent` tool. The orchestrator never invokes a
  `/speckit-*` skill itself.
- **Exact speckit commands.** Each subagent prompt MUST instruct the
  subagent to invoke the exact `/speckit-*` slash command for its
  phase via the Skill tool — `/speckit-specify`, `/speckit-clarify`,
  `/speckit-plan`, `/speckit-tasks`, `/speckit-analyze`,
  `/speckit-implement`. No paraphrasing, no reinterpreting, no
  reimplementing. The speckit command itself handles branch creation
  and artifact generation; the orchestrator does not enumerate paths
  or restate goals.
- **Lean context.** Subagents return only the structured report
  defined below. They never paste full artifact contents. If the
  orchestrator needs to verify something, it uses `Read` with a tight
  line range — not another subagent dump.
- **Commit gate.** In `COMMIT_MODE=dry` (default) it is FORBIDDEN to
  run `git commit`, `git push`, or `/speckit-git-commit`, or to invoke
  any tool that mutates git history. Writing artifacts under
  `specs/<feature>/` is fine — those are not commits. In
  `COMMIT_MODE=pr`, make exactly ONE commit at the end of phase 6
  covering all artifacts and code, then push and open a PR.
- **Critical clarifications win.** Anything classified as critical
  halts the pipeline and goes to the user verbatim via
  `AskUserQuestion`. The user's choice always wins.
- **No phase 6 without a clean phase 5.** Do not start
  `/speckit-implement` until the analyze phase reports no critical
  inconsistencies.

## Reference

The `speckit-orchestrate` skill at
`~/.claude/skills/speckit-orchestrate/SKILL.md` is your reference for
pipeline ordering and per-phase model recommendations. Read it once
at the start; do not re-read during the run.

## Per-phase delegation protocol

Run phases strictly in order: 1-Specify → 2-Clarify → 3-Plan →
4-Tasks → 5-Analyze → 6-Implement. Phases have hard dependencies, so
never run two in parallel. Within phase 6 only, independent slices
(frontend / backend / infra / data / tests / docs) MAY be fanned out
across multiple subagents in a single message — same protocol applies
per slice.

For each phase:

1. **Track.** Update `TodoWrite` so exactly one phase is `in_progress`.
2. **Spawn one subagent** with `subagent_type: general-purpose` (or a
   more specific installed agent if one obviously fits the slice for
   phase 6). The prompt must contain only:
   - The single instruction: "Invoke `/speckit-<phase>` via the Skill
     tool. Do not paraphrase, reinterpret, or reimplement it. Pass
     through the user's feature description as-is when the skill
     requires it."
   - The return contract (below).
   - For phase 1: the feature description string.
   - For phase 6 slices: the slice name (e.g. "backend", "frontend").
   Nothing else. No goals, no path lists, no architectural hints —
   the speckit skill owns that.
3. **Read only the structured report** when the subagent returns.
   Never let the subagent paste artifact contents.
4. **Act on the report:**
   - `STATUS: ok` → emit a 1–2 sentence phase summary to the user and
     mark the todo complete.
   - `STATUS: needs_clarification` → run severity triage (next
     section).
   - `STATUS: failed` → relay the failure reason to the user and stop
     the pipeline. Do not auto-retry destructive failures.

### Subagent return contract

Every subagent MUST return a report ≤200 words with exactly these
fields and nothing else:

- `STATUS`: one of `ok` | `needs_clarification` | `failed`
- `ARTIFACTS`: bullet list of paths written or changed (paths only,
  no contents)
- `CLARIFICATIONS`: list of `{severity, question, options}` where
  `severity` is `critical` | `medium` | `low`. Empty if none.
- `NOTES`: up to 3 bullets of next-step-relevant info (≤1 line each)

Forbid the subagent from pasting file bodies, full diffs, or full
speckit transcripts.

## Severity triage for clarifications

Apply these explicit rules to each item in `CLARIFICATIONS`:

**critical** — relay verbatim to the user via `AskUserQuestion`.
Halt the pipeline until every critical question has an explicit
answer. Triggers:

- Affects feature scope or user-visible behavior.
- Security, auth, permissions, or privacy choice.
- Data integrity, schema, migration, or persistence semantics.
- External contract (API shape, protocol, wire format).
- Cost, performance SLO, or availability target.
- The orchestrator genuinely cannot infer the answer from the spec
  or codebase.
- **When in doubt, OR whenever the choice could dramatically change
  the outcome of the feature** → critical.

**medium / low** — orchestrator resolves proactively, then:

- Records the decision and a one-line rationale so the next phase's
  subagent can fold it into the spec's `Assumptions` section
  (instruct the next subagent to add it; do not edit the spec
  yourself).
- Mentions the auto-resolution in the phase summary so the user can
  object before the pipeline moves on.

Triggers for medium/low:

- Naming, formatting, or file-layout choices internal to the feature.
- Defaults that match an obvious project convention (check
  neighboring code with `Read` / `rg` if needed).
- Test framework or fixture choices when the project already has one
  installed.
- Phrasing of internal log messages, comments, or doc strings.

Mis-classifying a critical item as low is the failure mode this
command is designed to prevent. Bias toward critical.

## Toolkit survey (between phases 3 and 4)

After phase 3 reports `STATUS: ok` and before spawning the phase 4
subagent, do a one-shot inventory in the orchestrator (not via a
subagent — this is a quick `ls`):

- `ls ~/.claude/agents/` plus any plugin-bundled agents.
- `ls ~/.claude/skills/` plus the user-invocable skills in the system
  reminders.

Present a short table: slice → recommended agent → fallback. This
informs phase 6's per-slice fan-out. Wait for the user to confirm or
adjust before phase 4.

## Wrap-up

After phase 6 reports `STATUS: ok` for every slice:

1. Run the project's smoke / test suite (still required in dry mode).
   If anything fails, report and stop — do not commit.
2. If `COMMIT_MODE=pr`:
   - Stage and create exactly ONE commit covering the whole feature.
     Match the project's commit style (check `git log` first).
   - Push the current feature branch with `git push -u origin <branch>`.
   - Open a PR via `mcp__github__create_pull_request` (ready for
     review, not draft).
3. If `COMMIT_MODE=dry`: print a one-paragraph summary of what was
   produced and explicitly state that nothing was committed.
