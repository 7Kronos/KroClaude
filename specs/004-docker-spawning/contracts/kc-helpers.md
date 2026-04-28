# Contract: `kc-*` Helper Scripts

**Feature**: 004-docker-spawning
**Spec**: [../spec.md](../spec.md) · **Plan**: [../plan.md](../plan.md)

This document is the authoritative contract for the four helper
scripts shipped by this feature. Any change to the surface described
here is a breaking change and MUST be reflected in the smoke test
([`tests/smoke/test_us5.sh`](../../../tests/smoke/test_us5.sh)).

---

## Common contract (all four helpers)

| Property | Value |
|----------|-------|
| Location | `/usr/local/bin/kc-{run,ps,stop,forward}` |
| Source | `scripts/kc-{run,ps,stop,forward}` (copied by Dockerfile) |
| Owner / mode | `root:root` `0755` |
| Shell | `#!/usr/bin/env bash`, `set -euo pipefail` |
| External deps | `docker` (CLI), `getent`, `stat`, `printf`, `date`, `id`, `awk` — all already in image |

### Preflight (FR-010)

Every helper, before doing any other work, MUST run:

```bash
docker info >/dev/null 2>&1 || sudo -n docker info >/dev/null 2>&1 || {
    echo "kc-<name>: docker.sock not available — mount /var/run/docker.sock to use this helper" >&2
    exit 2
}
```

If `docker info` works, subsequent calls use plain `docker`. If only
`sudo docker` works, subsequent calls use `sudo -n docker`. The
choice is made once at preflight; output MUST NOT mix the two.

### Exit codes (all helpers)

| Code | Meaning |
|------|---------|
| 0 | Success |
| 2 | Preflight failure (socket unreachable) |
| 3 | Validation failure (bad flag, bad target, refused operation) |
| 4 | Underlying `docker` command failed (exit code from docker is mapped here) |

---

## `kc-run [OPTIONS] IMAGE [CMD…]`

Wraps `docker run` with KroClaude defaults.

### Default behavior

- Adds `--network kroclaude-apps` if the user did not pass `--network`.
- Adds `--label kroclaude.managed=true` and `--label
  kroclaude.created=$(date -u +%FT%TZ)`.
- If no `--name` is given, generates `kc-<wordlist-slug>-<rand6>`
  (e.g. `kc-quietfox-a3f9c2`) and adds `--name <generated>`.
- Pass-through: every other flag and the image+command tail forward
  unchanged to `docker run`.
- The generated name is printed on stdout on success (matches `docker
  run -d` behavior of printing the container ID; we additionally print
  the chosen `--name`).

### Refused without `--unsafe` (FR-006, FR-006a)

| Refused argv pattern | Reason | Refusal message (one line) |
|----------------------|--------|----------------------------|
| `-p` or `--publish` (any value) | KroClaude routes traffic via SSH `-L` (FR-006) | `kc-run: -p/--publish not supported; use kc-forward instead` |
| `--privileged` | Bypasses container isolation | `kc-run: --privileged is blocked; pass --unsafe to override (audit-logged)` |
| `--network=host` / `--network host` | Joins host network namespace | `kc-run: --network=host is blocked; pass --unsafe to override (audit-logged)` |
| `--pid=host` / `--pid host` | Joins host PID namespace | (same shape, swap flag name) |
| `--ipc=host`, `--uts=host`, `--userns=host` | Host namespace joins | (same shape) |
| `--cap-add=SYS_ADMIN` / `--cap-add SYS_ADMIN` | Wide capability | (same shape) |
| `-v <abs-path>:…` or `--mount type=bind,source=<abs-path>,…` where `<abs-path>` starts with `/` and is NOT under `/home/claude`, `/workspace`, `/tmp` | Host-path bind mount outside KroClaude-owned paths | `kc-run: host-path bind mount outside /home/claude\|/workspace\|/tmp is blocked; pass --unsafe to override (audit-logged)` |

`-p`/`--publish` is **always** refused (it is not in scope for
`--unsafe`; the access pattern for this feature is `kc-forward`).

### `--unsafe` semantics (FR-006b)

- Strip `--unsafe` from argv before forwarding to `docker run`.
- Bypass every dangerous-flag block above (but NOT the `-p` block).
- Before `exec`-ing `docker run`, emit exactly one line to stderr:

  ```text
  [kc-run UNSAFE] <RFC3339> user=<whoami> name=<final-container-name> allowed=<comma-list-of-bypassed-flags>
  ```

  `allowed=` is the comma-separated names of dangerous flags that
  were detected in argv and would have been refused without
  `--unsafe`. If `--unsafe` was passed but no dangerous flag was
  present, `allowed=` is the empty string and the line is still
  printed.

