---
description: "Drive an end-to-end Spec Kit feature implementation via the speckit-orchestrate skill, fanning each phase out to specialized sub-agents."
argument-hint: "<feature description>"
---

# /tt-feature

You are the orchestrator for a full feature implementation. The feature
description is below. Do whatever yields the best implementation
quality, but ground every choice in the runbook from the
`speckit-orchestrate` skill.

## Feature description

```text
$ARGUMENTS
```

If the description is empty, ask the user to provide one before
continuing. Do not invent a feature.

## How to run

1. **Read the runbook.** Open the `speckit-orchestrate` skill at
   `~/.claude/skills/speckit-orchestrate/SKILL.md` and follow its
   pipeline, including the per-phase model recommendations and the
   non-negotiable rule about relaying clarification choices to the
   user verbatim.

2. **Survey the installed toolkit before generating tasks.** After
   phase 3 (plan) and before phase 4 (tasks), list what's actually
   available so the task plan can lean on it:
   - Agents: `ls ~/.claude/agents/` plus any plugin-bundled agents.
     Each entry is a subagent type you can invoke with the Agent tool.
   - Skills: `ls ~/.claude/skills/` and the user-invocable skills
     listed in the system reminders. Callable via the Skill tool.
   Show the inventory to the user.

3. **Recommend an agent/skill combo per major sub-feature.** Slice
   the planned work (frontend / backend / infra / data / tests /
   docs / etc.) and for each slice propose the best-fit subagent
   from the installed set. Examples:
   - .NET backend slice → a `dotnet-specialist` or `csharp-expert`
     subagent if one is installed; otherwise `general-purpose` Agent
     with an explicit .NET-focused prompt.
   - React/TS frontend slice → a `frontend-engineer` /
     `react-specialist` agent if available.
   - DB schema → `database-architect` or similar.
   - Cross-cutting code review → `code-reviewer` if installed.
   Present the lineup as a table (slice, recommended agent, fallback)
   and wait for the user to confirm or adjust before phase 6.

4. **Fan out per phase using subagents.** Where slices are
   independent, launch multiple subagents in parallel (single message,
   multiple Agent tool calls). Where they're not, serialize them.
   Stay in the parent conversation as orchestrator — do not let a
   subagent take control of the workflow.

5. **Relay clarification questions to the user.** During phase 2, and
   any time `[NEEDS CLARIFICATION]` markers appear in earlier phases,
   surface every question and every option to the user verbatim.
   NEVER pick on the user's behalf, even if one option looks obvious.
   Wait for an explicit per-question answer before updating any
   artifact.

6. **Stop at phase boundaries to summarize.** After phases 1, 3, 4,
   5, and 6, give the user a one-paragraph summary of what was
   produced and what's next so they can intervene early.

## Hard rules

- The user's clarification choices win. Always.
- Do not run `/speckit-implement` until `/speckit-analyze` is clean.
- Match the project's commit-message style (look at `git log` first).
- Run the project's smoke / test suite at the end of phase 6, before
  reporting the feature complete.
