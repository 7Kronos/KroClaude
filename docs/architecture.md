# KroClaude architecture

The single current description of how KroClaude builds, boots, persists
state, and updates. Feature specs under [`specs/`](../specs/) are
historical records of how each piece was introduced; where they
disagree with this document on file layout, this document wins.

```
Dockerfile ──build──► image ──boot──► entrypoint.d stages ──► s6-overlay (PID 1)
     │                                      │                     ├── xvfb
config/tools.json                    kroclaude-sync (bg)          └── sshd :2221
(pinned binaries)                    (all network work)
```

## Build (Dockerfile)

Layer order is chosen for cache stability — rarely-changing layers
first, weekly-changing last:

1. **apt packages** — one layer for the whole system toolset.
2. **apt repos** — GitHub CLI, Docker CLI (client only; talks to the
   dind sidecar).
3. **claude user** — the base image's `node` user (UID 1000) renamed.
4. **Claude Code CLI**, **npm globals**, **uv**, **starship**,
   **.NET SDKs**, **ruby-lsp**, **pip packages** — language runtimes
   and tooling. These float ("latest at build time") deliberately;
   they only rebuild when the Dockerfile itself changes.
5. **Third-party binaries** — everything in
   [`config/tools.json`](../config/tools.json), installed by
   [`scripts/install-tools.sh`](../scripts/install-tools.sh) in ONE
   layer: s6-overlay, bun, nats, supabase, kubectl, helm, k9s,
   kubectx/kubens, stern, kind, herdr, rtk, OmniSharp. All pinned; no
   GitHub API calls at build time. Placed after the heavy layers so a
   version bump rebuilds only from here down.
6. **s6 service definitions, sshd config, entrypoint stages, shell
   config, bundled `config/` tree** — cheap COPY layers last.

To **add a binary tool**: add an entry to `config/tools.json` (see the
schema in its `//` header). Do not add a hand-rolled `RUN curl …`
block to the Dockerfile.

## Updating tool versions

Nobody hand-searches release pages:

- `scripts/bump-tools.sh` — refreshes every pin in `config/tools.json`
  from upstream (GitHub releases / dl.k8s.io) in one command.
  `--check` reports without rewriting.
- [`bump-tools.yml`](../.github/workflows/bump-tools.yml) — runs the
  same script every Monday and opens a single PR with all bumps. CI
  builds the image and runs the full smoke suite against it, so
  merging that PR *is* the upgrade process. (Requires the repo setting
  "Allow GitHub Actions to create and approve pull requests".)
- [`dependabot.yml`](../.github/dependabot.yml) — covers what the
  script does not: Docker base images (`node:lts-trixie`,
  `docker:27-dind`) and GitHub Actions versions.
- Floating installers (Claude Code, starship, uv, dotnet channels,
  npm/pip packages) intentionally track latest at build time; rebuild
  to refresh them.

## Boot (entrypoint)

[`scripts/entrypoint.sh`](../scripts/entrypoint.sh) is a ~20-line
driver that runs each stage under
[`scripts/entrypoint.d/`](../scripts/entrypoint.d/) in lex order, then
`exec /init` (s6-overlay). Stages run as root, `set -euo pipefail`,
and source [`entrypoint-lib.sh`](../scripts/entrypoint-lib.sh).

| Stage | Concern |
|-------|---------|
| `10-home-seed.sh` | First-boot sentinel seed (settings.json, CLAUDE.md, claude-powerline.json), `~/.claude.json`, `/workspace/.omc-workspace` marker, codex/gemini/starship seeds, pre-refactor dotdir adoption |
| `20-git-identity.sh` | `GIT_USER_*` env → `~/.gitconfig`, `safe.directory` |
| `30-reflect-config.sh` | Bundled customization reflection (below) |
| `40-mcp.sh` | `claude mcp` user-scope registration (local config writes) |
| `45-nuget.sh` | NuGet "GitHub" source from `NUGET_REGISTRY_*` env (local config write) |
| `50-ssh.sh` | Host keys (once, persisted), `authorized_keys` (every boot from env) |
| `60-environment.sh` | Renders `/etc/environment` from `config/environment.d/` |
| `70-ownership.sh` | chown sweep over paths the stages touched |
| `80-sync.sh` | Backgrounds `kroclaude-sync` (the only network user) |

