# syntax=docker/dockerfile:1.7
FROM node:lts-trixie

LABEL org.opencontainers.image.source=https://github.com/7Kronos/KroClaude
LABEL org.opencontainers.image.description="Claude Code shell environment"

# ---------- Build args ----------
ARG S6_OVERLAY_VERSION=3.2.0.2
ARG NATS_CLI_VERSION=0.4.0
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

# ---------- s6-overlay v3 (multi-arch) ----------
RUN apt-get update && apt-get install -y --no-install-recommends \
    xz-utils curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/
RUN S6_ARCH=$(case "$TARGETARCH" in arm64) echo "aarch64";; *) echo "x86_64";; esac) && \
    curl -fsSL -o /tmp/s6-overlay-arch.tar.xz \
    "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" && \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-arch.tar.xz && \
    rm /tmp/s6-overlay-*.tar.xz

# ---------- System packages (FR-003) ----------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Shell core
    git curl wget jq ripgrep fd-find unzip zip tree tmux fzf bat sudo bubblewrap \
    # Build & language toolchain (Node provided by base image)
    build-essential pkg-config python3 python3-pip python3-venv pipx \
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

# ---------- NATS CLI ----------
# https://github.com/nats-io/natscli — admin/diagnostic CLI for NATS
# servers, JetStream, KV / object stores. No apt feed; ships per-arch zip
# archives that extract to nats-<ver>-linux-<arch>/nats. Multi-arch via
# TARGETARCH (matches the s6-overlay pattern). The binary lands in
# /usr/local/bin so it's on PATH for interactive shells and entrypoint.
RUN NATS_ARCH=$(case "$TARGETARCH" in arm64) echo "arm64";; *) echo "amd64";; esac) && \
    curl -fsSL -o /tmp/nats.zip \
    "https://github.com/nats-io/natscli/releases/download/v${NATS_CLI_VERSION}/nats-${NATS_CLI_VERSION}-linux-${NATS_ARCH}.zip" && \
    unzip -j /tmp/nats.zip "nats-${NATS_CLI_VERSION}-linux-${NATS_ARCH}/nats" -d /usr/local/bin && \
    chmod +x /usr/local/bin/nats && \
    rm /tmp/nats.zip

# ---------- bat / fd symlinks (Debian names them batcat / fdfind) + locale ----------
RUN ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true && \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

# ---------- claude user (rename node@1000 → claude@1000) ----------
RUN usermod -l claude -d /home/claude -m node && \
    groupmod -n claude node && \
    echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude && \
    chmod 0440 /etc/sudoers.d/claude

# ---------- Claude Code CLI (FR-002) ----------
# WORKDIR must be non-root-owned or the installer hangs.
WORKDIR /workspace
RUN chown claude:claude /workspace
USER claude
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root
ENV PATH="/home/claude/.local/bin:${PATH}"

# /etc/environment is read by pam_env (UsePAM yes in sshd_config) so SSH
# sessions inherit the same PATH that ENV PATH gives the entrypoint.
# DOCKER_HOST is baked here too so login/SSH shells point at the dind
# sidecar instead of the missing /var/run/docker.sock.
RUN printf 'PATH="/home/claude/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\nDOCKER_HOST="tcp://localhost:2375"\n' \
    > /etc/environment

# ---------- npm global packages (FR-003, FR-003a) ----------
RUN npm i -g \
    typescript tsx \
    pnpm \
    vite esbuild \
    eslint prettier \
    serve nodemon concurrently \
    dotenv-cli \
    lighthouse \
    @owloops/claude-powerline \
    @google/gemini-cli \
    @openai/codex

# ---------- uv (Astral standalone installer — self-contained binary) ----------
# Installed as the recommended path per Astral's docs (avoids polluting
# the system site-packages). Always installs the latest release at build
# time. `pipx` is provided alongside via apt for users who prefer it.
# `/tt-install-speckit` assumes `uv` is on PATH.
RUN curl -LsSf https://astral.sh/uv/install.sh \
    | UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh

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
    /tmp/dotnet-install.sh --channel 9.0  --install-dir "$DOTNET_ROOT" --no-path && \
    /tmp/dotnet-install.sh --channel 10.0 --install-dir "$DOTNET_ROOT" --no-path && \
    /tmp/dotnet-install.sh --channel 11.0 --quality preview --install-dir "$DOTNET_ROOT" --no-path && \
    rm /tmp/dotnet-install.sh && \
    ln -sf "$DOTNET_ROOT/dotnet" /usr/local/bin/dotnet

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
    xlsxwriter

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

# ---------- Helper scripts and default configs ----------
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/notify.py     /usr/local/bin/notify.py
# ---------- Bundled Claude Code customization (feature 005-config-bundling) ----------
# Single read-only image-time copy of the entire /config/ tree, replacing
# the granular per-file COPYs and the legacy /skills/ COPY. The entrypoint
# reflects each per-type subdirectory into ~/.claude/<type>/ on every boot
# (settings.json + CLAUDE.md remain sentinel-gated first-boot-only seeds —
# feature 001 contract preserved). See specs/005-config-bundling/.
COPY config/ /usr/local/share/kroclaude/config/

# ---------- Bundled third-party plugins/skills (curated cart) ----------
# Fetched at build time from upstream repos into the same /config/
# bundle tree, so they ride the existing entrypoint reflection into
# ~/.claude/{plugins,skills}/ on every boot. Refs are pinned in the
# script and overridable per-item via build args (e.g.
# `--build-arg CLAUDE_MEM_REF=<sha>`). See scripts/fetch-plugins.sh.
ARG ANTHROPIC_OFFICIAL_REF=main
ARG CLAUDE_MEM_REF=main
ARG PLAYWRIGHT_SKILL_REF=main
RUN --mount=type=bind,source=scripts/fetch-plugins.sh,target=/tmp/fetch-plugins.sh \
    ANTHROPIC_OFFICIAL_REF="$ANTHROPIC_OFFICIAL_REF" \
    CLAUDE_MEM_REF="$CLAUDE_MEM_REF" \
    PLAYWRIGHT_SKILL_REF="$PLAYWRIGHT_SKILL_REF" \
    bash /tmp/fetch-plugins.sh /usr/local/share/kroclaude/config

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/notify.py && \
    install -d -o claude -g claude /home/claude/.claude

# ---------- Bash history persistence (research R9) ----------
RUN printf '\nexport HISTFILE=/home/claude/.claude/.bash_history\nexport HISTSIZE=10000\nexport HISTFILESIZE=20000\n' \
    >> /home/claude/.bashrc && \
    chown claude:claude /home/claude/.bashrc

# ---------- Land interactive logins in /workspace (feature 003) ----------
# /etc/profile sources /etc/profile.d/*.sh for login shells (interactive
# SSH login, `bash -l`). Non-interactive `ssh user@host cmd` invocations
# stay in the user's HOME per standard SSH convention.
RUN printf 'if [ -d /workspace ] && [ "$PWD" = "$HOME" ]; then cd /workspace; fi\n' \
    > /etc/profile.d/kroclaude.sh && \
    chmod 0644 /etc/profile.d/kroclaude.sh

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
