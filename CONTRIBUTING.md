# Contributing to sluice

Thanks for helping. sluice is a small, security-focused CLI, so the bar is correctness and a tiny,
predictable surface. Skim the [README](README.md) and [THREAT_MODEL.md](THREAT_MODEL.md) first - they
are the single source of truth for what sluice does and the guarantees it makes.

## Found a security hole?

A sandbox escape or an egress bypass goes through [SECURITY.md](SECURITY.md) (privately), not a public
issue or PR.

## Filing issues

Use the issue forms: a **bug report** (it collects your version, engine, OS, and `sluice doctor`
output) or a **feature request**. Security holes do not go here - see above.

## Dev setup

`bin/sluice` is generated from the `src/*.sh` slices - edit a slice, `make build`, commit both (the
slice map and mechanics: [src/README.md](src/README.md)). Run it straight from a checkout, or
`./install.sh` to symlink it onto your `PATH`. You need **docker** or **podman** (auto-detected;
override with `SLUICE_ENGINE`).

## Run the tests

The suites are [bats-core](https://github.com/bats-core/bats-core), vendored as submodules - run
`make setup` once after a fresh clone. CI runs the same gate suites split across jobs, plus
`make build-check` and shellcheck; `make test` is the local equivalent - run it before opening a PR:

```bash
make test            # gate: CLI/init/install units + egress + security invariants (needs docker/podman)
make test-nightly    # heavy suites: lock, learn, runtimes, nix, agents, control-plane
make structure       # base-image invariants (no sudo, uid 1000, firewall packages) via container-structure-test
make lint-ci         # advisory: actionlint over .github/workflows (mirrors the scans.yml lane)
make test-awk        # re-run the no-Docker lane under every installed awk (see Style: awk portability)
```

Each suite is `test/<name>.bats` (gate) or `test/nightly-<name>.bats` (heavy); shared helpers live in
`test/test_helper/common.bash`. Run just the one your change touches with
`test/bats/bin/bats test/<name>.bats`, and extend it when you change behavior. The no-Docker gate
suites are the `UNIT_BATS` lane in the Makefile (run them all with `make test-unit`); the engine lanes
build real boxes.

## Style

The launcher (`src/*.sh`, assembled into `bin/sluice`) is the code to be careful with: it has to run under the **bash 3.2** that ships on
macOS, so avoid bashisms newer than 3.2 (no associative arrays, no `${var^^}`), and never put a
`case` inside a `$(...)` command substitution - bash 3.2 mis-parses it at runtime and `bash -n`
won't catch it, so run the real command, not just the syntax check. `sluice.config.sh` is sourced as
POSIX `sh` (space/newline strings, no bash arrays). `make lint` runs **shellcheck** (the gate;
`brew install shellcheck`); run it on what you touch, and keep comments terse.

**awk** is the other portability trap: macOS ships one-true-awk, Debian and CI ship mawk, and gawk is
common - they are not interchangeable. Three rules, each of which has already cost a bug:

- JSON strings go through `_json_esc` (shell), **never** an awk escaper - a `gsub` replacement
  containing a backslash is interpreted differently per awk.
- Formatting numbers? Prefix the invocation with `LC_ALL=C` - `printf "%f"` takes its radix from the
  locale in bwk/mawk but not gawk, so a comma-decimal host renders `5,10 GB` on one awk and `5.10 GB`
  on another.
- Passing data in? Use the environment and `ENVIRON["x"]`, not `-v x=...` - awk escape-processes a
  `-v` value (bwk drops a backslash, mawk keeps it, gawk drops it *and* warns).

Also avoid gawk-only builtins (`gensub`) and `{n}` regex intervals (mawk without `--re-interval` never
matches them - spell the repeat out). `make test-awk` re-runs the no-Docker lane under every awk you
have installed (`brew install mawk gawk`) - run it when you touch awk.

## Pull requests

- Keep the verb surface small and behavior predictable; a new knob needs a real use case. See
  [EXTENDING.md](EXTENDING.md) for which mechanism a new capability should use (prefer the lowest rung).
- A new knob PR ships the full set: a commented stub in `sluice.config.example.sh`, an entry in
  [docs/configuration.md](docs/configuration.md), a row in the README knob table if it is headline,
  and a `verify-<knob>.bats` gate suite (security knobs follow the `verify-security-<knob>.bats`
  pattern).
- A new agent preset is a rung-1 file - follow the preset contract in [agents/README.md](agents/README.md).
- Match the [Conventional Commits](https://www.conventionalcommits.org) style already in the log
  (`feat:`, `fix:`, `docs:`, `chore:`, with a scope when it helps).
- Keep docs lean - link to a single source of truth instead of duplicating it.
- Tests green (above); note the OS + engine you tested on (maintainers cover the Linux/Podman legs in CI).

By contributing you agree your work is licensed under the repo's [Apache-2.0](LICENSE) license.
