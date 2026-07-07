# Container Environment

You run inside the KroClaude container (Debian Trixie, Node 24,
Python 3). Treat the contents of this file as facts and operating
rules.

## Persistence

- `/workspace` — user project files. Persistent (named Docker volume).
  Default working directory.
- `/home/claude` — your ENTIRE home directory is persistent (single
  named Docker volume): `~/.claude` config/credentials/history,
  `~/.config`, `~/.kube`, `~/.docker`, `~/.codex`, `~/.gemini`,
  `~/.vscode-server`, and any dotdir a CLI creates.
- Everything outside `/workspace` and `/home/claude` — ephemeral.

## Tools available (already installed; do not propose installing them)

- AI CLIs: `claude` (you), `gemini`, `codex`.
- Shell core: `git`, `gh`, `curl`, `wget`, `jq`, `rg`, `fd`, `tree`,
  `tmux`, `fzf`, `bat`, `htop`, `strace`, `lsof`, `ss`.
- Build & languages: Node 24, Bun (`bun`/`bunx`), Python 3,
  `build-essential`, `pkg-config`.
- Python tooling: `pip`, `uv`, `pipx` (`uv tool install ...` /
  `pipx install ...` drop CLI tools into PATH without polluting
  system site-packages).
- .NET SDKs 9, 10, and 11 (preview), all addressed via the `dotnet`
  muxer at `/usr/share/dotnet`. List installed SDKs with
  `dotnet --list-sdks`.
- npm globals: `typescript`, `tsx`, `pnpm`, `vite`, `esbuild`,
  `eslint`, `prettier`, `serve`, `nodemon`, `concurrently`,
  `dotenv-cli`, `lighthouse`.
- Python packages: `requests`, `httpx`, `beautifulsoup4`, `lxml`,
  `Pillow`, `pandas`, `numpy`, `openpyxl`, `python-docx`, `jinja2`,
  `pyyaml`, `python-dotenv`, `markdown`, `rich`, `click`, `tqdm`,
  `playwright`, `apprise`, `xlsxwriter`.
- Database CLIs: `psql`, `redis-cli`, `sqlite3`.
- Kubernetes: `kubectl`, `helm`, `k9s`, `kubectx`/`kubens`, `stern`,
  `kind` (pairs with the dind sidecar). Also `nats`, `supabase`.
- Media: `imagemagick`, `ffmpeg`.
- `kroclaude-sync` — refreshes bundled plugin marketplaces, plugins,
  and cloned skills on demand (also runs in the background at boot;
  log: `~/.claude/logs/kroclaude-sync.log`).
- MCP servers (pre-registered, user scope): `context7`, `filesystem`,
  `serena`; `exa`/`github` appear when their env keys are set. For
  symbol-level code questions — find references/call sites, go to
  definition, hover types, post-edit diagnostics — prefer serena's
  tools over `grep`/`rg`; text search stays right for strings, config
  keys, and broad discovery.

If a needed tool is missing, `sudo apt-get install <pkg>` or use a
language-specific installer; `sudo` is passwordless for the `claude`
user.

## Browser automation

Chromium and Xvfb are preinstalled. `DISPLAY=:99` is already exported.
`CHROME_PATH` and `PUPPETEER_EXECUTABLE_PATH` are set to
`/usr/bin/chromium`. Use `playwright` (Python) or Puppeteer (Node) for
headless browsing — no extra setup needed.

## Docker

`docker` targets a `docker:dind` sidecar via
`DOCKER_HOST=tcp://localhost:2375`, not the host daemon. `docker ps`
inside the container only sees its own children; host containers are
invisible. The sidecar shares KroClaude's network namespace, so
containers it spawns are reachable on `localhost:<port>`. State
persists in the `dind-data` named volume.
