# Quickstart: Unified Claude Code Customization Bundle

**Feature**: 005-config-bundling
**Spec**: [spec.md](spec.md) · **Plan**: [plan.md](plan.md)

This quickstart shows the "drop a file and rebuild" workflow for each
of the seven customization types, what happens on name collisions, and
how to verify that reflection worked.

---

## Maintainer workflow (per customization type)

All seven types follow the same four-step loop: write a file or
directory into the right place under `config/`, rebuild the image,
restart the container, and verify. No edits to the entrypoint, the
Dockerfile, or any registry are needed.

### 1. Skill — `config/skills/<name>/`

```bash
# Create the skill directory and required SKILL.md
mkdir -p config/skills/db-helper
cat > config/skills/db-helper/SKILL.md <<'EOF'
# db-helper

Skill for working with the team Postgres schema.

## Usage
...
EOF

# Rebuild and restart
docker compose up -d --build

# Verify
docker exec -u claude kroclaude \
    ls -la /home/claude/.claude/skills/db-helper/SKILL.md
# → -rw-r--r-- 1 claude claude  ... SKILL.md
```

Skills may contain additional helper files beyond `SKILL.md`. The
entire `config/skills/<name>/` subdirectory is copied verbatim.

---

### 2. Slash command — `config/commands/<name>.md`

```bash
# Drop a single Markdown file per command
cat > config/commands/triage.md <<'EOF'
---
description: Triage an incoming issue
---

Review the issue, classify severity, and suggest next steps.
EOF

docker compose up -d --build

docker exec -u claude kroclaude \
    ls /home/claude/.claude/commands/triage.md
```

All files in `config/commands/` with a `.md` extension are reflected.
Files without a `.md` extension are silently skipped (the helper
filters by extension).

---

### 3. Sub-agent — `config/agents/<name>/agent.md`

```bash
mkdir -p config/agents/db-migration-reviewer
cat > config/agents/db-migration-reviewer/agent.md <<'EOF'
# db-migration-reviewer

Reviews database migration scripts for safety and correctness.

## Responsibilities
...
EOF

docker compose up -d --build

docker exec -u claude kroclaude \
    ls /home/claude/.claude/agents/db-migration-reviewer/agent.md
```

Each agent lives in its own subdirectory. The entire directory
(including any additional files alongside `agent.md`) is reflected
as one unit.

---

### 4. Output style — `config/output-styles/<name>.md`

```bash
cat > config/output-styles/brief.md <<'EOF'
---
description: Terse mode — one-sentence answers only
---

Respond in one sentence. No preamble. No caveats.
EOF

docker compose up -d --build

docker exec -u claude kroclaude \
    ls /home/claude/.claude/output-styles/brief.md
```

Same pattern as commands: one `.md` file per style, reflected by
the `dir-of-files` helper.

---

### 5. Hook fragment — `config/hooks.d/<name>.json`

