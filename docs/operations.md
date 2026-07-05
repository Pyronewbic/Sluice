# Inspecting and auditing your boxes

sluice is multi-box: every project (and every `git worktree`) gets its own sandbox. These commands
inspect the fleet, audit what each box reached, and clean up. The full verb list is in the
[README](../README.md#use) (`sluice help` prints it); this page is the operator's reference for the
fleet view, the egress audit trail, and lifecycle. For *what the egress receipt attests* (and what it
does not), see [THREAT_MODEL.md](../THREAT_MODEL.md#egress-receipts-what-they-attest-and-dont).

## The fleet: `sluice ls`

`sluice ls` lists every box on the machine with its posture - status, stack, allowlist size, published
ports, supply-chain lock state, and project path - and marks the box you are in with `*`:

<p align="center"><img src="../assets/operator-demo.gif" width="760" alt="sluice ls --running lists every running box with its posture (stack, allowlist size, ports, lock, path); sluice ls --egress --running adds the per-box count of hosts each was blocked from; sluice -b targets one box from anywhere and egress --export prints its tamper-evident audit log as JSONL"></p>

Filters and forms (combinable):

- `--running` - only the boxes that are up (the rest are stopped/built but still listed without it).
- `--orphans` - boxes whose project config is gone (left behind by a deleted/moved repo); `sluice prune --orphans` removes them.
- `--stack <name>` - only boxes of one detected stack (`node`, `python`, ...).
- `--egress` - add a per-box count of hosts the firewall blocked (it reads each running box's proxy log).
- `--json` - machine-readable, for scripting a dashboard.

`sluice -b <name> <command>` runs any inspect/lifecycle command against a box **by name, from anywhere** -
no need to `cd` into its project. `sluice -b sluice-api egress`, `sluice -b sluice-api doctor`, etc.

## The egress audit trail

Every run ends with an **egress receipt** - the hosts it reached vs. the ones the firewall blocked, with
byte counts - and appends one record to a host-side, append-only, **hash-chained** log
(`egress-log.jsonl` in the state dir). The sandboxed workload (uid 1000) can write neither the proxy log
nor that store, so it cannot forge or erase an entry (the integrity boundary is detailed in the
[threat model](../THREAT_MODEL.md#egress-receipts-what-they-attest-and-dont)).

```bash
sluice egress             # this box: per-host reached vs. blocked + bytes (--json to script it)
sluice egress --verify    # walk the hash chain; non-zero on any edit, reorder, or deletion
sluice egress --export    # emit the append-only JSONL log (one record per run) for a SIEM or CI
```

`--verify` is the tamper check: each record's `self` hash must recompute and its `prev` must link to the
previous record's `self` (genesis is 64 zeros), so altering, reordering, or dropping a past record is
detectable. `--export` ships the raw chain into a store the producing box can't reach (your SIEM) - that
is what turns tamper-*evident* into non-repudiation.

### Fleet-wide audit: `--all`

`--verify` and `--export` both take `--all` to span **every** box on the machine in one pass:

```bash
sluice egress --verify --all          # walk every box's chain; non-zero if ANY is broken/unreadable
sluice egress --verify --all --json   # {"schema":"sluice.fleet-verify/v1", boxes:[{box,verified,reason,...}]}
sluice egress --export --all           # concatenate every box's JSONL, slug-sorted (each record carries .box)
```

The `--all` paths are **pure host-side file reads** - no container engine, no per-project config - so they
run with the daemon down and cover **orphaned** boxes (a chain outlives its box). Because no config is
sourced, `--all` is chain-integrity only: per-box egress knobs (host budgets, byte caps) do not apply to
it, and `-b <box>` is rejected for `--all` (it spans every box by definition). An unreadable log reports
`verified:false, reason:"unreadable"` - never a silent pass.

## Machine-readable contracts

Every JSON surface carries a `schema` id so a consumer (a dashboard, a CI gate, the future control plane)
can key on it. The compatibility rule: fields are only **added** within a `/v1`; a removal or rename bumps
the suffix. So a `/v1` consumer keeps working as sluice grows.

| Schema | Emitted by | Notes |
|---|---|---|
| `sluice.version/v1` | `version --json` | version, engine, os, install |
| `sluice.doctor/v1` | `doctor --json` | single-box posture |
| `sluice.box/v1` | each `ls --json` element | adds `confighash`, `state_dir`, and `last_receipt` (a verbatim embed of the box's latest egress receipt - a fleet↔audit join; its integrity is attested by `egress --verify`, not by `ls`) |
| `sluice.egress/v1` | `egress --json`, each receipt record | per-host reached/blocked + bytes; `budget`/`over_budget` per host when `SLUICE_EGRESS_HOST_BUDGETS` is set |
| `sluice.egress-verify/v1` | `egress --verify --json` | one box's chain result |
| `sluice.fleet-verify/v1` | `egress --verify --all --json` | every box's chain result |

Every field is additive within its `/v1`; this table is the single registry.

### Gating egress volume in CI

`sluice egress` (and its `SLUICE_EGRESS_MAX_BYTES` gate) is **boot-scoped** - it reports the whole life
of the box, not just the last run; the at-exit receipt is **run-scoped**, so the two can differ.

`SLUICE_EGRESS_MAX_BYTES` caps how much a run may send to the hosts it reached (the exfil-relevant
upload volume). Over the cap, `sluice egress` **exits non-zero**, so it gates a pipeline:

```bash
SLUICE_EGRESS_MAX_BYTES=5242880 sluice run ./build.sh   # run the workload under a 5 MiB budget
sluice egress                                           # CI step: non-zero if the run went over, or
                                                        # if the in-box audit could not be read (fails closed)
```

## Health: `sluice doctor`

`sluice doctor` is the one-screen posture check for a single box - engine, the mounted project dir,
image/lock freshness, the allowlist, and the **in-box hazard warnings** (a secret-looking file the box
can still read, a symlink that resolves outside the mount), ending with the last run's blocked egress and
a `sluice learn` hint. The annotated panel is in the [README](../README.md#what-it-looks-like); `--json`
emits it for monitoring.

## Lifecycle

```bash
sluice stop             # remove this project's container (image kept; next run is fast)
sluice rm               # remove the container AND image (and overlay volumes)
sluice prune --orphans  # remove only boxes whose config is gone; bare `prune` removes every sluice box (confirms)
sluice logs             # follow the box's firewall + readiness logs
```
