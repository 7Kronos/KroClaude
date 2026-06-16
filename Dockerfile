# syntax=docker/dockerfile:1.7
FROM node:lts-trixie

LABEL org.opencontainers.image.source=https://github.com/7Kronos/KroClaude
LABEL org.opencontainers.image.description="Claude Code shell environment"

# ---------- Build args ----------
# Versions default to empty: each install layer fetches the latest
# upstream release at build time. Override per-build for reproducibility,
# e.g. `--build-arg S6_OVERLAY_VERSION=3.2.0.2`.
ARG S6_OVERLAY_VERSION=
ARG NATS_CLI_VERSION=
ARG SUPABASE_VERSION=
ARG KUBECTL_VERSION=
ARG HELM_VERSION=
ARG K9S_VERSION=
ARG KUBECTX_VERSION=
ARG STERN_VERSION=
ARG KIND_VERSION=
ARG OMNISHARP_VERSION=
ARG TARGETARCH

# ---------- Environment ----------
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    DISPLAY=:99 \
    DBUS_SESSION_BUS_ADDRESS=disabled: \
    CHROMIUM_FLAGS="--no-sandbox --disable-gpu --disable-dev-shm-usage" \
    CHROME_PATH=/usr/bin/chromium \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    # Redirect helm + k9s dotdirs onto the kroclaude-config persistent
    # volume via the CLIs' own env-var overrides. Replaces three
    # symlinks (helm-config, helm-cache, k9s) in entrypoint.sh —
    # cheaper than maintaining migrations and works without a symlink
    # lookup at runtime. Mirrored into /etc/environment for SSH login
    # shells (pam_env). HELM_DATA_HOME also persists helm plugins,
    # which the symlink-based version did not cover.
    HELM_CONFIG_HOME=/home/claude/.claude/helm-config \
    HELM_CACHE_HOME=/home/claude/.claude/helm-cache \
    HELM_DATA_HOME=/home/claude/.claude/helm-data \
    K9S_CONFIG_DIR=/home/claude/.claude/k9s

# ---------- s6-overlay v3 (multi-arch) ----------
# Defaults to the latest GitHub release at build time. Pin via
# `--build-arg S6_OVERLAY_VERSION=<x.y.z.w>` for reproducible builds.
# Both tarballs (noarch + arch-specific) are fetched via curl in this
# RUN layer so they share one shell-resolved version variable —
# Dockerfile `ADD` runs at parse time and cannot see RUN-computed vars.
# `jq` is not yet installed at this layer (apt installs it later), so we
# parse the GitHub API JSON with `grep -oP`.
RUN apt-get update && apt-get install -y --no-install-recommends \
    xz-utils curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN if [ -z "$S6_OVERLAY_VERSION" ]; then \
    S6_OVERLAY_VERSION=$(curl -fsSL https://api.github.com/repos/just-containers/s6-overlay/releases/latest \
    | grep -oP '"tag_name":\s*"v\K[^"]+'); \
    fi && \
    S6_ARCH=$(case "$TARGETARCH" in arm64) echo "aarch64";; *) echo "x86_64";; esac) && \
    curl -fsSL -o /tmp/s6-overlay-noarch.tar.xz \
    "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" && \
    curl -fsSL -o /tmp/s6-overlay-arch.tar.xz \
    "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" && \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-arch.tar.xz && \
    rm /tmp/s6-overlay-*.tar.xz

# ---------- System packages (FR-003) ----------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Shell core
    git curl wget jq ripgrep fd-find unzip zip tree tmux fzf bat sudo bubblewrap \
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

