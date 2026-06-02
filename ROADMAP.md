# Roadmap - to a credible v1

Positioning: **a local, self-hosted sandbox that lets any coding agent or untrusted
dependency run wide-open on your machine without exfiltrating your secrets.** Not a
hosted cloud (e2b/Daytona/Modal/Vercel/Cloudflare/Fly), not Claude-only (Anthropic's
built-in sandbox), not CI-only (StepSecurity Harden-Runner), not a dev-env-for-humans
(Coder/DevPod/Codespaces). The unserved space: developers who **won't ship code to a
SaaS**, want it **tool-agnostic**, and want **drop-in simplicity**.

## v1 cut line

> **v1 = #1-#3 done well + #4 in basic form.** That's the minimum that survives "how is
> this different from `<cloud>` / Anthropic's built-in / Harden-Runner?" - #1-#4 make it
> *defensible*, #5-#6 make it *adoptable*. Everything in "Later" is deliberately deferred
> and should be stated as such, not silently missing.

Ranked by what this field will judge us on.

**Toward 1.0.** The CLI surface stays intentionally changeable pre-1.0 (README says so), so we
keep the free-to-break window open through all of 0.x rather than guessing the final shape now.
Lock-before-1.0 item: a deliberate **command-surface review** - the 16 verbs are grouped now
(Common / Build & lifecycle / Inspect / Meta; `sluice ls` added under Inspect 2026-06-01). **Decided 2026-06-01: build/rebuild/update stay as
verbs** - they're frequent and side-effect-distinct (image / container / lock), unlike `lock`'s
niche, mutually-exclusive `--check`/`--diff`/`--sbom` modes, so the lock-flag precedent doesn't carry over
(docker uses a `--no-cache` flag, but cargo/npm keep `update` a verb - it's case-by-case). **Decided
2026-06-01: keep `smoke`** (harmless, distinct - runs the baked smoke-test.sh - and CI-useful), so the
**16-verb surface is final**. sluice stays a flat-verb task runner, not noun-verb.

**Direction - open (2026-06-02): weight the next cycle toward new features, less on fixes/hardening.**
0.7.0 was hardening-heavy (scoped TLS interception aside: the lean-comment pass, the escape-hatch test
suite, CI-gating the manual verify-* suites, CLI polish). Steer 0.8.x toward net-new capability over
further fix/test passes unless something is actually broken. Kept open - not yet resolved into items.

### 1.0 readiness checklist
1.0 = a **stability commitment**, not new features. The v1 cut line is met and #1-#6 are landed, so
cutting 1.0 is gated on locking the surface + closing (or consciously accepting) the confidence items
below - not on building anything new.

**A. Lock the surface (the hard gate - a decision + a doc change):**
- [x] Decide `smoke`: **KEEP** (decided 2026-06-01). Verb set is final at 16.
- [x] Freeze the verb set + their flags as the 1.0 CLI; freeze the `SLUICE_*` knob names + the
      `sluice.config.sh` contract (POSIX-sh sourced, space/newline strings, no bash arrays) as the
      stable config API. (Decided; the doc that states it is the compat promise below, landed at cut.)
- [ ] Write a **compatibility promise** (a short README "Stability" section): the documented
      commands/flags + `SLUICE_*` knobs + the config contract are stable; breaking changes only on a
      major (2.0) bump; additive changes (new knobs/commands/flags, new `--json` fields) are fine in
      minors. Out of the promise: `core/` internals, image layout, firewall/squid implementation.
- [ ] Remove the pre-1.0 caveats: the README "> Pre-1.0: the command surface is still stabilizing"
      note and the matching `usage()` line.

_Prepared (drafted 2026-06-01; drop the block below into the README verbatim at the 1.0 cut):_

> ## Stability
>
> sluice follows [Semantic Versioning](https://semver.org). As of 1.0 the **public API** is: the
> documented **commands and flags** (`sluice help`), the **`SLUICE_*` config knobs** and the
> `sluice.config.sh` contract (sourced as POSIX `sh` - space/newline-separated strings, no bash
> arrays), and the **runtime guarantees** in [`THREAT_MODEL.md`](THREAT_MODEL.md) (default-DROP egress,
> non-root, project-directory-only mount).
>
> Within 1.x these stay backward-compatible: new commands, flags, knobs, detected stacks, agent
> presets, and `--json` fields may be **added**, but nothing in the public API is removed, renamed, or
> has its default changed in a breaking way without a **major** bump. Anything slated to change is
> **deprecated first** (a warning for at least one minor release) before removal in the next major.
>
> **Not part of the stable API** (free to change in any release): the `core/` internals (Dockerfile,
> squid / firewall / entrypoint), the image layout and base-image contents, and exact log/console text.

At the cut, also: delete the README "> Pre-1.0..." note + its `usage()` line, and lead the v1.0.0
release notes with Highlights + Install + Docs links (the x.0 release-notes style).

**B. Close for confidence (or consciously accept the gap):**
- [ ] #3 live agent round-trips for amp/cursor/codex/gemini (credential-gated; claude/aider/opencode
      are already live) - so the wedge is "verified end-to-end," not just cred-free.
- [ ] #2 real Linux dev-box run (CI-green on Docker + rootful/rootless Podman, but never on a physical
      Linux dev machine; most target users are on Linux).

