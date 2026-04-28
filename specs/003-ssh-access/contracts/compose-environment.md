# Contract: Compose Environment Variables (delta vs feature 001)

**Branch**: `003-ssh-access` | **Date**: 2026-04-28

This contract is **additive** to feature 001's
[contracts/compose-environment.md](../../001-claude-shell-base/contracts/compose-environment.md).
Nothing in feature 001's contract is removed or changed; this feature
adds two new variables and one new published port.

## New required variables

None. The SSH server is enabled by default (sshd will run); the
operator activates SSH login by setting `KROCLAUDE_SSH_AUTHORIZED_KEY`
to a public key. Without it, sshd runs but accepts no logins.

## New optional variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `KROCLAUDE_SSH_AUTHORIZED_KEY` | unset (empty) | Verbatim contents of `~claude/.ssh/authorized_keys`. One or more public keys, one per line, comments allowed. Reseeded on every container start (latest env wins). When unset/empty, no SSH login is possible. |
| `KROCLAUDE_SSH_HOST_PORT` | `2221` | Host-side port to publish for SSH. Override when host port `2221` is already taken (e.g., set to `2222`). The in-container port stays `2221`. |

## New published port

The compose service grows a `ports:` block:

```yaml
ports:
  # Feature 003 — SSH access. Host-port overridable via env.
  - "${KROCLAUDE_SSH_HOST_PORT:-2221}:2221"
```

This is the **first** inbound port KroClaude publishes (feature 001
explicitly published none). The constitution permits ports as long as
they are explicitly enumerated — this one is, and it has a feature-
level rationale documented in spec FR-003b... wait no, FR-003 of
feature 003.

## Forbidden

- The actual public-key contents MUST NOT appear in the committed
  `.env.example` (only the variable name + an empty value).
- The host-port-override variable MUST NOT default to `0` or to a
  privileged port (<1024).
- No additional `ports:` entries beyond the one above. SSH is the
  only port published by KroClaude in v1.0 + this feature.
- No corresponding `cap_add` or `security_opt` additions — the SSH
  server runs within the existing privilege model (FR-015).

## Validation

The CI `compose-config-validate` step (defined in feature 001's CI)
already runs `docker compose --env-file .env.example config` and
`docker compose --env-file /dev/null config`. After this feature, both
runs MUST emit a `ports:` section with exactly the one mapping above —
no surprise ports introduced via env var interpolation.

## .env.example delta

Two lines appended to `.env.example`:

```sh
# ----- Optional: SSH access (feature 003-ssh-access) -----
# Verbatim contents of ~claude/.ssh/authorized_keys. One or more
# public keys, one per line. When empty, sshd runs but no login is possible.
KROCLAUDE_SSH_AUTHORIZED_KEY=
# Host-side port for the published SSH service. Container side is fixed at 2221.
KROCLAUDE_SSH_HOST_PORT=2221
```
