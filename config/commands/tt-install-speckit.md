---
description: "Update Spec Kit on this machine and initialize the current directory with the Claude integration (sh scripts) using uv."
---

# /tt-install-speckit

Refresh the Spec Kit toolchain and bootstrap Spec-Driven Development
in the current working directory, with the Claude Code integration
and POSIX shell scripts. Assumes `uv` is on `PATH` (the KroClaude
image bundles it).

Reference: https://github.com/github/spec-kit#-get-started

## How to run

1. **Update (or install) the Specify CLI.** `--force` overwrites any
   existing install with the latest from `main`:

   ```bash
   uv tool install specify-cli --force --from git+https://github.com/github/spec-kit.git
   ```

2. **Verify the install.**

   ```bash
   specify version
   ```

   If the binary isn't on `PATH`, run `uv tool update-shell` and
   reload the shell, then retry.

3. **Initialize the current directory.**

   ```bash
   specify init --here --integration claude --script sh
   ```

   - `--here` initializes in `$(pwd)` instead of creating a subdir.
   - `--integration claude` installs the Claude Code integration —
     skills land under `.claude/skills/`, slash commands under
     `.claude/commands/`.
   - `--script sh` selects POSIX shell scripts over PowerShell.

   If the directory is non-empty and `specify init` prompts for
   confirmation, surface the prompt to the user — do NOT auto-accept.
   Existing files may collide with Spec Kit's templates.

4. **Sanity check the bootstrap.**

   ```bash
   ls -la .specify .claude/skills .claude/commands 2>/dev/null
   ```

   Expect at minimum `.specify/templates/`, `.specify/extensions/`,
   `.claude/skills/speckit-*`, and `.claude/commands/`.

5. **Report to the user.** One short paragraph including:
   - Old vs new `specify version` (if upgrading).
   - The integration / script flavor used.
   - The top-level directories created.
   - Suggested next step: `/speckit-constitution` or
     `/tt-feature "<your feature description>"`.

## Hard rules

- If `.specify/` already exists with a different integration, surface
  the current state and ask the user whether they want to upgrade in
  place (`specify integration upgrade claude`) or switch
  (`specify integration switch claude`) before re-running `init`.
- Never auto-accept a destructive prompt from `specify init`. Relay
  it to the user.
