# Feature Specification: Remote SSH Access for Claude Code

**Feature Branch**: `003-ssh-access`
**Created**: 2026-04-28
**Status**: Draft
**Input**: User description: "ssh server we will need ssh server to the
container so we can remotely use claude code. We should introduce a
public ssh key env variable so we can configure the access from coolify
dashboard. We should remove the password challenge system (only
sshkeys). We should use by default port 2221, mapped to host."

## User Scenarios & Testing *(mandatory)*

### User Story 1 — SSH Into the Container and Use Claude Code Remotely (Priority: P1)

A developer working from a different machine wants to use the Claude
Code CLI running inside a deployed KroClaude container. They configure
their public SSH key once via an environment variable (locally in
`.env`, or as a Coolify secret), bring the stack up, and then `ssh`
into the container as the `claude` user on port 2221. They get an
interactive shell where `claude`, `codex`, `gemini`, and the curated
toolchain are all available — with no separate "install Claude on my
laptop" step needed.

**Why this priority**: this is the core motivation for the feature.
Before this, the only way to use Claude Code in a deployed KroClaude
was `docker exec` from the same host running Docker (or Coolify's web
terminal). Remote use unlocks the Coolify-as-personal-development-host
pattern.

**Independent Test**: from a workstation different from the host
running the stack, set `KROCLAUDE_SSH_AUTHORIZED_KEY` to the
workstation's public key, deploy the stack, then run
`ssh -p 2221 claude@<host>`. Verify the connection succeeds, `claude
--version` works in the resulting shell, and `/workspace` is the
working directory.

**Acceptance Scenarios**:

1. **Given** a deployed stack with `KROCLAUDE_SSH_AUTHORIZED_KEY` set
   to a valid public key, **When** the user runs `ssh -p 2221 claude@<host>` from a workstation whose private key matches,
   **Then** they land in an interactive shell as the `claude` user
   with `/workspace` as the working directory.
2. **Given** the SSH session above, **When** the user runs `claude`,
   **Then** the CLI launches and authenticates using the
   `ANTHROPIC_API_KEY` from the container's environment.
3. **Given** an SSH session, **When** the user disconnects and
   reconnects, **Then** their workspace files are still present (this
   is just feature 001's persistence guarantee, but it's worth
   re-asserting end-to-end across SSH).

---

### User Story 2 — Configure SSH Access from a Coolify Secret (Priority: P1)

A Coolify operator deploying KroClaude on a managed node wants to
configure who can SSH in without rebuilding the image or editing files
on the host. They paste a public SSH key into the Coolify "Environment
Variables" or "Secrets" UI for the application, save, and (re-)deploy.
The container picks up the key and accepts SSH logins from the matching
private-key holder.

**Why this priority**: Coolify's value proposition is point-and-click
ops; baking SSH keys into the image or requiring host file edits would
defeat that. This story is the operator-side reason the feature exists.

**Independent Test**: in a Coolify-managed deployment, set the
`KROCLAUDE_SSH_AUTHORIZED_KEY` environment variable in Coolify's UI
(without touching the host filesystem); redeploy; SSH into the
container with the matching private key.

**Acceptance Scenarios**:

1. **Given** a running stack, **When** the operator changes
   `KROCLAUDE_SSH_AUTHORIZED_KEY` in Coolify's UI and redeploys,
   **Then** the new key is in effect and the previously-configured
   key is no longer accepted (latest env wins; no merging).
2. **Given** a key configured at deploy time, **When** the operator
   inspects the running container, **Then** the key value is NOT in
   `docker history`, NOT in any committed file in the source repo,
   and NOT in any image layer (env-vars-only credential surface).
3. **Given** the env variable supports more than one key, **When** the
   operator pastes two public keys (separated by newlines) into the
   variable, **Then** both keys can SSH in.

---

### User Story 3 — Refuse Password Logins, Refuse Root, Refuse Anything but Public Keys (Priority: P1)

The exposed SSH port faces the public internet on Coolify deployments.
The container MUST refuse password authentication, keyboard-interactive
challenges, host-based authentication, and root login outright. The
only way in is a valid public-key match for the `claude` user.

**Why this priority**: an exposed SSH port is the highest-risk surface
this project has ever had. Getting auth wrong here is a direct
compromise. Same priority as the affirmative path (US1/US2).

**Independent Test**: from a workstation, run
`ssh -o PreferredAuthentications=password -p 2221 claude@<host>`,
`ssh -p 2221 root@<host>`, and a connection with a wrong key. All three
MUST be rejected by the server, and the rejection MUST happen at the
SSH-protocol level (not at a fall-through application banner).

**Acceptance Scenarios**:

1. **Given** the SSH server is running, **When** a client offers
   only password auth, **Then** the server refuses (no password
   prompt is ever presented) and disconnects with an authentication
   failure.
