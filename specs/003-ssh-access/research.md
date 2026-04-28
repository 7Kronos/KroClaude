# Phase 0 Research: Remote SSH Access for Claude Code

**Branch**: `003-ssh-access` | **Date**: 2026-04-28

This document records the technical decisions for the implementation
plan. Eight decisions cover the entire feature surface.

## R1 — SSH server source: openssh-server (Debian Bookworm)

- **Decision**: install `openssh-server` from Debian Bookworm's apt
  repository. Add it to feature 001's curated apt install list (the
  one already containing `openssh-client`).
- **Rationale**: it's the canonical SSH server, packaged for both
  amd64 and arm64, integrated with PAM/systemd/etc., and shares
  shared libraries with `openssh-client` so the marginal image growth
  is small (~5 MB compressed). Hardening is well-documented; the
  attack surface is well-studied.
- **Alternatives considered**:
  - **Dropbear**: smaller (~1 MB) but lacks some sshd_config
    directives we want (e.g., precise `KbdInteractiveAuthentication`
    semantics, modern cipher options) and has a smaller security
    audit history. Rejected.
  - **Tailscale SSH / Cloudflare Tunnel**: removes the public-port
    problem entirely but introduces a third-party service and an
    out-of-band setup step that breaks the "one env var, ssh in"
    UX (spec SC-001). Rejected for v1; could revisit.
  - **WeTTY / SSH-over-WebSocket**: relies on a web UI in the
    container, contradicts feature 001 FR-004 (no web UI). Rejected.

## R2 — sshd hardening posture

- **Decision**: ship `scripts/sshd_config_kroclaude` with the following
  directives (verbatim text in [contracts/sshd-config.md](contracts/sshd-config.md)).
  Listen on `Port 2221`. Auth: `PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`, `ChallengeResponseAuthentication
  no`, `HostbasedAuthentication no`, `PubkeyAuthentication yes`,
  `PermitRootLogin no`, `AllowUsers claude`. Session: `UsePAM yes`
  (needed for session module functionality on Debian — env, audit,
  cgroup; PAM is not an *auth* path here because the auth methods
  above are all disabled), `X11Forwarding no`, `AllowAgentForwarding
  no`, `AllowTcpForwarding yes` (port forwarding is useful for dev
  workflows over SSH and is not a credential-leak risk under
  pubkey-only auth), `PrintMotd no`, `PrintLastLog no`. Host keys
  from `/home/claude/.claude/.ssh-host-keys/` (per R4). Modern cipher
  list (chacha20-poly1305, aes256-gcm, aes128-gcm); modern KEX
  (curve25519-sha256, sntrup761x25519-sha512); strong MACs
  (hmac-sha2-256-etm, hmac-sha2-512-etm). LogLevel VERBOSE (helps
  forensic).
- **Rationale**: this is the standard "key-only, hardened" sshd
  posture used by every modern security baseline (NIST SP 800-53,
  CIS OpenSSH benchmark, Mozilla Modern profile). It satisfies spec
  FR-003 through FR-005 and SC-003. Keeping `UsePAM yes` is
  intentional — Debian's sshd needs PAM session module for proper
  user environment setup; turning it off has known breakage but
  doesn't help security here because the auth-side of PAM is unreachable.
- **Alternatives considered**:
  - **`UsePAM no`**: simpler reasoning ("no PAM, no PAM exploit"), but
    breaks Debian login flows (env, motd hooks). And since pubkey is
    the only auth path, PAM can't be used to mount a credential
    attack. Rejected.
  - **Stricter cipher list (only chacha20-poly1305 + curve25519)**:
    breaks older SSH clients with no real benefit for our threat
    model. Rejected — go with Mozilla "modern" instead.
  - **`AllowTcpForwarding no`**: more conservative, but breaks
    `ssh -L`/`-R` workflows that are genuinely useful for dev (e.g.,
    forwarding a local port into the container's `lighthouse` server
    or a local browser to the in-container Vite dev server). Pubkey
    auth means no credential-replay risk via forwarded sockets.
    Keep enabled.

## R3 — Process supervision: new s6 service `sshd`

