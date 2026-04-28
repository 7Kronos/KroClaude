# Contract: jq Merge Filters

**Feature**: 005-config-bundling
**Spec**: [../spec.md](../spec.md) · **Plan**: [../plan.md](../plan.md)

This document is the authoritative text of the two jq filters used by
the `merge_fragments` helper (see
[reflection-helpers.md](reflection-helpers.md)). Any change to the
filter text below is a breaking change and MUST be reflected in the
smoke test ([`tests/smoke/test_us6.sh`](../../../tests/smoke/test_us6.sh)).

> **Implementation update (2026-04-28)**: the original draft below
> assumed `merge_fragments` pre-folded all fragments into a single
> `$bundle` object via `jq -s '.[0] * .[1]'`. Implementation revealed
> that jq's `*` operator REPLACES nested arrays rather than
> concatenating them, which would let the lex-last fragment's
> `.hooks.<event>` array clobber earlier fragments' entries for
> different matchers. The shipping implementation passes a JSON ARRAY
> of all fragments as `$fragments` and lets the filter accumulate
> per-event-key. The corrected, authoritative filter text is below;
> the `$bundle` design discussion in the rest of the file is
> preserved for traceability.

## Shipping filter text (authoritative — matches `scripts/entrypoint.sh`)

**MCP**:

```jq
.mcpServers = (
  reduce ($fragments[] | (.mcpServers // {})) as $b
    ((.mcpServers // {}); . * $b)
)
```

**Hooks**:

```jq
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
```

Both filters are invoked as `jq --argjson fragments "$fragments_json" "$filter" "$target"` where `$fragments_json` is the lex-ordered JSON array of validated fragment files. Idempotency invariant from FR-007 holds: re-running the same fragments against the merged target produces a byte-identical result, because (a) `*` is idempotent on objects, (b) `group_by + reduce * $x` is a fixed point on its own output for hooks.

---

## Original design (preserved for traceability)

---

## MCP servers filter

### Filter text

```jq
.mcpServers = ((.mcpServers // {}) * $bundle)
```

This filter is stored in a bash variable and passed as
`<jq_filter_var_name>` to `merge_fragments`. The invocation:

```bash
MCP_MERGE_FILTER='.mcpServers = ((.mcpServers // {}) * $bundle)'

merge_fragments \
    "/usr/local/share/kroclaude/config/mcp-servers.d" \
    "/home/claude/.claude/.mcp.json" \
    "MCP_MERGE_FILTER" \
    '{"mcpServers":{}}'
```

### Semantics, line by line

| Expression | Meaning |
|------------|---------|
| `.mcpServers` (LHS of `=`) | Select the `mcpServers` key in the input document (`$target`, the current `~/.claude/.mcp.json` content) |
| `(.mcpServers // {})` | Current value of `.mcpServers` in the target, defaulting to `{}` if absent or null |
| `* $bundle` | Deep-merge with `jq`'s `*` operator. `$bundle` is the folded bundle object (result of the fold phase). For plain objects, `*` performs a right-key-wins recursive merge: keys only in the left operand are preserved; keys only in the right operand are added; keys in both are resolved by the right operand's value. |
| `.mcpServers = (…)` | Assign the merged result back to the `mcpServers` key, leaving all other keys in the target document untouched. |

**Net effect**: every `mcpServers` entry in the bundle overwrites the
same-named entry in the target (bundled-wins). Every `mcpServers`
entry in the target whose name is NOT in the bundle is preserved
unchanged. Other top-level keys in `~/.claude/.mcp.json` (if any)
are preserved.

The `jq -n --argjson bundle "$bundle" --argjson target "$current_target"
'$target | <filter>'` invocation passes both the bundle and the
existing target as named arguments so the filter body can reference
them without a pipe.

### Idempotency proof sketch

Let `T` be the target file content and `B` be the folded bundle.
After one application:

```
T' = T with .mcpServers set to ((T.mcpServers // {}) * B)
```

After a second application with the same `B`:

```
T'' = T' with .mcpServers set to ((T'.mcpServers // {}) * B)
    = T' with .mcpServers set to (((T.mcpServers // {}) * B) * B)
```

Because `jq`'s `*` is idempotent for objects when the right operand
is unchanged (`A * B * B = A * B` for all values in `B` that are
scalars or non-overlapping nested objects), `T'' = T'`. The filter
is idempotent given constant `B`. (FR-007.)

---

## Hooks filter

### Filter text

