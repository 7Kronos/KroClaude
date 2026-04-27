# Contract: Volume Layout

**Branch**: `001-claude-shell-base` | **Date**: 2026-04-27

The compose file declares exactly two named Docker volumes; nothing else
in the container filesystem is treated as persistent.

## Volumes

| Name | Mount point inside container | Owner | Contents |
|------|------------------------------|-------|----------|
| `kroclaude-config` | `/home/claude/.claude` | `claude` | Claude credentials, `settings.json`, `CLAUDE.md`, Codex config, Gemini config, `.bash_history`, first-boot sentinel |
| `kroclaude-workspace` | `/workspace` | `claude` | user project files |

## Compose declaration (canonical form)

```yaml
volumes:
  kroclaude-config:
  kroclaude-workspace:

services:
  kroclaude:
    # ...
    volumes:
      - kroclaude-config:/home/claude/.claude
      - kroclaude-workspace:/workspace
```

Both volumes use the default Docker `local` driver. Coolify backs up named
volumes natively; users on plain docker-compose can use
`docker run --rm -v kroclaude-config:/data -v $(pwd):/backup busybox tar -czf /backup/config.tgz -C /data .` (or equivalent) for ad-hoc backups.

## Forbidden

- Bind mounts to host paths for `/workspace` or `/home/claude/.claude`
  (out of scope per Q3 clarification, FR-007).
- Any third volume in v1 — the spec calls out exactly two persistence
  categories.
- Using the workspace volume to hold Claude credentials, or the config
  volume to hold project files. Categories MUST stay separated so they
  can be wiped independently (acceptance scenario 2 of US2).

## Lifecycle invariants

1. **First deploy**: both volumes are empty; the entrypoint seeds
   `/home/claude/.claude` with default config and writes the sentinel
   file. `/workspace` is left empty.
2. **Container recreation, image unchanged**: both volumes survive;
   entrypoint detects the sentinel and skips reseeding.
3. **Image rebuild + container recreation**: same as (2). Updated
   default config files baked into the image are NOT pushed over the
   user's modified copies. (To upgrade configs, the user removes the
   sentinel and restarts.)
4. **Workspace wipe** (`docker volume rm kroclaude-workspace`):
   credentials and config remain intact. Next start gets an empty
   `/workspace` again.
5. **Config wipe** (`docker volume rm kroclaude-config`): user must
   re-authenticate Claude; `/workspace` files are untouched. Entrypoint
   re-seeds default config.
