# syntax=docker/dockerfile:1.7
FROM node:lts-trixie

LABEL org.opencontainers.image.source=https://github.com/7Kronos/KroClaude
LABEL org.opencontainers.image.description="Claude Code shell environment"

# ---------- Build args ----------
ARG S6_OVERLAY_VERSION=3.2.0.2
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
    build-essential pkg-config python3 python3-pip python3-venv \
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

# ---------- Docker CLI (feature 004-docker-spawning) ----------
# Client only — NO daemon (docker-ce / containerd.io are intentionally
# omitted). The host's daemon is reached via the bind-mounted socket
# at /var/run/docker.sock; see specs/004-docker-spawning/research.md §R1.
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
RUN printf 'PATH="/home/claude/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n' \
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
    @google/gemini-cli \
    @openai/codex

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
COPY scripts/kc-run        /usr/local/bin/kc-run
COPY scripts/kc-ps         /usr/local/bin/kc-ps
COPY scripts/kc-stop       /usr/local/bin/kc-stop
COPY scripts/kc-forward    /usr/local/bin/kc-forward
COPY config/settings.json  /usr/local/share/kroclaude/settings.json
COPY config/CLAUDE.md      /usr/local/share/kroclaude/CLAUDE.md

# ---------- Bundled Claude Code skills (feature 002-skill-bundling) ----------
# Read-only image-time copy. The entrypoint reflects each immediate
# subdirectory into /home/claude/.claude/skills/<name>/ on every boot
# (FR-002), without touching user-installed skills (FR-003).
COPY skills/ /usr/local/share/kroclaude/skills/

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/notify.py \
             /usr/local/bin/kc-run /usr/local/bin/kc-ps \
             /usr/local/bin/kc-stop /usr/local/bin/kc-forward && \
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
