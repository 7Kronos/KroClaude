# syntax=docker/dockerfile:1.7
FROM node:lts-trixie

LABEL org.opencontainers.image.source=https://github.com/7Kronos/KroClaude
LABEL org.opencontainers.image.description="Claude Code shell environment"

# ---------- Build args ----------
# Third-party binary versions are NOT build args anymore: they are
# pinned in config/tools.json (one manifest, one installer layer).
# Bump them with scripts/bump-tools.sh or the weekly bump-tools workflow.
ARG TARGETARCH

# ---------- Environment ----------
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    DISPLAY=:99 \
    DBUS_SESSION_BUS_ADDRESS=disabled: \
    CHROMIUM_FLAGS="--no-sandbox --disable-gpu --disable-dev-shm-usage" \
    CHROME_PATH=/usr/bin/chromium \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

# ---------- System packages (FR-003) ----------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Shell core (xz-utils: install-tools.sh extracts s6-overlay .tar.xz)
    git curl ca-certificates wget jq ripgrep fd-find unzip zip xz-utils tree tmux fzf bat sudo bubblewrap \
    # Shell ergonomics (cherry-picked from dotfiles/home.nix — starship
    # installed separately below since trixie's package is too old)
    zsh direnv zoxide eza btop git-delta lazygit \
    # Language servers (C / C++ — clangd). Other LSPs install via npm
    # and gem below; csharp-ls via dotnet tool further down.
    clangd \
    # Build & language toolchain (Node provided by base image)
    build-essential pkg-config python3 python3-pip python3-venv pipx \
    ruby-full \
    # .NET runtime dep (libssl3 / libstdc++6 / zlib1g already pulled by base)
    libicu76 \
    # Browser automation stack (FR-003b)
    chromium xvfb \
    fonts-liberation2 fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji \
    # Locale
    locales \
    # Debugging
    strace lsof iproute2 procps htop \
    # Database clients
    postgresql-client redis-tools sqlite3 \
    # SSH client + server (server added in feature 003-ssh-access)
    openssh-client openssh-server \
    # Media
    imagemagick ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Codex CLI sandbox helper requires bwrap setuid on restricted kernels
RUN chmod u+s /usr/bin/bwrap

# ---------- GitHub CLI ----------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# ---------- Docker CLI (client only) ----------
# Talks to the isolated `dind` sidecar over tcp://localhost:2375; the
# sidecar shares this container's network namespace (see compose).
# No daemon installed here — dockerd runs inside the dind container.
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/debian trixie stable" \
    > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    docker-ce-cli docker-buildx-plugin docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

# ---------- bat / fd symlinks (Debian names them batcat / fdfind) + locale ----------
RUN ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true && \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

# ---------- claude user (rename node@1000 → claude@1000) ----------
RUN usermod -l claude -d /home/claude -m node && \
    groupmod -n claude node && \
    echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude && \
    chmod 0440 /etc/sudoers.d/claude

# ---------- /workspace ownership ----------
# The workspace volume inherits ownership from this directory on first
# creation (Docker copy-up).
WORKDIR /workspace
RUN chown claude:claude /workspace

# ~/.local/bin stays on PATH for user-installed tools (uv tool, pipx),
# which now persist on the home volume.
ENV PATH="/home/claude/.local/bin:${PATH}"

# /etc/environment is read by pam_env (UsePAM yes in sshd_config) so SSH
# sessions inherit the same PATH that ENV PATH gives the entrypoint.
# Its content is single-sourced from config/environment.d/: the baseline
# bake happens in the "Bundled Claude Code customization" layer below,
# and entrypoint stage 60 regenerates it on every boot with the
# compose-supplied passthrough vars appended.

# ---------- npm global packages (FR-003, FR-003a) ----------
# Claude Code (FR-002) installs HERE, system-wide via the official npm
# package — NOT via claude.ai/install.sh into ~/.local/bin. /home/claude
# is a persistent volume, so a home-dir install would freeze the CLI at
# whatever version the volume first captured; a system install means
# `docker compose build` actually updates it. Autoupdater is disabled in
# config/settings.json (DISABLE_AUTOUPDATER=1) — rebuild to update.
RUN npm i -g \
    @anthropic-ai/claude-code \
    typescript tsx \
    pnpm \
    vite esbuild \
    eslint prettier \
    serve nodemon concurrently \
    dotenv-cli \
    lighthouse \
    @owloops/claude-powerline \
    @google/gemini-cli \
    @openai/codex \
    oh-my-claude-sisyphus \
    typescript-language-server \
    pyright \
    bash-language-server \
    yaml-language-server \
    vscode-langservers-extracted \
    dockerfile-language-server-nodejs \
    @astrojs/language-server \
    @vue/language-server

# ---------- uv (Astral standalone installer — self-contained binary) ----------
# Installed as the recommended path per Astral's docs (avoids polluting
# the system site-packages). Always installs the latest release at build
# time. `pipx` is provided alongside via apt for users who prefer it.
# `/tt-install-speckit` assumes `uv` is on PATH.
RUN curl -LsSf https://astral.sh/uv/install.sh \
    | UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh

