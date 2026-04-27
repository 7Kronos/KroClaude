# Contract: Bundled Skill Format and Reflection Behavior

**Branch**: `002-skill-bundling` | **Date**: 2026-04-28

This contract governs (a) what counts as a bundled skill in this
project, and (b) what the entrypoint guarantees about reflecting them
into the persistent volume.

## Source-side contract (image build)

To ship a bundled skill, place a directory under
[`skills/<skill-name>/`](../../../skills/) at the repository root.
Requirements:

| Requirement | Rule |
|-------------|------|
| Directory name | Valid POSIX filename: lowercase ASCII, digits, `-`, `_`. No spaces, no slashes. |
| Contents | At minimum a file named `SKILL.md` in the directory root. Anything else is allowed and reflected verbatim. |
| Encoding | UTF-8 text. No binary blobs in v1. |
| Architecture | Architecture-neutral. No per-arch files (no precompiled binaries). |
| Size | Soft cap: total uncompressed size of all bundled skills ≤ 10 MB in v1. |
| Count | Soft cap: at most 20 bundled skills in v1. |

The Dockerfile copies the entire `skills/` directory into
`/usr/local/share/kroclaude/skills/`. There is no transformation step;
the on-disk contents in the image match the contents in the source repo
byte-for-byte.

## Runtime contract (entrypoint reflection)

On every container start, the entrypoint:

1. Checks whether `/usr/local/share/kroclaude/skills/` exists and
   contains at least one immediate subdirectory.
   - If not: skip the rest of this contract silently.
2. Ensures `/home/claude/.claude/skills/` exists (`mkdir -p`, owned by
   `claude:claude`).
3. For each immediate subdirectory `S` under
   `/usr/local/share/kroclaude/skills/`:
   - `rm -rf /home/claude/.claude/skills/S`
   - `cp -r /usr/local/share/kroclaude/skills/S /home/claude/.claude/skills/S`
   - `chown -R claude:claude /home/claude/.claude/skills/S`
4. Does NOT enumerate or touch any other directory under
   `/home/claude/.claude/skills/`.

### Guarantees

| Property | Guarantee |
|----------|-----------|
| Bundled skills present after start | Yes — each name in the bundled set is at `~/.claude/skills/<name>/` with the image's exact content. |
| Bundled skill update on image bump | Yes — content for an existing name is replaced atomically per skill. |
| User skills preserved (different names) | Yes — never read, never modified, never deleted (FR-003). |
| User-installed skill that COLLIDES with a bundled name | Overwritten by the bundled version on next start. Documented; users wanting to keep a custom variant must rename it. |
| Bundled skill removed in a new image version | Previously-installed copy stays in the volume untouched (orphaned but preserved). Manual cleanup is the user's responsibility (FR-007). |
| Permissions | All reflected files end up owned by `claude:claude` (UID/GID 1000), readable by the in-container `claude` user (FR-008). |
| Idempotence | Running the stanza twice in a row leaves the same byte-level state (FR-002). |
| Failure | Halts the entrypoint; Docker's restart policy retries. NOT silently swallowed. |

### Out of scope for v1

- A manifest file declaring the bundled set (the live filesystem listing is the manifest).
- An opt-out env var (`KROCLAUDE_NO_SKILLS=1` or similar).
- Garbage collection of skills that were bundled in a previous image version but no longer are.
- Selective bundling (only-some-skills mode).

## Verification

A passing run of [`tests/smoke/test_us2.sh`](../../../tests/smoke/test_us2.sh)
must, after this feature lands, additionally assert:

1. After empty-volume first boot, every directory present under
   `skills/` in the repo is also present under
   `~/.claude/skills/` in the container, with matching SKILL.md
   contents.
2. After writing a custom skill (`my-test-skill/SKILL.md`) into the
   volume and restarting the stack, `my-test-skill` is still present
   with byte-identical content.
3. After overwriting one of the bundled skills' source contents and
   triggering a `--no-cache` rebuild, the corresponding directory in
   the volume reflects the new content (and the `my-test-skill` from
   step 2 is still untouched).
