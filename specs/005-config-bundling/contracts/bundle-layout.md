# Contract: Bundle Layout (`/config/`)

**Feature**: 005-config-bundling
**Spec**: [../spec.md](../spec.md) · **Plan**: [../plan.md](../plan.md)

This document is the authoritative shape of the `config/` directory
tree in the repository and its image-time counterpart at
`/usr/local/share/kroclaude/config/`. Any change to the paths or
naming rules below is a breaking change and MUST be reflected in the
Dockerfile, the entrypoint call sites, and the smoke test.

---

## Top-level layout

```text
config/
├── settings.json          # First-boot seed — NOT reflected by helpers (FR-013)
├── CLAUDE.md              # First-boot seed — NOT reflected by helpers (FR-013)
├── skills/                # dir-of-dirs type
├── commands/              # dir-of-files type (.md)
├── agents/                # dir-of-dirs type
├── output-styles/         # dir-of-files type (.md)
├── hooks.d/               # fragment-merge type (→ settings.json .hooks)
├── mcp-servers.d/         # fragment-merge type (→ .mcp.json .mcpServers)
└── plugins/               # dir-of-dirs type (+ manifest check)
```

The two seed files (`settings.json`, `CLAUDE.md`) are handled by the
existing first-boot sentinel logic in
[`scripts/entrypoint.sh`](../../../scripts/entrypoint.sh) (unchanged
from feature 001). They are NOT processed by any of the three
reflection helpers.

The seven type subdirectories are all empty by default (each contains
only a `.gitkeep` file to preserve the directory in git). Operators
and maintainers drop content into them.

**Dockerfile COPY** (single line, ships all seven types plus the two
seed files in one operation):

```dockerfile
COPY config/ /usr/local/share/kroclaude/config/
```

The image-time path `/usr/local/share/kroclaude/config/` is
read-only from the `claude` user's perspective. Reflection always
reads from this path and writes to `/home/claude/.claude/`.

---

## Per-type subshape

### `skills/<name>/`

A skill is a directory containing at minimum `SKILL.md`. Additional
helper files (scripts, data files, sub-skills) may be present.

```text
config/skills/
└── db-helper/
    ├── SKILL.md           # Required — Claude Code discovers skill by this file
    └── queries.sql        # Optional helper file; copied verbatim
```

- The entire `db-helper/` tree is reflected as one unit.
- `SKILL.md` must be present for Claude Code to recognise the skill,
  but the entrypoint does NOT validate its presence — that is a Claude
  Code concern, not a reflection concern.
- Reflection target: `~/.claude/skills/db-helper/`.

---

### `agents/<name>/`

An agent is a directory containing at minimum `agent.md`. The
directory name is the agent's identity.

```text
config/agents/
└── db-migration-reviewer/
    └── agent.md           # Required — Claude Code discovers agent by this file
```

- Additional files alongside `agent.md` (e.g., example inputs) are
  copied verbatim.
- Reflection target: `~/.claude/agents/db-migration-reviewer/`.

---

### `plugins/<name>/`

A plugin is a self-contained directory tree that MUST contain
`.claude-plugin/plugin.json` at its root. It may contain nested
`skills/`, `commands/`, `agents/`, and other plugin-internal content.

```text
config/plugins/
└── analytics-pack/
    ├── .claude-plugin/
    │   └── plugin.json    # REQUIRED — missing → warn + skip
    ├── skills/
    │   └── query-builder/
    │       └── SKILL.md
    └── commands/
        └── run-report.md
```

- The ENTIRE `analytics-pack/` tree is reflected as one unit via a
  single `cp -r`.
- Plugin-internal `skills/` and `commands/` directories are reflected
  under `~/.claude/plugins/analytics-pack/skills/` etc., NOT under
  `~/.claude/skills/`. Claude Code's plugin runtime handles
  discovery of plugin-internal customizations.
- Reflection target: `~/.claude/plugins/analytics-pack/`.
- If `.claude-plugin/plugin.json` is missing, the entire plugin is
  skipped with a one-line warning. Other plugins and other types
  are unaffected.

---

### `commands/<name>.md`

Each slash command is a single Markdown file. Typically it contains
YAML frontmatter followed by a natural-language or template body.

```text
config/commands/
├── triage.md
└── run-tests.md
```

- Only `.md` files are reflected. Other extensions (e.g., `.txt`,
  `.json`) are silently ignored by the `dir-of-files` helper.
- Reflection target: `~/.claude/commands/triage.md`,
  `~/.claude/commands/run-tests.md`.

---

### `output-styles/<name>.md`

Each output style is a single Markdown file describing a response
mode or tone.

```text
config/output-styles/
├── brief.md
└── formal.md
```

- Same rules as `commands/`: only `.md` files are reflected.
- Reflection target: `~/.claude/output-styles/brief.md`, etc.

---

### `hooks.d/<name>.json`

Each fragment is a JSON file whose top-level structure is a partial
hooks object. The top-level keys are Claude Code hook event type
names (e.g., `"PostToolUse"`, `"PreToolUse"`, `"Stop"`). The value
for each key is an array of hook-group objects, each with a `matcher`
string and a `hooks` array.

```text
config/hooks.d/
├── 00-base.json        # applied first (lowest precedence)
├── 50-notify.json      # applied second
└── 99-lint.json        # applied last (highest precedence)
```