2. **Given** any client tries `ssh root@<host>`, **When** the request
   reaches sshd, **Then** the server refuses without prompting.
3. **Given** a client offers a public key not present in the
   container's authorized list, **When** sshd evaluates it, **Then**
   the server rejects with no prompt and no fall-back to other auth.
4. **Given** the `KROCLAUDE_SSH_AUTHORIZED_KEY` variable is empty or
   unset, **When** sshd starts, **Then** no SSH login is possible (the
   service may run, but `authorized_keys` is empty).

---

### Edge Cases

- **Key changes at runtime**: when the operator updates
  `KROCLAUDE_SSH_AUTHORIZED_KEY` and redeploys, the new value MUST
  fully replace the old one (latest env wins; no merge).
- **Multiple keys in one env var**: the variable contents are treated
  as the literal contents of `authorized_keys` (one or more keys, one
  per line, comments allowed) so an operator can authorise N keys.
- **No key configured**: the SSH service MAY start, but
  `authorized_keys` MUST be empty so no login is possible.
- **Host key persistence**: SSH host keys MUST persist across
  container recreation so users do not see "REMOTE HOST IDENTIFICATION
  HAS CHANGED" warnings every redeploy. Host keys live in the existing
  `kroclaude-config` named volume.
- **Port collision on the host**: the default host port (2221) MUST
  be overridable by an env variable so users with another service on
  2221 can pick a different host port without editing the compose
  file.
- **Coolify behind a public network**: deployments where the host
  exposes 2221 to the internet MUST work without any extra
  configuration; the container does not assume a private network.
- **SSH service crash**: the SSH server MUST be supervised (restart
  on failure) so a transient sshd crash does not lock the operator
  out of an otherwise-healthy container. The container's healthcheck
  MUST also surface SSH death (so Coolify can restart the container if
  supervisor recovery itself fails).
- **`docker exec` access**: existing `docker exec -u claude` access
  MUST continue to work alongside SSH; this feature adds a remote path,
  it does not replace the local one.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The image MUST include and run an OpenSSH-compatible SSH
  server, listening on TCP port 2221 inside the container.
- **FR-002**: The compose file MUST publish container port 2221 to the
  host, with the host port defaulting to 2221 and overridable via an
  environment variable (so users with port conflicts can pick another
  host port without editing the compose file).
- **FR-003**: SSH MUST accept public-key authentication ONLY. Password
  authentication, keyboard-interactive (challenge-response), PAM-based
  auth flows, and host-based auth MUST all be disabled in the SSH
  daemon's configuration.
- **FR-004**: SSH login as `root` MUST be disabled.
- **FR-005**: The only user permitted to SSH into the container is
  `claude`. Any other username MUST be refused at the SSH protocol
  level.
- **FR-006**: A new environment variable (named
  `KROCLAUDE_SSH_AUTHORIZED_KEY` for clarity and Coolify
  discoverability) MUST be readable by the container at runtime. Its
  contents are treated as the verbatim contents of
  `~claude/.ssh/authorized_keys` — one or more public keys, one per
  line, optionally with comments.
- **FR-007**: On every container start, the entrypoint MUST write the
  current value of `KROCLAUDE_SSH_AUTHORIZED_KEY` into
  `~claude/.ssh/authorized_keys`, fully replacing any previous
  contents (latest env wins). The file's mode MUST be `0600` and the
  containing `~claude/.ssh/` directory MUST be `0700`, both owned by
  `claude:claude`.
- **FR-008**: If `KROCLAUDE_SSH_AUTHORIZED_KEY` is unset or empty, the
  entrypoint MUST still ensure `~claude/.ssh/authorized_keys` exists
  but is empty (so no login is possible). The SSH service MAY still
  start in this state.
- **FR-009**: SSH host keys MUST persist across container recreation
  and image rebuilds. They MUST live in the existing
  `kroclaude-config` named volume (not in a new volume), so feature
  001's two-volume model is preserved.
- **FR-010**: The SSH server MUST be supervised — if the daemon dies,
  the supervisor MUST restart it. The container MUST NOT silently
  remain "healthy" without a working SSH service when SSH is the
  feature's user-facing entry point.
- **FR-011**: The container's healthcheck (defined in feature 001)
  MUST be extended to confirm the SSH server is listening on its
  configured port; healthy MUST require both the existing checks
  (Xvfb, claude on PATH) AND the SSH listener.
- **FR-012**: The configured SSH key MUST NOT appear in `docker
  history`, in any committed file in the repo, or in any image layer.
  It is sourced exclusively from the runtime environment.
- **FR-013**: This feature explicitly amends two prior decisions from
  feature 001 in service of US1/US2/US3:
  - Feature 001 FR-003 limited the SSH category to `openssh-client`
    only ("client only — no SSH server"). This feature ADDS
    `openssh-server` to the curated tool set.
  - Feature 001 [research.md §R2](../001-claude-shell-base/research.md)
    rejected an SSH server. That decision is reversed here, with the
    explicit security mitigations enumerated in FR-003 through FR-005
    and FR-012.
