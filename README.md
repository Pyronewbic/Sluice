# sluice

<img src="assets/logo-badge.svg" width="84" align="right" alt="sluice logo">

[![CI](https://github.com/Pyronewbic/Sluice/actions/workflows/acceptance.yml/badge.svg)](https://github.com/Pyronewbic/Sluice/actions/workflows/acceptance.yml)
[![Release](https://img.shields.io/github/v/release/Pyronewbic/Sluice?color=blue)](https://github.com/Pyronewbic/Sluice/releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

A sandboxed, firewalled, isolated container for any project - drop a `sluice.config.sh`
in a directory and run `sluice`. The sluice runs untrusted code/dependencies behind a
**default-DROP egress firewall** (only allowlisted hosts are reachable), as a
**non-root user**, seeing **only that project directory**. Declare what software the
project needs, what it may reach on the network, what ports it serves, and the command
to run - sluice builds the image and runs it.

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

The installer symlinks `bin/sluice` into `~/.local/bin` (ensure it's on `PATH`). Needs
**docker** or **podman** to build and run (`sluice init` needs neither).

### Updating

Update the **sluice CLI itself** (not to be confused with `sluice update`, which rebuilds your
project's sandbox) via your installer:

```bash
brew upgrade sluice                                # stable
brew upgrade --fetch-HEAD Pyronewbic/tap/sluice    # dev stream (latest main)
curl -fsSL https://raw.githubusercontent.com/Pyronewbic/Sluice/main/install.sh | sh   # script install: re-run to git-pull
```

`sluice version` flags a newer release when one is out (`SLUICE_NO_UPDATE_CHECK=1` skips the check).

## Use

From anywhere inside a project with a `sluice.config.sh` (found by walking up, like git
finds `.git`), `sluice` builds and runs it sandboxed. No config yet? Just run `sluice`: it
detects the stack, scaffolds one, shows what it'll do, and on confirm builds and runs it.

```bash
cd any-repo
sluice           # no config -> scaffold from detection, then (on [Y/n]) build + run
sluice learn     # proposes the hosts to allow (harvested from what the proxy blocked)
sluice rebuild   # apply the allowlist - now sandboxed + firewalled, and working
```

When a run exits, sluice prints a one-line hint of any hosts it blocked, so a failed fetch
points you straight at `sluice learn`. For a fuller picture, `sluice doctor` reports the
engine, image freshness, the effective allowlist, auth env, and the hosts blocked this run -
and works even before anything is built.

`learn` works in enforce mode (it reads what the proxy blocked, never opening egress). For the
one case that can't reach - trusted code whose fetcher aborts on the *first* blocked host -
`sluice learn --audit` runs the command once in a throwaway, **credential-stripped** container with
egress open to all HTTP/HTTPS hosts, then proposes the full allowlist from everything it reached.
It's loudly warned and confirm-gated; see [`THREAT_MODEL.md`](THREAT_MODEL.md).

`sluice init` does just the scaffold step (no prompt, no run) if you'd rather review the
config first; in CI, a bare `sluice` scaffolds and stops unless `SLUICE_YES=1`. `init` infers
the stack, run command, and ports; `learn` fills the one thing you can't guess statically -
the egress allowlist - by observing what the app reached. It covers **Node**
(npm/pnpm/yarn/bun + framework port), **Python** (pip/poetry/uv + framework), **Deno**,
**Ruby/Rails**, **Rust**, and **Go**. Any other language runs too, just without
auto-detection: set `SLUICE_EXTRA_PKGS` (the toolchain's Wolfi apk packages) and
`SLUICE_RUN_CMD`, and the generic base handles the rest.

The full command set:

```bash
# Common
sluice                 # build (if needed) + run SLUICE_RUN_CMD in the sandbox
sluice agent <name>    # run a coding agent (run `sluice agent` with no name to list them)
sluice init [--force]  # scaffold a sluice.config.sh by detecting the repo's stack
sluice learn           # propose the egress allowlist from blocked hosts (--print | --apply | --audit)
sluice shell           # a bash shell in the sandbox (as the non-root sluice user)
sluice run <cmd...>    # an ad-hoc command instead of SLUICE_RUN_CMD

# Build & lifecycle
sluice build           # build the image (if missing or the config changed)
sluice rebuild         # build + recreate the container - apply config/allowlist edits
sluice update          # rebuild from scratch (re-resolve packages) + refresh sluice.lock
sluice stop            # remove the project's container

# Inspect
sluice doctor          # health check: engine, image, allowlist, blocked egress (--json)
sluice ls              # list all sluice boxes on this machine (name, status, stack, path; --json)
sluice egress          # show what this box reached vs. was blocked (--json)
sluice logs            # follow firewall/readiness logs
sluice lock            # record installed apk+npm versions to sluice.lock (supply-chain audit)
sluice smoke           # build (if needed) + run the image smoke test
```

> Pre-1.0: the command surface is still stabilizing and may change before the 1.0 lock.

### What it looks like

`sluice doctor` shows the whole posture at a glance - engine, image freshness, the effective
allowlist, and what the firewall blocked this run:

```
sluice doctor
  engine     Docker version 27.4.0
  config     ~/code/blog/sluice.config.sh
  desc       personal blog
  image      sluice-blog built (config current)
  allowlist  api.anthropic.com
             base: github.com api.github.com registry.npmjs.org ...
  egress     1 host(s) blocked - run 'sluice learn' to allow:
             cdn.tracking.example
```

`sluice ls` shows every box on this machine, and which one you're in (`*`):

```
sluice boxes
  NAME         STATUS    STACK       PATH         DESCRIPTION
* sluice-blog  running   node/astro  ~/code/blog  personal blog
  sluice-api   built     python      ~/code/api   internal API
```

`ls`, `doctor`, and `egress` all take `--json` for scripting and CI - e.g. `sluice egress --json`
emits the box's reached-vs-blocked hosts as a machine-readable audit record.

`sluice lock` writes a committable `sluice.lock` — a full inventory of the image (every apk +
global npm package with its version and digest) so what's in your sandbox is reviewable in a
diff, and `sluice doctor` flags drift. It's an audit artifact, not a reproducibility guarantee:
Wolfi's apk repo is rolling, so `sluice update` re-resolves to current versions on demand.
`sluice lock --check` turns drift into a **CI gate** (exits non-zero if the built image differs
from `sluice.lock`), and `sluice lock --sbom` emits a deterministic **CycloneDX** SBOM for
scanners (Grype/Trivy/Dependency-Track):

```bash
sluice lock --check              # fail the build if the sandbox drifted from sluice.lock
sluice lock --sbom > sbom.cdx.json   # CycloneDX inventory (apk + npm purls), byte-stable
```

Image and container are named per project (`sluice-<dir>`, or `SLUICE_NAME` to override), so
projects never collide. The image auto-rebuilds when `sluice.config.sh` or the core changes
(a config hash is baked as an image label and compared each run).

### Run a coding agent

`sluice agent <name>` drops you into a coding agent that's non-root, sees only this repo,
and can only reach its own model API - so running it in YOLO mode is defensible:

```bash
export ANTHROPIC_API_KEY=sk-ant-...     # forwarded into the sluice, never baked into the image
cd my-repo
sluice agent claude                     # Claude Code, --dangerously-skip-permissions, sandboxed
```

Presets ship for **claude**, **codex**, **gemini**, **aider**, **cursor**, **opencode**, and **amp** (see
[`agents/`](agents/)); each is a normal `sluice.config.sh` declaring the tool, its API
hosts, and which auth env var to forward - so adding an agent is just adding a file. Run
`sluice agent` with no name to list them. If the agent hits a blocked host, `sluice learn`
surfaces it.

Sessions persist across runs: each preset declares the home dir it keeps history/auth in
(`SLUICE_STATE_DIRS`), bind-mounted to a per-project host store under `~/.local/state/sluice/`,
so `sluice agent claude` resumes where you left off and survives a rebuild, `sluice stop`, or
reboot. `sluice doctor` shows what's persisted; wipe it with `rm -rf ~/.local/state/sluice/<name>`.

Each preset runs the agent in **YOLO mode by default** (its skip-approvals flag), since the
sluice is the point of the per-action gate being unnecessary. Honest caveat: the sandbox
bounds the blast radius but does not zero it - a YOLO agent can still rewrite the mounted
repo and use any creds you forward, and the allowlist is host-granular. Work on a committed
branch, and see [`THREAT_MODEL.md`](THREAT_MODEL.md) for exactly what is and isn't contained.

## Configure

Everything is driven by `sluice.config.sh`. Copy [`sluice.config.example.sh`](sluice.config.example.sh)
- it documents every knob - and edit. The knobs, briefly:

| knob | purpose |
|------|---------|
| `SLUICE_NAME` | image/container name `sluice-<name>` (default: the project dir's name) |
| `SLUICE_DESC` | one-line description, shown in `sluice ls` and `sluice doctor` |
| `SLUICE_BASE_IMAGE` | opt-in: build FROM a cosign-signed base image (`ghcr.io/.../sluice-base`) instead of from `core/` |
| `SLUICE_EXTRA_PKGS` | extra apk packages (build time) |
| `SLUICE_EXTRA_NPM` | extra global npm packages, pinned (build time) |
| `SLUICE_SETUP_CMDS` | build-time setup (clones, dep installs) - runs as the sluice user, before the firewall |
| `SLUICE_SETUP_ROOT_CMDS` | build-time setup as root (free egress) - provision outside `$HOME`, e.g. a `/nix` store |
| `SLUICE_ALLOW_DOMAINS` | runtime egress domains, on top of the base |
| `SLUICE_ALLOW_IPS` | runtime egress IPs/CIDRs |
| `SLUICE_POLICY_URL` | URL of a plain-text allowlist fetched on the host and merged in (additive, host-trusted) |
| `SLUICE_PORTS` | TCP ports to publish (firewall opens a matching inbound rule) |
| `SLUICE_RUN_CMD` | the command a bare `sluice` runs (default: a shell) |
| `SLUICE_ENV` | host env var names to forward into the session |
| `SLUICE_MOUNTS` | extra bind mounts (`host:container[:ro]`) |
| `SLUICE_STATE_DIRS` | home-relative dirs to persist across runs (agent sessions/history/auth); host-side, per project |
| `SLUICE_PRELAUNCH` | a function (defined in the config) run on the host before launch, to stage credentials |

`sluice.config.sh` is sourced by `/bin/sh` (Docker build), `bash` (firewall, host), so keep
it POSIX-safe: space/newline-separated strings, **no bash arrays**.

Credential plumbing (token files, minted cloud tokens, etc.) stays in each project's
config via `SLUICE_PRELAUNCH` + `SLUICE_ENV`/`SLUICE_MOUNTS` - the core stays generic.

## Security model

The guardrail that makes running untrusted code defensible:

- **Default-DROP egress, hostname-filtered.** All HTTP/HTTPS is forced through an in-sluice
  proxy (squid) that allows by **Host / TLS-SNI** - spliced, never decrypted - so the
  decision is by *domain* and survives IP rotation. Only the base hosts (npm/yarn
  registries, GitHub git/release hosts) plus `SLUICE_ALLOW_DOMAINS` are reachable;
  `SLUICE_ALLOW_IPS` adds direct egress for non-HTTP services. IPv6 and direct-IP are blocked.
  The firewall self-tests at boot (a denied host must fail; a base host must work).
- **Non-root** (uid 1000) with only `NET_ADMIN`/`NET_RAW`; no Docker-in-Docker.
- **Filesystem isolation:** only the project dir is mounted (plus its git common dir
  when it's a worktree). The sluice can't see the rest of your machine.
- The allowlist is **host-granular** (not per-URL); keep it tight, and avoid allowing
  shared cloud hosts that could double as an exfil path.
- **Signed core (opt-in).** Build FROM a cosign-signed base image (`SLUICE_BASE_IMAGE`)
  instead of rebuilding `core/` locally; sluice verifies the signature first. The image
  carries no key (the splice cert is generated per-container).

Build-time setup (`SLUICE_SETUP_CMDS`) runs on the host *before* the firewall, so clones
and dependency downloads have free egress; the *running* container is locked down.

> Full threat model, trust boundaries, and **known weaknesses** (host-granular - data can
> still be laundered through an *allowed* host): [`THREAT_MODEL.md`](THREAT_MODEL.md).

## Examples

A quick taste - serve the [Strudel](https://strudel.cc) live-coding music REPL from the
sluice on `http://localhost:4321`:

```bash
mkdir strudel && cp examples/strudel.config.sh strudel/sluice.config.sh
cd strudel && sluice            # build + serve; then open http://localhost:4321
```

The full **[gallery](examples/)** has more self-contained demos - a **firewall/exfil** demo
(the egress block, made visible), **Jupyter** (a no-egress Python stack), and **Nix** (a
reproducible toolchain baked at build, contained at runtime) - plus the coding-agent presets. It shows the one runtime gotcha: a host the app needs at runtime must be in
`SLUICE_ALLOW_DOMAINS` (or `sluice learn` it), or the firewall blocks it - sluice flags which
host at exit (and in `sluice doctor`) so you can allow it. For any other stack, `sluice init`
scaffolds the config.

## Layout

```
bin/sluice                the CLI (a single bash script)
core/                     the sandbox image: Dockerfile + squid / firewall / entrypoint
agents/                   coding-agent presets (run `sluice agent` to list)
examples/                 self-contained gallery demos
test/                     acceptance + init-detection (the CI gate) and per-feature verify harnesses
packaging/                Homebrew formula
install.sh                curl|sh + local installer
sluice.config.example.sh  documented config template (every knob)
```

Runs on **docker** or **podman** (auto-detected; override with `SLUICE_ENGINE`). CI
([`.github/workflows/acceptance.yml`](.github/workflows/acceptance.yml)) runs the harness
on Linux Docker; the Linux/Podman legs are validated there rather than on macOS.

## License

[Apache-2.0](LICENSE) - permissive, use it however you like. Found a sandbox escape or
egress bypass? See [SECURITY.md](SECURITY.md).
