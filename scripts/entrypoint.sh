#!/bin/bash
# KroClaude — Container Entrypoint
# First-boot config seeding (sentinel-guarded) → handoff to s6-overlay (PID 1).
# Per FR-014: no PUID/PGID remap, no ~/.claude.json copy loop, no per-CLI
# symlink dance for excluded CLIs, no variant-aware fork.
#
# Authoritative refs:
#   - specs/001-claude-shell-base/research.md (R4, R7, R11)
#   - specs/001-claude-shell-base/contracts/volumes.md
set -euo pipefail

CLAUDE_HOME=/home/claude
CONFIG_DIR="$CLAUDE_HOME/.claude"
SOURCE_DIR=/usr/local/share/kroclaude
SENTINEL="$CONFIG_DIR/.kroclaude-bootstrapped"

# ---------- First-boot seeding ----------
if [ ! -f "$SENTINEL" ]; then
    install -d -o claude -g claude "$CONFIG_DIR" "$CLAUDE_HOME/.codex" "$CLAUDE_HOME/.gemini"

    cp "$SOURCE_DIR/settings.json" "$CONFIG_DIR/settings.json"
    cp "$SOURCE_DIR/CLAUDE.md"     "$CONFIG_DIR/CLAUDE.md"

    cat > "$CLAUDE_HOME/.codex/config.toml" <<'TOML'
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[features]
codex_hooks = true
TOML

    cat > "$CLAUDE_HOME/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/bin/notify.py stop",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
JSON

    cat > "$CLAUDE_HOME/.gemini/settings.json" <<'JSON'
{
  "hooks": {
    "SessionEnd": [
      {
        "matcher": "*",
        "hooks": [
          {
            "name": "notify",
            "type": "command",
            "command": "/usr/local/bin/notify.py stop",
            "timeout": 30000
          }
        ]
      }
    ]
  }
}
JSON

    runuser -u claude -- git config --global safe.directory /workspace
    runuser -u claude -- git config --global user.name  "${GIT_USER_NAME:-KroClaude User}"
    runuser -u claude -- git config --global user.email "${GIT_USER_EMAIL:-noreply@kroclaude.local}"

    # ~/.claude.json lives one level above the config volume; one-shot
    # symlink into the volume so writes persist (research R11).
    if [ ! -e "$CLAUDE_HOME/.claude.json" ] && [ ! -L "$CLAUDE_HOME/.claude.json" ]; then
        ln -s "$CONFIG_DIR/.claude.json" "$CLAUDE_HOME/.claude.json"
        chown -h claude:claude "$CLAUDE_HOME/.claude.json"
    fi
    if [ ! -f "$CONFIG_DIR/.claude.json" ]; then
        echo '{"hasCompletedOnboarding":true,"installMethod":"native"}' > "$CONFIG_DIR/.claude.json"
    fi

    chown -R claude:claude "$CONFIG_DIR" "$CLAUDE_HOME/.codex" "$CLAUDE_HOME/.gemini"
    touch "$SENTINEL"
    chown claude:claude "$SENTINEL"
    echo "[entrypoint] First-boot seed complete."
fi

# ---------- Bundled skill reflection (feature 002-skill-bundling) ----------
# Mirrors /usr/local/share/kroclaude/skills/<name>/ into
# /home/claude/.claude/skills/<name>/ on EVERY boot (NOT gated by the
# sentinel — FR-002). User-installed skills (different names) are never
# enumerated or touched (FR-003). No-op when the source is missing or
# empty (FR-004).
SKILLS_SRC=/usr/local/share/kroclaude/skills
SKILLS_DEST="$CONFIG_DIR/skills"
if [ -d "$SKILLS_SRC" ] && [ -n "$(ls -A "$SKILLS_SRC" 2>/dev/null)" ]; then
    install -d -o claude -g claude "$SKILLS_DEST"
    for skill_src in "$SKILLS_SRC"/*/; do
        [ -d "$skill_src" ] || continue
        skill_name=$(basename "$skill_src")
        rm -rf "$SKILLS_DEST/$skill_name"
        cp -r "$skill_src" "$SKILLS_DEST/$skill_name"
        chown -R claude:claude "$SKILLS_DEST/$skill_name"
    done
fi

# ---------- SSH host keys + authorized_keys seeding (feature 003-ssh-access) ----------
# Host keys are generated ONCE (FR-009 fingerprint stability) inside the
# kroclaude-config volume so they survive container recreation.
# authorized_keys is reseeded from KROCLAUDE_SSH_AUTHORIZED_KEY on EVERY
# boot (FR-007 — latest env wins; NOT sentinel-guarded).
SSH_HOST_KEY_DIR="$CONFIG_DIR/.ssh-host-keys"
install -d -m 0700 -o claude -g claude "$SSH_HOST_KEY_DIR"
if [ ! -f "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key" ]; then
    ssh-keygen -t ed25519 -N '' -f "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key" >/dev/null
    chown claude:claude "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key" "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key.pub"
    chmod 0600 "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key"
    chmod 0644 "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key.pub"
fi
if [ ! -f "$SSH_HOST_KEY_DIR/ssh_host_rsa_key" ]; then
    ssh-keygen -t rsa -b 3072 -N '' -f "$SSH_HOST_KEY_DIR/ssh_host_rsa_key" >/dev/null
    chown claude:claude "$SSH_HOST_KEY_DIR/ssh_host_rsa_key" "$SSH_HOST_KEY_DIR/ssh_host_rsa_key.pub"
    chmod 0600 "$SSH_HOST_KEY_DIR/ssh_host_rsa_key"
    chmod 0644 "$SSH_HOST_KEY_DIR/ssh_host_rsa_key.pub"
fi

install -d -m 0700 -o claude -g claude "$CLAUDE_HOME/.ssh"
printf '%s\n' "${KROCLAUDE_SSH_AUTHORIZED_KEY:-}" > "$CLAUDE_HOME/.ssh/authorized_keys"
chmod 0600 "$CLAUDE_HOME/.ssh/authorized_keys"
chown claude:claude "$CLAUDE_HOME/.ssh/authorized_keys"

export DISPLAY=:99

exec /init "$@"
