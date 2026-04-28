# Phase 1 Data Model: Remote SSH Access for Claude Code

**Branch**: `003-ssh-access` | **Date**: 2026-04-28

## Entity: SSH Server

| Field | Value / Constraint |
|-------|--------------------|
| Binary | `/usr/sbin/sshd` (from Debian Bookworm `openssh-server` package) |
| Configuration file | `/etc/ssh/sshd_config_kroclaude` (NOT the default `/etc/ssh/sshd_config` — keeps our overrides isolated) |
| Listen port (in container) | TCP `2221` (fixed; not env-overridable) |
| Supervision | s6-overlay `longrun` service at `/etc/s6-overlay/s6-rc.d/sshd/`; restart-on-crash |
| Run as | root (required to setuid to authenticated user) |
| Auth model | public-key only; no password / kbd-int / PAM-challenge / host-based |
| Allowed users | `claude` only |
| Cipher suite | Mozilla "modern" (chacha20-poly1305, aes256-gcm, aes128-gcm) |

## Entity: Authorized Keys File

| Field | Value / Constraint |
|-------|--------------------|
| Path | `/home/claude/.ssh/authorized_keys` |
| Permissions | mode `0600`, owner `claude:claude` |
| Containing dir | `/home/claude/.ssh/`, mode `0700`, owner `claude:claude` |
| Source | `KROCLAUDE_SSH_AUTHORIZED_KEY` environment variable (verbatim contents — one or more public keys, one per line, comments OK) |
| Update cadence | reseeded on every container start (NOT sentinel-guarded) — latest env wins, FR-007 |
| Persistence | NOT persisted in any volume; recreated each start from env |
| Empty/unset env | file exists, mode `0600`, but content is empty → no login possible (FR-008) |

## Entity: SSH Host Keys

| Field | Value / Constraint |
|-------|--------------------|
| Storage location | `/home/claude/.claude/.ssh-host-keys/` (inside the existing `kroclaude-config` named volume) |
| Permissions | dir `0700`, private keys `0600`, public keys `0644`, owner `claude:claude` |
| Key types | ed25519 (`ssh_host_ed25519_key{,.pub}`) and RSA-3072 (`ssh_host_rsa_key{,.pub}`) |
| Generation | first boot only — the entrypoint runs `ssh-keygen -t ed25519 -N '' -f ...` and `ssh-keygen -t rsa -b 3072 -N '' -f ...` if and only if the corresponding files are missing |
| Persistence guarantee | survives container recreation, image rebuild, and host reboot (via volume) — fingerprint stability for SSH clients (SC-002) |
| Referenced by | `sshd_config_kroclaude` via two `HostKey` directives |

## Entity: Port Mapping

| Field | Value / Constraint |
|-------|--------------------|
| Container side | `2221/tcp`, fixed |
| Host side | `${KROCLAUDE_SSH_HOST_PORT:-2221}/tcp`, configurable per-deployment |
| Protocol | TCP only |
| Declared in | `docker-compose.yaml` `services.kroclaude.ports[]` (additive to feature 001's compose; does NOT change cap_add or security_opt) |
| Coolify exposure | published to public network in default Coolify deployments; firewall/VPN/etc. handled at the network layer, not in-container |

## Entity: SSH Session

A single client connection from a remote workstation to the container.

| Property | Value |
|----------|-------|
| Trigger | client-initiated `ssh -p <host-port> claude@<host>` |
| Authentication | pubkey only (server checks signature against `authorized_keys`) |
| User | `claude` (UID/GID 1000) — same as `docker exec --user claude` lands in |
| Working dir on login | `/workspace` (claude's home is `/home/claude` but the in-image WORKDIR is `/workspace`; sshd respects pw->dir but we'll cd /workspace via login profile) |
| Available env | container env (`ANTHROPIC_API_KEY`, `TZ`, `GIT_*`, `NOTIFY_*`, etc.) is forwarded by sshd via `AcceptEnv` plus PAM session module |
| Exit | normal termination releases the connection; sshd remains supervised |

## Entity: Healthcheck (extended)

| Field | Value (delta from feature 001) |
|-------|--------------------------------|
| Existing checks | `pgrep -x Xvfb >/dev/null` AND `command -v claude >/dev/null` |
| **NEW check** | `bash -c '</dev/tcp/127.0.0.1/2221'` (succeeds iff sshd is listening locally) |
| Final command | `pgrep -x Xvfb >/dev/null && command -v claude >/dev/null && bash -c '</dev/tcp/127.0.0.1/2221' 2>/dev/null` |
| Cadence | unchanged: 30 s interval, 5 s timeout, 30 s start-period, 3 retries |

There are no relationships to model beyond the obvious containment:
the SSH Server reads SSH Host Keys (persisted), reads Authorized Keys
File (reseeded each boot), accepts SSH Sessions on the container side
of the Port Mapping. The Healthcheck samples the SSH Server's listen
socket as one of its three liveness signals.
