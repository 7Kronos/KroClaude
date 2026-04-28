---

description: "Task list template for feature implementation"
---

# Tasks: Docker Container Spawning from KroClaude

**Input**: Design documents from `/specs/004-docker-spawning/`
**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/](contracts/)

**Tests**: Spec FR-012 explicitly requires an end-to-end smoke test
(`tests/smoke/test_us5.sh`), so test tasks ARE included below. The
test is a single bash script built incrementally — Foundational
creates the scaffold, each user story adds its own assertion block.

**Organization**: Tasks are grouped by user story to enable
independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3, US4)
- All file paths are relative to repo root: `/home/krs/Repos/KroClaude/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Workspace prep for the four-helper scripts that will be
written in user-story phases.

- [X] T001 [P] Create empty placeholder files `scripts/kc-run`, `scripts/kc-ps`, `scripts/kc-stop`, `scripts/kc-forward` with `#!/usr/bin/env bash` and `set -euo pipefail` shebang+pragma so subsequent edits have a known starting state. Make each `chmod +x` locally for editor convenience.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Image, compose, entrypoint, and shared docs changes
that EVERY user story depends on. Without these, no `kc-*` helper
can ever run successfully.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T002 In `Dockerfile`, add a new install block AFTER the GitHub CLI block (around line 63) that installs `docker-ce-cli`, `docker-buildx-plugin`, `docker-compose-plugin` from `download.docker.com/linux/debian` (trixie channel) using the same keyring/apt pattern as the gh block. Add a comment header `# ---------- Docker CLI (feature 004-docker-spawning) ----------`. See [research.md §R1](research.md#r1--docker-client-install-official-apt-repo-vs-debians-dockerio).
- [X] T003 In `Dockerfile`, add `COPY scripts/kc-* /usr/local/bin/` next to the existing entrypoint COPY (around line 130-131), and extend the existing `RUN chmod +x` line to include `/usr/local/bin/kc-*`. Verify `/usr/local/bin` is on the SSH-session PATH (already true via line 87, no change needed).
- [X] T004 In `scripts/entrypoint.sh`, insert the socket-GID detection stanza BEFORE the SSH host-keys block (around line 109) and AFTER the bundled-skills block (around line 107). Implement exactly per [contracts/socket-group.md](contracts/socket-group.md). Verify the stanza short-circuits cleanly when the socket is absent (no `set -e` abort).
- [X] T005 In `docker-compose.yaml`, add the docker-socket bind-mount `- /var/run/docker.sock:/var/run/docker.sock` under `services.kroclaude.volumes` (around line 50). Per [contracts/compose-environment.md](contracts/compose-environment.md) §1.
- [X] T006 In `docker-compose.yaml`, add `KROCLAUDE_PUBLIC_HOST: "${KROCLAUDE_PUBLIC_HOST:-}"` under `services.kroclaude.environment` (alongside the other env vars). Per [contracts/compose-environment.md](contracts/compose-environment.md) §2.
- [X] T007 In `docker-compose.yaml`, attach the `kroclaude` service to both networks by adding `networks: [default, kroclaude-apps]` under the service. Add a top-level `networks:` block declaring `kroclaude-apps:` with `name: kroclaude-apps` and `external: true`. Per [contracts/compose-environment.md](contracts/compose-environment.md) §3-4.
- [X] T008 [P] In `.env.example`, append the feature-004 section per [contracts/compose-environment.md](contracts/compose-environment.md) — document `KROCLAUDE_PUBLIC_HOST` (commented out), the one-time `docker network create kroclaude-apps` prerequisite, and the security note about the socket bind-mount being host-root-equivalent.
- [X] T009 [P] Create `tests/smoke/test_us5.sh` skeleton modeled on [`tests/smoke/test_us4.sh`](../../tests/smoke/test_us4.sh): same `COMPOSE`, `wait_healthy`, `cleanup` trap, `log`/`fail` helpers, same shebang and `set -euo pipefail`. The skeleton should bring the stack up with an injected `KROCLAUDE_SSH_AUTHORIZED_KEY` (reuse US4's keygen pattern) and pre-create the `kroclaude-apps` network idempotently (`docker network create kroclaude-apps 2>/dev/null || true`). Register network teardown in the cleanup trap. Each user-story phase appends its own assertion block to this file.

**Checkpoint**: Image builds, container boots, sshd starts, the
shared network exists, and the test scaffold runs end-to-end (with
zero assertions). User story phases can now begin in parallel.

---

## Phase 3: User Story 1 — Spawn a Sibling Container from Inside KroClaude (Priority: P1) 🎯 MVP

**Goal**: From inside KroClaude, the `claude` user can spawn a
sibling container on `kroclaude-apps`, properly labeled, reachable
by name from KroClaude.

**Independent Test**: `docker exec -u claude kroclaude kc-run -d
--rm --name kc-smoke nginx:alpine && docker exec -u claude
kroclaude curl -fsS http://kc-smoke/ | head -1` returns the nginx
welcome HTML.

### Implementation for User Story 1

- [X] T010 [US1] Implement `scripts/kc-run` per [contracts/kc-helpers.md](contracts/kc-helpers.md) §`kc-run`. Argv parsing in bash (no external dep). Required behavior: preflight Docker, parse argv to detect `-p`/`--publish` (always refused), the dangerous-flag set (refused unless `--unsafe`), `--name` (auto-generate `kc-<slug>-<rand6>` if missing), `--network` (default `kroclaude-apps`). On `--unsafe`, strip the flag from argv and emit the audit-log line to stderr per FR-006b. Pass-through everything else to `docker run`. Map exit codes per the contract (0/2/3/4).
- [X] T011 [US1] In `tests/smoke/test_us5.sh`, append the US1 assertion block: (a) `docker exec -u claude kroclaude docker version` exits 0 without `sudo` — proves the entrypoint group bootstrap worked; (b) `kc-run -d --rm --name kc-smoke-nginx nginx:alpine` succeeds; (c) `docker inspect --format '{{ index .Config.Labels "kroclaude.managed" }}' kc-smoke-nginx` prints `true`; (d) `docker inspect --format '{{ json .NetworkSettings.Networks }}' kc-smoke-nginx` contains `kroclaude-apps`; (e) `docker exec -u claude kroclaude curl -fsS http://kc-smoke-nginx/ | head -1` returns the nginx welcome line; (f) `kc-run -p 8080:80 nginx:alpine` exits 3 with the documented refusal; (g) `kc-run --privileged nginx:alpine` exits 3 with the dangerous-flag refusal; (h) `kc-run --unsafe --privileged --rm --name kc-smoke-priv nginx:alpine` succeeds and stderr contains `[kc-run UNSAFE]`. Cleanup `kc-smoke-nginx` and `kc-smoke-priv` at end of block.

**Checkpoint**: User Story 1 fully functional. MVP-shippable as
"developers can spawn containers, but reaching them from a laptop
still requires hand-rolled `ssh -L`."

---

## Phase 4: User Story 2 — Reach a Spawned Container's App Port from a Laptop (Priority: P1)

**Goal**: From inside KroClaude, `kc-forward` prints a ready-to-
paste `ssh -L` command using `KROCLAUDE_PUBLIC_HOST` (or graceful
fallback). The printed command, when run on a laptop, tunnels to
the sibling container's port.

**Independent Test**: with `kc-smoke-nginx` running (US1),
`docker exec -u claude -e KROCLAUDE_PUBLIC_HOST=example.com
kroclaude kc-forward kc-smoke-nginx 80 8080` prints
`ssh -N -L 8080:kc-smoke-nginx:80 -p 2221 claude@example.com`.

### Implementation for User Story 2

- [X] T012 [US2] Implement `scripts/kc-forward` per [contracts/kc-helpers.md](contracts/kc-helpers.md) §`kc-forward`. Required behavior: preflight Docker; require positional args `<container>` and `<port>`, optional `[local-port]` (defaults to `<port>`); accept `--host HOST` per-call override; verify `getent hosts <container> >/dev/null` before printing anything; read `KROCLAUDE_SSH_HOST_PORT` (default 2221) and `KROCLAUDE_PUBLIC_HOST` (no default); when host is empty and `--host` not given, emit the warning line to stderr and substitute literal `<host>` in the printed `ssh` line; print the `ssh -N -L …` line to stdout. Map exit codes per contract.
- [X] T013 [US2] In `tests/smoke/test_us5.sh`, append the US2 assertion block: (a) `kc-forward kc-smoke-nginx 80 8080` (without `KROCLAUDE_PUBLIC_HOST`) prints exactly one warning line to stderr containing `KROCLAUDE_PUBLIC_HOST is unset`, and stdout matches `^ssh -N -L 8080:kc-smoke-nginx:80 -p 2221 claude@<host>$`; (b) re-run with `KROCLAUDE_PUBLIC_HOST=kroclaude.example.test` injected via `-e` — stderr is empty, stdout matches `^ssh -N -L 8080:kc-smoke-nginx:80 -p 2221 claude@kroclaude.example.test$`; (c) `kc-forward nonexistent-container 80` exits 3 with the cannot-resolve message; (d) re-run with `KROCLAUDE_SSH_HOST_PORT=2222` override — printed command uses `-p 2222`. Use `kc-smoke-nginx` from US1 (do not respawn).

**Checkpoint**: Users 1 + 2 complete. The full developer happy-
path (spawn → forward → reach from laptop) works end-to-end.

---

## Phase 5: User Story 3 — Inventory and Clean Up Spawned Containers (Priority: P2)

**Goal**: `kc-ps` shows ONLY KroClaude-managed containers; `kc-stop`
stops + removes labeled containers and refuses unlabeled ones.

**Independent Test**: spawn two `kc-run` containers and one
unlabeled host container (`docker run -d --name foreign
nginx:alpine`); `kc-ps` lists exactly the two; `kc-stop foreign`
exits 3 with the refusal; `kc-stop <managed-name>` succeeds.

### Implementation for User Story 3

- [X] T014 [P] [US3] Implement `scripts/kc-ps` per [contracts/kc-helpers.md](contracts/kc-helpers.md) §`kc-ps`. Required behavior: preflight Docker; accept optional `-a` flag; pass-through to `docker ps --filter label=kroclaude.managed=true --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'` with `-a` propagated when present; reject any other flag with exit 3.
- [X] T015 [P] [US3] Implement `scripts/kc-stop` per [contracts/kc-helpers.md](contracts/kc-helpers.md) §`kc-stop`. Required behavior: preflight Docker; require positional `<NAME>`; accept optional `--keep`; read the `kroclaude.managed` label via `docker inspect`; refuse with exit 3 if label is absent or not `true`; otherwise `docker stop NAME` then (unless `--keep`) `docker rm NAME`; idempotent on already-removed targets (exit 0).
- [X] T016 [US3] In `tests/smoke/test_us5.sh`, append the US3 assertion block: (a) spawn `kc-run -d --rm --name kc-us3-a nginx:alpine` and `kc-run -d --rm --name kc-us3-b nginx:alpine`; spawn an unlabeled `docker run -d --network kroclaude-apps --name kc-us3-foreign nginx:alpine`; (b) `kc-ps` output contains `kc-us3-a` and `kc-us3-b` but NOT `kc-us3-foreign`; (c) `kc-stop kc-us3-foreign` exits 3 with refusal; (d) `kc-stop kc-us3-a` exits 0; second `kc-stop kc-us3-a` also exits 0 (idempotent); (e) cleanup remaining containers including the unlabeled one via raw docker.

**Checkpoint**: Users 1 + 2 + 3 complete. The DX layer is feature-
complete for the happy path.

---

## Phase 6: User Story 4 — Graceful Behavior When Docker Is Not Available (Priority: P2)

**Goal**: When the docker socket is not mounted, the entrypoint
warns and continues, sshd still serves, and `kc-*` helpers exit
non-zero with one-line errors.

**Independent Test**: bring up the stack with the socket bind-
mount removed; assert sshd is healthy; assert `kc-run hello-world`
exits 2 with the documented one-line error; assert
`claude --version` still works.

### Implementation for User Story 4

- [X] T017 [US4] In `tests/smoke/test_us5.sh`, append the US4
  degraded-path assertion block. Strategy: use a second
  `docker compose -f docker-compose.yaml -f tests/smoke/no-socket.override.yaml up -d` invocation against a separate container name (or recreate after teardown). Assertions: (a) container becomes healthy without the socket; (b) entrypoint logs contain the `docker.sock not mounted` warning; (c) `docker exec -u claude kroclaude-nosock kc-run hello-world` exits 2 with stderr matching `docker.sock not available`; (d) `docker exec -u claude kroclaude-nosock claude --version` exits 0; (e) `docker exec -u claude kroclaude-nosock ssh -V` exits 0 (proves SSH stack still intact). Register the second stack in the cleanup trap.
- [X] T018 [US4] Create `tests/smoke/no-socket.override.yaml` — a minimal compose override that omits the `/var/run/docker.sock` bind-mount and renames the container/service to `kroclaude-nosock` so the two stacks don't collide. Use `services: { kroclaude-nosock: { extends: { ... }, container_name: kroclaude-nosock, volumes: [<no socket>] } }` shape, OR more simply duplicate the relevant subset.

**Checkpoint**: All four user stories independently functional.
The feature meets every FR in spec.md.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Wire CI, update top-level docs, run end-to-end
quickstart, ratify constitution check.

- [X] T019 In `.github/workflows/ci.yml`, register `tests/smoke/test_us5.sh` next to the existing `test_us{1..4}.sh` invocations. Verify the workflow's docker setup (it already runs in a docker-enabled runner so the socket is available) — no other changes expected.
- [X] T020 [P] Verify `docker compose config` succeeds against the modified `docker-compose.yaml`. Run locally as a sanity check before pushing.
- [X] T021 [P] Verify CLAUDE.md SPECKIT block points at `specs/004-docker-spawning/plan.md` (already done by /speckit-plan, double-check).
- [X] T022 Run the end-to-end quickstart in [quickstart.md](quickstart.md) §"Verification (smoke)" against a freshly-built image (`docker compose build --no-cache && docker compose up -d`). Confirm all output matches.
- [X] T023 Re-run constitution check after implementation: walk each principle in [`.specify/memory/constitution.md`](../../.specify/memory/constitution.md) v1.0.0 and verify the implemented changes still PASS each gate (matches the table in [plan.md](plan.md) §Constitution Check).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1, T001)**: No dependencies — can start immediately.
- **Foundational (Phase 2, T002–T009)**: Depends on Setup. BLOCKS all user stories.
  - T002, T003 are sequential (both edit Dockerfile, but at distinct sites — could parallelize with care).
  - T004 is independent of T002/T003 (entrypoint.sh).
  - T005, T006, T007 all edit `docker-compose.yaml` — sequential.
  - T008 (.env.example) and T009 (test scaffold) are independent — `[P]` marked.
- **User Stories (Phase 3-6)**: All depend on Foundational completion.
  - US1 (T010, T011): kc-run + smoke phase. Sequential within story.
  - US2 (T012, T013): kc-forward + smoke phase. Sequential within story. Independent of US1 EXCEPT T013 depends on T011 having spawned `kc-smoke-nginx`.
  - US3 (T014, T015, T016): kc-ps and kc-stop are independent files (`[P]`); T016 depends on both.
  - US4 (T017, T018): T018 must exist before T017 can run.
- **Polish (Phase 7)**: Depends on all desired user stories.

### User Story Dependencies

- **US1**: independent of all others. MVP candidate.
- **US2**: shares the smoke-test fixture with US1 (T013 depends on T011 leaving `kc-smoke-nginx` running OR re-spawning it). Functionally independent (different helper).
- **US3**: independent of US1/US2 (its own helpers and smoke phase).
- **US4**: independent (separate compose invocation).

### Within Each User Story

- Implementation task (helper script) before smoke-test task (assertions need the script to exist).
- For US3, both helper-script tasks can run in parallel.

### Parallel Opportunities

- T008 ‖ T009 (Foundational, different files).
- T014 ‖ T015 (US3 helpers, different files).
- T020 ‖ T021 (Polish, different files).
- After Foundational completes, US1, US2, US3, US4 implementation can be staffed in parallel — each touches a distinct script + a distinct section of the smoke test.

---

## Parallel Example: Foundational Phase

```bash
# After T001 (Setup), the dock-touching tasks must be sequential
# per file, but file-distinct ones can parallelize:

# Sequential within Dockerfile:
T002 (install Docker CLI block) → T003 (COPY kc-* + chmod)

# Independent, runnable in parallel with the Dockerfile work:
T004 (entrypoint.sh stanza)

# Sequential within docker-compose.yaml:
T005 (socket mount) → T006 (env var) → T007 (networks)

# Independent, runnable in parallel:
T008 (.env.example)  ‖  T009 (test scaffold)
```

## Parallel Example: User Story 3

```bash
# US3 has two independent helper scripts:
T014 [P] [US3] Implement scripts/kc-ps
T015 [P] [US3] Implement scripts/kc-stop

# Then sequential:
T016 [US3] Append US3 assertions to tests/smoke/test_us5.sh
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. T001 (Setup).
2. T002–T009 (Foundational) — image, compose, entrypoint, scaffold.
3. T010, T011 (US1) — kc-run + smoke phase.
4. **STOP and VALIDATE**: Run `tests/smoke/test_us5.sh` locally; manually `docker exec -u claude kroclaude kc-run -d --rm --name demo nginx:alpine && curl http://demo/`.
5. Demo: developers can spawn containers from inside KroClaude. Reaching them from a laptop is still hand-rolled at this point.

### Incremental Delivery

1. MVP (US1) → Test → Demo.
2. Add US2 (kc-forward) → Test → Demo. Now the full DX promise is delivered.
3. Add US3 (kc-ps, kc-stop) → Test. Quality-of-life polish.
4. Add US4 (degraded-path) → Test. Confidence under failure.
5. Polish: CI wiring + constitution recheck → Merge.

### Sequential Single-Developer Strategy

Given this feature ships a tightly coupled set of helpers (one bash
author can hold all four in their head simultaneously), a single
developer can productively go T001 → T009 → T010 → T011 → T012 → …
in numeric order over a single session. Per-story checkpoints still
matter — run the smoke test after each story's tasks complete to
catch regressions early.

---

## Notes

- [P] tasks = different files, no dependencies. Within a single
  config file (Dockerfile, docker-compose.yaml), tasks editing
  the same file are sequential even if they touch distinct
  sections.
- [Story] label maps task to a spec.md user story for traceability.
- Each user story is independently completable and testable; the
  smoke test is one file but its assertion blocks are gated by
  comment headers so partial completions still run cleanly.
- Verify each smoke phase passes before moving to the next story.
- Commit after each task or logical group (the auto-commit hook
  prompts on each /speckit step boundary).
- The Constitution Check in [plan.md](plan.md) is currently PASSING;
  T023 re-verifies after implementation.
- Avoid: editing scripts/kc-* in conflicting ways across stories
  (each helper has one owning user story per the mapping above).