- **Decision**: add `s6-overlay/s6-rc.d/sshd/{type,run}`. `type`
  contains `longrun`. `run` starts sshd in the foreground:

  ```sh
  #!/bin/sh
  exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config_kroclaude
  ```

  The Dockerfile activates the service with
  `touch /etc/s6-overlay/s6-rc.d/user/contents.d/sshd` (matching the
  existing `xvfb` pattern).
- **Rationale**: matches feature 001's existing supervisor pattern.
  s6 restarts the daemon if it crashes (FR-010). `-D` keeps sshd in
  the foreground (s6 requires that); `-e` sends logs to stderr (s6
  captures them under `/var/log/...`).
- **Alternatives considered**:
  - **Run sshd inline at the end of `entrypoint.sh`**: defeats
    supervision; if sshd crashes the container becomes a zombie shell.
    Rejected.
  - **`tini` + custom watchdog script**: more shell code than the
    s6 manifest format. Rejected.

## R4 — SSH host key location and lifecycle

- **Decision**: host keys live in
  `/home/claude/.claude/.ssh-host-keys/`, owned by `claude:claude`.
  The directory is created on first boot if missing. Two key types
  are generated: ed25519 (primary, fast) and RSA-3072 (compatibility
  with older clients). The sshd config references both via
  `HostKey /home/claude/.claude/.ssh-host-keys/ssh_host_ed25519_key`
  and `HostKey /home/claude/.claude/.ssh-host-keys/ssh_host_rsa_key`.
  Keys are NOT regenerated on subsequent boots (FR-009 — fingerprint
  stability across recreate/rebuild).
- **Rationale**: living inside `/home/claude/.claude` puts host keys
  in the existing `kroclaude-config` named volume — survives
  container recreation and image rebuild. No new volume needed.
  Permissions are tight (`0700` on the dir, `0600` on private keys).
- **Alternatives considered**:
  - **`/etc/ssh/`** (the standard location): inside the container's
    image filesystem, NOT the volume — wiped on every container
    recreation. Would force users to accept fingerprint warnings
    every redeploy. Rejected.
  - **A separate named volume just for host keys**: violates feature
    001's "two volumes, no more" stance without enough benefit.
    Rejected.

## R5 — `authorized_keys` seeding from env

