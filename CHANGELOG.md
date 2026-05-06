# Changelog

All notable changes to KroClaude will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Image tag versions are independent of the project constitution version.

## [Unreleased]

### Changed

- **Deployment-process simplification pass**: entrypoint, Dockerfile,
  fetch-plugins, smoke tests, and CI all reworked for maintainability.
  No user-facing behavior change; reflection / merge / first-boot
  contracts preserved.
  - Entrypoint: a single final `chown -R "$CLAUDE_HOME"` sweep replaces
    ~17 scattered per-block chowns; `/workspace` removed from the sweep
    (never written-to during build). `reflect_dir_of_dirs` +
    `reflect_dir_of_files` collapsed into one `reflect_dir` helper;
    new `reflect_tree` and `merge_one` helpers absorb the inline
    marketplace + `plugin-defaults.json` activation block. The orphan
    plugin cleanup list is now derived from `marketplace.json` instead
    of being hard-coded. The codex/gemini config heredocs moved to
    bundled files under `config/per-cli/`. ssh-keygen, the first-boot
    `cp` triplet, and the dotnet channel installs are all loops now.
    The indirect `${!filter_var}` ref in `merge_fragments` is gone.
  - fetch-plugins: rewritten to support SHA pins (was branch/tag-only
    despite the docs); the three Anthropic-monorepo sparse clones are
    folded into ONE shallow fetch with multi-subpath sparse-checkout.
  - Dockerfile: `S6_OVERLAY_VERSION` and `NATS_CLI_VERSION` no longer
    pinned by default — both fetch the latest release at build time
    (`--build-arg <NAME>=<version>` still overrides for reproducibility).
    The S6 `ADD` directive is now a `curl` inside the same RUN block
    so it can see the runtime-resolved version.
  - CI: the `bundled-skills-budget` job now checks `config/skills/`
    (was silently a no-op against the pre-feature-005 path `skills/`).
  - Smoke tests: shared scaffolding extracted to `tests/smoke/lib.sh`
    (`log`, `fail`, `wait_healthy`, `cleanup_compose`, common env).

### Added

- **VS Code Remote-SSH persistence**: new `kroclaude-vscode` named
  volume mounted at `/home/claude/.vscode-server`. The first time a
  VS Code Remote-SSH client connects over the existing port-2221 SSH
  channel, VS Code installs its server binary (~200 MB) and any
  user-installed extensions under `~/.vscode-server`. Without a
  dedicated volume, that install lived in the writable container
  layer and was discarded on every redeploy, forcing a re-download +
  re-install of every extension on the next connect. The entrypoint
  fixes initial ownership of the empty volume to `claude:claude`
  (same pattern already used for `~/.config/gh`).
  - Semver impact: **MINOR** (additive — new volume; no change to
    existing volume layout, mount points, or compose-environment
    contract).

- **NATS CLI** (`nats`): the official `nats-io/natscli` binary is now
  baked into the image at `/usr/local/bin/nats` for administering NATS
  servers, JetStream, and KV / object stores. Multi-arch (amd64 +
  arm64), pinned via the `NATS_CLI_VERSION` build arg. Smoke verification
  added to `tests/smoke/test_us1.sh` (PATH check).

