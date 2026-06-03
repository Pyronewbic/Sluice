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
> *defensible*, #5-#6 make it *adoptable*.

**Toward 1.0.** The CLI surface stayed intentionally changeable through 0.x rather than guessing the
final shape early. The lock-before-1.0 review is **done: the 16-verb surface is final** (decided
2026-06-01 - `build`/`rebuild`/`update` stay verbs, being frequent + side-effect-distinct; `smoke`
stays, harmless + CI-useful). sluice is a flat-verb task runner, not noun-verb.

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
- [x] #3 live agent round-trips verified (2026-06-03, manual with real keys) - claude/aider/opencode
      run live daily and the credential-gated four (amp/cursor/codex/gemini) were round-tripped end to
      end, so the wedge is "verified end-to-end," not just cred-free.
- [x] #2 real Linux dev-box run (done 2026-06-02). On a stock Ubuntu 24.04 / Docker 29.5.2 box, non-sudo
      (docker group): `install.sh` curl|sh from main -> `sluice build` on the **unpatched** Dockerfile ->
      egress matrix holds (registry.npmjs.org reached, example.com DROP) -> `doctor` clean. The live
      `sluice agent <name>` round-trip was tracked separately as #3 above, not part of this smoke.

**C. Quality bar (should already mostly hold - audit before cutting):**
- [ ] All tests green: the gate bats suites (acceptance, init-detection, the no-Docker CLI + installer
      units, security) and the `nightly-*` bats suites (agents / runtimes / lock / learn / control-plane
      / nix - sharing `test/test_helper/common.bash`; gated in nightly).
- [ ] Docs current + consistent: README, THREAT_MODEL, examples/, sluice.config.example.sh, and help
      all match the locked surface (knob table = the frozen knobs; command list = the frozen verbs).
- [ ] Distribution intact (already done): signed GHCR base + cosign-verify, signed release tarballs
      (cosign keyless + SHA256SUMS), tap, install.sh, SECURITY.md, LICENSE, SBOM, the version + opt-out
      update notice.

**D. Cut 1.0.0:** bump `SLUICE_VERSION`, signed tag, publish-base + release (the Highlights + Install +
Docs format), tap bump. The README then no longer says "pre-1.0."

