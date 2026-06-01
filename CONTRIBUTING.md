# Contributing to sluice

Thanks for helping. sluice is a small, security-focused CLI, so the bar is correctness and a tiny,
predictable surface. Skim the [README](README.md) and [THREAT_MODEL.md](THREAT_MODEL.md) first - they
are the single source of truth for what sluice does and the guarantees it makes.

## Found a security hole?

A sandbox escape or an egress bypass goes through [SECURITY.md](SECURITY.md) (privately), not a public
issue or PR.

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

`ACCEPTANCE_QUICK=1 ./test/acceptance.sh` skips the slow Strudel build. The `test/verify-*.sh`
harnesses cover individual features (lock, learn, ls, seams, agents, runtimes) - run the one your
change touches, and extend it when you change behavior.

## Pull requests

- Keep the verb surface small and behavior predictable; a new knob needs a real use case.
- Match the [Conventional Commits](https://www.conventionalcommits.org) style already in the log
  (`feat:`, `fix:`, `docs:`, `chore:`, with a scope when it helps).
- Keep docs lean - link to a single source of truth instead of duplicating it.
- Tests green (above); note the OS + engine you tested on (maintainers cover the Linux/Podman legs in CI).

By contributing you agree your work is licensed under the repo's [Apache-2.0](LICENSE) license.