```jq
def merge_hooks_event(existing; bundled):
  ((existing // []) + (bundled // []))
  | group_by(.matcher // "")
  | map(reduce .[] as $x ({}; . * $x));

.hooks = (
  (.hooks // {}) as $cur
  | reduce ($bundle | to_entries[]) as $e
      ($cur; .[$e.key] = merge_hooks_event(.[$e.key]; $e.value))
)
```

This filter is stored in a bash variable and passed to `merge_fragments`:

```bash
HOOKS_MERGE_FILTER='
def merge_hooks_event(existing; bundled):
  ((existing // []) + (bundled // []))
  | group_by(.matcher // "")
  | map(reduce .[] as $x ({}; . * $x));

.hooks = (
  (.hooks // {}) as $cur
  | reduce ($bundle | to_entries[]) as $e
      ($cur; .[$e.key] = merge_hooks_event(.[$e.key]; $e.value))
)
'

merge_fragments \
    "/usr/local/share/kroclaude/config/hooks.d" \
    "/home/claude/.claude/settings.json" \
    "HOOKS_MERGE_FILTER" \
    '{}'
```

### Semantics, line by line

#### The `merge_hooks_event` helper function

```jq
def merge_hooks_event(existing; bundled):
  ((existing // []) + (bundled // []))
  | group_by(.matcher // "")
  | map(reduce .[] as $x ({}; . * $x));
```

| Expression | Meaning |
|------------|---------|
| `existing // []` | The array of hook-group objects already under a given event key (e.g. `settings.hooks.PostToolUse`), defaulting to `[]` if absent |
| `bundled // []` | The array of hook-group objects from the bundle for the same event key, defaulting to `[]` |
| `(existing // []) + (bundled // [])` | Concatenate the two arrays. All groups (from both target and bundle) are now in one flat list |
| `group_by(.matcher // "")` | Group the concatenated list by the `matcher` string (or `""` if absent). Each group is an array of hook-group objects sharing the same `matcher` value |
| `map(reduce .[] as $x ({}; . * $x))` | For each matcher group, reduce its members into a single object by deep-merging with `*`. Later items in the group (i.e. bundled items, which were appended second) win on direct key collision within the group object |

**Net effect per event type**: hook groups are deduplicated by
`matcher`. When the target and the bundle both define a group for
the same `matcher`, their fields are merged (`*`), with the bundled
group's fields winning on collision. Hook groups whose `matcher`
appears in only one source are kept as-is.

#### The outer reduction

```jq
.hooks = (
  (.hooks // {}) as $cur
  | reduce ($bundle | to_entries[]) as $e
      ($cur; .[$e.key] = merge_hooks_event(.[$e.key]; $e.value))
)
```

| Expression | Meaning |
|------------|---------|
| `(.hooks // {}) as $cur` | Current value of `.hooks` in the target document, defaulting to `{}` |
| `$bundle \| to_entries[]` | Iterate over each `{ key, value }` entry in the bundle object. Each key is a hook event type (e.g. `"PostToolUse"`); each value is an array of hook groups |
| `reduce … as $e ($cur; .[$e.key] = merge_hooks_event(…))` | Fold over the bundle's event types. For each event type `$e.key`, replace the accumulator's `$e.key` entry with the merged result of `merge_hooks_event` |
| `.hooks = (…)` | Assign the merged hooks map back to `.hooks`, leaving all other keys in `settings.json` untouched |

**Net effect at top level**: every event type key in the bundle is
merged into the target's `hooks` map. Event type keys in the target
that are NOT in the bundle are preserved unchanged via `$cur`'s
pass-through.

### Idempotency proof sketch

Let `T` be the target `settings.json` and `B` be the folded hook
bundle. After one application, `T'.hooks` is the fully merged hooks
map. After a second application with the same `B`:

- For each event type `k` in `B`: `merge_hooks_event(T'.hooks[k],
  B[k])` is called. `T'.hooks[k]` already contains all groups from
  `B[k]` merged in. The `group_by(.matcher)` step groups them
  identically; the `reduce .[] as $x ({}; . * $x)` step produces the
  same merged-group objects. No new keys are added; no existing keys
  change value.
- For each event type `k` NOT in `B`: `T'.hooks[k]` is passed
  through from `$cur` unchanged.

Therefore `T'' = T'`. (FR-007.)

---

## Test vectors

### MCP filter test vectors

**Vector 1 — empty target + bundle with one server**

Input target (`~/.claude/.mcp.json`): `{}`

Input bundle (from single fragment):
```json
{
  "mcpServers": {
    "postgres": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-postgres"]
    }
  }
}
```