# ---------- NATS CLI ----------
# https://github.com/nats-io/natscli — admin/diagnostic CLI for NATS
# servers, JetStream, KV / object stores. No apt feed; ships per-arch zip
# archives that extract to nats-<ver>-linux-<arch>/nats. Multi-arch via
# TARGETARCH (matches the s6-overlay pattern). The binary lands in
# /usr/local/bin so it's on PATH for interactive shells and entrypoint.
# Defaults to the latest GitHub release at build time; pin via
# `--build-arg NATS_CLI_VERSION=<x.y.z>` for reproducible builds. `jq` is
# available at this layer (installed in the system-packages layer above)
# so we parse the GitHub API JSON with it. The same shell-resolved
# version variable is used for both the download URL and the unzip
# subpath (`nats-<ver>-linux-<arch>/nats`).
RUN if [ -z "$NATS_CLI_VERSION" ]; then \
    NATS_CLI_VERSION=$(curl -fsSL https://api.github.com/repos/nats-io/natscli/releases/latest \
    | jq -r .tag_name | tr -d v); \
    fi && \
    NATS_ARCH=$(case "$TARGETARCH" in arm64) echo "arm64";; *) echo "amd64";; esac) && \
    curl -fsSL -o /tmp/nats.zip \
    "https://github.com/nats-io/natscli/releases/download/v${NATS_CLI_VERSION}/nats-${NATS_CLI_VERSION}-linux-${NATS_ARCH}.zip" && \
    unzip -j /tmp/nats.zip "nats-${NATS_CLI_VERSION}-linux-${NATS_ARCH}/nats" -d /usr/local/bin && \
    chmod +x /usr/local/bin/nats && \
    rm /tmp/nats.zip

# ---------- Supabase CLI ----------
# https://github.com/supabase/cli — local-dev CLI for Supabase projects
# (db migrations, edge functions, type generation). Multi-arch via
# TARGETARCH. Defaults to the latest GitHub release at build time; pin
# via `--build-arg SUPABASE_VERSION=<x.y.z>` for reproducible builds.
# Release tarball is `supabase_<ver>_linux_<arch>.tar.gz` and ships the
# `supabase` binary at root. ${VAR#v} normalization on both auto-detect
# and override paths so a v-prefixed override doesn't 404.
RUN if [ -z "$SUPABASE_VERSION" ]; then \
    SUPABASE_VERSION=$(curl -fsSL https://api.github.com/repos/supabase/cli/releases/latest | jq -r .tag_name); \
    fi && \
    SUPABASE_VERSION=${SUPABASE_VERSION#v} && \
    SUPABASE_ARCH=$(case "$TARGETARCH" in arm64) echo "arm64";; *) echo "amd64";; esac) && \
    curl -fsSL -o /tmp/supabase.tar.gz \
    "https://github.com/supabase/cli/releases/download/v${SUPABASE_VERSION}/supabase_${SUPABASE_VERSION}_linux_${SUPABASE_ARCH}.tar.gz" && \
    tar -xzf /tmp/supabase.tar.gz -C /usr/local/bin supabase && \
    chmod +x /usr/local/bin/supabase && \
    rm /tmp/supabase.tar.gz

# ---------- Kubernetes tooling ----------
# Operational toolkit for connecting to Kubernetes clusters: the canonical
# CLI plus daily-driver TUI / log / context utilities. Each layer fetches
# the latest upstream release at build time; pin individually via the
# matching `--build-arg <NAME>_VERSION=<x.y.z>` for reproducible builds.
# All binaries land in /usr/local/bin so they're on PATH for interactive
# shells, the entrypoint, and SSH sessions. Multi-arch via TARGETARCH.
# Cluster credentials are NOT baked in — operators populate ~/.kube/config
# at runtime. Note: ~/.kube is NOT on the kroclaude-config persistent
# volume (only ~/.claude/ is), so mount a host kubeconfig at runtime or
# symlink ~/.kube → ~/.claude/kube if you need it to survive restarts.