**C. Quality bar (should already mostly hold - audit before cutting):**
- [ ] All tests green: acceptance (15), init-detection (43), the no-Docker CLI + installer units
      (cli / install), and the verify-* harnesses (security / agents / runtimes / lock / learn /
      control-plane / nix - sharing test/lib.sh; the manual ones gated in nightly).
- [ ] Docs current + consistent: README, THREAT_MODEL, examples/, sluice.config.example.sh, and help
      all match the locked surface (knob table = the frozen knobs; command list = the frozen verbs).
- [ ] Distribution intact (already done): signed GHCR base + cosign-verify, tap, install.sh,
      SECURITY.md, LICENSE, SBOM, the version + opt-out update notice.

**D. Cut 1.0.0:** bump `SLUICE_VERSION`, signed tag, publish-base + release (a milestone release - use
the Highlights + Install + Docs format, the x.0 release-notes style), tap bump. The README then no
longer says "pre-1.0."

**Explicitly NOT 1.0** (deferred - state as such so they're not "silently missing"): the control-plane
SaaS (seams landed; the SaaS waits for adoption), stronger isolation (gVisor/microVM), Windows/WSL2 +
GPU, multi-tenant adversarial isolation, the non-server batch demo, and richer policy bundles / fleet
`ls` / credential brokering.

### Pre-launch readiness (before the LinkedIn / HN push)
No new features needed - every claim in the launch post is backed by shipped code. This is about not
fumbling first contact when the post drives a skeptical, Linux-heavy dev/security crowd to the repo.
- [ ] **Linux dev-box smoke (the real risk).** Most of the audience is on Linux; sluice is CI-green on
      Linux Docker + rootful/rootless Podman but **never run on a physical Linux dev box**. Do a ~15-min
      smoke on a throwaway cloud Linux VM: `brew`/`install.sh` -> `sluice agent claude` -> confirm the
      firewall blocks a host. A first-try failure in public is the worst outcome. (Also closes #2.)
- [x] **Demo asset (landed 2026-06-02).** Three capability GIFs, all pasted real commands, in the README:
      **cage** (the top-of-README hero, Contain + Control in one arc - non-root + no host secrets, then the
      egress receipt shows the firewall block, `sluice learn` collapses the google subdomains to a wildcard
      and skips openai live/no-rebuild, and the next run's receipt shows the change), **doctor** (the one-screen
      health panel - engine, mounted dir, ports, auth, and the last run's blocked egress), **lock** (Audit -
      drift caught -> SBOM with purl + integrity hash). The probe and learn demos were merged into the cage
      hero, and doctor was split into its own clip; the standalone `agent-live` tape was removed; the live
      agent demo still wants a real key, so record it live when cutting the post.
- [x] **Top-of-README quickstart (landed 2026-06-01).** Install -> one command -> see the block in
      ~10 seconds: a one-paragraph value prop, then the hero gif (the firewall block, above the fold),
      then the copy-paste `sluice agent claude` / bare `sluice` quickstart.
- [ ] **First-comment text** for the post (repo link + a 3-line "how it works") - LinkedIn suppresses
      body links, so the link goes in the first comment.
- [x] **Issue templates + CONTRIBUTING (landed 2026-06-02).** Bug + feature issue forms (the bug form
      collects version/engine/OS/`doctor`), a config that disables blank issues and routes security
      reports to the existing `SECURITY.md`, and a lean `CONTRIBUTING.md` (dev/test/PR, Conventional
      Commits) that links the existing docs instead of duplicating them.
- Mechanics (not roadmap, just don't forget): post Tue/Wed ~7:30pm IST (US dev morning), reply in the
  first 90 min, cross-post HN/Reddit at the same window. Accuracy nit: the cosign-signed base is
  **opt-in** (`SLUICE_BASE_IMAGE`); the default build is `FROM cgr.dev/chainguard/wolfi-base` - the
  post's "builds on a cosign-signed Chainguard/Wolfi base" line is defensible (Chainguard signs it) but
  know the default doesn't verify a signature unless you opt in.

---

### 1. Egress that actually holds (the linchpin) - ✅ LANDED
**Problem.** Enforcement resolved domains -> IPv4 -> ipset at boot. It leaked: rotating
CDN IPs, direct-IP/SNI bypass, DoH, and unfiltered IPv6.
**Shipped.** `core/` now runs an in-sluice **squid** proxy in transparent-intercept +
peek-and-splice mode: iptables REDIRECTs all tcp/80+443 to squid (which is the only uid
granted direct egress), squid allows by **Host / TLS-SNI** and splices (never decrypts);
IPv6 is disabled and direct-IP/DoH blocked; the boot self-test fails closed.
**Verified.** Allow/deny is by hostname (squid access log shows `TCP_TUNNEL` for
allowlisted SNIs, `NONE_NONE/000` terminate for the rest); allowed hosts survive IP
rotation; denied host, direct-IP, and HTTP-by-Host all fail closed. (Required `--sysctl
route_localnet=1` + IPv6 off at `docker run`.)
**Out of scope (held).** TLS interception / per-URL filtering - host-granular is the
contract. Non-HTTP egress is now default-denied except `SLUICE_ALLOW_IPS`.

### 2. Linux support (Docker + Podman) - ✅ CI-green: Docker + Podman (rootful & rootless)
**Problem.** Assumed Docker Desktop on macOS; most agent/dev users are on Linux.
**Done.** `bin/sluice` is engine-agnostic (`SLUICE_ENGINE`; docker->podman fallback). The DNS
rule already derives the resolver from `/etc/resolv.conf`, so the Docker-Desktop vs
Linux-Docker difference is handled. `test/acceptance.sh` is an automated pass/fail harness
(egress matrix, non-root, IPv6-off, scoped TLS bump);
`.github/workflows/acceptance.yml` runs it on Linux Docker (gate) + rootful Podman
(best-effort). All 12 pass locally on macOS/Docker.
**Linux write-access fixed.** The nightly runtime build-smoke surfaced a real Linux gap: a
bind mount keeps the host uid, so when it isn't node's (1000) the sandboxed user - and any
agent it runs - could not write to the repo. The launcher now passes the mounted paths and
the root entrypoint chowns them to node when needed (no-op at uid 1000 / on Docker Desktop).
With that fix the nightly went 0/7 -> 5/7 on Linux.
**Rotating-CDN egress fixed (root-caused).** The 2 remaining nightly failures (cargo's
`static.crates.io`, `go run`'s `proxy.golang.org`) were not a uid or allowlist gap: squid's
transparent-intercept Host-forgery check compares the client's connected IP against squid's own
DNS of the SNI, and for large rotating pools (Google/Akamai/Fastly) the two lookups land on
different IPs, so squid 409s a legitimate allowlisted host (the app sees only an opaque TLS
error). It bit Linux CI but not macOS because Docker Desktop's resolver is stickier. Fixed by
running a small caching `dnsmasq` in the box and pointing both the client and squid at it
(resolv.conf -> 127.0.0.1), so a name pins to one IP set per session and the intercepted IP is
always in squid's set (DNS-tunnel protection unchanged: only the saved upstreams + loopback are
reachable on :53). The scoped rust/go/deno nightly now passes 3/3 on Linux Docker (commit
54e8602). Diagnosis used a non-mutating "dump squid's view + DNS on a serve failure" probe
added to verify-runtimes (4a37cce) - the IPv6/MTU hypotheses were both wrong.
**Podman verified - rootful AND rootless.** Both acceptance Podman jobs pass in CI: rootful,
and - resolving the open risk - **rootless** (commit 40ea0e2 added a rootless job; `rootless:
true`, 8/8 egress matrix with allow/deny/direct-IP/HTTP-block/non-root/IPv6 all correct in an
unprivileged user namespace). So the `route_localnet`/`disable_ipv6` sysctls + in-netns iptables
the proxy needs work rootless too - no rootful requirement.
**Cleanup-noise resolved.** The `rm: Permission denied` from the entrypoint chowning the mount
to uid 1000 is fixed in both harnesses by chowning back to the host uid before teardown
(verify-runtimes 979ac08, acceptance 40ea0e2).
**Remaining.** Only the dev-box leg: the Linux paths are CI-verified, not yet run on a real
Linux dev machine (the macOS dev box uses Docker Desktop).

### 3. Agent-native, tool-agnostic wrapping (the wedge) - ✅ all 7 presets cred-free verified + sessions persist (live round-trips one key away)
**Problem.** "Run any agent YOLO, safely" must be one command, not a config exercise.
**Done.** `sluice agent <name>` scaffolds an agent preset (if no config yet) and drops you
into it. Presets ship for **Claude Code, Codex, aider, Cursor** in `agents/<name>.config.sh`
- each declares the tool, its API egress hosts, and the auth env var forwarded via
`SLUICE_ENV` (never baked); agent specifics stay out of `core/`. A warning fires if the
auth env var isn't set on the host. **Verified end-to-end for Claude Code**: scaffold ->
build -> `claude --version` in the box -> `api.anthropic.com` reachable through the proxy,
`example.com` blocked -> `ANTHROPIC_API_KEY` forwarded.
**Seven presets** now: claude, codex, gemini, aider, cursor, opencode, amp. **aider also
verified** (build -> `aider --version` -> api.openai.com reachable, example.com blocked).
**All default to YOLO** (skip-approvals): claude `--dangerously-skip-permissions`, codex
`--dangerously-bypass-approvals-and-sandbox` (confirmed in codex 0.135.0 help), gemini
`--yolo`, aider `--yes-always`, cursor `cursor-agent --force`, amp `--dangerously-allow-all`,
opencode via a baked global allow-all permission config (no stable --yolo flag yet). Each
header has a one-line residual-risk note (the sandbox bounds the blast radius but the agent
can still rewrite the mounted dir + use forwarded creds).
**Presets verified by a harness (`test/verify-agents.sh` + manual `verify-agents.yml`).** It
builds each preset and checks, cred-free, that the CLI binary installs + runs, every API host
is reachable through the proxy, a non-allowlisted host is blocked, and the auth env var is
forwarded; the live authenticated round-trip is the only cred-gated step. It caught + fixed a
real bug: **cursor** installed `@cursor/cli` (a 404 on npm) - cursor-agent ships via Cursor's
own install script, now switched + PATH-symlinked. Cred-free verified: **all 7** -
cursor, amp, opencode, **codex, gemini** (binary + hosts + auth-forward; codex/gemini cleared
8/8 with no preset bug, 2026-06-01); **opencode's full live round-trip passes** too;
claude + aider were already verified end-to-end. The harness now ships a probe for every preset
and defaults to the full set.
**Session persistence landed** (2026-06-01): a general `SLUICE_STATE_DIRS` knob bind-mounts a
per-project host store (`~/.local/state/sluice/<name>`) into the agent home, so each preset's
sessions/history/auth survive a rebuild, `sluice stop`, or reboot (e2e-verified). `sluice doctor`
reports it.
**Drift caught proactively (2026-06-02).** The cred-free preset checks (install + declared-host
reachability + block + auth-forward) now run weekly on a schedule (`.github/workflows/agents-smoke.yml`),
so a rotted preset (renamed package, moved egress host) is caught before a user hits it - not just on a
manual `verify-agents` run. A pre-run `note` also fires if an agent's `SLUICE_ENV` key is unset with no
saved session, instead of failing confusingly inside the box.

**Pending.** The live authenticated round-trips for amp/cursor/codex/gemini are one credential
away (run the harness with the key, or add a repo secret) - the only remaining #3 loose end.

### 4. Observability + learn-mode - ✅ learn + passive surfacing + audit hatch landed
**Problem.** Blocks were **silent** - an app that needs a runtime host just hangs/fails with no clue why.
**Done.** squid's log now records the **SNI/Host** of every blocked connection (a custom
logformat - a terminated TLS connection otherwise logs only the IP). `sluice learn` reads
that log, extracts the blocked hostnames (excluding base-allowed hosts and raw IPs),
proposes a `SLUICE_ALLOW_DOMAINS`, and writes it into the config on confirmation.
**Passive surfacing landed (v0.2.0).** The silent-block gotcha is now closed without the
explicit `learn` step: a default run prints a one-line at-exit hint of any not-yet-allowed
hosts it blocked (fires even on Ctrl-C), and `sluice doctor` reports engine/image/allowlist/
auth + the hosts blocked this run, working even before anything is built. All three paths
share one allowlist-aware filter, so none re-proposes an already-allowed host.
**`learn` friction reduced (2026-06-01):** `sluice learn --print` emits the merged allowlist to
stdout (review/CI), `sluice learn --apply` writes it + rebuilds in one step (collapsing the
run->learn->rebuild loop). Enforce-mode only - no egress opened. `test/verify-learn.sh` (6/6).
**Allowlist is now a runtime input (2026-06-02):** `SLUICE_ALLOW_DOMAINS` is excluded from `config_hash`
and passed at `docker run` (`SLUICE_RUNTIME_ALLOW`, won over the baked copy in the entrypoint), so an
interactive `learn` applies live (squid HUP) *and* the next `sluice run` picks the host up with **no
rebuild** - the learned host is no-rebuild end-to-end, not just hot-reloaded for the current box.
**Open-egress audit hatch - ✅ landed (2026-06-01).** `sluice learn --audit` closes the one narrow
gap enforce-mode can't: a trusted, sequential abort-on-failure fetcher that dies on the first blocked
host (so one enforce run reveals only one host). It runs SLUICE_RUN_CMD once in a loud-warned,
confirm-gated, **credential-stripped** (no SLUICE_ENV/SLUICE_PRELAUNCH/state dirs), **ephemeral**
`<container>-audit` with `-e SLUICE_AUDIT=1`; the entrypoint sed-toggles that container's OWN
/etc/squid.conf to `splice all` + `http_access allow all` (runtime-only - never the image, core/squid.conf,
or the real persistent container, and not in config_hash so no rebuild), and a new `reached_hosts`/
`reached_new` parser reads the *allowed* SNIs to propose the full list, then an EXIT trap tears the
audit container down (so it can never be left in audit mode). Two nuances the original design shorthand
missed, both handled: (1) init-firewall.sh's boot deny self-tests (canary + direct-IP must be blocked)
fail closed under splice-all, so they're skipped when SLUICE_AUDIT=1; (2) audit opens ALL HTTP/HTTPS
incl. direct-IP on 80/443 - only non-HTTP ports + IPv6 stay default-DROP (the honest contract, now in
THREAT_MODEL #9). Verified by test/verify-audit.sh (8/8: discovery, credential-strip, no residue,
enforce-still-holds). Enforce-mode learn stays the default; the clean log format remains the on-ramp to
a control plane.

### 5. Distribution & trust - ✅ landed
**Problem.** OSS credibility = installable + auditable + a clear security posture.
**Done.** **Apache-2.0** `LICENSE` (open-core: permissive CLI; the moat is the future
control plane, kept closed). `SECURITY.md` (private reporting + in/out-of-scope). `install.sh`
works both `curl | sh` (clones) and from a checkout. Homebrew formula template in
`packaging/`. `release.yml` cuts a GitHub release on a `v*` tag. `THREAT_MODEL.md` linked.
**v0.1.0 cut** (signed tag -> GitHub release). The CLI reports its version (`-v` / `version`),
from `git describe` + a baked `SLUICE_VERSION` fallback.
**v0.2.0 cut + tap live.** Signed `v0.2.0` tag -> release with full notes; the release
workflow now cuts a **draft** (auto-notes only scaffold; edit + publish). Brew tap is live and
sha-pinned: `brew install Pyronewbic/tap/sluice` (now **v0.4.0**) plus a `--HEAD` dev stream that
builds the latest `main` commit.
**v0.4.0 released (2026-06-01).** 11 commits since v0.3.1: lock --check/--sbom, session
persistence, learn --print/--apply, the Nix example + SLUICE_SETUP_ROOT_CMDS, the SLUICE_ALLOW_IPS
database demo, codex/gemini verified, the update notice, grouped help, parallel verify-runtimes.
Base image cosign-signed + published, tap bumped, release published as Latest. (Notes feature-framed;
the learn deny-canary fix was deliberately left out of the public notes.)
**v0.5.0 released (2026-06-01).** Focused single-feature release: `learn --audit` (the open-egress
discovery hatch, ROADMAP #4) + the slim-layout doc. Tag v0.5.0 at the bump commit 9d89be4; base image
ghcr.io/pyronewbic/sluice-base:0.5.0 cosign-signed + published, acceptance green, release published as
Latest (feature-framed notes), tap bumped (sha acb9e0e..., commit 9e77d53). Update-notice now points
v0.4.x users at it.
**v0.6.0 released (2026-06-01).** 5 commits since v0.5.0: `sluice ls` + SLUICE_DESC, the README
best-practice pass (badges / local-first line / "What it looks like" real output), and the
control-plane OSS seams (ls/doctor `--json`, `sluice egress [--json]`, `SLUICE_POLICY_URL`). Tag v0.6.0
at bump 15212ef; base image sluice-base:0.6.0 cosign-signed + published, acceptance green, release
published Latest (feature-framed notes), tap bumped (sha 953fd16..., commit d320e8a).
**Signed GHCR base image - published (v0.3.0).** `core/Dockerfile` is a two-stage build: a
generic `base` (the sandbox core) + a thin per-project layer. `publish-base.yml` built the base
for amd64+arm64, pushed it to `ghcr.io/pyronewbic/sluice-base` (`:0.3.0` + `:latest`, **public**),
and cosign-signed it keyless (GitHub OIDC, no key secrets); the CI cosign-verify passed. `bin/sluice`
builds a project FROM the signed base via `SLUICE_BASE_IMAGE` (opt-in this release; verifies the
signature, `SLUICE_REQUIRE_SIGNED=1` to enforce) - local-from-core stays the default, to flip later
once proven. The base is keyless (the splice cert moved to runtime). With this, **#5 has no
remaining gap**.
**Supply-chain: `sluice.lock` (spike, commit 4f73e63).** Closed the asymmetry where
`SLUICE_EXTRA_NPM` was pinned but `SLUICE_EXTRA_PKGS` (Wolfi apk) was unpinned. `sluice lock`
writes a committable full image inventory (base digest + every apk name/version/apk-checksum +
every global npm pkg); `sluice doctor` flags drift (caught ripgrep + its 6 transitive deps in
testing); `sluice update` rebuilds fresh + relocks. Honest scope: audit/drift, NOT
reproducibility (Wolfi apk is a rolling repo). Idea borrowed from jetify/devbox's `devbox.lock`
(the lone on-motto borrow from a devbox eval; the rest - Nix, plugins, services, cloud secrets -
is incompatible or dev-env breadth). Follow-ups: **CI drift gate + CycloneDX SBOM landed**
(2026-06-01) - `sluice lock --check` exits non-zero on drift (CI-gateable) and `sluice lock --sbom`
emits a deterministic CycloneDX SBOM, both folded under `lock`; verified by `test/verify-lock.sh`.
**Inventory + SBOM hardened (2026-06-01):** coverage now spans **apk+npm+pip+gem+go** (the languages the
presets install at build time, not just apk/npm; go binaries read their module/version from embedded
build info via `go version -m`, scanning GOBIN + both root's and the sluice user's `GOPATH/bin`); drift
is **classified** (added/removed/version-bumped) and re-lock/`update` print the supply-chain delta for
review; `--check --json` + read-only `--diff`; the SBOM moved to **CycloneDX 1.6** with spec-correct
purls (apk arch/distro qualifiers, pypi/gem/golang), **apk integrity hashes** (the Q1 checksum decoded
to SHA-1), and `metadata.tools`/image component. **Check semantics tightened (2026-06-02):**
`--check`/`--diff` now verify the built image *as-is* - they build only when no image exists and **flag**
(never silently rebuild) a stale one via a stderr note, so a CI gate can't mutate local state; the npm
count in the `lock` summary is conditional like pip/gem/go. Still deferred: enforce/replay of pinned
versions, APKINDEX-snapshot pinning, cargo/rust-crate inventory, SPDX output (chose CycloneDX), and a
vuln-scan pass-through / cosign SBOM attestation.

### 6. `sluice init` + a preset gallery (the "drag & drop") - 🚧 init + gallery landed
**Problem.** Adoption UX; the preset library is also community moat.
**Done.** `sluice init` now detects much more than the stack name. **Node:** package
manager from lockfile or the `packageManager` field (npm/pnpm/yarn/**bun**), framework
(vite/astro/sveltekit/vitepress/nuxt/next/remix/gatsby/docusaurus/angular) with the right
default port *and* that framework's host/port flag spelling, and it reads the project's
**real dev script** - honoring an explicit `--port` and not double-setting host if the
script already binds `0.0.0.0`. **Python:** manager (pip/**poetry**/**uv**), framework +
entry command (django/fastapi/flask/streamlit/gradio, else a guessed entry file), and the
interpreter version from `.python-version`/`requires-python`. Also added **deno** and
**ruby/rails** detection, a `--force` flag, and a polyglot/monorepo note when secondary
manifests are present. Every generated config is POSIX-clean (verified `sh`-sourceable), and
`sluice init` now needs no container engine (pure scaffolding).
**Build-verified end-to-end** (init -> build -> run, with a dependency pulled through the
egress proxy): node(npm via the node fixture), python(pip via fastapi/flask), **deno**,
**ruby** (Sinatra+Puma), **bun**, **go**, **poetry**, **uv**, **rust**. Two preset bugs the
verification caught and fixed: ruby (`gem`'s `--bindir` needs `mkdir -p`; native-extension
gems need `ruby-3.3-dev build-base linux-headers`) and rust (`cargo` needs a C linker, so
`build-base`).
**Tests (a test pyramid).** `test/init-detection.sh` is a fast, Docker-free unit suite (39
assertions) that locks in detection + the toolchain fixes; it runs as a gating CI job. The
slower integration layer is `test/verify-runtimes.sh`, which build-smokes each runtime fixture
in `test/fixtures/<rt>/` (one runnable app per toolchain) end-to-end (build -> serve -> curl,
deps through the proxy); it runs as a **nightly + manual** workflow (`nightly.yml`), kept off
the PR gate to bound cost/flake. (The fixtures used to live in `examples/`, but `sluice init`
scaffolds those configs now, so they moved to `test/` - they're fixtures, not gallery items.)
**Gallery curated by capability (commit 0b343ff).** `examples/` is now three self-contained
demos that each show a *different* slice: **firewall** (the egress block made visible - reaches
an allowlisted host, blocked exfiltrating a fake secret to a non-allowlisted host + a raw IP,
surfaced by `sluice doctor`), **jupyter** (serve a web app - a Python stack with no runtime
egress), and **nix** (Nix composed inside a sluice - a reproducible
pinned toolchain fetched + baked at build, run locked at runtime; added 2026-06-01 with a new
general `SLUICE_SETUP_ROOT_CMDS` build hook + `test/verify-nix.sh`). The README is a capability
matrix and elevates the coding-agent wedge. The vite/next/fastapi starters were trimmed (redundant
with `sluice init`, which scaffolds them) to an init pointer.
**Zero-config landed.** A bare `sluice` in a repo with no `sluice.config.sh` now scaffolds
one from detection, previews the run command/ports, and (interactively) asks to build + run
it - the `create-next-app` pattern. On a TTY it prompts `[Y/n]`; non-interactively it
scaffolds and stops for review unless `SLUICE_YES=1` (so CI never auto-runs a guessed
command). `sluice init` still does scaffold-only.
**Language scope frozen (decided).** Auto-detection stays at the current 6 stacks
(node/python/deno/ruby/rust/go + generic); adding more is scope creep - the generic base +
`SLUICE_EXTRA_PKGS`/`SLUICE_RUN_CMD` already run any language (now documented in the README).
PHP is the only defensible future add, and only on real demand. Separately, the sandbox user
was de-node-ified (`node` -> `sluice`, uid unchanged) so the generic base reads as such.
**Demos broadened (2026-06-01):** added the **`SLUICE_ALLOW_IPS` database-egress** demo
(`examples/database.config.sh` - a fixed IP reachable on a non-HTTP port vs a denied IP blocked)
and a **`sluice learn` walkthrough** (examples/README). Building the walkthrough surfaced + fixed a
real bug: `sluice learn` proposed `example.com` (the firewall's own boot deny-canary); now the
reserved `example.*` domains are filtered from learn's proposal (doctor/hint stay factual).
**Pending.** Only a non-server batch/data job demo remains deferred (low priority).

---

## Later (deliberately deferred - say so)

- **Stronger isolation** - opt-in gVisor runtime or microVM (Lima/krunkit) for users who
  need kernel-level isolation. Roadmap, not a v1 claim.
  - *Edera (edera.dev) candidate (noted 2026-06-02).* A container-native Type-1 hypervisor (Xen); each
    workload runs in a "zone" with its own kernel - the kernel-escape gap THREAT_MODEL disclaims.
    Complementary on isolation, but the egress philosophies overlap: Edera filters at the host (nftables
    + a host-side Squid/Envoy, by zone subnet); sluice filters in-box. Linchpin: do sluice's in-zone
    iptables REDIRECT + squid + route_localnet/disable_ipv6 sysctls come up inside a zone? If yes, clean
    compose (Edera is the escape-proof box, sluice runs unchanged inside); if no, fall back to Edera's
    host-side filter and lose "policy travels with the box". Spike (Linux+Xen only; macOS stays
    docker/podman): `protect workload launch --help` (its CLI has `-m` mount + `--cap-add`; `--sysctl`
    is the open flag), then a ~30-min in-zone bring-up of `core/init-firewall.sh` + squid against the
    acceptance egress matrix.
- **Hosted control plane** - managed runners, org egress policies, audit/compliance, SSO.
  The monetization, *after* OSS adoption - not first. **OSS seams landed 2026-06-01** (the
  integration points, not the SaaS): `ls --json` / `doctor --json` (machine-readable inventory +
  posture), `sluice egress [--json]` (the reached-vs-blocked audit record), and `SLUICE_POLICY_URL`
  (host-fetched central allowlist, additive). Metadata-only by design; the SaaS aggregator/dashboard,
  fleet `ls`, credential brokering, and richer policy bundles stay deferred until adoption pull.
- **Windows/WSL2, GPU, multi-tenant adversarial isolation** - not our fight for now.
