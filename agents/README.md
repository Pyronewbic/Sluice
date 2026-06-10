# Agent presets - the contract

A preset (`<name>.config.sh`) is a normal `sluice.config.sh` - knob semantics in
[docs/configuration.md](../docs/configuration.md) - that `sluice agent <name>` copies into the
project as its scaffolded config. User-facing behavior (auth, sessions, worktrees) is documented
in [docs/agents.md](../docs/agents.md); this file is the contract a preset must follow.

## Rules

- **The first comment line is the preset's identity.** `sluice agent` tells which agent a repo is
  scaffolded for by matching the config's first line against every preset (`src/60-main-flow.sh`).
  Keep it unique across presets and never rewrite it in place.
- **Every preset sets**: an install knob (`SLUICE_EXTRA_NPM`, or `SLUICE_SETUP_CMDS` when the agent
  isn't an npm package), `SLUICE_ALLOW_DOMAINS`, `SLUICE_DESC` (shown by the `sluice agent` listing),
  `SLUICE_ENV` (auth vars to forward - the first one is what the listing reports as set/unset),
  `SLUICE_MASK=".env*"`, `SLUICE_STATE_DIRS`, and `SLUICE_RUN_CMD` (the agent with its
  skip-approvals flag; comment which flag to drop for interactive use).
- **The allowlist is tool-only**: the model API and auth hosts the agent needs to function.
  Telemetry hosts stay blocked - name them in a comment so their entries in the egress receipt are
  explained. Do NOT add package-registry hosts: the scaffold unions the detected stack's registries
  into the project's copy (`_stack_registry_hosts`, `src/60-main-flow.sh`); the preset file stays
  stack-agnostic.
- **`SLUICE_STATE_DIRS`** lists the agent's home-relative session/auth dirs. Never a dir holding
  build-baked content (cursor's `.local`, opencode's `.config/opencode`) - the mount would shadow it.
- **The header comment** documents auth (which var, where it comes from) and any quirks.

## Adding a preset

1. `agents/<name>.config.sh` per the rules above.
2. A `@test` line plus an `_agent_probe` case in [`test/nightly-agents.bats`](../test/nightly-agents.bats)
   (cred-free install/egress/env checks; a live round-trip when a key is set). Runs weekly cred-free
   via `agents-smoke.yml`, live via `verify-agents.yml`.
3. Add the name to the preset lists in [`README.md`](../README.md) and [`docs/agents.md`](../docs/agents.md).
