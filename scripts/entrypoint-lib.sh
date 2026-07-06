# entrypoint-lib.sh — shared context for /etc/kroclaude/entrypoint.d/
# stages. Sourced (not executed) by every stage; keep it to variables
# and tiny helpers.
#
# Authoritative refs:
#   - specs/001-claude-shell-base/research.md (R4, R7, R11)
#   - specs/005-config-bundling/contracts/
CLAUDE_HOME=/home/claude
CONFIG_DIR="$CLAUDE_HOME/.claude"
SOURCE_DIR=/usr/local/share/kroclaude/config
FILTER_DIR=/usr/local/share/kroclaude/filters
SENTINEL="$CONFIG_DIR/.kroclaude-bootstrapped"

warn() { echo "[entrypoint] WARN: $*" >&2; }
