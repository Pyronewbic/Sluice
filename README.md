# sluice

<img src="assets/logo-badge.svg" width="84" align="right" alt="sluice logo">

A sandboxed, firewalled, isolated container for any project - drop a `sluice.config.sh`
in a directory and run `sluice`. The sluice runs untrusted code/dependencies behind a
**default-DROP egress firewall** (only allowlisted hosts are reachable), as a
**non-root user**, seeing **only that project directory**. Declare what software the
project needs, what it may reach on the network, what ports it serves, and the command
to run - sluice builds the image and runs it.

## Install

```bash
brew install Pyronewbic/tap/sluice
# dev stream (latest main commit):  brew install --HEAD Pyronewbic/tap/sluice
# or:  curl -fsSL https://raw.githubusercontent.com/Pyronewbic/Sluice/main/install.sh | sh
# or, from a checkout:  ./install.sh
```

The installer symlinks `bin/sluice` into `~/.local/bin` (ensure it's on `PATH`). Needs
**docker** or **podman** to build and run (`sluice init` needs neither).

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
sluice init [--force]  # scaffold a sluice.config.sh by detecting the repo's stack
sluice agent <name>    # run a coding agent (run `sluice agent` with no name to list them)
sluice learn           # propose the egress allowlist from the hosts the proxy blocked
sluice                 # build (if needed) + run SLUICE_RUN_CMD in the sandbox
sluice shell           # a bash shell in the sandbox (as the non-root sluice user)
sluice run <cmd...>    # an ad-hoc command instead of SLUICE_RUN_CMD
sluice build           # (re)build the project's image
sluice rebuild         # rebuild + recreate the container
sluice lock            # record installed apk+npm versions to sluice.lock (supply-chain audit)
sluice update          # rebuild from scratch (re-resolve packages) + refresh sluice.lock
sluice smoke           # build (if needed) + run the image smoke test
sluice logs            # follow firewall/readiness logs
sluice doctor          # health check: engine, image, allowlist, blocked egress
sluice stop            # remove the project's container
```

`sluice lock` writes a committable `sluice.lock` — a full inventory of the image (every apk +
global npm package with its version and digest) so what's in your sandbox is reviewable in a
diff, and `sluice doctor` flags drift. It's an audit artifact, not a reproducibility guarantee:
Wolfi's apk repo is rolling, so `sluice update` re-resolves to current versions on demand.

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
| `SLUICE_BASE_IMAGE` | opt-in: build FROM a cosign-signed base image (`ghcr.io/.../sluice-base`) instead of from `core/` |
| `SLUICE_EXTRA_PKGS` | extra apk packages (build time) |
| `SLUICE_EXTRA_NPM` | extra global npm packages, pinned (build time) |
| `SLUICE_SETUP_CMDS` | build-time setup (clones, dep installs) - runs as the sluice user, before the firewall |
| `SLUICE_SETUP_ROOT_CMDS` | build-time setup as root (free egress) - provision outside `$HOME`, e.g. a `/nix` store |
| `SLUICE_ALLOW_DOMAINS` | runtime egress domains, on top of the base |
| `SLUICE_ALLOW_IPS` | runtime egress IPs/CIDRs |
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
(the egress block, made visible) and **Jupyter** (a no-egress Python stack) - plus the
coding-agent presets. It shows the one runtime gotcha: a host the app needs at runtime must be in
`SLUICE_ALLOW_DOMAINS` (or `sluice learn` it), or the firewall blocks it - sluice flags which
host at exit (and in `sluice doctor`) so you can allow it. For any other stack, `sluice init`
scaffolds the config.

## Layout

```
bin/sluice                  the global CLI (launcher)
core/Dockerfile          Wolfi base + base tooling (incl. squid) + the SLUICE_* build hooks
core/squid.conf          the egress proxy: allow by Host/SNI, splice (never decrypt)
core/init-firewall.sh    iptables: redirect HTTP/HTTPS to squid, default-DROP rest, IPv6 off
core/entrypoint.sh       starts squid, runs the firewall, then idles
core/smoke-test.sh       image smoke test (base tooling + non-root)
sluice.config.example.sh    documented config template
examples/                self-contained demos (firewall, strudel, jupyter, nix)
agents/                  coding-agent presets (run sluice agent to list them)
test/acceptance.sh       automated pass/fail harness (egress matrix + serve); run by CI
test/init-detection.sh   unit tests for `sluice init` stack detection (no Docker); run by CI
test/verify-runtimes.sh  build-smoke of the runtime fixtures (build + serve); nightly + manual
test/verify-agents.sh    verify agent presets (binary + API hosts + auth) through the proxy; manual
test/fixtures/           one runnable app per runtime (deno/ruby/rust/go/bun/poetry/uv) for the above
install.sh               curl|sh + local installer (symlinks bin/sluice onto PATH)
packaging/               Homebrew formula (for a tap)
SECURITY.md              how to report a vulnerability
THREAT_MODEL.md          trust boundaries + known weaknesses
LICENSE                  Apache-2.0 (permissive)
```

Runs on **docker** or **podman** (auto-detected; override with `SLUICE_ENGINE`). CI
([`.github/workflows/acceptance.yml`](.github/workflows/acceptance.yml)) runs the harness
on Linux Docker; the Linux/Podman legs are validated there rather than on macOS.

## License

[Apache-2.0](LICENSE) - permissive, use it however you like. Found a sandbox escape or
egress bypass? See [SECURITY.md](SECURITY.md).