**Explicitly NOT 1.0** (so they're not silently missing): everything in **Candidate features** below -
the control plane, stronger isolation, Windows/GPU, etc. - is deferred past 1.0. 1.0 adds nothing new;
it's the stability commitment.

### Readiness
No new features needed - every claim here is backed by shipped code. This is about not fumbling first
contact with a skeptical, Linux-heavy dev/security crowd landing on the repo.
- [x] **Linux dev-box smoke (landed 2026-06-02).** Ran the real first-try path on a throwaway cloud
      Linux VM (Ubuntu 24.04 / Docker 29.5.2): `install.sh` curl|sh from main, `sluice build` on the
      stock Dockerfile, the egress matrix (npmjs reached, example.com blocked), and `doctor`, all
      credential-free and non-sudo. No first-try surprises; the stock build needs no manual patch. (Closes #2.)
- [x] **Demo assets (landed 2026-06-02).** Two capability GIFs in the README (real pasted commands):
      **doctor** (the one-screen health panel, incl. the supply-chain lock line) and **lock** (drift
      caught -> SBOM with purl + integrity hash). The cage hero GIF was dropped as low-value (2026-06-02,
      prose leads instead). The live agent round-trip is now verified (#3); a dedicated agent demo GIF stays optional.
- [x] **Top-of-README quickstart (landed 2026-06-01).** Value prop -> copy-paste quickstart.
- [x] **Issue templates + CONTRIBUTING (landed 2026-06-02).** Bug + feature forms (bug form collects
      version/engine/OS/`doctor`), blank issues disabled + security routed to `SECURITY.md`, lean
      `CONTRIBUTING.md`.

---

## Candidate features (next cuts)

The forward backlog. Everything here is **additive** (semver-minor), so it fits 0.8.x / 1.x without
disturbing the 1.0 stability lock above - 1.0 is the freeze, these ride the minors around it. Each item
rides the lowest extension rung that fits (preset / knob / flag, not a new verb); see
[EXTENDING.md](EXTENDING.md) for the ladder and the in-scope test. Tiered by sequencing; all consolidated
from the planks' deferred notes + the threat model + the isolation spike (nothing new invented), with
rough effort (S/M/L) and the gap each closes.

**Next (build-ready):**
- **`SLUICE_RUNTIME` micro-VM isolation - ✅ LANDED (opt-in).** `SLUICE_RUNTIME=kata` runs the box under an
  own-kernel runtime (Kata, via containerd/nerdctl) so a kernel escape can't reach the host - closing the
  **#1 admitted THREAT_MODEL gap** (shared kernel) as an opt-in. `$ENGINE` still builds the image; the box
  runs under nerdctl and the image is loaded across (the `$RUNNER` split, default unset = unchanged). Verified
  on the spike VM 2026-06-02: the firewall/squid stack comes up unchanged (guest kernel distinct from host,
  egress matrix holds). Edera is Track B (its `protect` launch interface, pending the access key). Runbook +
  Terraform: [`spike/terraform/`](spike/terraform/README.md).
- **More agent presets - S.** The wedge; a preset is "just a file" (tool + API hosts + auth var). Cheap
  adoption, and the preset library is community moat.

**Later (adoption-gated / bigger):**
- **Hosted control plane / fleet - L.** The OSS seams already shipped (`ls` with posture/orphan/filters + `--egress`,
  cross-dir `-b/--box` targeting, `prune --orphans`, `doctor`/`egress --json`, `SLUICE_POLICY_URL`). The SaaS aggregator/dashboard + fleet `ls` + richer policy bundles +
  credential brokering wait on adoption pull - the monetization (open-core), not first.
- **Supply-chain depth - M.** APKINDEX-snapshot pinning + full pinned-version replay (CycloneDX + cosign
  SBOM attestation + cargo inventory + SPDX output + `lock --enforce` strict gate shipped).

**Deferred (on real demand / not now):** Windows/WSL2, GPU passthrough, further stack detection beyond
the current 11 (the generic base + `SLUICE_EXTRA_PKGS`/`SLUICE_RUN_CMD`, or a Procfile/Makefile run target,
already run any language), a non-server batch/data-job demo, and multi-tenant adversarial isolation (a different
product - sluice is anti-exfil for code you mostly trust, not hostile-tenant isolation).

---

## Shipped - the v1 planks (condensed)

### 1. Egress that actually holds (the linchpin) - ✅ LANDED
The old enforcement (resolve domains -> IPv4 -> ipset at boot) leaked: rotating CDN IPs, direct-IP/SNI
bypass, DoH, IPv6. **Shipped:** an in-box **squid** proxy in transparent-intercept + peek-and-splice
mode - iptables REDIRECTs all tcp/80+443 to squid (the only uid with direct egress), which allows by
**Host/TLS-SNI** and splices (never decrypts); IPv6 off, direct-IP/DoH blocked, boot self-test fails
closed. Allow/deny is by hostname and survives IP rotation. **Caveat:** host-granular - per-URL needs
TLS interception, now a scoped opt-in via `SLUICE_BUMP_DOMAINS`; non-HTTP egress is default-DROP except
the reviewed `SLUICE_ALLOW_IPS`.

### 2. Linux support (Docker + Podman) - ✅ CI-green: Docker + rootless Podman (rootful unsupported)
`bin/sluice` is engine-agnostic (`SLUICE_ENGINE`; docker->podman fallback). The acceptance bats suite runs the
egress + isolation matrix on Linux Docker (the gate) + rootless Podman (best-effort) - the
`route_localnet`/`disable_ipv6` sysctls + in-netns iptables work even rootless. **Rootful Podman is
unsupported**: its `netavark` backend leaves the box's `dnsmasq` unable to enumerate interfaces
(`Permission denied`), so the firewall never comes up - it works under rootless `slirp4netns` + Docker
(same class as the gVisor incompatibility). Two Linux-only bugs the
nightly surfaced and fixed: (1) bind mounts keep the host uid, so the root entrypoint chowns the mount to
1000 when needed (no-op on Docker Desktop); (2) rotating-CDN hosts 409'd because squid's Host-forgery
check saw a different pool IP than the client - fixed with an in-box caching **dnsmasq** both point at, so
a name pins to one IP set per session. The real physical-Linux-dev-box smoke (the last gap) ran clean on
2026-06-02: stock `install.sh` -> build -> egress matrix -> `doctor` on Ubuntu 24.04 / Docker 29.5.2.

### 3. Agent-native wrapping (the wedge) - ✅ 9 presets verified (cred-free harness + live keyed round-trip), sessions persist
`sluice agent <name>` scaffolds a preset (if there's no config) and drops you in. Nine ship - **claude,
codex, gemini, aider, cursor, opencode, amp, qwen, crush** - each a normal `sluice.config.sh` declaring the tool, its
API hosts, and the auth var forwarded via `SLUICE_ENV` (never baked); all default to **YOLO**
(skip-approvals), since the sandbox is the gate. A harness (`nightly-agents.bats` + a weekly drift smoke)
checks cred-free that each CLI installs, its hosts are reachable, a non-allowlisted host is blocked, and
the auth var forwards; the live keyed round-trip is verified separately (manual, with real keys,
done 2026-06-03). Sessions persist across runs via `SLUICE_STATE_DIRS` (a per-project host store), so an agent
resumes after a rebuild/reboot.

### 4. Observability + learn-mode - ✅ landed
Blocks used to be silent. squid now logs the **SNI/Host** of every blocked connection; `sluice learn`
reads it and proposes a `SLUICE_ALLOW_DOMAINS` (per-host review with `.domain` wildcard collapse;
`--print` for CI, `--apply` to write+apply). Picks apply **live, no rebuild** (`SLUICE_ALLOW_DOMAINS` is
a runtime input, excluded from `config_hash`). A default run also prints an at-exit egress receipt of
what it reached vs blocked, and `sluice doctor` shows the same - so the silent-block gotcha is closed
even without `learn`. For trusted code whose fetcher aborts on the first block, `sluice learn --audit`
discovers the full list in one credential-stripped, ephemeral, egress-open run (non-HTTP + IPv6 stay
blocked; THREAT_MODEL #9).

### 5. Distribution & trust - ✅ landed
**Apache-2.0** (open-core; the control plane is the moat), `SECURITY.md`, `install.sh` (curl|sh or
checkout), and a Homebrew tap (+ a `--HEAD` dev stream) pinning the **cosign-signed release tarball**.
`release.yml` cuts a draft GitHub release on a `v*` tag carrying a deterministic source tarball +
`SHA256SUMS` + a **cosign keyless** signature bundle (sign-blob via GitHub OIDC; verify steps in
`SECURITY.md`). Released through **v0.8.0**. A **signed GHCR base image**
(`publish-base.yml`, amd64+arm64, cosign keyless via GitHub OIDC, **keyless** - the splice cert is
per-container) is opt-in via `SLUICE_BASE_IMAGE` (`SLUICE_REQUIRE_SIGNED=1` to enforce); CI also attests
its **CycloneDX SBOM** to the signed digest, which `sluice` soft-verifies with the signature. **Supply
chain:** `sluice lock` writes a committable inventory (apk+npm+pip+gem+go+cargo with versions+digests);
`sluice doctor` flags drift; `lock --check` is a CI gate and `lock --enforce` a stricter one (refuses to
build or to pass against a stale image); `lock --sbom [--format cyclonedx|spdx]` emits a deterministic
**CycloneDX 1.6** or **SPDX 2.3** SBOM (purls + apk integrity hashes) from one introspection codepath, and
`lock --scan` vuln-checks it through a **host** Grype/Trivy (`--fail-on` to gate). Honest scope: audit/drift,
**not** reproducibility (Wolfi apk is rolling). Remaining depth (APKINDEX-snapshot pinning, full replay) is
in the backlog above.

### 6. `sluice init` + a preset gallery - ✅ landed
`sluice init` detects the stack and scaffolds a working config: **node** (npm/pnpm/yarn/bun + framework
port/flags read from the real dev script), **python** (pip/poetry/uv + framework), **deno, ruby/rails,
rust, go**, plus **java (maven/gradle), php, .NET, elixir, dart** - POSIX-clean, no engine needed. `init
--update` re-detects without clobbering manual edits, and an unknown stack sources a Procfile/Makefile run
target. **F2 dep prefetch** (go/rust/ruby/python-pip when a lockfile is present) fetches deps at build so
the runtime allowlist can drop the package registry. Build-verified end-to-end (init -> build -> serve) via
`test/fixtures/<rt>` (nightly `nightly-runtimes.bats`) for node/python/deno/ruby/rust/go/php/dart/dotnet/java
plus the go/python prefetch path; elixir detection ships but its deps don't yet compile on wolfi (an erlang-
headers gap). A bare `sluice` in an unconfigured repo scaffolds + previews + asks to run (`SLUICE_YES=1` in
CI). The `examples/` gallery is three capability demos - **firewall**, **jupyter**, **nix**.
