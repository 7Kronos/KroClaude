# Implementation Plan: Remote SSH Access for Claude Code

**Branch**: `003-ssh-access` | **Date**: 2026-04-28 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from [spec.md](spec.md)

## Summary

Add a hardened OpenSSH server to the KroClaude image, exposing it on
container port `2221` (host port default `2221`, overridable via
`KROCLAUDE_SSH_HOST_PORT`). Authentication is **public-key only** for
the `claude` user — password, keyboard-interactive, PAM-challenge, and
host-based auth are all disabled at the sshd level; root login is
disabled. The authorized public key(s) come from the
`KROCLAUDE_SSH_AUTHORIZED_KEY` environment variable (set in `.env` or
as a Coolify secret) and are reseeded into
`~claude/.ssh/authorized_keys` on every container start. SSH host
keys are generated on first boot and persisted in the existing
`kroclaude-config` named volume so client fingerprints stay stable.

The change adds one apt package (`openssh-server`), one new s6-overlay
service (`sshd`, alongside the existing `xvfb`), one new in-image
config file (`scripts/sshd_config_kroclaude`), and one new entrypoint
stanza (host-key generation + `authorized_keys` seeding). The
healthcheck and `.env.example` are extended; `config/CLAUDE.md` is
updated to remove the now-obsolete "no SSH server" guidance.

This feature **explicitly amends two prior decisions** (feature 001
FR-003 SSH client-only stance, and feature 001 research §R2 rejecting
an SSH server). The amendment is captured in spec FR-013 and re-stated
here so the cross-feature semver impact is visible.

## Technical Context