# kubectl — official binary from dl.k8s.io (no GitHub API rate limit).
# stable.txt returns "vX.Y.Z"; we strip the leading v and re-add it in
# the URL. The ${VAR#v} normalization runs on both auto-detect and
# `--build-arg`-override paths so a v-prefixed override doesn't 404.
RUN if [ -z "$KUBECTL_VERSION" ]; then \
    KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt); \
    fi && \
    KUBECTL_VERSION=${KUBECTL_VERSION#v} && \
    K_ARCH=$(case "$TARGETARCH" in arm64) echo "arm64";; *) echo "amd64";; esac) && \
    curl -fsSL -o /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${K_ARCH}/kubectl" && \
    chmod +x /usr/local/bin/kubectl

# helm — upstream install script (handles arch detection + checksum).
# Lands at /usr/local/bin/helm. DESIRED_VERSION takes the v-prefixed tag;
# we prepend the v when HELM_VERSION is set so users pass naked x.y.z.
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get-helm-3 && \
    chmod +x /tmp/get-helm-3 && \
    if [ -n "$HELM_VERSION" ]; then \
    DESIRED_VERSION="v${HELM_VERSION#v}" /tmp/get-helm-3; \
    else \
    /tmp/get-helm-3; \
    fi && \
    rm /tmp/get-helm-3

# k9s — terminal UI for live cluster inspection (derailed/k9s). Tarball
# ships the k9s binary at root alongside LICENSE/README.
RUN if [ -z "$K9S_VERSION" ]; then \
    K9S_VERSION=$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest | jq -r .tag_name); \
    fi && \
    K9S_VERSION=${K9S_VERSION#v} && \
    K9S_ARCH=$(case "$TARGETARCH" in arm64) echo "arm64";; *) echo "amd64";; esac) && \
    curl -fsSL -o /tmp/k9s.tar.gz \
    "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_${K9S_ARCH}.tar.gz" && \
    tar -xzf /tmp/k9s.tar.gz -C /usr/local/bin k9s && \
    chmod +x /usr/local/bin/k9s && \
    rm /tmp/k9s.tar.gz

# kubectx + kubens — context/namespace switchers (ahmetb/kubectx). Each
# binary ships in its own tarball; arch naming uses x86_64 (not amd64)
# on intel but matches on arm64.
RUN if [ -z "$KUBECTX_VERSION" ]; then \
    KUBECTX_VERSION=$(curl -fsSL https://api.github.com/repos/ahmetb/kubectx/releases/latest | jq -r .tag_name); \
    fi && \
    KUBECTX_VERSION=${KUBECTX_VERSION#v} && \
    KUBECTX_ARCH=$(case "$TARGETARCH" in arm64) echo "arm64";; *) echo "x86_64";; esac) && \
    curl -fsSL -o /tmp/kubectx.tar.gz \
    "https://github.com/ahmetb/kubectx/releases/download/v${KUBECTX_VERSION}/kubectx_v${KUBECTX_VERSION}_linux_${KUBECTX_ARCH}.tar.gz" && \
    tar -xzf /tmp/kubectx.tar.gz -C /usr/local/bin kubectx && \
    curl -fsSL -o /tmp/kubens.tar.gz \
    "https://github.com/ahmetb/kubectx/releases/download/v${KUBECTX_VERSION}/kubens_v${KUBECTX_VERSION}_linux_${KUBECTX_ARCH}.tar.gz" && \
    tar -xzf /tmp/kubens.tar.gz -C /usr/local/bin kubens && \
    chmod +x /usr/local/bin/kubectx /usr/local/bin/kubens && \
    rm /tmp/kubectx.tar.gz /tmp/kubens.tar.gz

# stern — multi-pod multi-container log tailer (stern/stern).
RUN if [ -z "$STERN_VERSION" ]; then \
    STERN_VERSION=$(curl -fsSL https://api.github.com/repos/stern/stern/releases/latest | jq -r .tag_name); \
    fi && \
    STERN_VERSION=${STERN_VERSION#v} && \
    STERN_ARCH=$(case "$TARGETARCH" in arm64) echo "arm64";; *) echo "amd64";; esac) && \
    curl -fsSL -o /tmp/stern.tar.gz \
    "https://github.com/stern/stern/releases/download/v${STERN_VERSION}/stern_${STERN_VERSION}_linux_${STERN_ARCH}.tar.gz" && \
    tar -xzf /tmp/stern.tar.gz -C /usr/local/bin stern && \
    chmod +x /usr/local/bin/stern && \
    rm /tmp/stern.tar.gz

