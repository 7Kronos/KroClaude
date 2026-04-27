# KroClaude — In-Container Memory

This file is seeded into `~/.claude/CLAUDE.md` on first boot. Edit it from
inside the container (it lives in the persistent config volume).

## Environment

- Working directory: `/workspace` — your project files live here.
- Persistent paths: `/workspace` (project files) and `~/.claude` (Claude
  credentials, per-tool config, shell history). Anything outside these is
  ephemeral and lost on container recreation.
- In-container user: `claude` (UID 1000). `sudo` works without a password
  for ad-hoc package installs.

## Available tooling

- AI CLIs: `claude`, `gemini`, `codex`.
- Shell core: `git`, `curl`, `wget`, `jq`, `rg` (ripgrep), `fd`, `tmux`,
  `fzf`, `bat`.
- Build & language: Node 22, Python 3, `build-essential`, `pkg-config`.
- npm globals: `typescript`, `tsx`, `pnpm`, `vite`, `esbuild`, `eslint`,
  `prettier`, `serve`, `nodemon`, `concurrently`, `dotenv-cli`, `lighthouse`.
- Python packages: `requests`, `httpx`, `beautifulsoup4`, `Pillow`,
  `pandas`, `numpy`, `openpyxl`, `python-docx`, `playwright`, `apprise`,
  `xlsxwriter`, others.
- Database CLIs: `psql`, `redis-cli`, `sqlite3`.
- Browser automation: headless Chromium via Xvfb (`DISPLAY=:99`); use
  `playwright` (Python) or Puppeteer (Node).
- GitHub: `gh`.
- Media: `imagemagick`, `ffmpeg`.
- Debugging: `strace`, `lsof`, `ss`, `htop`.

## Git

`git` is preconfigured at first boot with `user.name`, `user.email`, and
`safe.directory /workspace` from the `GIT_USER_NAME` / `GIT_USER_EMAIL`
environment variables.

## Notifications (opt-in)

To enable Apprise-based notifications when Claude finishes a task:

1. `touch ~/.claude/notify-on`
2. Set at least one `NOTIFY_*` env var in the host `.env` (e.g.,
   `NOTIFY_URLS=tgram://token/chat_id`).

Notifications stay silent if either gate is missing, and silent on any
delivery failure.
