# KroClaude

A containerized Claude Code shell environment (Dockerfile +
docker-compose stack, deployable on Coolify).

**Current architecture — read this first**:
[docs/architecture.md](docs/architecture.md) covers build layers, boot
stages, the persistence model, SSH access, and how tool versions are
bumped. Consult it before changing `Dockerfile`, `docker-compose.yaml`,
or anything under `scripts/`.

Key invariants (rationale in docs/architecture.md):

- **Boot is offline-safe.** Nothing under `scripts/entrypoint.d/` may
  touch the network. Network work belongs in `scripts/kroclaude-sync`
  (backgrounded by stage 80).
- **Third-party binaries are manifest-pinned.** Add tools as entries in
  `config/tools.json` (installed by `scripts/install-tools.sh`), never
  as hand-rolled `RUN curl …` Dockerfile blocks. Bump pins with
  `scripts/bump-tools.sh` or the weekly `bump-tools` workflow PR.
- **`/home/claude` is ONE persistent volume.** Dotdirs persist at their
  natural paths — no per-CLI volumes, symlinks, or env-var redirects.
  Interactive-shell setup therefore lives system-level in
  `config/shell/` (→ `/etc`), never appended to `~/.bashrc` in the
  image.
- **Reflection preserves user items.** `config/<type>/` →
  `~/.claude/<type>/` on every boot; user-installed items with
  non-colliding names are never touched. Merge-filter contracts:
  `specs/005-config-bundling/contracts/`, unit tests in `tests/unit/`.

`specs/` (features 001, 002, 003, 005) is **historical** feature
documentation. The behavioral contracts still hold, but file layouts
referenced there may predate the simplify-stack refactor —
docs/architecture.md wins on conflicts.
