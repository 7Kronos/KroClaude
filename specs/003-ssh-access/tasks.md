---

description: "Task list for KroClaude remote SSH access — feature 003-ssh-access"
---

# Tasks: Remote SSH Access for Claude Code

**Input**: Design documents from [/home/krs/Repos/KroClaude/specs/003-ssh-access/](.)
**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: smoke tests are mandated deliverables (Constitution §Build/Release/Workflow + each user story's Independent Test in `spec.md`). This feature gets a brand-new [`tests/smoke/test_us4.sh`](../../tests/smoke/test_us4.sh) since SSH testing has its own harness shape (keypair generation, network path, ssh-client invocations) — keeping it separate prevents SSH regressions from blaming the wrong scenario in the existing `test_us{1,2,3}.sh`.

**Organization**: 25 tasks across Setup (2) + Foundational (10) + US1 (3) + US2 (4) + US3 (3) + Polish (3).

## Format

`- [ ] [TaskID] [P?] [Story?] Description with file path`

- **[P]**: parallelizable (different files, no dependency on incomplete tasks)
- **[Story]**: maps to user stories from [spec.md](spec.md) — US1, US2, US3
- File paths are repo-relative from the project root `/home/krs/Repos/KroClaude/`

## Path Conventions

Same deployment-artifact layout as features 001/002. New surfaces:

- `scripts/sshd_config_kroclaude` — hardened sshd config
- `s6-overlay/s6-rc.d/sshd/{type,run}` — second supervised service
- `tests/smoke/test_us4.sh` — SSH-specific smoke test

Modified existing files: `Dockerfile`, `scripts/entrypoint.sh`, `docker-compose.yaml`, `.env.example`, `config/CLAUDE.md`, `CHANGELOG.md`, `README.md`, `.github/workflows/ci.yml`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: scaffold the new files and the s6 service directory before the foundational changes wire them up.

- [ ] T001 Create the directory `s6-overlay/s6-rc.d/sshd/` (mirroring the existing `s6-overlay/s6-rc.d/xvfb/` layout). It will hold `type` and `run` (T005, T006).
- [ ] T002 [P] Verify [`.dockerignore`](../../.dockerignore) does NOT exclude `scripts/sshd_config_kroclaude` or `s6-overlay/s6-rc.d/sshd/`. Existing patterns shouldn't catch them, but confirm with `docker compose --env-file /dev/null config` after later steps land.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: install sshd, write the hardened config, set up supervision, seed authorized_keys + host keys, extend the healthcheck, publish the port, document the env vars. Every user-story phase depends on this phase.

**⚠️ CRITICAL**: No US task can begin until this phase is complete.

- [ ] T003 In [`Dockerfile`](../../Dockerfile): add `openssh-server` to the existing apt install list (the one that already contains `openssh-client`). Keep alphabetic / category grouping — `openssh-server` goes next to `openssh-client` under the SSH category. Per [research.md §R1](research.md).
- [ ] T004 [P] Write [`scripts/sshd_config_kroclaude`](../../scripts/sshd_config_kroclaude) with the verbatim required-directives block from [contracts/sshd-config.md](contracts/sshd-config.md). Header comment: "KroClaude SSH server — key-only, claude-only, hardened." Includes the two `HostKey` paths, all `*Authentication no` lines, `PermitRootLogin no`, `AllowUsers claude`, modern cipher / KEX / MAC lists, and `Subsystem sftp internal-sftp`.
- [ ] T005 [P] Write [`s6-overlay/s6-rc.d/sshd/type`](../../s6-overlay/s6-rc.d/sshd/type) containing the single line `longrun`.
- [ ] T006 [P] Write [`s6-overlay/s6-rc.d/sshd/run`](../../s6-overlay/s6-rc.d/sshd/run) — a one-line shell script: `#!/bin/sh` shebang, `exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config_kroclaude`. Mark executable (`chmod +x` happens in the Dockerfile, T007).
- [ ] T007 In [`Dockerfile`](../../Dockerfile): after the existing `xvfb` service activation, add (a) `COPY scripts/sshd_config_kroclaude /etc/ssh/sshd_config_kroclaude`, (b) `COPY s6-overlay/s6-rc.d/sshd/type /etc/s6-overlay/s6-rc.d/sshd/type`, (c) `COPY s6-overlay/s6-rc.d/sshd/run /etc/s6-overlay/s6-rc.d/sshd/run`, (d) `RUN chmod +x /etc/s6-overlay/s6-rc.d/sshd/run && touch /etc/s6-overlay/s6-rc.d/user/contents.d/sshd`. Per [research.md §R3](research.md).
- [ ] T008 In [`Dockerfile`](../../Dockerfile): replace the existing `HEALTHCHECK` block with the extended form from [contracts/healthcheck.md](contracts/healthcheck.md):

  ```dockerfile
  HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
      CMD pgrep -x Xvfb >/dev/null \
       && command -v claude >/dev/null \
       && bash -c '</dev/tcp/127.0.0.1/2221' 2>/dev/null
  ```

  Cadence (`--interval`, `--timeout`, `--start-period`, `--retries`) is unchanged. Per FR-011.

- [ ] T009 In [`scripts/entrypoint.sh`](../../scripts/entrypoint.sh): append a new stanza AFTER the existing bundled-skill reflection (feature 002) and BEFORE the `exec /init "$@"` line. Stanza body (per [research.md §R4, §R5](research.md)):

  ```bash
  # ---------- SSH host keys + authorized_keys seeding (feature 003) ----------
  SSH_HOST_KEY_DIR="$CONFIG_DIR/.ssh-host-keys"
  install -d -m 0700 -o claude -g claude "$SSH_HOST_KEY_DIR"
  if [ ! -f "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key" ]; then
      ssh-keygen -t ed25519 -N '' -f "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key" >/dev/null
      chown claude:claude "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key"{,.pub}
      chmod 0600 "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key"
      chmod 0644 "$SSH_HOST_KEY_DIR/ssh_host_ed25519_key.pub"
  fi
  if [ ! -f "$SSH_HOST_KEY_DIR/ssh_host_rsa_key" ]; then
      ssh-keygen -t rsa -b 3072 -N '' -f "$SSH_HOST_KEY_DIR/ssh_host_rsa_key" >/dev/null
      chown claude:claude "$SSH_HOST_KEY_DIR/ssh_host_rsa_key"{,.pub}
      chmod 0600 "$SSH_HOST_KEY_DIR/ssh_host_rsa_key"
      chmod 0644 "$SSH_HOST_KEY_DIR/ssh_host_rsa_key.pub"
  fi

  # Reseed ~claude/.ssh/authorized_keys from env on EVERY boot (NOT
  # gated by the sentinel — latest env wins per FR-007).
  install -d -m 0700 -o claude -g claude "$CLAUDE_HOME/.ssh"
  printf '%s\n' "${KROCLAUDE_SSH_AUTHORIZED_KEY:-}" > "$CLAUDE_HOME/.ssh/authorized_keys"
  chmod 0600 "$CLAUDE_HOME/.ssh/authorized_keys"
  chown claude:claude "$CLAUDE_HOME/.ssh/authorized_keys"
  ```

  The stanza inherits the script's `set -euo pipefail`. Host-key generation is one-shot (FR-009 fingerprint stability); authorized_keys reseeding is every-boot (FR-007).

- [ ] T010 In [`docker-compose.yaml`](../../docker-compose.yaml): (a) add a top-level `ports:` block to the `kroclaude` service: `- "${KROCLAUDE_SSH_HOST_PORT:-2221}:2221"` with an inline comment "Feature 003 — SSH access. Host port overridable via env."; (b) add two new entries to the existing `environment:` block: `KROCLAUDE_SSH_AUTHORIZED_KEY: "${KROCLAUDE_SSH_AUTHORIZED_KEY:-}"` and `KROCLAUDE_SSH_HOST_PORT: "${KROCLAUDE_SSH_HOST_PORT:-2221}"`. Per [contracts/compose-environment.md](contracts/compose-environment.md). Do NOT add any new `cap_add` or `security_opt` (FR-015).
- [ ] T011 [P] In [`.env.example`](../../.env.example): append the two new variables documented in [contracts/compose-environment.md §`.env.example` delta](contracts/compose-environment.md). Header comment: "Optional: SSH access (feature 003-ssh-access)". Both values empty/default in the committed file (FR-016 — no real keys committed).
- [ ] T012 [P] In [`config/CLAUDE.md`](../../config/CLAUDE.md): in the "Out of scope — do not propose" section, REMOVE the line "A web UI, exposing inbound ports, or running an SSH server. This image is shell-only by design." and REPLACE it (in the same section, OR move to an affirmative section) with: "An SSH server is available on container port 2221 with public-key-only auth (env var `KROCLAUDE_SSH_AUTHORIZED_KEY`). Web UIs and other inbound ports remain out of scope." Per FR-014. Keep the rest of the "do not propose" list intact.

**Checkpoint**: foundation ready — Phase 3+ user-story work can begin.

---

## Phase 3: User Story 1 — SSH In and Use Claude Code Remotely (Priority: P1) 🎯 MVP

**Goal**: a developer with a public key configured via env can `ssh -p 2221 claude@host` and land in a working `/workspace` shell where `claude --version` succeeds.

**Independent Test**: per [spec.md US1 Independent Test](spec.md). The smoke test generates a throwaway ed25519 keypair, plumbs the public part through `KROCLAUDE_SSH_AUTHORIZED_KEY`, brings the stack up, and verifies the positive auth path end-to-end.

- [ ] T013 [US1] Write [`tests/smoke/test_us4.sh`](../../tests/smoke/test_us4.sh) shebang and harness: `set -euo pipefail`; `: "${COMPOSE:=docker compose}"`; `SVC=kroclaude`; `export COMPOSE_PROJECT_NAME=kroclaude`; `log()`, `fail()`, `wait_healthy()` (matching the existing test_us2.sh shape); a `TMP_DIR=$(mktemp -d)` step; `ssh-keygen -t ed25519 -N '' -f "$TMP_DIR/id_test1" -q` to generate the first throwaway keypair; an `ssh_test()` helper that wraps `ssh -i $key -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes claude@127.0.0.1 -- "$@"`; cleanup trap that runs `$COMPOSE down --remove-orphans -v` and `rm -rf $TMP_DIR`.
- [ ] T014 [US1] In `tests/smoke/test_us4.sh`: bring up the stack with the test key plumbed in. `KROCLAUDE_SSH_AUTHORIZED_KEY=$(cat "$TMP_DIR/id_test1.pub") $COMPOSE up -d --force-recreate`. Then `wait_healthy` (which now also exercises the SSH listener via the extended healthcheck — FR-011).
- [ ] T015 [US1] In `tests/smoke/test_us4.sh`: positive-auth assertion. `ssh_test "$TMP_DIR/id_test1" 2221 "claude --version" >/tmp/us4_claude_version 2>&1` MUST exit 0; `grep -qE 'Claude Code|^[0-9]+\.[0-9]+\.[0-9]+' /tmp/us4_claude_version` MUST find the CLI's version line. Plus assert `ssh_test "$TMP_DIR/id_test1" 2221 "pwd"` returns `/workspace` (per data-model "Working dir on login"). Plus assert `ssh_test "$TMP_DIR/id_test1" 2221 "id -un"` returns `claude` (FR-005).

**Checkpoint**: User Story 1 fully functional and testable independently. Stop here to demo the MVP if desired.

---

## Phase 4: User Story 2 — Configure SSH Access from Coolify Env (Priority: P1)

**Goal**: changing `KROCLAUDE_SSH_AUTHORIZED_KEY` in the env (Coolify dashboard or `.env`) and redeploying makes the new key in effect and the old key rejected; multiple keys in one env var both work.

**Independent Test**: per [spec.md US2 Independent Test](spec.md). The smoke test rotates keys and verifies "latest env wins, no merging" + multi-key support.

- [ ] T016 [US2] In `tests/smoke/test_us4.sh`: generate a SECOND throwaway keypair: `ssh-keygen -t ed25519 -N '' -f "$TMP_DIR/id_test2" -q`. Restart the stack with ONLY key 2 in env: `KROCLAUDE_SSH_AUTHORIZED_KEY=$(cat "$TMP_DIR/id_test2.pub") $COMPOSE up -d --force-recreate`; `wait_healthy`.
- [ ] T017 [US2] In `tests/smoke/test_us4.sh`: rotation assertion. `ssh_test "$TMP_DIR/id_test2" 2221 'true'` MUST exit 0 (new key works). `ssh_test "$TMP_DIR/id_test1" 2221 'true'` MUST exit non-zero (old key now rejected) — confirms FR-007 "fully replacing any previous contents", spec edge case "Key changes at runtime".
- [ ] T018 [US2] In `tests/smoke/test_us4.sh`: multi-key support. Restart with BOTH keys in env (one per line): `KROCLAUDE_SSH_AUTHORIZED_KEY="$(cat "$TMP_DIR/id_test1.pub")"$'\n'"$(cat "$TMP_DIR/id_test2.pub")" $COMPOSE up -d --force-recreate`; `wait_healthy`. Assert BOTH `ssh_test "$TMP_DIR/id_test1" 2221 'true'` AND `ssh_test "$TMP_DIR/id_test2" 2221 'true'` exit 0 — confirms FR-006 multi-key support.
- [ ] T019 [US2] In `tests/smoke/test_us4.sh`: env-secret hygiene assertion. `docker history --no-trunc --format '{{.CreatedBy}}' kroclaude:dev | grep -F "$(cat "$TMP_DIR/id_test1.pub" | awk '{print $2}')"` MUST exit non-zero (the key MUST NOT appear in the image's layer history) — confirms FR-012 / SC-005.

**Checkpoint**: US1 and US2 fully functional.

---

## Phase 5: User Story 3 — Refuse Passwords / Root / Wrong Keys (Priority: P1)

**Goal**: 100% rejection of password auth, root login, and wrong-key attempts. No fall-back, no banner-only success, no prompt visible to the client.

**Independent Test**: per [spec.md US3 Independent Test](spec.md).

- [ ] T020 [US3] In `tests/smoke/test_us4.sh`: password-auth rejection. `ssh -p 2221 -o PreferredAuthentications=password -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes claude@127.0.0.1 'true' 2>&1 | tee /tmp/us4_pw.log; rc=${PIPESTATUS[0]}` — assert `[ "$rc" != 0 ]` AND `! grep -qi 'password:' /tmp/us4_pw.log` (no password prompt was ever shown). Per FR-003 + SC-003.
- [ ] T021 [US3] In `tests/smoke/test_us4.sh`: root-login rejection. `ssh -i "$TMP_DIR/id_test1" -p 2221 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes root@127.0.0.1 'true' 2>&1 | tee /tmp/us4_root.log; rc=${PIPESTATUS[0]}` — assert `[ "$rc" != 0 ]`. Per FR-004 + SC-003.
- [ ] T022 [US3] In `tests/smoke/test_us4.sh`: wrong-key rejection. Generate a THIRD throwaway keypair (`id_test3`) that is NOT plumbed through env. `ssh_test "$TMP_DIR/id_test3" 2221 'true' 2>&1 | tee /tmp/us4_wrongkey.log; rc=${PIPESTATUS[0]}` — assert `[ "$rc" != 0 ]` AND `grep -q 'Permission denied (publickey)' /tmp/us4_wrongkey.log`. Per spec US3 acceptance scenario 3 + SC-003.

**Checkpoint**: all three user stories independently functional. The full positive + negative SSH surface is covered.

---

## Phase 6 (Final): Polish & Cross-Cutting Concerns

**Purpose**: docs, CI integration, traceability audits.

- [ ] T023 [P] In [`CHANGELOG.md`](../../CHANGELOG.md): add an entry under `[Unreleased]` describing the SSH access feature. Mention: new env vars `KROCLAUDE_SSH_AUTHORIZED_KEY` and `KROCLAUDE_SSH_HOST_PORT` (default 2221); the **MINOR** semver bump rationale (additive, no breaking change to volume layout or compose-env contract); the explicit amendment of feature 001 FR-003 (SSH category was client-only) and feature 001 research §R2 (SSH server was rejected). Per FR-013.
- [ ] T024 [P] In [`README.md`](../../README.md): add a "Remote SSH access" section after the existing "Bundled skills" section, pointing to [`specs/003-ssh-access/quickstart.md`](quickstart.md) and noting the default port (2221) + that auth is key-only.
- [ ] T025 [P] In [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml): add a "Smoke — US4 (SSH access)" step in the `build-and-smoke` job, running `bash tests/smoke/test_us4.sh` after the existing US3 smoke. Place the step BEFORE the failure-artifact upload steps so logs from test_us4.sh are captured if it fails.

---

## Dependencies & Execution Order

### Phase dependencies

- **Phase 1 (Setup)**: no dependencies — can start immediately
- **Phase 2 (Foundational)**: depends on Phase 1; BLOCKS all user-story phases
- **Phase 3 (US1, MVP)**: depends on Phase 2 only
- **Phase 4 (US2)**: depends on Phase 3 (reuses test_us4 harness; T016 builds on the keypair created in T013)
- **Phase 5 (US3)**: depends on Phase 4 (continuation of test_us4; references id_test1 from T013)
- **Phase 6 (Polish)**: T023, T024 are file-isolated and parallelizable; T025 depends on test_us4.sh existing

### Within Phase 2 (Foundational)

- T003 (Dockerfile apt) → T007 (Dockerfile COPY + s6 activation) → T008 (Dockerfile HEALTHCHECK) sequential because all touch Dockerfile
- T004, T005, T006 (new files) all parallelizable with each other and with T003 (different files)
- T009 (entrypoint.sh) is independent of Dockerfile changes
- T010 (compose) is independent
- T011 (.env.example), T012 (config/CLAUDE.md) parallelizable (different files)

### Within Phases 3–5

- All tests live in test_us4.sh, so they're sequential within the file
- Within a single task, the steps are sequential by nature (build, run, assert)

### Parallel opportunities

- Setup: T002 in parallel with T001 (different files)
- Foundational burst: T004, T005, T006, T009, T010, T011, T012 all in parallel after T003 lands. Then T007, T008 sequence on Dockerfile
- Polish: T023, T024, T025 all parallel

---

## Parallel Example: Phase 2 burst

```bash
# After T003 (Dockerfile apt: openssh-server) is committed, fan out:
Task: "T004 — write scripts/sshd_config_kroclaude (per contracts/sshd-config.md)"
Task: "T005 — write s6-overlay/s6-rc.d/sshd/type"
Task: "T006 — write s6-overlay/s6-rc.d/sshd/run"
Task: "T009 — append SSH host-key + authorized_keys stanza to scripts/entrypoint.sh"
Task: "T010 — add ports + env entries to docker-compose.yaml"
Task: "T011 — append SSH env vars to .env.example"
Task: "T012 — flip the SSH guidance in config/CLAUDE.md"
# Then converge on T007 (Dockerfile COPY + s6 activation) and T008
# (Dockerfile HEALTHCHECK update); then user-story phases.
```

---

## Implementation Strategy

### MVP first (User Story 1 only)

1. Phase 1 (Setup) — `s6-overlay/s6-rc.d/sshd/` directory, `.dockerignore` audit
2. Phase 2 (Foundational) — Dockerfile additions, sshd config, s6 service, entrypoint stanza, compose ports/env, .env.example, config/CLAUDE.md, healthcheck update
3. Phase 3 (US1) — smoke harness + positive auth assertion
4. **STOP and validate**: `bash tests/smoke/test_us4.sh` passes US1 portion (T013–T015); a real `ssh -p 2221 claude@localhost` works with a real key
5. Tag a pre-release if you want to cut early (e.g., `v1.2.0-rc.1`)

### Incremental delivery

1. Setup + Foundational + US1 → MVP — `v1.2.0-rc.1`
2. + US2 → key rotation + multi-key validated — `v1.2.0-rc.2`
3. + US3 → security postures asserted — `v1.2.0-rc.3`
4. + Phase 6 (Polish) → docs, CI integration, audits — `v1.2.0`

### Parallel team strategy

After Phase 2 completes:

- Developer A: Phase 3 (US1 — positive auth surface)
- Developer B: Phase 4 (US2 — env + rotation)
- Developer C: Phase 5 (US3 — negative auth surface)

Phase 6 polish can be split task-by-task (each task is `[P]`).

---

## Notes

- `[P]` = different files, no dependency on incomplete tasks
- `[US#]` maps to a user story in [spec.md](spec.md) for traceability
- `tests/smoke/test_us4.sh` is a NEW file — does NOT extend any existing test_us#.sh. SSH testing has its own harness shape (keypair generation, network path) and isolating it makes regressions easier to attribute.
- The smoke test runs in CI alongside US1/US2/US3 (T025). It expects `ssh` client present on the runner — GitHub Actions ubuntu-latest has it by default.
- Avoid: introducing `nc` / `ncat` / `socat` to the smoke test (just use `ssh` directly); reading or writing real user keys (everything is throwaway under `mktemp -d`); persisting `authorized_keys` in any volume (it's reseeded from env every boot per FR-007); adding any new `cap_add` or `security_opt` to the compose file (FR-015).

### FR / SC traceability (filled by audit, written in this commit)

| Spec item | Covered by | Implementation location |
|-----------|------------|-------------------------|
| FR-001 (sshd in image, listens on 2221) | T003, T004, T007 | apt install; sshd_config_kroclaude `Port 2221`; Dockerfile COPY + s6 activation |
| FR-002 (host port overridable) | T010 | compose `ports: ${KROCLAUDE_SSH_HOST_PORT:-2221}:2221` |
| FR-003 (pubkey only; no password/kbdint/PAM-challenge/host-based) | T004 | sshd_config: `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `ChallengeResponseAuthentication no`, `HostbasedAuthentication no`, `PubkeyAuthentication yes`, `AuthenticationMethods publickey` |
| FR-004 (no root login) | T004 | sshd_config: `PermitRootLogin no` |
| FR-005 (claude only) | T004 | sshd_config: `AllowUsers claude` |
| FR-006 (env-driven authorized_keys verbatim contents) | T009, T011 | entrypoint stanza writes env into `authorized_keys`; .env.example documents the var |
| FR-007 (every-boot reseed; latest env wins) | T009, T017 | stanza is OUTSIDE sentinel; rotation smoke test confirms |
| FR-008 (empty env → no login possible) | T009 | empty `printf` produces empty file; sshd refuses (no matching key) |
| FR-009 (host keys persist across recreate / rebuild) | T009 | host keys in `/home/claude/.claude/.ssh-host-keys/` (kroclaude-config volume); generation guarded by `[ ! -f ... ]` |
| FR-010 (sshd supervised, restart on crash) | T005, T006, T007 | s6 longrun service; activated in `user/contents.d/sshd` |
| FR-011 (healthcheck includes SSH listener) | T008 | extended HEALTHCHECK with bash TCP-builtin probe |
| FR-012 (no SSH credentials in image / repo / docker history) | T011, T019 | .env.example holds empty values; smoke asserts via `docker history` grep |
| FR-013 (amends feature 001 FR-003 and research §R2) | T003, T012, T023 | apt list grows; CLAUDE.md guidance flipped; CHANGELOG documents the amendment |
| FR-014 (config/CLAUDE.md updated) | T012 | "no SSH" line removed; affirmative note added |
| FR-015 (no new cap_add or security_opt) | T010 | compose change scoped to `ports:` and `environment:` only |
| FR-016 (`.env.example` documents new vars) | T011 | two new lines, both empty/default values |
| SC-001 (5-min from key to ssh in) | quickstart.md, T015 | quickstart steps; smoke validates the path is short |
| SC-002 (host-key fingerprint stable across 100 cycles) | T009 | one-shot host-key gen; smoke could be extended for multi-cycle if desired |
| SC-003 (100% rejection of password / root / wrong-user) | T020, T021, T022 | three negative scenarios in test_us4.sh |
| SC-004 (healthy iff sshd listening) | T008 | extended HEALTHCHECK |
| SC-005 (zero SSH creds in repo / docker history / layers) | T011, T019 | .env.example empty; smoke `docker history` grep |
| SC-006 (host port overridable without rebuild) | T010, quickstart.md | env-driven compose interpolation |
