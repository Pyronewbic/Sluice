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

Drop a `sluice.config.sh` in a directory and run `sluice`, or just run `sluice` and let it
detect the stack, scaffold the config, and build + run it. You declare what the project
needs, what it may reach, what ports it serves, and the command to run.

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

## Quickstart

Sandbox a coding agent - non-root, sees only this repo, behind the egress firewall, so YOLO mode is
defensible:

```bash
brew install Pyronewbic/tap/sluice     # needs docker or podman
export ANTHROPIC_API_KEY=sk-ant-...     # forwarded into the sandbox, never baked into the image
cd your-project
sluice agent claude                     # also: codex, gemini, cursor, aider, opencode, amp, qwen, crush
```

Or run any project sandboxed, then see where its egress hit a wall:

```bash
cd your-project
sluice            # detect the stack, scaffold a config, build + run it sandboxed
sluice egress     # what it reached vs. what the firewall blocked
```

## Updating

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
sluice learn     # review the hosts the proxy blocked; allow the ones you pick - live, no rebuild
```

When a run exits, sluice prints an **egress receipt**: the hosts it reached (with hit counts)
and any it tried but the firewall blocked - so you see at a glance everything your code or
agent talked to, and a failed fetch points you straight at `sluice learn`. `sluice egress`
shows the same per-host on demand, and `sluice doctor` reports the engine, the mounted project dir,
image freshness, published ports, the effective allowlist, auth env, and the hosts your last run was
blocked from - even before anything is built.

<p align="center"><img src="assets/doctor-demo.gif" width="680" alt="sluice doctor prints a one-screen health panel: the container engine, the mounted project dir (the box's only host path), image freshness (config current), the supply-chain lock (in sync), the published port, the auth env var (set), and the hosts the last run was blocked from (api.openai.com) with a 'sluice learn' hint - green for ok, red for blocked"></p>

`learn` is a **per-host review**, not a rubber-stamp: for each blocked host you **allow / skip /
collapse to a `.domain` wildcard**, so a telemetry or exfil host stays blocked while the real
dependency goes through. Picks are written to the config and applied live (no rebuild); `--apply`
takes them all, `--print` emits the list for CI. For trusted code whose fetcher aborts on the *first*
blocked host, `sluice learn --audit` discovers the full list in one **credential-stripped**,
egress-open run (loudly warned; see [`THREAT_MODEL.md`](THREAT_MODEL.md)). Full walkthrough in the
[gallery](examples/README.md).

`sluice init` does just the scaffold step (no prompt, no run); in CI, a bare `sluice` scaffolds and
stops unless `SLUICE_YES=1`. It infers the stack, run command, and ports for **Node, Python, Deno,
Ruby/Rails, Rust, and Go**; `learn` then fills the one thing you can't guess statically - the egress
allowlist. Any other language runs too: set `SLUICE_EXTRA_PKGS` + `SLUICE_RUN_CMD` and the generic
base handles the rest.

The commands you'll reach for:

```bash
sluice                 # build (if needed) + run SLUICE_RUN_CMD in the sandbox
sluice agent <name>    # run a coding agent (run `sluice agent` with no name to list them)
sluice init [--force]  # scaffold a sluice.config.sh by detecting the repo's stack
sluice learn           # propose the egress allowlist from blocked hosts (--print | --apply | --audit)
sluice run <cmd...>    # an ad-hoc command instead of SLUICE_RUN_CMD
sluice doctor          # health check: engine, image, allowlist, blocked egress (--json)
sluice lock            # inventory apk+npm+pip+gem+go+cargo to sluice.lock (--check | --diff | --enforce | --sbom | --scan)
```

Plus `build` / `rebuild` / `update` / `stop` / `rm` / `prune` for lifecycle and `shell` / `ls` /
`egress` / `logs` / `smoke` to inspect - **`sluice help`** lists them all.

> Pre-1.0: the command surface is still stabilizing and may change before the 1.0 lock.

### What it looks like

`sluice doctor` shows the whole posture at a glance - engine, image freshness, the effective
allowlist, and what the firewall blocked this run:

```
sluice doctor
  engine     Docker version 27.4.0
  config     ~/code/blog/sluice.config.sh
  desc       personal blog
  mount      ~/code/blog
  image      sluice-blog built (config current)
  lock       in sync (142 pkgs)
  allowlist  api.anthropic.com
             base: github.com api.github.com registry.npmjs.org ...
  egress     1 host(s) blocked (last run) - run 'sluice learn' to allow:
             cdn.tracking.example
