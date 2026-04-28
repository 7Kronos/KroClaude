<!-- SPECKIT START -->
Active feature: `004-docker-spawning` (Docker-out-of-Docker container
spawning from inside KroClaude with shared network and SSH-forward DX).
For technologies, project structure, shell commands, and other context,
read the current implementation plan: [specs/004-docker-spawning/plan.md](specs/004-docker-spawning/plan.md).
Companion artifacts: [spec.md](specs/004-docker-spawning/spec.md),
[research.md](specs/004-docker-spawning/research.md),
[data-model.md](specs/004-docker-spawning/data-model.md),
[quickstart.md](specs/004-docker-spawning/quickstart.md),
[contracts/](specs/004-docker-spawning/contracts/).

Prior feature references:
- `001-claude-shell-base` — [specs/001-claude-shell-base/](specs/001-claude-shell-base/)
  base image, compose, entrypoint, smoke suite. **NOTE**: feature 003
  amends FR-003 (SSH was client-only) and reverses research §R2
  (rejected SSH server) — see feature 003 FR-013.
- `002-skill-bundling` — [specs/002-skill-bundling/](specs/002-skill-bundling/)
  bundled skills + reflection-on-boot.
- `003-ssh-access` — [specs/003-ssh-access/](specs/003-ssh-access/)
  hardened sshd on port 2221, key-only, claude-only, with
  `AllowTcpForwarding yes` (load-bearing for feature 004's
  `kc-forward` SSH local-port-forward DX).
<!-- SPECKIT END -->
