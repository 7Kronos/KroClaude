---
description: "Audit project docs for contradictions against the latest changes, fold new decisions into the docs, and persist lessons learned to memory."
---

# /tt-ship

You are wrapping up a finished implementation phase. "Shipped" means:
the docs match the new reality, no contradictions are left behind,
and the lessons that came out of this round are remembered for next
time.

## How to run

1. **Survey the doc surface.** Spawn an `Explore` subagent to
   enumerate every docs target in the project. At minimum:
   - `/docs/` and any nested doc folders.
   - `README.md`, `CLAUDE.md`, `AGENTS.md` if present.
   - `specs/<feature>/` for the most recent feature(s).
   - `.specify/` artifacts.
   - Inline JSDoc / docstrings for newly touched modules.
   - OpenAPI / contract files / ADRs.
   Have the agent return a path-keyed inventory.

2. **Audit for contradictions in parallel.** Spawn one or more
   `general-purpose` subagents (parallel calls in a single message,
   each with a slice of the inventory) to find:
   - Statements that contradict the latest `git diff` against `main`
     (or the relevant base branch).
   - Statements that contradict each other across docs.
   - Behavioral claims no longer covered by the smoke / test suite.
   - Stale instructions referring to removed files, flags, env vars,
     or commands.
   Aggregate findings as a punch list and present it to the user
   BEFORE editing anything.

3. **Fold in new findings and decisions.** For decisions made during
   the just-finished implementation that aren't yet written down
   anywhere durable, propose where each one belongs (`CLAUDE.md`,
   the feature's `research.md` or `plan.md`, an ADR, the README,
   inline doc) and write them after the user confirms the punch list.
   Don't silently rewrite docs.

4. **Persist lessons learned to memory.** Anything that would help a
   future conversation — a non-obvious gotcha, a tooling quirk, a
   pattern that worked, a wrong turn worth avoiding — goes into the
   auto-memory system:
   - **Project memory** for facts specific to this codebase.
   - **User memory / feedback memory** for preferences about how the
     user wants to collaborate, valid across projects.
   Use the memory directory and `MEMORY.md` index that the auto-memory
   system already maintains for this project; one file per memory,
   one index line each, types per the auto-memory rules. Do NOT
   duplicate things that are already in `CLAUDE.md` or derivable
   from code or git history.

5. **Summarize.** End with a three-block punch list:
   - **Docs updated** — file paths + one line each.
   - **Memories written** — one line each.
   - **Open questions** — anything ambiguous the user should decide.

## Hard rules

- Memories are for surprising or non-obvious knowledge only. If the
  fact is already in `CLAUDE.md` or trivially in the code, skip it.
- Don't auto-edit docs without the user signing off on the punch
  list.
- If a contradiction is between docs and tests, tests usually win —
  but flag it for the user instead of resolving silently.
- If the doc surface is large, prefer many narrow subagent slices
  over one broad agent: independent slices in parallel beat a single
  long pass.