Expected output:
```json
{
  "mcpServers": {
    "postgres": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-postgres"]
    }
  }
}
```

---

**Vector 2 — target has colliding key, bundle wins**

Input target:
```json
{
  "mcpServers": {
    "postgres": {
      "command": "old-postgres-binary",
      "args": []
    },
    "local-dev": {
      "command": "my-local-server",
      "args": []
    }
  }
}
```

Input bundle:
```json
{
  "mcpServers": {
    "postgres": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-postgres"]
    }
  }
}
```

Expected output:
```json
{
  "mcpServers": {
    "postgres": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-postgres"]
    },
    "local-dev": {
      "command": "my-local-server",
      "args": []
    }
  }
}
```

`local-dev` is preserved (not in bundle). `postgres` is the bundled
value (bundled wins).

---

**Vector 3 — target has unrelated top-level key**

Input target:
```json
{
  "mcpServers": {
    "existing": { "command": "existing-server", "args": [] }
  },
  "unrelatedKey": "preserved"
}
```

Input bundle:
```json
{
  "mcpServers": {
    "new-server": { "command": "new-server", "args": [] }
  }
}
```

Expected output:
```json
{
  "mcpServers": {
    "existing": { "command": "existing-server", "args": [] },
    "new-server": { "command": "new-server", "args": [] }
  },
  "unrelatedKey": "preserved"
}
```

`unrelatedKey` is untouched. The filter only assigns `.mcpServers`.

---

### Hooks filter test vectors

**Vector 1 — empty target + bundle with one event type**

Input target (`~/.claude/settings.json`): `{}`

Input bundle:
```json
{
  "PostToolUse": [
    {
      "matcher": "Write|Edit|MultiEdit",
      "hooks": [{ "type": "command", "command": "/usr/local/bin/kc-lint" }]
    }
  ]
}
```

Expected output (`.hooks` portion):
```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [{ "type": "command", "command": "/usr/local/bin/kc-lint" }]
      }
    ]
  }
}
```

---

**Vector 2 — target has same event type, different matcher — both preserved**

Input target `.hooks`:
```json
{
  "PostToolUse": [
    {
      "matcher": "Read",
      "hooks": [{ "type": "command", "command": "/usr/local/bin/notify.py" }]
    }
  ]
}
```

Input bundle:
```json
{
  "PostToolUse": [
    {
      "matcher": "Write|Edit|MultiEdit",
      "hooks": [{ "type": "command", "command": "/usr/local/bin/kc-lint" }]
    }
  ]
}
```

Expected output `.hooks`:
```json
{
  "PostToolUse": [
    {
      "matcher": "Read",
      "hooks": [{ "type": "command", "command": "/usr/local/bin/notify.py" }]
    },
    {
      "matcher": "Write|Edit|MultiEdit",
      "hooks": [{ "type": "command", "command": "/usr/local/bin/kc-lint" }]
    }
  ]
}
```

Both matchers are distinct. No collision. Both hook groups survive.
(Ordering within the array follows `group_by` output order, which
is sorted by matcher string.)

---

**Vector 3 — target has unrelated top-level key + same event, same matcher — bundled wins**

Input target `settings.json`:
```json
{
  "theme": "dark",
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [{ "type": "command", "command": "/usr/local/bin/old-linter" }],
        "userKey": "preserved-if-not-overwritten"
      }
    ]
  }
}
```

Input bundle:
```json
{
  "PostToolUse": [
    {
      "matcher": "Write|Edit|MultiEdit",
      "hooks": [{ "type": "command", "command": "/usr/local/bin/kc-lint" }]
    }
  ]
}
```

Expected output `settings.json`:
```json
{
  "theme": "dark",
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [{ "type": "command", "command": "/usr/local/bin/kc-lint" }],
        "userKey": "preserved-if-not-overwritten"
      }
    ]
  }
}
```

- `theme` is untouched (not `.hooks`).
- The `matcher: "Write|Edit|MultiEdit"` group is merged: `userKey`
  (only in user's group) is preserved; `hooks` (in both) is won by
  the bundled value (`kc-lint` replaces `old-linter`).

---

## Stability guarantees

- Both filter texts above are part of the contract. Any change to
  them that alters output for existing valid inputs is a breaking
  change.
- The `$bundle` and `$target` argument names in the jq invocation are
  part of the contract — the filter text references them by name.
- The fold operator (`jq -s '.[0] * .[1]'`) is not in this file but
  is specified in [reflection-helpers.md](reflection-helpers.md).
  Changes to the fold operator affect the `$bundle` value passed to
  these filters.