Hook fragments are JSON files containing a partial `hooks` object.
They are merged (not copied) into `~/.claude/settings.json`'s
`hooks` key on every boot. See the [Hook fragment example](#hook-fragment-example)
section below for the exact file shape.

```bash
# Drop one fragment per logical hook group
cat > config/hooks.d/lint.json <<'EOF'
{
  "PostToolUse": [
    {
      "matcher": "Write|Edit|MultiEdit",
      "hooks": [
        {
          "type": "command",
          "command": "/usr/local/bin/kc-lint"
        }
      ]
    }
  ]
}
EOF

docker compose up -d --build

# Verify the hook is present in the merged settings
docker exec -u claude kroclaude \
    jq '.hooks.PostToolUse' /home/claude/.claude/settings.json
```

---

### 6. MCP server fragment — `config/mcp-servers.d/<name>.json`

MCP server fragments are JSON files containing one or more
`mcpServers` entries. They are merged into `~/.claude/.mcp.json`'s
`mcpServers` key on every boot. See the [MCP fragment example](#mcp-fragment-example)
section below.

```bash
cat > config/mcp-servers.d/postgres.json <<'EOF'
{
  "mcpServers": {
    "postgres": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-postgres"],
      "env": {
        "POSTGRES_CONNECTION_STRING": "${POSTGRES_URL}"
      }
    }
  }
}
EOF

docker compose up -d --build

docker exec -u claude kroclaude \
    jq '.mcpServers.postgres' /home/claude/.claude/.mcp.json
```

---

### 7. Plugin — `config/plugins/<name>/`

Plugins are self-contained directory trees that MUST contain a
`.claude-plugin/plugin.json` manifest. The entire tree is reflected
verbatim. See the [Plugin example](#plugin-example) section below.

```bash
mkdir -p config/plugins/sample-plugin/.claude-plugin

cat > config/plugins/sample-plugin/.claude-plugin/plugin.json <<'EOF'
{
  "name": "sample-plugin",
  "version": "1.0.0",
  "description": "Example bundled plugin"
}
EOF

# Plugins may also contain nested skills, commands, agents, etc.
mkdir -p config/plugins/sample-plugin/skills/greet
cat > config/plugins/sample-plugin/skills/greet/SKILL.md <<'EOF'
# greet
Greets the user politely.
EOF

docker compose up -d --build

docker exec -u claude kroclaude \
    ls /home/claude/.claude/plugins/sample-plugin/.claude-plugin/plugin.json
```

A plugin missing its `.claude-plugin/plugin.json` is logged as a
warning and skipped. All other types continue to reflect normally.

---

## What survives, what doesn't

| Scenario | User item | Bundled item | Result |
|----------|-----------|--------------|--------|
| Names don't collide | `~/.claude/skills/private/` | `config/skills/db-helper/` | Both present; `private/` untouched |
| Names collide (dir-of-dirs / dir-of-files) | `~/.claude/skills/db-helper/` (user copy) | `config/skills/db-helper/` | Bundled wins; user copy overwritten on boot |
| Hook event type only in user settings | `PostToolUse: [{matcher: "Read", …}]` | `config/hooks.d/lint.json` (PostToolUse Write) | Both present; user's Read hook preserved |
| Hook event type in both | `PostToolUse: [{matcher: "Write", …}]` | `config/hooks.d/lint.json` (PostToolUse Write) | Merged by matcher; bundled matcher entry wins on key collision within the group |
| MCP server key only in user file | `.mcpServers.local-dev: …` | `config/mcp-servers.d/postgres.json` | Both present; `local-dev` preserved |
| MCP server key in both | `.mcpServers.postgres: …` (user copy) | `config/mcp-servers.d/postgres.json` | Bundled wins |
| Plugin missing manifest | — | `config/plugins/broken/` (no `.claude-plugin/plugin.json`) | Warning logged; `broken/` skipped; other types unaffected |
| Bundled item removed in new image | `~/.claude/skills/old-helper/` (orphan) | *(no longer in bundle)* | Orphan survives; not garbage-collected |

---

## Hook fragment example

`config/hooks.d/lint.json` — a minimal `PostToolUse` hook that runs
a linter after every file write:

```json
{
  "PostToolUse": [
    {
      "matcher": "Write|Edit|MultiEdit",
      "hooks": [
        {
          "type": "command",
          "command": "/usr/local/bin/kc-lint",
          "timeout": 10000
        }
      ]
    }
  ]
}
```

The top-level key (`"PostToolUse"`) is a Claude Code hook event type.
The value is an array of hook groups, each with a `matcher` (which
Claude Code tool names trigger it) and a `hooks` array of commands.

**Precedence between fragments**: if `config/hooks.d/a.json` and
`config/hooks.d/b.json` both define a `PostToolUse` entry with the
same `matcher` string, the fragments are folded together via
`jq -s '.[0] * .[1]'` in `LC_ALL=C` lex order. Within a given event
type + matcher combination, the `group_by(.matcher // "")` step merges
all matching entries into one via `reduce .[] as $x ({}; . * $x)`,
so `b.json`'s keys win on any direct key collision inside the hook
group object. The operator controls this with numeric prefixes:
`00-base.json` (applied first, lowest precedence),
`99-override.json` (applied last, highest precedence).

---

## MCP fragment example

`config/mcp-servers.d/postgres.json` — a minimal Postgres MCP server:

```json
{
  "mcpServers": {
    "postgres": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-postgres"],
      "env": {
        "POSTGRES_CONNECTION_STRING": "${POSTGRES_URL}"
      }
    }
  }
}
```

The top-level key MUST be `"mcpServers"`. The merge filter
`.mcpServers = ((.mcpServers // {}) * $bundle)` deep-merges the
fragment's `mcpServers` object into the target file's existing
`mcpServers` map. The `postgres` key in the bundle wins over any
existing `postgres` key in `~/.claude/.mcp.json` (bundled-wins rule).

A fragment file MAY define multiple servers in one file or one server
per file — both work. One server per file is recommended because it
makes precedence obvious and diffs clean.

---

## Plugin example

Minimum viable plugin tree:

```text
config/plugins/sample-plugin/
└── .claude-plugin/
    └── plugin.json
```

`config/plugins/sample-plugin/.claude-plugin/plugin.json`:

```json
{
  "name": "sample-plugin",
  "version": "1.0.0",
  "description": "Example bundled plugin"
}
```

A richer plugin that bundles its own skills and commands:

```text
config/plugins/analytics-pack/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   └── query-builder/
│       └── SKILL.md
└── commands/
    └── run-report.md
```

The `.claude-plugin/plugin.json` manifest is required. Any plugin
directory missing it is skipped on boot with a one-line warning:

```text
[entrypoint] WARN: skipping plugin 'analytics-pack' — .claude-plugin/plugin.json not found
```

Note: this feature only reflects plugin trees into
`~/.claude/plugins/`. Registration or enabling of plugins in Claude
Code (if that requires a separate `/plugin` command or UI step)
is outside the scope of reflection.

---

## Verification

The CI smoke test
[`tests/smoke/test_us6.sh`](../../tests/smoke/test_us6.sh) exercises
all seven types end-to-end with one fixture per type drawn from
`tests/smoke/fixtures/005/`. It asserts:

1. **Presence and ownership** — each reflected item is present at
   the expected `~/.claude/<type>/` path and owned `claude:claude`.
2. **Fragment merge correctness** — the merged `settings.json` and
   `.mcp.json` contain both the bundled fragment content and any
   first-boot-seeded keys (notify.py wiring etc.) with no loss.
3. **User-item preservation** — a user-installed item with a
   different name is present and unmodified after a restart.
4. **Malformed-fragment resilience** — a deliberately malformed
   fragment causes one warning line in the container log and does
   not prevent the other fragments from being merged or the
   container from booting.

For a manual one-off verification after a fresh build:

```bash
# From the Docker host — substitute your container name if different
docker exec -u claude kroclaude bash -lc '
  set -e
  # dir-of-dirs types
  ls ~/.claude/skills/hello/SKILL.md
  ls ~/.claude/agents/db-reviewer/agent.md
  ls ~/.claude/plugins/sample/.claude-plugin/plugin.json
  # dir-of-files types
  ls ~/.claude/commands/triage.md
  ls ~/.claude/output-styles/brief.md
  # fragment-merge types
  jq ".hooks.PostToolUse | length > 0" ~/.claude/settings.json
  jq ".mcpServers | has(\"postgres\")" ~/.claude/.mcp.json
  echo "All assertions passed"
'
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Reflected file not present after rebuild+restart | Source file not committed to the image; COPY path wrong | Run `docker exec kroclaude ls /usr/local/share/kroclaude/config/<type>/` — if missing, the file wasn't COPY'd |
| File present but owned by `root:root` | `chown` step failed (rare, requires UID/GID mismatch) | Check entrypoint log for `[entrypoint] WARN:` lines; verify `claude` user is UID 1000 |
| Hook fragment not appearing in `settings.json` | Fragment is malformed JSON | Check container log for `[entrypoint] WARN: skipping malformed fragment …`; run `jq empty config/hooks.d/<name>.json` locally |
| MCP server not appearing in `.mcp.json` | Same as above — malformed JSON | Same fix |
| Plugin skipped with manifest warning | `.claude-plugin/plugin.json` is missing from the plugin directory | Add the manifest file; see [Plugin example](#plugin-example) |
| User-installed skill was overwritten | Bundled skill has the same `<name>` as the user skill | Rename either the bundled or the user skill |
| `settings.json` has no `hooks` key at all after merge | Fragment defines keys outside `hooks` at the top level | Verify fragment shape matches [Hook fragment example](#hook-fragment-example); top-level key MUST be `"PostToolUse"` (or another hook event name), not `"hooks"` |
| Two fragments define the same MCP key — wrong one wins | Lex order not as expected | Rename files with explicit numeric prefixes: `00-base.json` < `99-override.json` |
| Skill from old `/skills/` repo root is missing | Repo still has skill in `/skills/`; feature 005 moved source to `/config/skills/` (FR-012) | Move skill directory from `skills/<name>/` to `config/skills/<name>/` and rebuild |
