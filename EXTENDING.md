# Extending sluice

How sluice grows without sprawling. The public surface is intentionally small and frozen (16 verbs, 6
detected stacks); new capability is supposed to ride the cheapest mechanism that fits, not add to that
surface. This is the rule we apply to every feature - including our own backlog.

## The ladder

Add capability on the **lowest rung** that does the job. Higher rungs cost more surface and more support
burden, so each step up needs a reason the rung below could not serve.

| Rung | Mechanism | Surface cost | Lives in | Precedent |
|---|---|---|---|---|
| 1 | A preset / example **file** | none (auto-discovered) | `agents/*.config.sh`, `examples/*.config.sh` | the agent presets |
| 2 | A config **knob** (`SLUICE_*`) | additive contract | existing code paths in `bin/sluice` | `SLUICE_POLICY_URL`, `SLUICE_BUMP_DOMAINS` |
| 3 | A **flag** on an existing verb | verb count unchanged | the verb's `case` arm | `lock --scan`, `learn --audit` |
| 4 | A new `--json` field / output mode | additive | the verb's JSON code path | `doctor --json`, `egress --json` |
| 5 | A hidden `__` arm | none (not in `help`) | the early dispatch | `__sbom`, `__parent` |
| 6 | A new **stack** or a new **verb** | spends frozen-surface budget | `cmd_init` / the verb dispatch | gated, rare, justified |

Rungs 1-5 are additive (semver-minor): they only ever add. Rung 6 changes the frozen surface, so it is a
deliberate decision, not a default - reach for it only when no lower rung can express the capability.

## The test: does it branch out too much?

Before building, three questions:

1. **Identity.** Does it stay inside the [THREAT_MODEL](THREAT_MODEL.md) boundary - anti-exfil for code
   you mostly trust? A hosted SaaS, a dev-environment-for-humans, or hostile-tenant isolation is a
   different product, not a sluice feature.
2. **Rung.** Can it ride rungs 1-5 instead of adding a verb or a stack? If yes, it must.
3. **Additivity.** Is it semver-minor - adds without removing, renaming, or changing a default - per the
   README Stability promise?

Three yeses: it fits. A no on (1) is out of scope; a no on (2) or (3) needs an explicit case in the PR.

## How the backlog maps

The same rule sorts what is already planned (see [ROADMAP](ROADMAP.md)):

- More agent presets -> rung 1 (a file each).
- SPDX output, cargo inventory, pinned-version replay -> rung 3 (flags on `lock`).
- `SLUICE_RUNTIME` micro-VM isolation -> rung 2 knob plus an internal run path, no new verb.
- Control plane / fleet -> mostly an external service over the existing `--json` seams.
- More language stacks (PHP, etc.) -> rung 6, on real demand only.

For the mechanics of opening a change (tests, commit style, the surface bar), see
[CONTRIBUTING](CONTRIBUTING.md).
