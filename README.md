# KroClaude

A reproducible Claude Code shell environment, packaged as a Dockerfile and a
docker-compose stack and deployable on Coolify. Inspired by
[HolyClaude](https://github.com/CoderLuii/HolyClaude); see
[`THIRD-PARTY-NOTICES`](THIRD-PARTY-NOTICES) for attribution.

## Quickstart

See [`specs/001-claude-shell-base/quickstart.md`](specs/001-claude-shell-base/quickstart.md).

## Specification

The full specification, design, and task plan live under
[`specs/001-claude-shell-base/`](specs/001-claude-shell-base/):

- [spec.md](specs/001-claude-shell-base/spec.md) — what and why
- [plan.md](specs/001-claude-shell-base/plan.md) — technical context, structure, constitutional check
- [research.md](specs/001-claude-shell-base/research.md) — decisions and rationale
- [contracts/](specs/001-claude-shell-base/contracts/) — env-var, volume, healthcheck, notification contracts
- [tasks.md](specs/001-claude-shell-base/tasks.md) — implementation task list

The project constitution is at
[`.specify/memory/constitution.md`](.specify/memory/constitution.md).