- **FR-014**: The in-container default memory file (`config/CLAUDE.md`)
  MUST be updated to reflect that an SSH server is available — the
  current "Out of scope — do not propose: ... an SSH server" line MUST
  be removed and replaced with a one-line note that SSH is available
  on port 2221 with key-based auth, and that the operator configures
  authorized keys via an env variable.
- **FR-015**: The compose file's existing capability and security
  posture (cap_add, security_opt) MUST NOT be expanded by this
  feature. The SSH server MUST run within the existing privilege
  model.
- **FR-016**: The `.env.example` file MUST document
  `KROCLAUDE_SSH_AUTHORIZED_KEY` and the optional host-port-override
  variable, with placeholder/empty values (no real keys committed).

### Key Entities

- **SSH Server**: a long-running daemon that accepts inbound
  connections on the container's port 2221 and authenticates them
  against the authorized-keys file. Restarted by the supervisor on
  crash.
- **Authorized Keys File**: the file at `~claude/.ssh/authorized_keys`
  inside the container. Contents come from the
  `KROCLAUDE_SSH_AUTHORIZED_KEY` environment variable on every
  container start. File permissions: `0600`, owned by `claude:claude`.
- **SSH Host Keys**: the server's identity keys. Persisted in the
  `kroclaude-config` named volume so SSH client fingerprints stay
  stable across container recreation.
- **SSH Port Mapping**: container port 2221 → host port (default
  2221, overridable via env var). Single TCP port; no UDP, no
  alternative protocol.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A first-time operator can go from "I have a public SSH
  key" to "I am SSH'd into the container as `claude`" in under 5
  minutes, with no host-side commands beyond `cp .env.example .env`,
  editing `.env`, and `docker compose up -d`.
- **SC-002**: Across 100 deploy cycles with the same configured SSH
  key, the operator MUST NOT see a "REMOTE HOST IDENTIFICATION HAS
  CHANGED" warning more than once (the first time the host key is
  generated). Persistent host keys means stable fingerprints.
- **SC-003**: A penetration probe attempting password authentication,
  keyboard-interactive auth, root login, or any user other than
  `claude` MUST be rejected by the SSH server in 100% of attempts —
  with no prompt, no banner-only success, no fallback path.
- **SC-004**: The container reaches the `healthy` healthcheck state
  ONLY when the SSH server is actually listening on its configured
  port (along with the existing feature 001 checks). A killed sshd
  MUST flip the container's status to unhealthy within two
  healthcheck intervals.
- **SC-005**: Zero credentials related to SSH (the configured public
  key, host private keys, anything else) appear in the committed
  repository, in `docker history`, or in any built image layer.
- **SC-006**: The default port (2221) is overridable for the host
  side without rebuilding the image or editing the compose file
  (env-var-driven), so operators with a port conflict can deploy
  cleanly.

## Assumptions

- The deployment environment is the same as in features 001 and 002 —
  Linux Docker host, Coolify-managed or local. macOS and Windows are
  best-effort, not first-class.
- Claude Code, Codex, and Gemini CLIs (already installed by feature
  001) all work fine when launched inside an SSH session — the SSH
  TTY allocation, environment, and PATH setup match the
  `docker exec -u claude` UX. We will validate this in the smoke
  suite.
- Coolify deployments expose 2221 to the public internet by default.
  Operators who want to restrict it (firewall, VPN, port knocking)
  apply that at the Coolify or network level; this feature does not
  attempt in-container IP allow-listing.
- The new env variable name `KROCLAUDE_SSH_AUTHORIZED_KEY` is chosen
  for self-documentation (rather than the shorter `SSH_KEY` or
  `AUTHORIZED_KEY`) so it is unambiguous in Coolify's UI alongside
  other apps' variables.
- The host-port-override variable name is `KROCLAUDE_SSH_HOST_PORT`,
  defaulting to 2221, exclusively for the host side of the port
  mapping (the in-container port stays 2221 always so the
  authorized-keys instructions and CLAUDE.md memory are consistent).
- Operators who want multiple authorized keys paste them all into the
  one env variable (one key per line). We do NOT add a separate
  variable per key; that's a complexity v1 doesn't need.
- SSH agent forwarding, X11 forwarding, port forwarding, and SFTP
  defaults are deferred to planning. Reasonable starting point: SFTP
  on, port forwarding on (key-only auth makes it low-risk), agent
  forwarding off, X11 forwarding off (the container has Xvfb
  headless; client X11 doesn't help).
- This feature deliberately revises two earlier design decisions
  documented in feature 001 (FR-003 SSH inclusion; research §R2
  rejecting an SSH server). The rationale is in FR-013.
