# KroClaude

[![CI](https://github.com/7Kronos/KroClaude/actions/workflows/ci.yml/badge.svg)](https://github.com/7Kronos/KroClaude/actions/workflows/ci.yml)
[![Security scan](https://github.com/7Kronos/KroClaude/actions/workflows/security-scan.yml/badge.svg)](https://github.com/7Kronos/KroClaude/actions/workflows/security-scan.yml)

A reproducible Claude Code shell environment, packaged as a Dockerfile and
docker-compose stack and deployable on Coolify. Non-root by default,
SSH-accessible, with persistent named volumes for config and workspace state.

## Quickstart

```bash
cp .env.example .env          # set ANTHROPIC_API_KEY (and your SSH pubkey)
docker compose build
docker compose up -d
docker exec -it -u claude kroclaude bash      # local shell
ssh -p 2221 claude@<host>                     # remote shell (after pubkey is set)
```

Inside the container, `claude`, `codex`, and `gemini` are on `PATH`.

## Configuration

Copy [.env.example](.env.example) to `.env` and fill it in. All env vars are
optional except `ANTHROPIC_API_KEY`.

| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_API_KEY` | **Required.** Claude Code authentication. |
| `KROCLAUDE_SSH_AUTHORIZED_KEY` | Verbatim authorized_keys content (one or more public keys, one per line). Required to SSH in. |
| `KROCLAUDE_SSH_HOST_PORT` | Host-side port override (default `2221`). |
| `TZ`, `GIT_USER_NAME`, `GIT_USER_EMAIL`, `NODE_OPTIONS` | Runtime niceties. |
| `NOTIFY_URLS` | Apprise URLs for Stop/error notifications. |

Persistent named volumes (declared in [docker-compose.yaml](docker-compose.yaml)):

- `kroclaude-config` → `/home/claude/.claude` — CLI config, credentials, history, bundled skills/commands/agents/etc.
- `kroclaude-workspace` → `/workspace` — your code.

Both survive `docker compose down` and image rebuilds. Wipe with `down -v`.

## Deploy on Coolify

1. Point a Coolify "Docker Compose" application at this repo.
2. Set `ANTHROPIC_API_KEY` and `KROCLAUDE_SSH_AUTHORIZED_KEY` (and any other
   env vars you need) as Coolify secrets.
3. Deploy. The named volumes are created on first boot and persist
   across redeploys.

## Remote SSH access

The image runs a hardened OpenSSH server on container port `2221` (default
host port `2221`, overridable via `KROCLAUDE_SSH_HOST_PORT`). Authentication
is **public-key only** — set `KROCLAUDE_SSH_AUTHORIZED_KEY` to your public
key(s) and `ssh -p 2221 claude@<host>`. Passwords, keyboard-interactive auth,
and root login are disabled. See
[`specs/003-ssh-access/quickstart.md`](specs/003-ssh-access/quickstart.md)
for key rotation and troubleshooting.

## Isolated Docker daemon

The compose stack runs a `docker:dind` sidecar alongside the main
container. Inside KroClaude, `docker` (and anything that uses it —
`.NET Aspire`, Testcontainers, ad-hoc `docker run`) targets this
sidecar via `DOCKER_HOST=tcp://localhost:2375`, **not** the host
daemon. `docker ps` inside the container only sees its own children;
host containers are invisible. The sidecar shares KroClaude's network
namespace, so containers it spawns are reachable via `localhost:<port>`
for the standard port-publishing pattern. State persists in the
`dind-data` named volume across redeploys.

## Bundled customizations

Anything you drop under [`config/`](config/) at the repo root gets baked
into the image at build time and reflected into `~/.claude/` on every
container start. Drop a folder/file → rebuild → restart → it's there.

| Drop here | Becomes | Pattern |
|-----------|---------|---------|
| `config/skills/<name>/SKILL.md` | A Claude Code skill | One folder per skill |
| `config/commands/<name>.md` | A `/<name>` slash command | One file per command |
| `config/agents/<name>/agent.md` | A sub-agent (callable via the Agent tool) | One folder per agent |
| `config/output-styles/<name>.md` | A selectable output style | One file per style |
| `config/hooks.d/<name>.json` | A hook merged into `~/.claude/settings.json` | One JSON fragment per file |
| `config/mcp-servers.d/<name>.json` | An MCP server merged into `~/.claude/.mcp.json` | One JSON fragment per file |
| `config/plugins/<name>/.claude-plugin/plugin.json` | A Claude Code plugin tree | One folder per plugin |

**Anything you install manually inside the running container** (under
`~/.claude/skills/`, `~/.claude/commands/`, etc.) is preserved across
restarts and rebuilds — the bundling pipeline only touches items whose
names match the bundled set. To replace a hand-installed item with a
bundled one, rename your local copy.

For hook and MCP fragments: multiple files are merged in
filename-lex order (later wins on key collision — name fragments
`00-base.json`, `99-override.json` to control precedence). Bundled
entries overlay any same-named entry already in `settings.json` /
`.mcp.json`. See
[`specs/005-config-bundling/quickstart.md`](specs/005-config-bundling/quickstart.md)
for fragment shapes and examples.

The two seed files [`config/settings.json`](config/settings.json) and
[`config/CLAUDE.md`](config/CLAUDE.md) are special: they're copied
into the persistent volume **once on first boot** (sentinel-gated).
Edits to those files in the repo affect new deployments only — to
re-seed an existing container, wipe the `kroclaude-config` volume.

## Default behaviour

The image ships [`config/settings.json`](config/settings.json) tuned
for an isolated, ephemeral container:

- **Permission mode**: `bypassPermissions`. No per-tool prompts;
  only `rm -rf /` and `rm -rf ~` still ask. Fine for a throwaway
  container, **not** for one with mounted host paths.
- **Model & reasoning**: `opus` with `effortLevel: xhigh`,
  `alwaysThinkingEnabled: true`, `useAutoModeDuringPlan: true`.
- **rm-guard safety belt**: a bundled PreToolUse hook
  ([`scripts/rm-guard.sh`](scripts/rm-guard.sh)) denies recursive
  deletes whose target resolves into `/workspace` or `~/.claude` —
  the only paths that survive container recreation.
- **Commit / PR attribution**: the `attribution` block sets the
  footer appended to git commits and PRs. Edit it in
  `config/settings.json` to change.

Change anything you don't want and rebuild; the seed only takes
effect the first time the `kroclaude-config` volume is empty.

## Maintenance

- **Update Claude Code or any tool** → `docker compose build && docker compose up -d`. Volumes survive.
- **Add a skill / command / agent / hook / MCP / plugin** → drop the file under `config/`, then build + up.
- **Rotate SSH keys** → update `KROCLAUDE_SSH_AUTHORIZED_KEY` and `docker compose up -d` (recreate). The new key takes effect on the next SSH connection; the old key stops working immediately.
- **Wipe state** → `docker compose down -v` (deletes both volumes; you lose authenticated sessions, history, hand-installed skills, and `/workspace` content).
- **Backups** → snapshot the two named volumes (`kroclaude-config`, `kroclaude-workspace`) on whatever cadence makes sense for you. Coolify's volume backup integration covers them.

## Credits

Inspired by [HolyClaude](https://github.com/CoderLuii/HolyClaude). See
[THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES) for full attribution and
licensing.

## Third-party software

Bundled in the image; see [Dockerfile](Dockerfile) for the authoritative
list and versions. Highlights: Debian Trixie + s6-overlay base; Claude
Code, Codex, Gemini CLIs; Node.js 24 + TypeScript/Vite/esbuild/ESLint/
Prettier; Python 3 + Playwright/pandas/httpx/etc.; Chromium + Xvfb for
browser automation; GitHub CLI; NATS CLI; jq; Postgres/Redis/SQLite clients;
ImageMagick/ffmpeg.