**The boot path is offline-safe.** No stage may require the network;
the container reaches healthy with networking down. All network work —
plugin marketplaces, plugin install/update, `call-me-pilot`,
`playwright-skill` — lives in
[`scripts/kroclaude-sync`](../scripts/kroclaude-sync), backgrounded on
boot (`KROCLAUDE_SYNC_ON_BOOT=0` disables) and runnable on demand
inside the container. It logs to `~/.claude/logs/kroclaude-sync.log`;
every step is best-effort.

## Bundled customization reflection

Feature 005 behavior, unchanged: each `config/<type>/` subtree is
baked into the image and reflected into `~/.claude/<type>/` on every
boot (skills, agents, plugins, commands, output-styles), and
`hooks.d`/`mcp-servers.d` JSON fragments are jq-merged into
`settings.json`/`.mcp.json`. The merge filters are versioned files
under [`scripts/filters/`](../scripts/filters/) with offline unit
tests in [`tests/unit/test_merge_filters.sh`](../tests/unit/test_merge_filters.sh).
Precedence: fragments merge in filename-lex order (later wins);
bundled beats target; user items with non-colliding names are never
touched. Contracts: [`specs/005-config-bundling/contracts/`](../specs/005-config-bundling/contracts/).

## Persistence

Three named volumes, one rule — *if it's under `/home/claude` or
`/workspace`, it survives*:

| Volume | Mount | Holds |
|--------|-------|-------|
| `kroclaude-home` | `/home/claude` | ALL dotdirs at natural paths: `~/.claude` (claude-code creds/config/history), `~/.config/gh`, `~/.codex`, `~/.gemini`, `~/.kube`, `~/.docker`, `~/.config/helm`, `~/.vscode-server`, bash history, … |
| `kroclaude-workspace` | `/workspace` | Your code |
| `dind-data` | (dind sidecar) | Docker images/containers of the isolated daemon |

There are deliberately **no** per-CLI volumes, no symlink redirects,
and no env-var dotdir overrides — a new CLI's login persists with zero
configuration. Interactive-shell setup is system-level
(`/etc/profile.d/`, `/etc/kroclaude/bashrc.d/` from
[`config/shell/`](../config/shell/)) precisely so the home volume can
shadow image-baked home files without losing it.

Upgrading a deployment that used the old five-volume layout: stop the
stack, run [`scripts/migrate-volumes.sh`](../scripts/migrate-volumes.sh)
once on the host, start. In-container path adoption (old
`~/.claude/kube`, `helm-config`, `k9s`, … → natural locations) is
automatic on next boot (stage 10).

## Environment propagation

SSH sessions are built from `/etc/environment` (pam_env), not PID 1's
env. [`config/environment.d/`](../config/environment.d/) is the single
source: `static.env` (PATH, DOCKER_HOST, DISPLAY) plus
`passthrough.list` (allowlisted compose var names). Stage 60 renders
both into `/etc/environment` on every boot. `ANTHROPIC_API_KEY` and
`GH_TOKEN` are deliberately excluded — each would shadow a persisted
interactive login (see the comments in `passthrough.list`).

## Runtime & access

- **PID 1** is s6-overlay (as root — required for supervision),
  running two services: `xvfb` (`:99`) and `sshd` (port 2221,
  key-only, claude-only; config contract in
  [`specs/003-ssh-access/`](../specs/003-ssh-access/)).
- **Shells**: `docker exec -it -u claude kroclaude bash` or
  `ssh -p 2221 claude@host`. Login shells land in `/workspace`.
- **Docker**: `DOCKER_HOST=tcp://localhost:2375` targets the
  privileged `dind` sidecar sharing this container's network
  namespace; the host daemon is never exposed.
- **Healthcheck**: Xvfb process + `claude` on PATH + sshd listening.

## Tests

- `tests/unit/` — no-Docker jq filter tests (fast CI job).
- `tests/smoke/` — full-stack scenarios: US1 (tools/health), US2
  (persistence + skill bundling), US3 (notifications), US4 (SSH),
  US6 (all seven customization types).