# ---------- starship (prompt) ----------
# Vendor install script lands the binary at /usr/local/bin/starship —
# trixie's apt package lags upstream substantially. The `--yes` flag
# accepts the EULA and skips the interactive overwrite prompt.
RUN curl -sS https://starship.rs/install.sh | sh -s -- --yes

# ---------- .NET SDKs (9, 10, 11-preview, side-by-side) ----------
# Microsoft's dotnet-install.sh handles side-by-side majors in one
# directory and supports the preview channel that the
# packages.microsoft.com apt feed does not carry. Each channel always
# installs the latest patch at build time.
ENV DOTNET_ROOT=/usr/share/dotnet \
    PATH="/usr/share/dotnet:${PATH}" \
    DOTNET_CLI_TELEMETRY_OPTOUT=0 \
    DOTNET_NOLOGO=1
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh && \
    chmod +x /tmp/dotnet-install.sh && \
    for ch in "9.0" "10.0" "11.0 --quality preview"; do \
    /tmp/dotnet-install.sh --channel $ch --install-dir "$DOTNET_ROOT" --no-path || exit 1; \
    done && \
    rm /tmp/dotnet-install.sh && \
    ln -sf "$DOTNET_ROOT/dotnet" /usr/local/bin/dotnet

# OmniSharp (.NET LSP for the OMC csharp plugin) installs via the
# tools.json manifest layer further down. Its net6.0 build declares
# `rollForward: LatestMajor`, so it runs on the .NET 9/10/11 installed
# here without a separate .NET 6 runtime.

# ---------- csharp-ls (alternate .NET LSP) ----------
# Kept alongside OmniSharp so the upstream `csharp-lsp@claude-plugins-
# official` plugin (which shells out to `csharp-ls`) keeps working.
# Different binary name, no conflict with the omnisharp install above.
RUN dotnet tool install csharp-ls --tool-path /usr/local/bin

# ---------- ruby-lsp (Ruby language server, Shopify) ----------
# Installed system-wide via the ruby-full gem env from the apt block.
# `--no-document` skips rdoc/ri generation to keep the layer small.
# Binary stub lands on PATH via the gem environment's default bin dir.
RUN gem install --no-document ruby-lsp

# ---------- Python packages (FR-003) ----------
RUN pip install --no-cache-dir --break-system-packages \
    requests httpx beautifulsoup4 lxml \
    Pillow \
    pandas numpy \
    openpyxl python-docx \
    jinja2 pyyaml python-dotenv markdown \
    rich click tqdm \
    playwright \
    apprise \
    xlsxwriter \
    python-lsp-server

# ---------- graphify (knowledge-graph skill + CLI) ----------
# https://github.com/safishamsi/graphify — turns any input (code, docs,
# papers, images) into a navigable knowledge graph with community
# detection. The PyPI distribution is `graphifyy` (double-y); it exposes
# the `graphify` console script that the bundled /graphify skill
# (config/skills/graphify/) shells out to. Installing it here means the
# skill's Step-1 `import graphify` probe succeeds with no runtime pip
# install. Pulls tree-sitter language bindings + networkx/graspologic.
# PINNED (unlike the unpinned Python-packages layer above) because the
# vendored SKILL.md is frozen against this release and imports PRIVATE
# internals (`graphify.detect`, `graphify.extract`) that carry no
# stability guarantee — an unpinned bump could break the skill silently.
# When bumping this pin, re-vendor config/skills/graphify/SKILL.md from
# the matching upstream tag. Same `--break-system-packages` as above.
RUN pip install --no-cache-dir --break-system-packages graphifyy==0.9.4

# ---------- Third-party binaries (manifest-driven, feature: simplify-stack) ----------
# s6-overlay, nats, supabase, kubectl, helm, k9s, kubectx, kubens, stern,
# kind, herdr, rtk, OmniSharp — all pinned in config/tools.json and
# installed by one generic script in one layer. To add a tool: add a
# manifest entry. To bump versions: `scripts/bump-tools.sh` (or wait for
# the weekly bump-tools workflow PR). No GitHub API calls happen during
# the build — versions are resolved at bump time, not build time.
# Cluster credentials are NOT baked in — populate ~/.kube at runtime.
# Placed AFTER the npm/pip/dotnet layers so a routine version bump only
# rebuilds from here down, keeping the heavy language layers cached.
COPY config/tools.json        /usr/local/share/kroclaude/tools.json
COPY scripts/install-tools.sh /usr/local/bin/install-tools.sh
RUN chmod +x /usr/local/bin/install-tools.sh && \
    install-tools.sh /usr/local/share/kroclaude/tools.json

# ---------- s6-overlay service definitions ----------
COPY s6-overlay/s6-rc.d/xvfb/type /etc/s6-overlay/s6-rc.d/xvfb/type
COPY s6-overlay/s6-rc.d/xvfb/run  /etc/s6-overlay/s6-rc.d/xvfb/run
RUN chmod +x /etc/s6-overlay/s6-rc.d/xvfb/run && \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/xvfb

