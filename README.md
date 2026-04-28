# KroClaude

A reproducible Claude Code shell environment, packaged as a Dockerfile and
docker-compose stack and deployable on Coolify. Non-root by default,
shell-only (no inbound ports), with persistent named volumes for config and
workspace state.

## Quickstart

```bash
cp .env.example .env          # set ANTHROPIC_API_KEY
docker compose build
docker compose up -d
docker exec -it kroclaude bash   # drops you in as the `claude` user
```

Inside the container, `claude`, `codex`, and `gemini` are on `PATH`.

## Configuration

- Environment variables: copy [.env.example](.env.example) to `.env` and
  fill it in. `ANTHROPIC_API_KEY` is required; `TZ`, `GIT_USER_NAME`,
  `GIT_USER_EMAIL`, `NODE_OPTIONS`, and `NOTIFY_URLS` are optional.
- Persistent volumes (declared in [docker-compose.yaml](docker-compose.yaml)):
  - `kroclaude-config` → `/home/claude/.claude` (CLI config, history, auth)
  - `kroclaude-workspace` → `/workspace` (your code)
- Healthcheck and s6-overlay supervision are baked into the image — no
  extra wiring needed.

## Deploy on Coolify

Point a Coolify "Docker Compose" application at this repo. Set
`ANTHROPIC_API_KEY` (and any other env vars from `.env.example`) as
Coolify secrets. The compose file works as-is; the two named volumes are
created on first boot and persist across redeploys.

## Bundled skills

Claude Code skills committed under [`skills/`](skills/) at the repo root
are baked into the image at build time and reflected into the
persistent `~/.claude/skills/` directory on every container start. Any
skill you install in the running container under that directory whose
name is not in the bundled set is preserved verbatim across restarts,
image rebuilds, and pulls of new image versions. See
[`specs/002-skill-bundling/quickstart.md`](specs/002-skill-bundling/quickstart.md)
for how to add a bundled skill, install a user skill, or reset state.

## Credits

Inspired by [HolyClaude](https://github.com/CoderLuii/HolyClaude). See
[THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES) for full attribution and
licensing.

## Third-party software

Bundled in the image (see [Dockerfile](Dockerfile) for the authoritative
list and versions):

- **Base**: Debian Bookworm (`node:24-bookworm-slim`), s6-overlay v3.
- **CLIs**: Claude Code, [`@openai/codex`](https://www.npmjs.com/package/@openai/codex), [`@google/gemini-cli`](https://www.npmjs.com/package/@google/gemini-cli), GitHub CLI (`gh`).
- **Toolchain**: Node.js 24, TypeScript, tsx, pnpm, Vite, esbuild, ESLint,
  Prettier, Python 3, pip.
- **Browser automation**: Chromium, Xvfb, Playwright, Lighthouse.
- **Shell / dev tools**: tmux, fzf, ripgrep, fd, jq, tree, bubblewrap.
- **DB clients**: postgresql-client, redis-tools, sqlite3.
- **Media**: ImageMagick, ffmpeg.
- **Python libraries (notable)**: requests, httpx, BeautifulSoup, Pillow,
  pandas, Playwright, apprise, rich.