- **Decision**: on every container start, the entrypoint writes the
  current value of `KROCLAUDE_SSH_AUTHORIZED_KEY` (verbatim) to
  `/home/claude/.ssh/authorized_keys`, fully replacing prior
  contents. The directory `/home/claude/.ssh/` is created if missing
  with mode `0700`; the file is written with mode `0600`; both owned
  by `claude:claude`. If the env var is unset or empty, the file is
  written empty (so no login is possible, per spec FR-008). This
  stanza does NOT live inside the first-boot sentinel — it must run
  every boot so updates to the env var (e.g., key rotation in
  Coolify's UI) take effect on the next start.
- **Rationale**: matches the feature 002 reflection-stanza pattern.
  Reseeding-from-env on every boot is the simplest correct way to
  satisfy "latest env wins, no merging" (spec edge case "Key changes
  at runtime"). The file is OUTSIDE the named volume's mount point
  (`/home/claude/.ssh` ≠ `/home/claude/.claude`), so it lives in the
  ephemeral container layer — recreated each start, not persisted.
- **Alternatives considered**:
  - **Symlink `~claude/.ssh` into the volume**: persists the file
    but creates a confusing situation where the persisted file might
    diverge from the env var. Reseed-on-boot is cleaner. Rejected.
  - **Write only on first boot (sentinel-guarded)**: breaks key
    rotation and FR-007's "fully replacing any previous contents".
    Rejected.

## R6 — Port mapping and override

- **Decision**: in `docker-compose.yaml`, declare:

  ```yaml
  ports:
    - "${KROCLAUDE_SSH_HOST_PORT:-2221}:2221"
  ```

  The container-side port is fixed at `2221` (matches sshd's `Port`
  directive and the affirmative messaging in CLAUDE.md / quickstart).
  The host-side port defaults to `2221` and is overridable via
  `KROCLAUDE_SSH_HOST_PORT` (e.g., set `2222` if `2221` is taken).
- **Rationale**: the simplest "compose file untouched, env var changes
  the host port" UX. Variable name matches the feature 001
  contracts/compose-environment.md naming convention.
- **Alternatives considered**:
  - **Host-network mode**: removes the port-mapping problem but
    forces all of the container's other networking onto the host net,
    which has unrelated security implications and is generally
    discouraged on Coolify. Rejected.
  - **Dynamic in-container port**: complicates the "ssh on 2221"
    messaging and requires the entrypoint to rewrite sshd_config at
    boot. Pure overhead. Rejected.

## R7 — Healthcheck extension

- **Decision**: extend the existing healthcheck command from
  feature 001 with a TCP listen check on port 2221. Final command
  string:

  ```text
  pgrep -x Xvfb >/dev/null && \
  command -v claude >/dev/null && \
  bash -c '</dev/tcp/127.0.0.1/2221' 2>/dev/null
  ```

  The `bash -c '</dev/tcp/host/port'` builtin opens a TCP connection
  with no extra binaries needed. Returns 0 if the port is listening,
  non-zero otherwise.
- **Rationale**: spec FR-011 mandates that healthy require the SSH
  listener too. Using bash's TCP builtin avoids adding `nc` / `nmap`
  / `curl` to the image (already present, but the TCP-builtin form
  is the leanest and most portable).
- **Alternatives considered**:
  - **`ss -lnt sport = :2221`** (`iproute2`, already in the image):
    works, slightly more verbose. Either is fine — go with the
    `/dev/tcp` form for terseness.
  - **Full SSH-handshake probe**: would catch sshd misconfig that
    bash's TCP open would miss, but adds a real ssh client invocation
    every 30 s (sshd log noise, marginal CPU). Rejected as overkill
    — auth is exercised by the smoke suite, not the healthcheck.

## R8 — Smoke test approach (`tests/smoke/test_us4.sh`)

- **Decision**: write a new smoke test file with these phases:
  1. Generate a throwaway ed25519 keypair under `mktemp -d`.
  2. Set `KROCLAUDE_SSH_AUTHORIZED_KEY` to the public part; `up -d`
     the stack with that env in scope; `wait_healthy`.
  3. **Positive**: `ssh -i $TMP_KEY -p 2221 -o
     StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     claude@127.0.0.1 'claude --version'` → exit 0, output matches.
  4. **Configuration via env**: confirm
     `~claude/.ssh/authorized_keys` content equals the env var; rotate
     the env var to a NEW key, restart, confirm OLD key now fails and
     NEW key now works.
  5. **Negative**:
     - password-only auth offer → rejected
     - `ssh root@…` → rejected
     - wrong key → rejected
  6. **Persistence**: down/up cycle, fingerprint unchanged (capture
     the host key, recreate the container, re-capture, `diff`).
  7. Cleanup: remove the tmp keys, `compose down -v`.
- **Rationale**: covers all three user stories end-to-end with a real
  SSH client invocation (no mocking), exercises FR-003..FR-008 +
  FR-009 + FR-011. Keeps SSH-specific harness isolated from the
  existing US1/US2/US3 tests so a SSH regression doesn't blame the
  wrong scenario.
- **Alternatives considered**:
  - **Extend `test_us1.sh`**: cluttered the original test with
    network-path setup/teardown that has nothing to do with US1's
    "spin up a Claude shell" goal. Rejected.
  - **Skip negative tests**: the spec is explicit that all three
    rejection paths must be tested (SC-003). Rejected.

## Open items deferred to `/speckit-tasks`

- Exact wording of the in-container `config/CLAUDE.md` SSH note (per
  spec FR-014) — content choice is a one-line string; defer to task
  authoring.
- Whether to surface the ssh_config-style fingerprint preview in the
  quickstart docs — pure ergonomic polish; defer.
- Concrete pinning of `openssh-server` apt version — same approach as
  feature 001 (rely on Debian's apt + base-image-digest pinning at
  release).