# ---------- SSH server (feature 003-ssh-access) ----------
# Hardened sshd config (key-only, claude-only, Mozilla "modern" crypto).
# See specs/003-ssh-access/contracts/sshd-config.md for the contract.
COPY scripts/sshd_config_kroclaude    /etc/ssh/sshd_config_kroclaude
COPY s6-overlay/s6-rc.d/sshd/type     /etc/s6-overlay/s6-rc.d/sshd/type
COPY s6-overlay/s6-rc.d/sshd/run      /etc/s6-overlay/s6-rc.d/sshd/run
RUN chmod +x /etc/s6-overlay/s6-rc.d/sshd/run && \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/sshd

# ---------- Helper scripts, entrypoint stages, merge filters ----------
# entrypoint.sh is a ~20-line driver; the actual boot logic lives in
# lex-ordered stages under /etc/kroclaude/entrypoint.d/ (one concern
# each, individually testable). kroclaude-sync holds ALL boot-time
# network work and runs backgrounded (stage 80) or on demand.
COPY scripts/entrypoint.sh     /usr/local/bin/entrypoint.sh
COPY scripts/entrypoint-lib.sh /etc/kroclaude/entrypoint-lib.sh
COPY scripts/entrypoint.d/     /etc/kroclaude/entrypoint.d/
COPY scripts/filters/          /usr/local/share/kroclaude/filters/
COPY scripts/kroclaude-sync    /usr/local/bin/kroclaude-sync
COPY scripts/notify.py         /usr/local/bin/notify.py
COPY scripts/rm-guard.sh       /usr/local/bin/rm-guard.sh
# ---------- Bundled Claude Code customization (feature 005-config-bundling) ----------
# Single read-only image-time copy of the entire /config/ tree, replacing
# the granular per-file COPYs and the legacy /skills/ COPY. The entrypoint
# reflects each per-type subdirectory into ~/.claude/<type>/ on every boot
# (settings.json + CLAUDE.md remain sentinel-gated first-boot-only seeds —
# feature 001 contract preserved). See specs/005-config-bundling/.
COPY config/ /usr/local/share/kroclaude/config/

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/kroclaude-sync \
    /usr/local/bin/notify.py /usr/local/bin/rm-guard.sh && \
    chmod 0755 /etc/kroclaude/entrypoint.d/*.sh && \
    # Baseline /etc/environment (single-sourced; see config/environment.d/).
    # Covers images started with a non-default entrypoint that skips the
    # boot-time regeneration in stage 60.
    grep -v '^\s*#' /usr/local/share/kroclaude/config/environment.d/static.env \
    | grep -v '^\s*$' > /etc/environment && \
    install -d -o claude -g claude /home/claude/.claude && \
    # The kroclaude-home volume is seeded from the image's /home/claude on
    # first creation (Docker named-volume copy-up) — make sure everything
    # it copies is claude-owned.
    chown -R claude:claude /home/claude

# ---------- Shell configuration (config/shell/, installed system-level) ----------
# Interactive-shell setup lives in versioned files instead of Dockerfile
# heredocs, and installs to /etc rather than appending to ~/.bashrc — so
# it is diffable in review AND keeps applying when /home/claude is a
# volume (a volume shadows image-baked home files after first creation).
# Coverage: Debian's /etc/profile sources /etc/bash.bashrc for login
# shells (SSH), and interactive non-login bash (docker exec -it … bash)
# reads /etc/bash.bashrc directly — the loader below covers both.
# NOTE: a non-interactive `docker exec kroclaude claude ...` (no -it)
# sources neither and still inherits ANTHROPIC_API_KEY from PID 1 —
# acceptable; the documented usage is interactive exec / SSH.
COPY config/shell/profile.d/kroclaude.sh /etc/profile.d/kroclaude.sh
COPY config/shell/bashrc.d/              /etc/kroclaude/bashrc.d/
RUN chmod 0644 /etc/profile.d/kroclaude.sh /etc/kroclaude/bashrc.d/*.sh && \
    printf '\n# KroClaude shell setup (source: config/shell/bashrc.d/ in the repo)\nfor _kc in /etc/kroclaude/bashrc.d/*.sh; do [ -r "$_kc" ] && . "$_kc"; done\nunset _kc\n' \
    >> /etc/bash.bashrc

# ---------- Working directory ----------
WORKDIR /workspace

# ---------- Health check (contracts/healthcheck.md) ----------
# Extended in feature 003-ssh-access: also requires sshd to be listening on 2221.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD pgrep -x Xvfb >/dev/null \
    && command -v claude >/dev/null \
    && bash -c '</dev/tcp/127.0.0.1/2221' 2>/dev/null

# ---------- s6-overlay as PID 1 via entrypoint ----------
# PID 1 runs as root (required by s6-overlay /init for service supervision).
# To get a `claude`-user shell, callers use `docker exec -u claude` (or set
# the user in Coolify's terminal UI). Setting USER claude here would not
# survive compose's `user:` override and would break s6 supervision; see
# the smoke test for the user-experience assertion.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