```

`sluice ls` shows every box on this machine, which one you're in (`*`), and its security posture -
allowlist size, published ports, and whether it's locked:

```
sluice boxes
  NAME         STATUS    STACK       ALLOW  PORTS  LOCK    PATH         DESCRIPTION
* sluice-blog  running   node/astro  3      4321   locked  ~/code/blog  personal blog
  sluice-api   built     python      7      8000   -       ~/code/api   internal API
```

ALLOW/PORTS come from build-time labels, so they show `-` until the box is next rebuilt
(`sluice rebuild`/`update`). `sluice ls --egress` adds a BLOCKED column - a live count of
denied-but-unallowed hosts per running box (it execs into each, so it's opt-in and slower).

Filter with `sluice ls --running`, `--orphans` (boxes whose project dir was deleted, marked `(gone)`),
or `--stack <name>`. `sluice prune --orphans` removes just the orphans. To act on a box from anywhere
without `cd`-ing into its project, put `-b <name>` (the short slug or full `sluice-<name>`) before the
command, e.g. `sluice -b api egress` or `sluice -b api shell`; it echoes the target to stderr.

`ls`, `doctor`, and `egress` all take `--json` for scripting and CI - e.g. `sluice egress --json`
emits the box's reached-vs-blocked hosts as a machine-readable audit record.

`sluice lock` writes a committable `sluice.lock` - a full inventory of the image (every apk, npm,
pip, gem, go, and cargo package with its version and digest) so what's in your sandbox is reviewable
in a diff, and `sluice doctor` flags drift. It's an audit artifact, not a reproducibility guarantee
(Wolfi's apk repo is rolling). `--check` turns drift into a **CI gate** (`--enforce` is the strict
variant: it refuses to build or to tolerate a stale image), `--diff` reviews it locally, `--sbom`
emits a deterministic SBOM (**CycloneDX 1.6** or **SPDX** via `--format`), and **`--scan`** vuln-checks
the box with a host **Grype/Trivy** (`--fail-on <severity>` to gate CI):

```bash
sluice lock --check                  # fail the build if the sandbox drifted from sluice.lock
sluice lock --sbom > sbom.cdx.json   # CycloneDX inventory (apk/npm/pip/gem/go/cargo purls), byte-stable
sluice lock --scan --fail-on high    # vuln-scan the box; non-zero exit on a high+ CVE (needs host grype/trivy)
```

<p align="center"><img src="assets/lock-demo.gif" width="700" alt="sluice lock --check reports the inventory in sync; after a dependency is added and the box rebuilt, lock --check catches the drift (classified: + apk tree, exit 1); re-lock records the supply-chain delta, then a CycloneDX SBOM carries the new package with its purl and SHA-1 integrity hash; finally lock --scan --fail-on high runs that SBOM through a host grype and gates the build on the lodash CVEs (non-zero exit)"></p>

Image and container are named per project (`sluice-<dir>`, or `SLUICE_NAME`), and the image
auto-rebuilds when `sluice.config.sh` or the core changes.

### Run a coding agent

`sluice agent <name>` drops you into a coding agent that's non-root, sees only this repo,
and can only reach its own model API - so running it in YOLO mode is defensible:

```bash
export ANTHROPIC_API_KEY=sk-ant-...     # forwarded into the sluice, never baked into the image
cd my-repo
sluice agent claude                     # Claude Code, --dangerously-skip-permissions, sandboxed
sluice agent claude -p "fix the test"   # one-shot: args after the name are forwarded to the agent
```

Presets ship for **claude**, **codex**, **gemini**, **aider**, **cursor**, **opencode**, **amp**,
**qwen**, and **crush** (see [`agents/`](agents/)); each is a normal `sluice.config.sh` declaring the
tool, its API hosts, and which auth env var to forward - so adding an agent is just adding a file. Run
`sluice agent` with no name to list them (each with its auth var and whether it's set on your host).
If the agent hits a blocked host, `sluice learn` surfaces it.

Each agent runs in the project's box (named for the directory), so a repo holds **one agent at a
time** - `sluice agent codex` in a repo already set up for claude reuses the claude config (sluice
says so). To run several agents in parallel, give each its own checkout or a **git worktree** (sluice
mounts the git common dir, so each worktree gets an isolated box):

```bash
git worktree add ../myrepo-codex
cd ../myrepo-codex && sluice agent codex   # isolated box + branch, separate from the claude one
```

Sessions persist across runs (via `SLUICE_STATE_DIRS`, kept in a per-project host store under
`~/.local/state/sluice/`), so `sluice agent claude` resumes where you left off and survives a
rebuild or reboot; `sluice doctor` shows what's persisted.

Each preset runs the agent in **YOLO mode by default** (its skip-approvals flag), since the
sluice is the point of the per-action gate being unnecessary. Honest caveat: the sandbox
bounds the blast radius but does not zero it - a YOLO agent can still rewrite the mounted
repo and use any creds you forward, and the allowlist is host-granular. Work on a committed
branch, and see [`THREAT_MODEL.md`](THREAT_MODEL.md) for exactly what is and isn't contained.

## Configure

Everything is driven by `sluice.config.sh`. Copy [`sluice.config.example.sh`](sluice.config.example.sh)
- it documents every knob - and edit. The ones you'll reach for most:

| knob | purpose |
|------|---------|
| `SLUICE_RUN_CMD` | the command a bare `sluice` runs (default: a shell) |
| `SLUICE_EXTRA_PKGS` | extra apk packages baked in at build time |
| `SLUICE_ALLOW_DOMAINS` | runtime egress domains, on top of the base allowlist |
| `SLUICE_ALLOW_IPS` | runtime egress IPs/CIDRs for non-HTTP services |
| `SLUICE_PORTS` | TCP ports to publish (firewall opens a matching inbound rule) |
| `SLUICE_ENV` | host env var names to forward into the session |

The rest - build-time setup, a central egress policy (`SLUICE_POLICY_URL`), scoped TLS
interception (`SLUICE_BUMP_DOMAINS`/`SLUICE_BUMP_URLS`), persisted state, credential staging
(`SLUICE_PRELAUNCH`) - are documented inline in [`sluice.config.example.sh`](sluice.config.example.sh).

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
  shared cloud hosts that could double as an exfil path. For a host you control,
  `SLUICE_BUMP_DOMAINS` opts into decrypting it for per-URL filtering (off by default;
  see [THREAT_MODEL](THREAT_MODEL.md#scoped-tls-interception-opt-in-off-by-default)).
- **Signed core (opt-in).** Build FROM a cosign-signed base image (`SLUICE_BASE_IMAGE`)
  instead of rebuilding `core/` locally; sluice verifies the signature and its CycloneDX
  SBOM attestation first. The image carries no key (the splice cert is generated per-container).

Build-time setup (`SLUICE_SETUP_CMDS`) runs on the host *before* the firewall, so clones
and dependency downloads have free egress; the *running* container is locked down.

> Full threat model, trust boundaries, and **known weaknesses** (host-granular - data can
> still be laundered through an *allowed* host): [`THREAT_MODEL.md`](THREAT_MODEL.md).

## Examples

A quick taste - serve JupyterLab from the sluice on `http://localhost:8888` (a Python/pip
stack that needs no runtime egress at all):

