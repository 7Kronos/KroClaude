# mcp-merge.jq — merge bundled mcp-servers.d fragments into a target
# .mcp.json. Consumes $fragments: a JSON ARRAY of whole fragment objects
# in lex order.
#
# Precedence (feature 005 FR-008):
#   - within bundle: lex-order, later fragment wins on key collision
#   - bundle vs target: bundled wins (matches feature 002 FR-003)
# User-installed servers under non-colliding keys are preserved.
#
# Contract + proofs: specs/005-config-bundling/contracts/merge-filters.md
.mcpServers = (
  reduce ($fragments[] | (.mcpServers // {})) as $b
    ((.mcpServers // {}); . * $b)
)