### Exit-code mapping

| Situation | Exit |
|-----------|------|
| `docker run` succeeded | 0 |
| Preflight failure | 2 |
| `-p` / dangerous flag refused | 3 |
| `docker run` failed (image pull error, name collision, etc.) | 4 |

---

## `kc-ps [-a]`

Lists ONLY KroClaude-managed containers.

### Behavior

- Without `-a`: equivalent to
  `docker ps --filter label=kroclaude.managed=true
  --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'`.
- With `-a`: adds `-a` to the underlying `docker ps`.
- No other flags accepted (helper exits 3 on unknown args).

### Exit-code mapping

| Situation | Exit |
|-----------|------|
| Listing succeeded (zero or more rows) | 0 |
| Preflight failure | 2 |
| Unknown flag | 3 |
| `docker ps` failed | 4 |

---

## `kc-stop NAME [--keep]`

Stops (and by default removes) a KroClaude-managed container.

### Behavior

- Reads the container's `kroclaude.managed` label via
  `docker inspect --format '{{ index .Config.Labels "kroclaude.managed" }}' NAME`.
- If the label is absent or not `true`, refuses with exit 3:
  `kc-stop: <NAME> is not a KroClaude-managed container; refusing`.
- If the label is `true`: `docker stop NAME` then (unless `--keep`)
  `docker rm NAME`. Both are best-effort; second `kc-stop` on an
  already-removed container exits 0 with `kc-stop: <NAME> already
  removed`.

### Exit-code mapping

| Situation | Exit |
|-----------|------|
| Stopped (and removed) | 0 |
| Preflight failure | 2 |
| Unlabeled / wrong-label target | 3 |
| `docker stop` or `docker rm` failed unexpectedly | 4 |

---

## `kc-forward CONTAINER PORT [LOCAL_PORT] [--host HOST]`

Prints the SSH local-forward command to paste into a laptop terminal.

### Argument resolution

- `CONTAINER` — required. Sibling container name on `kroclaude-apps`.
- `PORT` — required. The port the app inside the sibling listens on.
- `LOCAL_PORT` — optional, defaults to `PORT`.
- `--host HOST` — optional. Per-call override of `KROCLAUDE_PUBLIC_HOST`.

### Resolution checks

Before printing anything:

1. Run `getent hosts CONTAINER >/dev/null` (uses Docker's embedded
   resolver via the container's resolv.conf).
2. On failure: exit 3 with one line
   `kc-forward: cannot resolve container '<CONTAINER>' on
   kroclaude-apps; is it spawned via kc-run?`.

### Output

Read `KROCLAUDE_SSH_HOST_PORT` (default `2221`) and
`KROCLAUDE_PUBLIC_HOST` (no default; `--host` overrides).

If `KROCLAUDE_PUBLIC_HOST` is set:

```text
ssh -N -L <LOCAL_PORT>:<CONTAINER>:<PORT> -p <KROCLAUDE_SSH_HOST_PORT> claude@<KROCLAUDE_PUBLIC_HOST>
```

If `KROCLAUDE_PUBLIC_HOST` is empty/unset and `--host` not passed:

```text
[kc-forward] KROCLAUDE_PUBLIC_HOST is unset; substitute <host> with your deployment URL or set the env var
ssh -N -L <LOCAL_PORT>:<CONTAINER>:<PORT> -p <KROCLAUDE_SSH_HOST_PORT> claude@<host>
```

The warning goes to stderr; the `ssh` command goes to stdout. This
makes `kc-forward foo 80 | xclip` work cleanly.

### Exit-code mapping

| Situation | Exit |
|-----------|------|
| Printed (with or without warning) | 0 |
| Preflight failure (socket) | 2 |
| Container not resolvable | 3 |
| Wrong arg count / unknown flag | 3 |

---

## Stability guarantees

- Output formats above are part of the contract. Smoke tests grep
  on them; changing them is a breaking change.
- Exit codes 0/2/3/4 are part of the contract.
- Refusal-message wording can be edited freely as long as the
  one-line and exit-code shape is preserved.
- Adding new flags is non-breaking; removing or repurposing
  existing flags requires a major image-version bump.