```bash
mkdir lab && cp examples/jupyter.config.sh lab/sluice.config.sh
cd lab && sluice                # build + serve; then open http://localhost:8888
```

The full **[gallery](examples/)** has more self-contained demos - a **firewall/exfil** demo
(the egress block, made visible) and **Nix** (a reproducible toolchain baked at build,
contained at runtime) - plus the coding-agent presets. It shows the one runtime gotcha: a host the app needs at runtime must be in
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
completion/               bash + zsh shell completion
packaging/                Homebrew formula
install.sh                curl|sh + local installer
sluice.config.example.sh  documented config template (every knob)
```

Shell completion (commands, flags, agent names) auto-installs via `brew install` / `install.sh`.
Manual: `source completion/sluice.bash` (bash), or add `completion/` to your `fpath` before `compinit` (zsh).

Runs on **docker** or **podman** (auto-detected; override with `SLUICE_ENGINE`). For own-kernel
isolation, `SLUICE_RUNTIME=kata` runs the box as a Kata micro-VM (Linux + containerd/nerdctl). CI
([`.github/workflows/acceptance.yml`](.github/workflows/acceptance.yml)) runs the harness
on Linux Docker; the Linux/Podman legs are validated there rather than on macOS.

## License

[Apache-2.0](LICENSE) - permissive, use it however you like. Found a sandbox escape or
egress bypass? See [SECURITY.md](SECURITY.md).