**Language/Version**: Bash 5.x (entrypoint addition); static OpenSSH
config text (`scripts/sshd_config_kroclaude`); s6-overlay v3 service
manifest.
**Primary Dependencies**: `openssh-server` from Debian Bookworm
(adds to feature 001's curated apt set). Everything else reuses
feature 001's machinery: s6-overlay supervisor, the existing
`scripts/entrypoint.sh`, the `kroclaude-config` named volume.
**Storage**: re-uses the existing `kroclaude-config` named volume.
SSH host keys live in `/home/claude/.claude/.ssh-host-keys/` (inside
that volume). User `authorized_keys` is reseeded every boot from the
env var into `/home/claude/.ssh/authorized_keys` (NOT under the volume
mount — recreated each start, no persistence needed).
**Testing**: a new `tests/smoke/test_us4.sh` covers all three SSH user
stories (positive: connect with key; configuration: env-driven key
seeding; negative: password / root / wrong-key all rejected). The
test generates a throwaway ed25519 keypair under `$TMPDIR`, plumbs the
public part through the env, and runs `ssh -o StrictHostKeyChecking=no
-o UserKnownHostsFile=/dev/null -i <tmp_key> -p 2221 claude@localhost`
assertions against the running container.
**Target Platform**: same as features 001/002 — Linux Docker host,
multi-arch `linux/amd64` + `linux/arm64`. `openssh-server` is
available for both arches on Debian Bookworm.
**Project Type**: extension to the existing deployment artifact.
**Performance Goals**: SSH handshake under 1 s on localhost (no
deliberate cipher slowdowns); host-key generation on first boot under
2 s (ed25519 + RSA-3072); first-boot bootstrap budget from feature 001
(SC-003: <15 s) MUST still hold with this feature added.
**Constraints**: no `privileged: true`; no new `cap_add` or
`security_opt` entries (FR-015); the SSH service runs within the
existing privilege model; only port 2221 is published; in-container
SSH listens on 2221 (not 22).
**Scale/Scope**: single-tenant per container; one or a handful of
authorized keys per deployment (operators can add multiple, one per
line in the env var).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Walking each principle from
[`.specify/memory/constitution.md`](../../.specify/memory/constitution.md)
v1.0.0:

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Reproducible Builds (NON-NEGOTIABLE) | ✅ | `openssh-server` is a pinned apt package; `sshd_config_kroclaude` is checked in; host keys are generated deterministically on first boot. No network fetch at runtime. |
| II. Container-First Delivery | ✅ | New env vars (`KROCLAUDE_SSH_AUTHORIZED_KEY`, `KROCLAUDE_SSH_HOST_PORT`) and a new published port are declared in compose; nothing requires host-side prep beyond setting the env vars. |
| III. Curated Tooling, Lean Image | ✅ | Single new apt package (`openssh-server`, ~5 MB compressed). The base image already has `openssh-client` from feature 001; the server share libraries with the client. Net image growth is small. |
| IV. Coolify-Native Deployment | ✅ | No `privileged: true`, no new `cap_add`, no new `security_opt`. Port `2221` is declaratively published; healthcheck extended. Coolify operators set the SSH key from the secrets UI. |
| V. Stateless Container, Explicit Persistence | ✅ | Host keys live inside the existing `kroclaude-config` volume (no new volume). `authorized_keys` is regenerated from env on every boot — no on-disk credential persistence. |
| Security & Secrets | ⚠ Justified — new public port | This feature deliberately opens a public-internet attack surface (port 2221) for the first time in KroClaude. Mitigations are explicit: pubkey-only auth (no passwords/kbdint/PAM challenge), no root, single allowed user (`claude`), keys never on disk in plaintext outside the volume the operator owns, sshd hardened cipher list. Captured in [research R2](research.md). |
| Build, Release & Workflow | ✅ | This is a **MINOR** image-version bump per the constitution (new capability, no breaking change to volume layout or compose-environment contract — the new port and env vars are additive). CHANGELOG entry mandatory. |
| Feature 001 FR-014 (challenge sh scripts) | ⚠ Justified | One new entrypoint stanza (~10 LOC) for host-key generation + authorized_keys seeding. Justified for the same reason as feature 002: the named volume mount shadows any image-time setup; the seeding has to happen at runtime. See Complexity Tracking. |

**Result**: PASS with two justified deviations:

1. **New public-internet attack surface** — fully captured in spec FR-003..FR-005 + FR-012, plus research R2. Mitigations are concrete and testable.
2. **One new entrypoint stanza** — same FR-014 trade-off as feature 002, identical justification.

### Post-Phase-1 Re-Check

Re-walked all principles after writing [research.md](research.md),
[data-model.md](data-model.md),
[contracts/sshd-config.md](contracts/sshd-config.md),
[contracts/compose-environment.md](contracts/compose-environment.md),
[contracts/healthcheck.md](contracts/healthcheck.md), and
[quickstart.md](quickstart.md). No new violations. Notable:

- The new `sshd` s6 service is the second long-running service (after
  `xvfb`), which retroactively strengthens the user's
  `keep s6-overlay` directive from feature 001 — supervising two
  services is exactly what s6-overlay is for.
- The `config/CLAUDE.md` "do not propose: an SSH server" line is
  removed and replaced with a one-line affirmative note (per spec
  FR-014); no other CLAUDE.md drift.

## Project Structure

### Documentation (this feature)

```text
specs/003-ssh-access/
├── plan.md              # This file
├── research.md          # Phase 0 — decisions and rationales
├── data-model.md        # Phase 1 — entities (SSH Server, Authorized Keys, Host Keys, Port Mapping)
├── quickstart.md        # Phase 1 — operator setup, first SSH, key rotation, port override
├── contracts/
│   ├── sshd-config.md            # Phase 1 — sshd hardening contract
│   ├── compose-environment.md    # Phase 1 — new env vars (delta vs feature 001's contract)
│   └── healthcheck.md            # Phase 1 — extended healthcheck contract (delta vs feature 001's)
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks command — NOT created here)
```

### Source Code (repository root)

Adds two new files and modifies six existing ones:

```text
KroClaude/
├── scripts/
│   ├── entrypoint.sh                       # MODIFIED — adds host-key gen + authorized_keys seed stanza
│   └── sshd_config_kroclaude               # NEW — hardened sshd config (key-only, claude-only)
├── s6-overlay/
│   └── s6-rc.d/
│       └── sshd/                           # NEW — second supervised service
│           ├── type                        # "longrun"
│           └── run                         # exec sshd -D -e -f /etc/ssh/sshd_config_kroclaude
├── Dockerfile                              # MODIFIED — apt: openssh-server; COPY sshd_config + s6 service
├── docker-compose.yaml                     # MODIFIED — adds env vars + port mapping
├── .env.example                            # MODIFIED — documents new env vars
├── config/CLAUDE.md                        # MODIFIED — removes "no SSH" line; adds affirmative one
├── tests/smoke/test_us4.sh                 # NEW — SSH-specific smoke (positive + negative + config)
└── specs/003-ssh-access/                   # this feature's spec dir
```

**Structure Decision**: extension to feature 001's layout. The new
`sshd` s6 service mirrors the `xvfb` pattern; the new
`sshd_config_kroclaude` lives next to the existing `entrypoint.sh` and
`notify.py` under `scripts/`. A dedicated `tests/smoke/test_us4.sh` is
the right scope (rather than extending an existing test file) because
SSH testing has a different harness shape — it generates a throwaway
keypair, plumbs it through the env, and exercises the network path.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| One new ~10-line shell-script stanza in `scripts/entrypoint.sh` (touches feature 001 FR-014) | Host-key generation must happen at runtime (target dir is in the named volume, which shadows any image-time `COPY`). `authorized_keys` seeding from env must also happen at runtime by definition. Both naturally belong in entrypoint. | Same shape of justification as feature 002's reflection stanza. Init container / standalone bootstrap script / s6 oneshot all add more code than the inline stanza. |
| First public-internet inbound port in KroClaude | Direct user requirement (US1, US2). Closed alternatives — `docker exec` only, Coolify-terminal-only — do not satisfy "use Claude Code remotely". | Tunneling everything over a Coolify-managed reverse proxy with mTLS would be more secure but adds an out-of-band auth setup that defeats the "set one env var, ssh in" UX in spec SC-001. Documented mitigations (pubkey-only, single user, no root, sshd hardened) make the tradeoff acceptable. |
| Image gains a long-running daemon (`sshd`) supervised by s6 | Required by the feature's affirmative path (US1). Without supervision, a sshd crash silently locks the operator out. | A non-supervised `sshd` started inline in entrypoint would not restart on crash. Adding `tini` or rolling-our-own watchdog would be more shell code than s6's existing manifest format. The user already opted into keeping s6-overlay during feature 001 planning; this feature uses s6 exactly as designed. |
