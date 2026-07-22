# sluice

<img src="assets/logo-badge.svg" width="84" align="right" alt="sluice logo">

[![CI](https://github.com/Pyronewbic/Sluice/actions/workflows/acceptance.yml/badge.svg)](https://github.com/Pyronewbic/Sluice/actions/workflows/acceptance.yml)
[![Release](https://img.shields.io/github/v/release/Pyronewbic/Sluice?color=blue)](https://github.com/Pyronewbic/Sluice/releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Run any project - or a coding agent in full YOLO mode - in a locked-down container that
**can't read your secrets, reach outside the repo, or phone home**. sluice runs it as a
**non-root user**, seeing **only that project directory**, behind a **default-DROP egress
firewall** (only the hosts you allow, by name, are reachable) - and ends every run with a
**receipt** of exactly what it reached and what the firewall blocked.

<p align="center"><img src="assets/agent-demo.gif" width="680" alt="sluice agent runs a coding agent caged: the presets listed with auth status read live from the host env, 'cat .env' inside the box printing nothing because SLUICE_MASK shadows the secret, and an egress receipt showing api.anthropic.com reached in green and pypi.org blocked in red"></p>

The same cage contains any untrusted **dependency**, too. Here a poisoned npm package's module
code runs the moment your app imports it and tries to steal your `.env` and SSH key and POST them
out - the sandbox masks the secret, never mounts your keys, and drops the exfil, while the install
and import still complete:

<p align="center"><img src="assets/npm-supply-chain.gif" width="680" alt="a routine npm install runs clean, then the app imports a poisoned dependency whose module code harvests secrets: inside the sandbox the .env reads 0 bytes (masked by SLUICE_MASK), ~/.ssh is not mounted, and the exfil POST to the attacker host is dropped by the default-DROP firewall; the install and import still complete, and the egress receipt shows registry.npmjs.org reached in green and the exfil host blocked in red, the record tamper-evident"></p>

Drop a `sluice.config.sh` in a directory and run `sluice`, or just run `sluice` and let it
detect the stack, scaffold the config, and build + run it sandboxed.

**Runs entirely on your machine** - no account, no telemetry, nothing uploaded. The only
network call sluice itself makes is an opt-out check to GitHub for a newer release
(`SLUICE_NO_UPDATE_CHECK=1` to disable).

## Install

```bash
brew install Pyronewbic/tap/sluice
# dev stream (latest main commit):  brew install --HEAD Pyronewbic/tap/sluice
# or:  curl -fsSL https://raw.githubusercontent.com/Pyronewbic/Sluice/main/install.sh | sh
# or, from a checkout:  ./install.sh
```

The installer symlinks `bin/sluice` into `~/.local/bin` (ensure it's on `PATH`). Needs a
**running docker or rootless podman** (Docker Desktop or `podman machine` on macOS;
rootful podman is unsupported - its network backend breaks the box's DNS). `sluice init`
needs no engine at all.

## Quickstart

Sandbox a coding agent - non-root, sees only this repo, behind the egress firewall, so YOLO
mode is defensible:

```bash
export ANTHROPIC_API_KEY=sk-ant-...     # or CLAUDE_CODE_OAUTH_TOKEN; forwarded, never baked
cd your-project
sluice agent claude                     # also: codex, gemini, cursor, aider, opencode, amp, qwen, crush, plandex
```

Or run any project sandboxed, then see where its egress hit a wall:

```bash
cd your-project
sluice            # detect the stack, scaffold a config, build + run it sandboxed
sluice egress     # what it reached vs. what the firewall blocked
```

The first build bakes the sandbox image (a few minutes); reruns reuse it. Done with a
project? `sluice rm` removes its container, image, and overlay volumes.

## Updating

Update the **sluice CLI itself** (not to be confused with `sluice update`, which rebuilds
your project's sandbox) via your installer:

```bash
brew upgrade sluice                                # stable
brew upgrade --fetch-HEAD Pyronewbic/tap/sluice    # dev stream (latest main)
curl -fsSL https://raw.githubusercontent.com/Pyronewbic/Sluice/main/install.sh | sh   # re-run to repin main's latest; SLUICE_REF=<sha> pins a commit
# stable -> dev stream needs a reinstall:  brew uninstall sluice && brew install --HEAD Pyronewbic/tap/sluice
```

`sluice version` flags a newer release when one is out.

## Use

From anywhere inside a project with a `sluice.config.sh` (found by walking up, like git
finds `.git`), `sluice` builds and runs it sandboxed. No config yet? A bare `sluice`
detects the stack (**Node, Python, Deno, Ruby/Rails, Rust, Go, Java, PHP, .NET, Elixir,
Dart** - anything else runs via the generic base), scaffolds the config, and on confirm
builds + runs it.

When a run exits, sluice prints an **egress receipt**: the hosts it reached and any it
tried but the firewall blocked. `sluice learn` then turns the blocked list into your
allowlist with a **per-host review** - allow / skip / collapse to a `.domain` wildcard -
applied live, no rebuild. `sluice doctor` is the one-screen health check: engine, image
freshness, allowlist, persisted state, blocked hosts - plus warnings for what would
silently misbehave in-box (unmasked secret-looking files, symlinks that resolve outside
the mount). Full firewall + learn walkthrough: [examples/](examples/README.md).

The firewall is not just a claim - an allowlisted host gets through, an exfil POST and a
raw-IP bypass are blocked, and the run's audit log is **tamper-evident** (`egress --verify`
flips from green to red if a record is altered).

When a host you actually need is blocked, `sluice learn` allows it from the receipt, live -
see [examples/](examples/README.md) for the full walkthrough.

```bash
sluice                 # build (if needed) + run SLUICE_RUN_CMD in the sandbox
sluice agent <name>    # run a coding agent (no name lists them) - see docs/agents.md
sluice init            # scaffold sluice.config.sh from the detected stack (--force | --update)
sluice learn           # allowlist the blocked hosts you pick (--all | --print | --apply | --audit)
sluice run <cmd...>    # an ad-hoc command instead of SLUICE_RUN_CMD
sluice doctor          # health check + in-box hazard warnings (--json)
sluice lock            # supply-chain inventory to sluice.lock (--check | --sbom | --scan) - see docs/supply-chain.md
sluice diff | apply    # review / write back changes from a protected workspace (SLUICE_WORKSPACE=overlay)
```

Plus `build` / `rebuild` / `update` / `stop` / `rm` / `prune` for lifecycle and `shell` /
`ls` / `egress` / `logs` / `smoke` to inspect - **`sluice help`** lists them all. `ls`,
`doctor`, and `egress` take `--json` for scripting; `egress --export`/`--verify` dump and
integrity-check the run's append-only audit log; `sluice -b <name> <cmd>` targets any box
from anywhere. Full fleet view + egress-audit reference: [docs/operations.md](docs/operations.md).

### What it looks like

```
sluice doctor
  engine     Docker version 27.4.0
  config     ~/code/blog/sluice.config.sh
  mount      ~/code/blog
  image      sluice-blog built (config current)
  lock       in sync (142 pkgs)
  allowlist  api.anthropic.com
             base: github.com api.github.com registry.npmjs.org ...
  egress     1 host(s) blocked (last run) - run 'sluice learn' to allow:
             cdn.tracking.example
```

`sluice ls` shows every box on this machine, which one you're in (`*`), and its posture:

```
sluice ls
  NAME         STATUS    STACK       ALLOW  PORTS  LOCK    PATH         DESCRIPTION
* sluice-blog  running   node/astro  3      4321   locked  ~/code/blog  personal blog
  sluice-api   built     python      7      8000   -       ~/code/api   internal API
```

### Run a coding agent

`sluice agent <name>` drops you into a coding agent that's non-root, sees only this repo,
and can only reach its own model API. Ten presets ship (claude, codex, gemini, aider,
cursor, opencode, amp, qwen, crush, plandex); each runs **YOLO by default** (the sandbox is the
gate), masks `.env*` files from the box, and persists its sessions across rebuilds. The
scaffold also allowlists your stack's package registry, so the agent's first install
doesn't trip the firewall. Auth, parallel agents via git worktrees, and the preset list:
[docs/agents.md](docs/agents.md).

## Configure

Everything is driven by `sluice.config.sh` - copy
[`sluice.config.example.sh`](sluice.config.example.sh) and edit. Every knob, with live-vs-
rebuild semantics: [docs/configuration.md](docs/configuration.md). The ones you'll reach
for most:

| knob | purpose |
|------|---------|
| `SLUICE_RUN_CMD` | the command a bare `sluice` runs (default: a shell) |
| `SLUICE_EXTRA_PKGS` | extra apk packages baked in at build time |
| `SLUICE_ALLOW_DOMAINS` | runtime egress domains, on top of the base allowlist |
| `SLUICE_ALLOW_IPS` | runtime egress IPs/CIDRs for non-HTTP services |
| `SLUICE_PORTS` | TCP ports to publish, bound to host loopback only |
| `SLUICE_ENV` | host env var names to forward into the session |
| `SLUICE_MASK` | in-repo secret globs shadowed from the box (agent presets default `.env*`) |
| `SLUICE_OVERLAY_DIRS` | project dirs given a box-local volume (e.g. `node_modules`) - host contents untouched |

The config contract is POSIX `sh`: space/newline-separated strings, no bash arrays.

## Security model

The guardrails, one line each - full guarantees, trust boundaries, and **known
weaknesses** in [`THREAT_MODEL.md`](THREAT_MODEL.md):

- **Default-DROP egress, hostname-filtered**: all HTTP/HTTPS goes through an in-box proxy
  that allows by Host/TLS-SNI (spliced, never decrypted); DNS is scoped to the allowlist;
  IPv6 and direct-IP are blocked; the firewall self-tests at boot and fails closed.
- **Non-root, capability-stripped**: sessions run uid 1000; the container drops ALL
  capabilities and the root entrypoint keeps only what boot needs, with
  `no-new-privileges` and pids/memory caps.
- **Filesystem isolation**: only the project dir is mounted (plus its git common dir for
  worktrees); `SLUICE_MASK` shadows in-repo secrets from the box.
- **Published ports bind 127.0.0.1** - reachable from your machine only.
- **Opt-in hardening**: a seccomp denylist that supersets the engine default
  (`SLUICE_SECCOMP`), immutable rootfs (`SLUICE_READONLY_ROOT`), a read-only protected
  workspace with `sluice diff`/`apply` (`SLUICE_WORKSPACE=overlay`), and an own-kernel
  micro-VM runtime (`SLUICE_RUNTIME=kata`) - see [docs/hardening.md](docs/hardening.md).
- **Egress volume bounds**: a **preventive** in-box byte cap that stops bytes mid-flight
  (`SLUICE_EGRESS_HARD_CAP_BYTES`, and `SLUICE_ALLOW_IPS_MAX_BYTES` for the direct-IP lane),
  plus detective per-host budgets and an opt-in DNS-tunnel audit - see [docs/hardening.md](docs/hardening.md).
- **Supply chain**: the sandbox builds on Chainguard's `wolfi-base`; an opt-in
  cosign-signed, multi-arch (amd64 + arm64) base image with an SBOM attestation replaces
  the local core build (`SLUICE_BASE_IMAGE`, enforced by `SLUICE_REQUIRE_SIGNED=1`),
  `sluice lock` records what's inside, and `sluice lock --pin` + `SLUICE_PIN=1` builds a
  **verified** pinned replay - see [docs/supply-chain.md](docs/supply-chain.md).
- **Centralized policy**: an org can enforce a deny-capable egress policy (deny hosts, refuse a
  `deny-ip` CIDR overlap, forbid loosening knobs, cap `SLUICE_ALLOW_IPS` count + direct-lane volume)
  that a developer's local config can't override - see [docs/policy.md](docs/policy.md).
- **The honest caveat**: the allowlist is host-granular, so data can still be laundered
  through an *allowed* host - sluice flags such hosts and `SLUICE_EGRESS_MAX_BYTES` caps
  run volume, but read [THREAT_MODEL.md](THREAT_MODEL.md) before trusting it with
  anything that matters.

Build-time setup runs before the firewall (free egress for dependency installs); the
*running* container is locked down.

## Stability

sluice follows [Semantic Versioning](https://semver.org). The **public API** is: the
documented **commands and flags** (`sluice help`), the **`SLUICE_*` config knobs** and the
`sluice.config.sh` contract (sourced as POSIX `sh` - space/newline-separated strings, no
bash arrays), and the **runtime guarantees** in [`THREAT_MODEL.md`](THREAT_MODEL.md)
(default-DROP egress, non-root, project-directory-only mount).

The surface is frozen ahead of 1.0 and stays backward-compatible within a major: new
commands, flags, knobs, detected stacks, agent presets, and `--json` fields may be
**added**, but nothing in the public API is removed, renamed, or has its default changed
in a breaking way without a **major** bump. Anything slated to change is **deprecated
first** (a warning for at least one minor release) before removal in the next major.

**Not part of the stable API** (free to change in any release): the `core/` internals
(Dockerfile, squid / firewall / entrypoint), the image layout and base-image contents,
and exact log/console text.

Release history and per-version notes: [Releases](https://github.com/Pyronewbic/Sluice/releases).

## Examples

The **[gallery](examples/README.md)** is self-contained demos, everyday tasks first: serve
an app and `learn` its one upstream live, let a tool edit a copy you review with
`diff`/`apply`, the firewall/exfil block made visible, a database over `SLUICE_ALLOW_IPS`,
and a Nix toolchain baked at build and contained at runtime.

## Layout

```
bin/sluice                the CLI launcher (one file; generated from src/ by `make build`)
src/                      the launcher in ordered slices - edit here, then `make build`
core/                     the sandbox image: Dockerfile + squid / firewall / entrypoint
agents/                   coding-agent presets + the preset contract (agents/README.md)
docs/                     configuration, agents, hardening, supply-chain references
examples/                 self-contained gallery demos
test/                     gate + nightly bats suites
terraform/                Linux test-runner VM (+ optional Kata micro-VM), driven by sluice-vm.sh
sluice-vm.sh              start/stop/sync/test the runner VM (env-driven; see terraform/README.md)
completion/               bash + zsh shell completion
install.sh                curl|sh + local installer
sluice.config.example.sh  copyable config template
```

Shell completion auto-installs via `brew install` / `install.sh`. For own-kernel isolation,
`SLUICE_RUNTIME=kata` runs the box as a Kata micro-VM (Linux + containerd/nerdctl). CI runs
the gate on Linux Docker + rootless Podman ([acceptance.yml](.github/workflows/acceptance.yml)).

## License

[Apache-2.0](LICENSE) - permissive, use it however you like. Found a sandbox escape or
egress bypass? See [SECURITY.md](SECURITY.md).

## Acknowledgments

The sandbox image builds on [Chainguard](https://www.chainguard.dev/)'s
[`wolfi-base`](https://github.com/wolfi-dev/os) and installs packages from the Wolfi OS
repository, each used under its own open-source license; `sluice lock`/`--sbom` inventory
exactly what is installed on top. sluice is an independent project, not affiliated with,
sponsored by, or endorsed by Chainguard. The test suite uses
[bats-core](https://github.com/bats-core/bats-core) and its helpers, vendored under `test/`.