# kind — Kubernetes-in-Docker (kubernetes-sigs/kind). Pairs with the dind
# sidecar in docker-compose.yaml: `kind create cluster` spins up a local
# control plane without needing a remote cluster. Single binary release.
RUN if [ -z "$KIND_VERSION" ]; then \
    KIND_VERSION=$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | jq -r .tag_name); \
    fi && \
    KIND_VERSION=${KIND_VERSION#v} && \
    KIND_ARCH=$(case "$TARGETARCH" in arm64) echo "arm64";; *) echo "amd64";; esac) && \
    curl -fsSL -o /usr/local/bin/kind \
    "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-linux-${KIND_ARCH}" && \
    chmod +x /usr/local/bin/kind

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
# The entrypoint regenerates this file on every boot so compose-supplied
# runtime vars (API keys, tokens, etc.) reach SSH login shells too — see
# the "/etc/environment propagation" block in scripts/entrypoint.sh.
# This baseline write covers the case where the image is started with a
# non-default entrypoint that skips the regeneration.
RUN printf 'PATH="/home/claude/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\nDOCKER_HOST="tcp://localhost:2375"\nHELM_CONFIG_HOME="/home/claude/.claude/helm-config"\nHELM_CACHE_HOME="/home/claude/.claude/helm-cache"\nHELM_DATA_HOME="/home/claude/.claude/helm-data"\nK9S_CONFIG_DIR="/home/claude/.claude/k9s"\n' \
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
    @openai/codex \
    oh-my-claude-sisyphus \
    typescript-language-server \
    pyright \
    bash-language-server \
    yaml-language-server \
    vscode-langservers-extracted \
    dockerfile-language-server-nodejs

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

# ---------- OmniSharp (.NET LSP, used by the OMC csharp plugin) ----------
# OmniSharp-Roslyn (OmniSharp/omnisharp-roslyn) replaces the prior
# csharp-ls install because the OMC csharp plugin shells out to the
# `omnisharp` binary. The net6.0 build's runtimeconfig.json declares
# `rollForward: LatestMajor`, so it runs on the .NET 9/10/11 already
# installed above without needing a separate .NET 6 runtime in the
# image. Tarball extracts a flat dir of dlls + an `OmniSharp` launcher;
# we drop the dir under /usr/local/share/omnisharp/ and symlink the
# launcher to /usr/local/bin/omnisharp so it's on PATH. Latest at
# build time; pin via `--build-arg OMNISHARP_VERSION=<x.y.z>`.
RUN if [ -z "$OMNISHARP_VERSION" ]; then \
    OMNISHARP_VERSION=$(curl -fsSL https://api.github.com/repos/OmniSharp/omnisharp-roslyn/releases/latest | jq -r .tag_name); \
    fi && \
    OMNISHARP_VERSION=${OMNISHARP_VERSION#v} && \
    OMNI_ARCH=$(case "$TARGETARCH" in arm64) echo "arm64";; *) echo "x64";; esac) && \
    curl -fsSL -o /tmp/omnisharp.tar.gz \
    "https://github.com/OmniSharp/omnisharp-roslyn/releases/download/v${OMNISHARP_VERSION}/omnisharp-linux-${OMNI_ARCH}-net6.0.tar.gz" && \
    install -d /usr/local/share/omnisharp && \
    tar -xzf /tmp/omnisharp.tar.gz -C /usr/local/share/omnisharp && \
    chmod +x /usr/local/share/omnisharp/OmniSharp && \
    ln -sf /usr/local/share/omnisharp/OmniSharp /usr/local/bin/omnisharp && \
    rm /tmp/omnisharp.tar.gz

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
COPY scripts/rm-guard.sh   /usr/local/bin/rm-guard.sh
# ---------- Bundled Claude Code customization (feature 005-config-bundling) ----------
# Single read-only image-time copy of the entire /config/ tree, replacing
# the granular per-file COPYs and the legacy /skills/ COPY. The entrypoint
# reflects each per-type subdirectory into ~/.claude/<type>/ on every boot
# (settings.json + CLAUDE.md remain sentinel-gated first-boot-only seeds —
# feature 001 contract preserved). See specs/005-config-bundling/.
COPY config/ /usr/local/share/kroclaude/config/

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/notify.py /usr/local/bin/rm-guard.sh && \
    install -d -o claude -g claude /home/claude/.claude

