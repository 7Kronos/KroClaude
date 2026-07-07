#!/bin/bash
# tests/unit/test_merge_filters.sh — offline unit tests for the two jq
# merge filters used by entrypoint stage 30 (scripts/filters/*.jq).
# Needs only jq; no Docker. Run from repo root:
#   bash tests/unit/test_merge_filters.sh
#
# Covers the documented precedence rules (feature 005 FR-008):
#   - within bundle: lex-order, later fragment wins
#   - bundle vs target: bundled wins; user-only keys survive
#   - hooks: per-(event, matcher) merge, distinct matchers accumulate
#   - idempotence: applying the merge twice is byte-identical
set -euo pipefail

FILTER_DIR="$(dirname "$0")/../../scripts/filters"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# ---------------- MCP merge ----------------
cat > "$TMP/target-mcp.json" <<'EOF'
{"mcpServers":{"local-only":{"command":"echo"},"postgres":{"command":"stale"}}}
EOF
cat > "$TMP/00-frag.json" <<'EOF'
{"mcpServers":{"postgres":{"command":"v1"}}}
EOF
cat > "$TMP/99-frag.json" <<'EOF'
{"mcpServers":{"postgres":{"command":"v2"},"extra":{"command":"x"}}}
EOF

fragments=$(jq -s '.' "$TMP/00-frag.json" "$TMP/99-frag.json")
merged=$(jq --argjson fragments "$fragments" -f "$FILTER_DIR/mcp-merge.jq" "$TMP/target-mcp.json")

jq -e '.mcpServers["local-only"].command == "echo"' <<<"$merged" >/dev/null \
    || fail "mcp: user-only key clobbered"
pass "mcp: user-only key preserved"
jq -e '.mcpServers.postgres.command == "v2"' <<<"$merged" >/dev/null \
    || fail "mcp: lex-last fragment should win (got $(jq -c .mcpServers.postgres <<<"$merged"))"
pass "mcp: lex-last-wins over both target and earlier fragment"
jq -e '.mcpServers.extra.command == "x"' <<<"$merged" >/dev/null \
    || fail "mcp: new bundled key missing"
pass "mcp: new bundled key added"

merged2=$(jq --argjson fragments "$fragments" -f "$FILTER_DIR/mcp-merge.jq" <<<"$merged")
[ "$merged" = "$merged2" ] || fail "mcp: merge not idempotent"
pass "mcp: idempotent"

# ---------------- Hooks merge ----------------
cat > "$TMP/target-hooks.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"notify stop"}]}]}}
EOF
cat > "$TMP/00-hooks.json" <<'EOF'
{"hooks":{"PostToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"echo BASE"}]},
  {"matcher":"Edit","hooks":[{"type":"command","command":"echo EDIT"}]}
]}}
EOF
cat > "$TMP/99-hooks.json" <<'EOF'
{"hooks":{"PostToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"echo OVERRIDE"}]}
]}}
EOF

fragments=$(jq -s '.' "$TMP/00-hooks.json" "$TMP/99-hooks.json")
merged=$(jq --argjson fragments "$fragments" -f "$FILTER_DIR/hooks-merge.jq" "$TMP/target-hooks.json")

jq -e '.hooks.Stop[0].hooks[0].command == "notify stop"' <<<"$merged" >/dev/null \
    || fail "hooks: target-only Stop event clobbered"
pass "hooks: target-only event preserved"
bash_cmds=$(jq -r '.hooks.PostToolUse[] | select(.matcher=="Bash") | .hooks[].command' <<<"$merged")
[ "$bash_cmds" = "echo OVERRIDE" ] \
    || fail "hooks: Bash matcher should hold ONLY the lex-last command (got: $bash_cmds)"
pass "hooks: lex-last-wins per (event, matcher)"
jq -e '.hooks.PostToolUse[] | select(.matcher=="Edit") | .hooks[0].command == "echo EDIT"' <<<"$merged" >/dev/null \
    || fail "hooks: distinct matcher from earlier fragment lost"
pass "hooks: distinct matchers accumulate across fragments"

merged2=$(jq --argjson fragments "$fragments" -f "$FILTER_DIR/hooks-merge.jq" <<<"$merged")
[ "$merged" = "$merged2" ] || fail "hooks: merge not idempotent"
pass "hooks: idempotent"

echo "PASS"
