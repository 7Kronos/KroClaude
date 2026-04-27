# Quickstart: Bundling and Verifying Skills

**Branch**: `002-skill-bundling` | **Date**: 2026-04-28

## Add a new bundled skill

1. Create the directory at the repo root:
   ```sh
   mkdir -p skills/my-new-skill
   ```
2. Add a `SKILL.md`:
   ```sh
   $EDITOR skills/my-new-skill/SKILL.md
   ```
   Format follows the standard Claude Code skill convention.
3. Add any supporting files (scripts, templates, refs) under the same
   directory.
4. Rebuild and restart:
   ```sh
   docker compose build
   docker compose up -d --force-recreate
   ```
5. Verify it's present in the volume:
   ```sh
   docker exec --user claude kroclaude ls ~/.claude/skills/
   ```

## Update an existing bundled skill

Edit `skills/<name>/...` in the repo. Rebuild and restart. The next
healthy state has the updated content; user-installed skills (different
names) remain untouched.

## Install a user skill (in-container)

From inside the container as the `claude` user:

```sh
mkdir -p ~/.claude/skills/my-personal-skill
$EDITOR ~/.claude/skills/my-personal-skill/SKILL.md
```

This skill survives container restart, image rebuild, and pulls of new
KroClaude image versions, **as long as** its name doesn't collide with
a bundled skill name.

## Forget the difference between bundled and user skills

`ls ~/.claude/skills/` lists both side by side. There is no marker on
disk distinguishing the two — the source of truth for "which are
bundled" is the contents of `/usr/local/share/kroclaude/skills/` inside
the image. List that path inside the container if you need to know:

```sh
docker exec kroclaude ls /usr/local/share/kroclaude/skills/
```

## Reset bundled skills to the image-default state

```sh
docker exec kroclaude bash -c 'rm -rf /home/claude/.claude/skills/*'
docker compose restart
```

This wipes ALL skills (bundled AND user) from the volume; the
entrypoint repopulates the bundled ones on next start. User skills you
care about should be backed up first.

## Run the smoke checks

```sh
bash tests/smoke/test_us2.sh
```

This will exercise the persistence scenarios from feature 001 plus the
new skill-bundling scenarios introduced by this feature.