Fragment shape:

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

- The top-level key (`"PostToolUse"`) is NOT `"hooks"`. The fragment
  represents the VALUE that would go inside `settings.json`'s
  `"hooks"` key. Think of each fragment as a partial `settings.json`
  with only the `hooks.*` children, one level unwrapped.
- A single fragment MAY define multiple event types (`"PostToolUse"`
  and `"PreToolUse"` in the same file).
- Reflection target: merged into `~/.claude/settings.json` under the
  `.hooks` key. The rest of `settings.json` is untouched.

---

### `mcp-servers.d/<name>.json`

Each fragment is a JSON file whose top-level key is `"mcpServers"`.
The value is an object mapping server name → server configuration.

```text
config/mcp-servers.d/
├── 00-base.json
└── postgres.json
```

Fragment shape:

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

- The top-level key MUST be `"mcpServers"`. The merge filter reads
  `.mcpServers` from the folded bundle. A fragment with a different
  top-level key (e.g., `"servers"`) will fold without error but the
  merge filter will find `bundle.mcpServers` as `null`, and the
  `.mcpServers = ((.mcpServers // {}) * $bundle)` expression will
  produce unexpected results. Validation of fragment shape is the
  maintainer's responsibility.
- Reflection target: merged into `~/.claude/.mcp.json` under the
  `.mcpServers` key. Other keys in `.mcp.json` (if any) are untouched.

---

## Naming rules

These rules apply to `<name>` in all seven types.

| Rule | Examples |
|------|---------|
| Lowercase letters, digits, and hyphens only | `db-helper`, `run-tests`, `00-base` |
| No spaces | `my skill` is INVALID |
| No dots EXCEPT in the file extension for dir-of-files types | `brief.md` is valid; `my.skill` is INVALID as a skill name |
| No leading or trailing hyphens | `-helper` is INVALID |
| For fragment files (`hooks.d/`, `mcp-servers.d/`): numeric prefix allowed and encouraged | `00-base.json`, `99-override.json` |
| For fragment files: extension MUST be `.json` | `.yaml`, `.json5`, `.json.bak` are not processed |
| Maximum `<name>` length: 64 characters | Enforced by convention, not by the helpers |

The `<name>` for dir-of-dirs types (skills, agents, plugins) is the
directory's basename. For dir-of-files types (commands,
output-styles) it is the file's basename WITHOUT the extension. For
fragment types (hooks.d, mcp-servers.d) the fragment filename (WITH
extension) is used only for ordering and warning messages, not as an
identity in the reflection target.

---

## The two `.d` directories — fragment shape in depth

The naming convention `hooks.d` and `mcp-servers.d` follows the
established Linux pattern for "drop-in" configuration directories
(analogous to `cron.d`, `logrotate.d`, `systemd/system/*.d`). Each
file in such a directory contributes a partial configuration that
is merged into a canonical target file.

### How a hooks fragment relates to `settings.json`

A complete `~/.claude/settings.json` (with hooks) looks like:

```json
{
  "theme": "dark",
  "hooks": {
    "PostToolUse": [ { "matcher": "…", "hooks": [ … ] } ],
    "PreToolUse":  [ { "matcher": "…", "hooks": [ … ] } ]
  }
}
```

A `hooks.d` fragment is the VALUE of the `"hooks"` key — i.e., just:

```json
{
  "PostToolUse": [ { "matcher": "…", "hooks": [ … ] } ]
}
```

The fragment does NOT wrap itself in `{ "hooks": { … } }`. The merge
filter places it correctly under `.hooks` in the target file.

### How an MCP fragment relates to `.mcp.json`

A complete `~/.claude/.mcp.json` looks like:

```json
{
  "mcpServers": {
    "postgres": { "command": "…", "args": [ … ] }
  }
}
```

A `mcp-servers.d` fragment is the ENTIRE file shape, including the
top-level `"mcpServers"` wrapper:

```json
{
  "mcpServers": {
    "postgres": { "command": "…", "args": [ … ] }
  }
}
```

The merge filter reads `$bundle.mcpServers` (after folding) and merges
it into the target's `.mcpServers` key. The fragment therefore looks
identical in shape to a complete `.mcp.json` file — which is
intentional: you can validate a fragment by treating it as a minimal
`.mcp.json` and running it through Claude Code's configuration
tooling.

This asymmetry between the two fragment shapes (hooks fragments are
the inner object; MCP fragments are the full outer shape) is a
consequence of the Claude Code data model and is intentional per the
design.

---

## What is NOT in `/config/`

- `config/settings.json` and `config/CLAUDE.md` — present in the
  directory but handled by existing first-boot sentinel logic, not
  by any reflection helper. See [spec FR-013](../spec.md).
- Any file or directory at the root of `config/` that does not match
  one of the nine listed names above is silently ignored by the
  Dockerfile COPY (it still ships into the image) and by the
  entrypoint (no call site processes it). Future types can be added
  by creating a new subdirectory and a new call site.
- Secrets, credentials, or anything that changes between deployments.
  All bundled content is checked into version control. Runtime-
  variable content (e.g., database URLs referenced in MCP config)
  MUST use environment variable substitution within the tool that
  reads the config — the fragment stores the `${ENV_VAR}` reference,
  not the resolved value.
