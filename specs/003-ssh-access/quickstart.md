# Quickstart: Remote SSH Access

**Branch**: `003-ssh-access` | **Date**: 2026-04-28

This is the minimum path from "I have a public key" to "I am ssh'd
into the running container as `claude`".

## First-time setup (local Docker)

1. **Generate a key on your workstation** (if you don't already have
   one):
   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/id_kroclaude
   ```
   That produces `~/.ssh/id_kroclaude` (private) and
   `~/.ssh/id_kroclaude.pub` (public).

2. **Configure the container's authorized key**:
   ```sh
   cp .env.example .env
   $EDITOR .env
   ```
   In `.env`, set:
   ```sh
   KROCLAUDE_SSH_AUTHORIZED_KEY="$(cat ~/.ssh/id_kroclaude.pub)"
   ```
   (Inline-pasting the public key works too — the variable contents
   are the verbatim contents of `~claude/.ssh/authorized_keys`.)

3. **Bring the stack up**:
   ```sh
   docker compose up -d
   ```
   First boot generates the SSH host keys (~2 s) and writes
   `authorized_keys` from your env value.

4. **SSH in**:
   ```sh
   ssh -i ~/.ssh/id_kroclaude -p 2221 claude@localhost
   ```
   You land in `/workspace` as the `claude` user, with `claude`,
   `codex`, `gemini`, and the rest of the curated toolchain on
   `PATH`. Run `claude` to start a session.

## Coolify deployment

1. In the Coolify "Environment Variables" or "Secrets" UI for the
   application, set:
   - `KROCLAUDE_SSH_AUTHORIZED_KEY` = your public key (one or more,
     one per line)
   - `KROCLAUDE_SSH_HOST_PORT` = `2221` (or another port if `2221`
     is taken on the Coolify node)
   - `ANTHROPIC_API_KEY` = your Anthropic API key (from feature 001)
2. Deploy. Coolify will publish the SSH port to the public network
   per the compose file; firewall / VPN restrictions are managed at
   the network layer (not in-container).
3. SSH in:
   ```sh
   ssh -i ~/.ssh/id_kroclaude -p 2221 claude@<coolify-node-host>
   ```

## Adding more keys

Paste them all into the same env variable, one per line:

```sh
KROCLAUDE_SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... user1@laptop
ssh-ed25519 AAAA... user2@laptop"
```

After the next `docker compose up -d` (or Coolify redeploy), both
keys can SSH in.

## Rotating the key

Update the env variable to the new public key (replace the entire
value — the file is reseeded verbatim, no merging). Restart the
stack:

```sh
$EDITOR .env                # update KROCLAUDE_SSH_AUTHORIZED_KEY
docker compose up -d        # picks up the new env
```

The OLD key is now rejected; the NEW key is accepted. There is
nothing to clean up on disk.

## Overriding the host port

If host port `2221` is taken:

```sh
# in .env
KROCLAUDE_SSH_HOST_PORT=2222
```

Then `ssh -p 2222 claude@<host>`. The in-container port stays
`2221`; only the published mapping changes.

## Troubleshooting (terse)

| Symptom | First check |
|---------|-------------|
| `Permission denied (publickey)` | `KROCLAUDE_SSH_AUTHORIZED_KEY` matches your `~/.ssh/<key>.pub`; check `docker exec kroclaude cat /home/claude/.ssh/authorized_keys`. |
| Connection refused | Container is `healthy`? `docker compose ps`. Host port is the right one? Check `docker compose port kroclaude 2221`. |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` (only the first time) | The `kroclaude-config` volume was wiped (which regenerates host keys). Run `ssh-keygen -R '[host]:2221'` on your workstation, then SSH again. |
| Password prompt appears | This MUST NOT happen — file a bug; sshd config is misapplied. Smoke test would have caught this. |

## Reset SSH state

- **Re-generate host keys** (will trigger fingerprint warning on
  next connect):
  ```sh
  docker exec kroclaude rm -rf /home/claude/.claude/.ssh-host-keys
  docker compose restart
  ```
- **Lock the container** (revoke all SSH access without removing the
  service):
  ```sh
  KROCLAUDE_SSH_AUTHORIZED_KEY=
  docker compose up -d
  ```
  Existing sessions stay alive until they disconnect; new logins are
  refused.

## Smoke test

```sh
bash tests/smoke/test_us4.sh
```

Generates a throwaway keypair, brings the stack up with the public
key in env, exercises positive auth + key rotation + all three
negative auth paths + host-key persistence. Passes when sshd is
correctly configured per
[`contracts/sshd-config.md`](contracts/sshd-config.md).
