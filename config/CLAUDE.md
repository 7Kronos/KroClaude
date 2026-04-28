# Container Environment

You are running inside the KroClaude container (Debian Bookworm, Node 24,
Python 3). This file is your persistent memory for this environment. Treat
its contents as facts and operating rules.

## Persistence

- `/workspace` — user project files. Persistent (named Docker volume).
  Your default working directory.
- `~/.claude` — your own config, credentials, shell history, and hook
  configs. Persistent (separate named Docker volume).
- Everything else — ephemeral. Anything written outside the two paths
  above is lost on container recreation. When you need to save state,
  put it in one of the persistent paths.

## Tools available (already installed; do not propose installing them)

- AI CLIs: `claude` (you), `gemini`, `codex`.
- Shell core: `git`, `gh`, `curl`, `wget`, `jq`, `rg`, `fd`, `tree`,
  `tmux`, `fzf`, `bat`, `htop`, `strace`, `lsof`, `ss`.
- Build & languages: Node 24, Python 3, `build-essential`, `pkg-config`.
- npm globals: `typescript`, `tsx`, `pnpm`, `vite`, `esbuild`, `eslint`,
  `prettier`, `serve`, `nodemon`, `concurrently`, `dotenv-cli`,
  `lighthouse`.
- Python packages: `requests`, `httpx`, `beautifulsoup4`, `lxml`,
  `Pillow`, `pandas`, `numpy`, `openpyxl`, `python-docx`, `jinja2`,
  `pyyaml`, `python-dotenv`, `markdown`, `rich`, `click`, `tqdm`,
  `playwright`, `apprise`, `xlsxwriter`.
- Database CLIs: `psql`, `redis-cli`, `sqlite3`.
- Media: `imagemagick`, `ffmpeg`.

If a needed tool is missing, you can `sudo apt-get install <pkg>` or
install a language-specific package; `sudo` is passwordless for the
`claude` user.

## Browser automation

Chromium and Xvfb are preinstalled. `DISPLAY=:99` is already exported.
`CHROME_PATH` and `PUPPETEER_EXECUTABLE_PATH` are set to
`/usr/bin/chromium`. Use `playwright` (Python) or Puppeteer (Node) for
headless browsing — no extra setup needed.

## Git

`user.name`, `user.email`, and `safe.directory /workspace` are
preconfigured at first boot from the `GIT_USER_NAME` / `GIT_USER_EMAIL`
environment variables. Do not reconfigure unless explicitly asked.

## Notifications

`Stop`, `SessionEnd`, and `PostToolUseFailure` hooks are wired to
`/usr/local/bin/notify.py`. Notifications fire only when both
`~/.claude/notify-on` exists AND at least one `NOTIFY_*` env var is set.
You don't need to act on this — it's ambient.

## Remote access

An SSH server runs on container port `2221` (default host port `2221`,
overridable via `KROCLAUDE_SSH_HOST_PORT`). Authentication is
public-key only; the operator configures authorized keys via the
`KROCLAUDE_SSH_AUTHORIZED_KEY` environment variable. Password auth,
keyboard-interactive auth, and root login are disabled.

## Out of scope — do not propose

- A web UI or any inbound port other than `2221/tcp` (SSH). The image
  remains shell-only at the application layer.
- Host bind-mounts for `/workspace`. Workspace is a named Docker volume.
- Installing Cursor, Junie, or OpenCode CLIs. They were deliberately
  excluded.
- Switching to a profile / variant system. There is one curated tool
  set, not a slim/full split.

## Reference

The full project spec lives outside this container at
`specs/001-claude-shell-base/` in the source repo
(<https://github.com/7Kronos/KroClaude>). You don't need to read it to
operate inside the container.
