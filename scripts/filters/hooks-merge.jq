# hooks-merge.jq — merge bundled hooks.d fragments into a target
# settings.json. Consumes $fragments: a JSON ARRAY of whole fragment
# objects in lex order.
#
# A plain `*` object-merge would let the lex-last fragment's
# .hooks.<event> ARRAY clobber earlier fragments' entries for DIFFERENT
# matchers under the same event — hence the concat-then-group_by(matcher)
# shape: entries for distinct matchers accumulate, entries for the same
# matcher merge with lex-last-wins.
#
# Precedence (feature 005 FR-008):
#   - within bundle: lex-order, later fragment wins per (event, matcher)
#   - bundle vs target: bundled wins; target-only events/matchers survive
#
# Contract + proofs: specs/005-config-bundling/contracts/merge-filters.md
def merge_hooks_event(existing; bundled):
  ((existing // []) + (bundled // []))
  | group_by(.matcher // "")
  | map(reduce .[] as $x ({}; . * $x));

.hooks = (
  (.hooks // {}) as $cur
  | (($cur | keys) + ([$fragments[] | (.hooks // {}) | keys] | flatten) | unique) as $events
  | reduce $events[] as $e
      ($cur;
       .[$e] = merge_hooks_event(
                 .[$e];
                 [$fragments[] | (.hooks // {})[$e] // []] | add
               ))
)
