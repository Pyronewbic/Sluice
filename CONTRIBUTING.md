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

The CLI ships as one bash script, `bin/sluice`, **assembled from the ordered `src/*.sh` slices** by
`make build` (so the curl-one-file install still works). Edit the slices, not `bin/sluice` directly,
then `make build`; a CI gate (`make build-check`) fails if the committed `bin/sluice` drifts from
`src/`. Run it straight from a checkout, or `./install.sh` to symlink it onto your `PATH`. You need
**docker** or **podman** (auto-detected; override with `SLUICE_ENGINE`).

## Run the tests

The suites are [bats-core](https://github.com/bats-core/bats-core), vendored as submodules - run
`make setup` once after a fresh clone. CI's gate is `make test`; run it before opening a PR:

```bash
make test            # gate: CLI/init/install units + egress + security invariants (needs docker/podman)
make test-nightly    # heavy suites: lock, learn, runtimes, nix, agents, control-plane
make structure       # base-image invariants (no sudo, uid 1000, firewall packages) via container-structure-test
```

Each suite is `test/<name>.bats` (gate) or `test/nightly-<name>.bats` (heavy); shared helpers live in
`test/test_helper/common.bash`. Run the one your change touches, and extend it when you change behavior.

## Style

The launcher (`src/*.sh`, assembled into `bin/sluice`) is the code to be careful with: it has to run under the **bash 3.2** that ships on
macOS, so avoid bashisms newer than 3.2 (no associative arrays, no `${var^^}`), and never put a
`case` inside a `$(...)` command substitution - bash 3.2 mis-parses it at runtime and `bash -n`
won't catch it, so run the real command, not just the syntax check. `sluice.config.sh` is sourced as
POSIX `sh` (space/newline strings, no bash arrays). `make lint` runs **shellcheck** (the gate) plus
**shfmt** `-i 2 -ci` (`brew install shellcheck shfmt`); run it on what you touch, and keep comments terse.

## Pull requests

- Keep the verb surface small and behavior predictable; a new knob needs a real use case. See
  [EXTENDING.md](EXTENDING.md) for which mechanism a new capability should use (prefer the lowest rung).
- Match the [Conventional Commits](https://www.conventionalcommits.org) style already in the log
  (`feat:`, `fix:`, `docs:`, `chore:`, with a scope when it helps).
- Keep docs lean - link to a single source of truth instead of duplicating it.
- Tests green (above); note the OS + engine you tested on (maintainers cover the Linux/Podman legs in CI).

## Code of conduct

This project has a [Code of Conduct](CODE_OF_CONDUCT.md); by taking part you agree to it.

By contributing you agree your work is licensed under the repo's [Apache-2.0](LICENSE) license.