# ---------- Bash history persistence (research R9) ----------
RUN printf '\nexport HISTFILE=/home/claude/.claude/.bash_history\nexport HISTSIZE=10000\nexport HISTFILESIZE=20000\n' \
    >> /home/claude/.bashrc && \
    chown claude:claude /home/claude/.bashrc

# ---------- Shell ergonomics (cherry-picked from dotfiles/home.nix) ----------
# Wires starship prompt, zoxide smart-cd, direnv auto-load, eza ls
# aliases, and fzf key bindings + completion + bat/fd integration into
# claude's interactive bash sessions. Each integration is command-guarded
# so a missing tool downgrades cleanly instead of breaking login.
RUN <<'DOCKERFILE'
cat >> /home/claude/.bashrc <<'BASHRC'

# Shell ergonomics
export EDITOR=nano

command -v starship >/dev/null && eval "$(starship init bash)"
command -v zoxide   >/dev/null && eval "$(zoxide init bash)"
command -v direnv   >/dev/null && eval "$(direnv hook bash)"

if command -v eza >/dev/null; then
    alias ls='eza --icons=auto'
    alias ll='eza --icons=auto -l'
    alias la='eza --icons=auto -la'
    alias lt='eza --icons=auto --tree'
fi

if command -v fzf >/dev/null; then
    [ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && \
        source /usr/share/doc/fzf/examples/key-bindings.bash
    [ -f /usr/share/doc/fzf/examples/completion.bash ] && \
        source /usr/share/doc/fzf/examples/completion.bash
    export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
    export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_CTRL_T_OPTS="--preview 'bat --style=numbers --color=always --line-range :500 {}'"
    export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
fi
BASHRC
chown claude:claude /home/claude/.bashrc
DOCKERFILE

# ---------- `remote` shell function (claude remote-control launcher) ----------
# Convenience launcher: spins up a Remote Control server in $PWD (controllable
# from claude.ai/code), spawns one isolated git worktree per on-demand session,
# prefixes session names with $(basename $PWD), runs sessions with permissions
# bypassed, and pre-flags $PWD as trusted in ~/.claude.json so the workspace-
# trust dialog never blocks bootstrap. ~/.claude.json is a symlink into the
# persistent ~/.claude/ volume — the jq edit writes through `cat >` (not mv)
# so we don't replace the symlink with a regular file.
RUN <<'DOCKERFILE'
cat >> /home/claude/.bashrc <<'BASHRC'

remote() {
    local prefix
    prefix=$(basename "$PWD")

    if command -v jq >/dev/null 2>&1 && [ -e "$HOME/.claude.json" ]; then
        local tmp
        if tmp=$(mktemp) && jq --arg p "$PWD" \
                '.projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})' \
                "$HOME/.claude.json" > "$tmp"; then
            cat "$tmp" > "$HOME/.claude.json"
        fi
        [ -n "${tmp:-}" ] && rm -f "$tmp"
    fi

    claude remote-control \
        --spawn worktree \
        --remote-control-session-name-prefix "$prefix" \
        --permission-mode bypassPermissions \
        "$@"
}
BASHRC
chown claude:claude /home/claude/.bashrc
DOCKERFILE

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
