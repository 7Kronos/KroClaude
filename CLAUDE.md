<!-- SPECKIT START -->
Active feature: `005-config-bundling` (unify all Claude Code
customization types — skills, commands, agents, output-styles, hooks
fragments, MCP server fragments, plugins — under `/config/` with
per-element subfolders, reflected into ~/.claude on every boot).
For technologies, project structure, shell commands, and other
context, read the current implementation plan:
[specs/005-config-bundling/plan.md](specs/005-config-bundling/plan.md).
Companion artifacts: [spec.md](specs/005-config-bundling/spec.md),
[research.md](specs/005-config-bundling/research.md),
[data-model.md](specs/005-config-bundling/data-model.md),
[quickstart.md](specs/005-config-bundling/quickstart.md),
[contracts/](specs/005-config-bundling/contracts/).

Prior feature references:
- `001-claude-shell-base` — [specs/001-claude-shell-base/](specs/001-claude-shell-base/)
  base image, compose, entrypoint, smoke suite. **NOTE**: feature 003
  amends FR-003 (SSH was client-only) and reverses research §R2
  (rejected SSH server) — see feature 003 FR-013.
- `002-skill-bundling` — [specs/002-skill-bundling/](specs/002-skill-bundling/)
  bundled skills + reflection-on-boot. **NOTE**: feature 005 amends
  FR-001 (source path moves from /skills/ to /config/skills/) but
  preserves all runtime behavior FRs — see feature 005 FR-012.
- `003-ssh-access` — [specs/003-ssh-access/](specs/003-ssh-access/)
  hardened sshd on port 2221, key-only, claude-only.
<!-- SPECKIT END -->
