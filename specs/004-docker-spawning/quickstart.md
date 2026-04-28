# Quickstart: Docker Container Spawning from KroClaude

**Feature**: 004-docker-spawning
**Spec**: [spec.md](spec.md) · **Plan**: [plan.md](plan.md)

This quickstart shows the two paths through the feature: the one-time
operator setup, and the per-session developer workflow.

---

## Operator setup (once per host)

These steps assume KroClaude is being deployed to a Coolify host (or any
host with Docker installed). Run them once on the host, before bringing
the stack up.

```bash
# 1. Create the shared Docker network. KroClaude and every container
#    spawned by `kc-run` will join this network so KroClaude can resolve
#    siblings by name.
docker network create kroclaude-apps

# 2. (Coolify only) Add a "post-deployment command" in the application
#    settings:  docker network create -d bridge kroclaude-apps || true
#    The `|| true` makes redeploys idempotent.
```

Then in `.env` (or Coolify's environment-variables UI), set:

```dotenv
# Required for SSH (already documented by feature 003).
KROCLAUDE_SSH_AUTHORIZED_KEY=ssh-ed25519 AAAA...

# Optional — used only by `kc-forward` to print ready-to-paste
# `ssh -L` commands. If unset, `kc-forward` emits a placeholder
# `<host>` and a one-line warning.
KROCLAUDE_PUBLIC_HOST=kroclaude.example.com

# Optional — host-side SSH port override (existing from feature 003).
# KROCLAUDE_SSH_HOST_PORT=2221
```

Bring the stack up:

```bash
docker compose up -d
```

That's it for the operator. Verify with:

```bash
docker exec -u claude kroclaude docker version
# → Client and Server versions printed; no permission error.
```

If `permission denied` appears, the entrypoint failed to add `claude`
to the host's docker group — check container logs for the
`[entrypoint] claude added to group …` line. Fallback: `sudo docker
version` will still work because of NOPASSWD sudo.

---

## Developer workflow (per session)

From inside KroClaude (either via `docker exec -u claude` on the host
or via `ssh -p 2221 claude@<host>`), spawn and reach a container in
three commands.

### Spawn

```bash
kc-run -d --name myapp ghcr.io/your/app:latest
```

The container starts on `kroclaude-apps`, labeled `kroclaude.managed=true`.
A name is auto-generated if you omit `--name` (e.g. `kc-quietfox-a3f9c2`).

### Reach the app port from your laptop

```bash
kc-forward myapp 3000
```

Output:

```text
ssh -N -L 3000:myapp:3000 -p 2221 claude@kroclaude.example.com
```

(or `claude@<host>` with a warning if `KROCLAUDE_PUBLIC_HOST` isn't set)

Copy that line, paste into a terminal on your laptop, leave it
running. In your laptop browser, open `http://localhost:3000` —
the request tunnels through SSH to KroClaude, then to the sibling
container's port 3000.

To use a different local port:

```bash
kc-forward myapp 3000 8080
# → ssh -N -L 8080:myapp:3000 -p 2221 claude@kroclaude.example.com
```

### Inventory and clean up

```bash
kc-ps
# NAME           IMAGE                          STATUS         PORTS
# myapp          ghcr.io/your/app:latest        Up 2 minutes
# kc-quietfox…   nginx:alpine                   Up 14 seconds

kc-stop myapp
# → stops and removes
```

`kc-ps` shows ONLY KroClaude-managed containers. Coolify-managed and
unrelated host containers are filtered out. `kc-stop` refuses to
operate on anything not labeled `kroclaude.managed=true`.

---

## Helper cheat sheet

| Command | What it does | Notable flags |
|---------|--------------|---------------|
| `kc-run [OPTS] IMAGE [CMD]` | Wrap `docker run` with sane KroClaude defaults. Auto-attach to `kroclaude-apps`, auto-label, auto-name. | `--unsafe` to bypass dangerous-flag blocks (audit-logged) |
| `kc-ps [-a]` | List KroClaude-managed containers only | `-a` includes stopped |
| `kc-stop NAME` | Stop + remove a managed container. Refuses unlabeled targets. | `--keep` to skip removal |
| `kc-forward CONTAINER PORT [LOCAL_PORT]` | Print the `ssh -L` command to paste into your laptop terminal | `--host HOST` to override `KROCLAUDE_PUBLIC_HOST` for one call |

---

## Verification (smoke)

End-to-end check — run from the host of a freshly deployed stack:

```bash
# Assumes the operator setup above is done.
docker exec -u claude kroclaude bash -lc '
  set -e
  kc-run -d --rm --name kc-smoke nginx:alpine
  curl -fsS http://kc-smoke/ | head -1
  kc-ps | grep kc-smoke
  kc-forward kc-smoke 80 8080
  kc-stop kc-smoke
'
```

Expected output: the nginx welcome HTML's first line, the `kc-smoke`
row in `kc-ps`, the `ssh -N -L 8080:kc-smoke:80 -p 2221 claude@…` line,
then a stop confirmation.

The CI smoke test
[`tests/smoke/test_us5.sh`](../../tests/smoke/test_us5.sh) runs the
same flow plus the negative paths (US3 label-only filtering, US4
graceful degrade when the socket is missing, the `--unsafe` audit
log assertion).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `kc-run: docker.sock not available` | Compose came up without the bind-mount | Check `docker-compose.yaml` has `- /var/run/docker.sock:/var/run/docker.sock` under volumes |
| `permission denied on /var/run/docker.sock` | Entrypoint's GID-detection didn't run, or sshd started before `usermod` took effect | Restart the container; entrypoint runs at boot. Logs show `[entrypoint] claude added to group …` line on success. |
| `network kroclaude-apps not found` at `docker compose up` | Operator setup not done | `docker network create kroclaude-apps` on the host |
| `kc-forward` prints `<host>` placeholder | `KROCLAUDE_PUBLIC_HOST` not set | Set the env var in `.env` or Coolify, redeploy |
| `kc-run --privileged` is refused | Hard-block (FR-006a) | Add `--unsafe` if you really mean it (audit-logged) |
