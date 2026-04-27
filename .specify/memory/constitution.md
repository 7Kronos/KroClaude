<!--
SYNC IMPACT REPORT
==================
Version change: TEMPLATE (unratified) → 1.0.0
Bump rationale: Initial ratification — first concrete fill of the placeholder
constitution for the KroClaude project (a Dockerfile/docker-compose deployment
on Coolify providing a reproducible Claude Code shell environment, inspired by
HolyClaude — https://github.com/CoderLuii/HolyClaude).

Modified principles (placeholder → defined):
  - [PRINCIPLE_1_NAME]              → I. Reproducible Builds (NON-NEGOTIABLE)
  - [PRINCIPLE_2_NAME]              → II. Container-First Delivery
  - [PRINCIPLE_3_NAME]              → III. Curated Tooling, Lean Image
  - [PRINCIPLE_4_NAME]              → IV. Coolify-Native Deployment
  - [PRINCIPLE_5_NAME]              → V. Stateless Container, Explicit Persistence

Added sections:
  - Security & Secrets (former [SECTION_2_NAME])
  - Build, Release & Workflow (former [SECTION_3_NAME])
  - Governance (filled)

Removed sections: none.

Templates requiring updates:
  - .specify/templates/plan-template.md       ✅ aligned (Constitution Check
    block references the constitution generically; gates are derived from the
    principles defined here at plan time, no template edit needed)
  - .specify/templates/spec-template.md       ✅ aligned (no
    constitution-specific references)
  - .specify/templates/tasks-template.md      ✅ aligned (sample-only tasks,
    no principle-driven categories to remove or add yet)
  - .specify/templates/checklist-template.md  ✅ aligned (generic)
  - README.md                                 ⚠ pending — file does not yet
    exist; create on first feature describing how to build/run the image
  - docs/quickstart.md                        ⚠ pending — does not yet exist;
    will be produced by /speckit-plan for the first feature

Deferred / TODOs: none. RATIFICATION_DATE is set to 2026-04-27 (today) since
this is the initial adoption.
-->

# KroClaude Constitution

## Core Principles

### I. Reproducible Builds (NON-NEGOTIABLE)

The same `git` revision MUST produce a byte-equivalent (or functionally
equivalent) container image regardless of who builds it or when. To achieve
this:

- All tool versions installed in the image MUST be pinned (apt package
  versions, language toolchain versions, `npm`/`pip`/binary release tags).
- Network-fetched assets MUST be checksum-verified (`sha256sum` or
  signature) inside the Dockerfile.
- The build MUST NOT depend on the host's environment, mounted state, or
  ambient credentials.
- `docker compose build --no-cache` from a clean checkout MUST succeed in
  CI before any tag is published.

Rationale: a Claude Code shell is only useful if "it works on my machine"
extends to every machine. Drift between builds silently breaks user trust.

### II. Container-First Delivery

The Dockerfile and `docker-compose.yml` are the single source of truth for
the runtime environment. Anything a user needs to run KroClaude MUST be
expressible through:

- Environment variables (configuration),
- Volume mounts (persistent data, host project access),
- Compose-declared secrets (credentials, API keys),
- Compose-declared ports/networks (connectivity).

Out-of-band setup steps (manual `docker exec`, host-side installs, README
"also do X" instructions) are forbidden for required functionality. If a
capability cannot be expressed declaratively in the compose stack, it MUST
be redesigned or removed.

Rationale: declarative deployment is what makes the environment portable
across Coolify, local Docker, and CI runners.

### III. Curated Tooling, Lean Image

The image bundles a deliberate, justified set of common developer tools
(shell utilities, language runtimes, version control, network tooling,
editors). New tools MUST clear two gates before being added:

- **Justified**: a written rationale tied to a real Claude Code workflow,
  not "nice to have."
- **Bounded**: the resulting compressed image growth and the long-term
  maintenance burden (CVE surface, version drift) are documented in the
  PR.

Tools that overlap an existing one MUST replace it, not stack alongside.
Final image size SHOULD be tracked per release; a >10% increase in
compressed size requires explicit approval in the amendment record.

Rationale: a kitchen-sink image becomes slow to pull, slow to patch, and
hard to audit. Curation keeps the environment honest.

### IV. Coolify-Native Deployment

KroClaude MUST remain deployable on Coolify using only Coolify's
docker-compose application type, with no host-side patches, no privileged
mode, and no Coolify-version-specific hacks. Concretely:

- The compose file MUST validate against `docker compose config` and
  Coolify's compose loader.
- All persistent data MUST live in named volumes (not bind mounts to
  Coolify-managed paths) so Coolify can manage backup and lifecycle.
- Health checks (`healthcheck:`) MUST be defined for every long-running
  service so Coolify's status indicator is meaningful.
- Secrets MUST be sourced from Coolify environment variables or Coolify
  secrets, never committed to the repo or baked into the image.

Rationale: Coolify is the declared deployment target; breaking its
contract negates the project's reason for existing.

### V. Stateless Container, Explicit Persistence

The container filesystem is treated as ephemeral. Anything that must
survive a redeploy or image rebuild MUST be written to a declared volume.
Persistent state categories MUST be separated into distinct volumes so
they can be backed up, restored, or wiped independently:

- Claude Code configuration and credentials,
- User projects / workspace data,
- Shell history and per-user dotfiles,
- Tool caches (optional; explicitly opt-in, never required for
  correctness).

The image MUST start cleanly with empty volumes — first-run
initialization is the responsibility of the entrypoint, not of a
hand-prepared host. No process inside the container may write critical
state outside a declared volume.

Rationale: ambiguous persistence is the most common cause of "I lost my
work after redeploy" incidents on Coolify.

## Security & Secrets

- The container MUST run as a non-root user by default. Any root-required
  step MUST happen at build time, not at runtime.
- `ANTHROPIC_API_KEY` and any other credential MUST be injected at runtime
  via environment variables or Coolify secrets. They MUST NOT appear in
  the image, in `docker history`, in build args, or in committed files.
- `.env` files containing real values MUST be gitignored; only
  `.env.example` (with placeholder values) is committed.
- Base images MUST be pinned by digest (`@sha256:...`) for release tags;
  floating tags (`:latest`, `:bookworm`) are allowed only on `main`
  development builds.
- A vulnerability scan (e.g., `trivy image`, `docker scout`) MUST run on
  every release tag; HIGH/CRITICAL findings without a documented
  exception block the release.
- Inbound network exposure is limited to ports explicitly published in
  `docker-compose.yml`; everything else stays internal.

## Build, Release & Workflow

- Image tags follow semantic versioning: `MAJOR.MINOR.PATCH`. The image's
  semver is independent of this constitution's version.
- The `main` branch is always buildable; `docker compose build` and
  `docker compose up` MUST succeed on every merge.
- Every PR that changes the Dockerfile or compose file MUST:
  1. Build the image cleanly,
  2. Boot the stack,
  3. Run a smoke check that confirms `claude` (Claude Code CLI) is
     installed, on PATH, and reports its version,
  4. Confirm the listed curated tools are present (automated smoke
     script).
- Breaking changes (removed tools, renamed volumes, incompatible env
  vars) MUST be called out in `CHANGELOG.md` under a `BREAKING:` entry
  and bump the image's MAJOR version.
- Inspiration is acknowledged: KroClaude derives ideas from HolyClaude
  (<https://github.com/CoderLuii/HolyClaude>). Any code or asset reused
  from upstream MUST preserve its license and attribution.

## Governance

This constitution supersedes ad-hoc decisions and informal conventions
within the KroClaude repository. All PRs and reviews MUST verify
compliance with the principles above; reviewers MUST cite the specific
principle when requesting changes on a constitutional ground.

Amendments:

- Proposed via a PR that edits this file and updates the Sync Impact
  Report comment at the top.
- Version bump rules (this constitution, not the image):
  - **MAJOR**: a principle is removed, redefined incompatibly, or a
    governance rule is loosened in a way that invalidates prior
    compliance reviews.
  - **MINOR**: a new principle or section is added, or existing guidance
    is materially expanded.
  - **PATCH**: clarifications, wording, typo fixes, non-semantic
    refinements.
- An amendment PR MUST list which dependent templates and docs were
  reviewed and updated (or explicitly marked as still aligned).
- Complexity that violates a principle MUST be justified in the relevant
  plan's Complexity Tracking table; unjustified violations block merge.

Compliance review: at minimum once per MAJOR image release, a maintainer
walks the principles top-to-bottom against the current image and files an
issue for any drift discovered.

**Version**: 1.0.0 | **Ratified**: 2026-04-27 | **Last Amended**: 2026-04-27