- **Remote SSH access** (feature 003-ssh-access): the image now runs a
  hardened OpenSSH server on container port `2221`, published to the
  host on the same port by default (override via
  `KROCLAUDE_SSH_HOST_PORT`). Authentication is **public-key only** —
  password, keyboard-interactive, PAM-challenge, and host-based auth
  are all disabled at the sshd level; root login is disabled; only
  the `claude` user is allowed in. The authorized public key(s) come
  from the `KROCLAUDE_SSH_AUTHORIZED_KEY` environment variable
  (Coolify-friendly, multi-key supported one-per-line) and are
  reseeded on every container start (latest env wins). SSH host keys
  persist in the existing `kroclaude-config` named volume so client
  fingerprints stay stable across rebuilds. See
  [`specs/003-ssh-access/`](specs/003-ssh-access/) for spec, plan,
  and contracts.
  - Semver impact: **MINOR** (additive — no breaking change to
    volume layout or compose-environment contract; the new port and
    env vars are additive). Per
    [`specs/003-ssh-access/research.md`](specs/003-ssh-access/research.md) §R6
    (inherited from feature 002's policy).
  - **Amends prior decisions**: feature 001 FR-003 (SSH category was
    `openssh-client` only) and feature 001 research §R2 (SSH server
    rejected). Both reversed here with explicit security mitigations
    enumerated in feature 003 FR-003..FR-005 + FR-012.
  - Smoke verification: new `tests/smoke/test_us4.sh` exercises
    positive auth + key rotation + multi-key + password / root /
    wrong-key rejection paths using throwaway ed25519 keypairs under
    `mktemp -d`.

- **Bundled skills**: image now ships Claude Code skills under
  `skills/` at the repo root and reflects them into the persistent
  `~/.claude/skills/` directory on every container start. User-installed
  skills (any directory under `~/.claude/skills/` whose name is not in
  the bundled set) are never read, modified, or deleted by the start
  sequence. See
  [`specs/002-skill-bundling/`](specs/002-skill-bundling/) for spec,
  plan, and contracts.
  - The bundled skill set is part of the image's semver:
    **PATCH** for content fixes inside an existing bundled skill,
    **MINOR** for adding a bundled skill, **MAJOR** for removing,
    renaming, or contract-breaking changes (per
    [`specs/002-skill-bundling/research.md`](specs/002-skill-bundling/research.md) §R6).
  - Collision rule (user-installed skill with the same name as a
    bundled one): the bundled version wins on the next start.
  - Smoke verification: extends `tests/smoke/test_us2.sh` with five
    new scenarios covering reflection, user-skill preservation,
    collision, orphan preservation, and update propagation.

## [1.0.0] — Unreleased (target)

### Added

- Initial Coolify-deployable Docker image based on `node:24-bookworm-slim`.
- Claude Code CLI installed via the official native installer.
- Codex CLI (`@openai/codex`) and Gemini CLI (`@google/gemini-cli`).
- Curated apt + npm + pip toolchain (see
  [`specs/001-claude-shell-base/spec.md`](specs/001-claude-shell-base/spec.md)
  FR-003 for the canonical inventory).
- Headless Chromium support with `Xvfb` supervised by `s6-overlay` v3.
- Two named Docker volumes (`kroclaude-config`, `kroclaude-workspace`)
  for separable persistence of credentials and project files.
- First-boot config seeding via a sentinel-guarded entrypoint stanza
  (no separate `bootstrap.sh`).
- Opt-in Apprise-based notifications via `scripts/notify.py`,
  double-gated on a sentinel file and the presence of `NOTIFY_*` env vars.
- CI: build + smoke (US1 / US2 / US3), Trivy scan, image-size budget,
  secrets-in-history check, and tag-driven multi-arch publish.

### Excluded vs. HolyClaude reference

- The `@siteboon/claude-code-ui` web UI ("CloudCLI"), its plugins, and
  all WebSocket / Shell-scroll / model patches against it (FR-004).
- Cursor CLI, Junie CLI, OpenCode CLI, `task-master-ai` (Q1 clarification).
- The `slim` / `full` profile system and the `VARIANT` build arg
  (Q4 clarification).
- `PUID` / `PGID` runtime UID/GID remapping and the corresponding
  entrypoint logic (Q3 clarification).
- `~/.claude.json` 60-second background copy loop (research R11).
- Azure CLI and various vendor deploy CLIs (Wrangler, Vercel, Netlify,
  PM2, Prisma, Drizzle, eas-cli, etc.) — see
  [`specs/001-claude-shell-base/spec.md`](specs/001-claude-shell-base/spec.md)
  Clarifications session for the full list.

### Attribution

KroClaude is inspired by HolyClaude
(<https://github.com/CoderLuii/HolyClaude>); see
[`THIRD-PARTY-NOTICES`](THIRD-PARTY-NOTICES) for the upstream license
and credit.
