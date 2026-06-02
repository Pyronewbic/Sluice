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

The CLI is one bash script, `bin/sluice` - there's no build step. Run it straight from a checkout, or
`./install.sh` to symlink it onto your `PATH`. You need **docker** or **podman** (auto-detected;
override with `SLUICE_ENGINE`).

## Run the tests

CI's gate is two scripts - run them before opening a PR:

```bash
./test/init-detection.sh     # stack-detection unit tests (no engine needed)
./test/acceptance.sh         # end-to-end security invariants (needs docker/podman)
```

The `test/verify-*.sh` harnesses cover individual features (security, lock, learn, control-plane,
agents, runtimes, nix; all share `test/lib.sh`) - run the one your change touches, and extend it
when you change behavior.

## Style

`bin/sluice` is the one file to be careful with: it has to run under the **bash 3.2** that ships on
macOS, so avoid bashisms newer than 3.2 (no associative arrays, no `${var^^}`), and never put a
`case` inside a `$(...)` command substitution - bash 3.2 mis-parses it at runtime and `bash -n`
won't catch it, so run the real command, not just the syntax check. `sluice.config.sh` is sourced as
POSIX `sh` (space/newline strings, no bash arrays). Run **shellcheck** on what you touch, and keep
comments terse.

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
