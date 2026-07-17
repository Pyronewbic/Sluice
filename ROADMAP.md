# Roadmap - to a credible v1

Positioning: **a local, self-hosted sandbox that lets any coding agent or untrusted
dependency run wide-open on your machine without exfiltrating your secrets.** Not a
hosted cloud, not single-vendor, not CI-only, not a dev-environment service. The
unserved space: developers who **won't ship code to a SaaS**, want it
**tool-agnostic**, and want **drop-in simplicity**.

## v1 cut line

> **v1 = #1-#3 done well + #4 in basic form.** That's the minimum that survives "how is
> this different?" - #1-#4 make it *defensible*, #5-#6 make it *adoptable*.

**Toward 1.0.** The CLI surface stayed intentionally changeable through 0.x rather than guessing the
final shape early. The lock-before-1.0 review is **done: the verb surface is frozen** (decided
2026-06-01 - `build`/`rebuild`/`update` stay verbs, being frequent + side-effect-distinct; `smoke`
stays, harmless + CI-useful). Amended 2026-06: `diff`/`apply` landed with `SLUICE_WORKSPACE=overlay`,
so `sluice help` now lists 19 task verbs - the help output is the canonical list. sluice is a
flat-verb task runner, not noun-verb.

### 1.0 readiness checklist
1.0 = a **stability commitment**, not new features. The v1 cut line is met and #1-#6 are landed, so
cutting 1.0 is gated on locking the surface + closing (or consciously accepting) the confidence items
below - not on building anything new.

**A. Lock the surface (the hard gate - a decision + a doc change):**
- [x] Decide `smoke`: **KEEP** (decided 2026-06-01). Verb set frozen (amended 2026-06 with
      `diff`/`apply`, above).
- [x] Freeze the verb set + their flags as the 1.0 CLI; freeze the `SLUICE_*` knob names + the
      `sluice.config.sh` contract (POSIX-sh sourced, space/newline strings, no bash arrays) as the
      stable config API.
- [x] Write a **compatibility promise** - landed in the README [Stability](README.md#stability)
      section.
- [ ] Remove the pre-1.0 caveats: the README "> Pre-1.0: the command surface is still stabilizing"
      note. At the cut, lead the v1.0.0 release notes with Highlights + Install + Docs links.

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
- [ ] Docs current + consistent: README, THREAT_MODEL, SECURITY.md, EXTENDING.md, core/README.md,
      src/README.md, examples/, sluice.config.example.sh, and help all match the locked surface
      (knob table = the frozen knobs; command list = the frozen verbs).
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
- [x] **Linux dev-box smoke (landed 2026-06-02).** The real first-try path on a throwaway cloud Linux VM
      ran clean, credential-free and non-sudo; the stock build needs no manual patch. (Closes #2; detail in B above.)
- [x] **Demo assets (landed 2026-06-02).** Two capability GIFs in the README (real pasted commands):
      **doctor** and **learn**. The cage hero GIF was dropped as low-value (2026-06-02, prose leads
      instead); a dedicated agent demo GIF stays optional.
- [x] **Top-of-README quickstart (landed 2026-06-01).** Value prop -> copy-paste quickstart.
- [x] **Issue templates + CONTRIBUTING (landed 2026-06-02).** Bug + feature forms (bug form collects
      version/engine/OS/`doctor`), blank issues disabled + security routed to `SECURITY.md`, lean
      `CONTRIBUTING.md`.

---

## Candidate features (next cuts)

The forward backlog. Everything here is **additive** (semver-minor), so it fits 0.9.x / 1.x without
disturbing the 1.0 stability lock above - 1.0 is the freeze, these ride the minors around it. Each item
rides the lowest extension rung that fits (preset / knob / flag, not a new verb); see
[EXTENDING.md](EXTENDING.md) for the ladder and the in-scope test. Tiered by sequencing; all consolidated
from the planks' deferred notes + the threat model + the isolation spike (nothing new invented), with
rough effort (S/M/L) and the gap each closes.

**Next (build-ready):**
- **`SLUICE_RUNTIME` micro-VM isolation - LANDED (opt-in).** `SLUICE_RUNTIME=kata` runs the box under an
  own-kernel runtime (Kata Containers, via containerd/nerdctl) so a kernel escape can't reach the host -
  closing the **#1 admitted THREAT_MODEL gap** (shared kernel) as an opt-in. `$ENGINE` still builds the
  image; the box runs under nerdctl and the image is loaded across (the `$RUNNER` split, default unset =
  unchanged). Verified on the spike VM 2026-06-02: the firewall/squid stack comes up unchanged. Edera is
  Track B (its `protect` launch interface, pending the access key). Runbook:
  [`terraform/`](terraform/README.md) (`enable_kata=true`).
- **More agent presets - S.** The wedge; a preset is "just a file" (tool + API hosts + auth var). Cheap
  adoption, and the preset library is community moat.

**Later (adoption-gated / bigger):**
- **Hosted control plane / fleet - L.** The OSS seams already shipped (`ls` with posture/orphan/filters + `--egress`,
  cross-dir `-b/--box` targeting, `prune --orphans`, `doctor`/`egress --json`, a deny-capable central
  [policy](docs/policy.md)). The SaaS aggregator/dashboard + fleet `ls` + signed policy bundles +
  credential brokering wait on adoption pull - the monetization (open-core), not first.
- **Supply-chain depth - M - pinned replay LANDED.** `sluice lock --pin` writes a `sluice.pin` (base
  @sha256 digest + exact apk/npm/pip/gem/go/cargo versions); `SLUICE_PIN=1` replays it into a build that
  is **verified** against `sluice.lock` (fails closed on drift) - inventory-identical, not bit-for-bit
  (Wolfi apk is rolling; an aged-out version fails closed, and `sluice update` re-resolves + re-pins).
  (CycloneDX + cosign SBOM attestation + cargo inventory + SPDX output + `lock --enforce` strict gate
  shipped earlier.) Remaining depth: a full APKINDEX snapshot for offline replay of aged-out versions.

**Deferred (on real demand / not now):** Windows/WSL2, GPU passthrough, further stack detection beyond
the current 11 (the generic base + `SLUICE_EXTRA_PKGS`/`SLUICE_RUN_CMD`, or a Procfile/Makefile run target,
already run any language), a non-server batch/data-job demo, and multi-tenant adversarial isolation (a different
product - sluice is anti-exfil for code you mostly trust, not hostile-tenant isolation).

---

## Shipped - the v1 planks (condensed)

### 1. Egress that actually holds (the linchpin) - LANDED
The old enforcement (resolve domains -> IPv4 -> ipset at boot) leaked: rotating CDN IPs, direct-IP/SNI
bypass, DoH, IPv6. Shipped instead: the in-box squid intercept proxy allowing by Host/TLS-SNI, which
survives IP rotation and fails closed. Mechanics, caveats, and the TLS-interception opt-in:
[THREAT_MODEL.md](THREAT_MODEL.md).

### 2. Linux support (Docker + Podman) - CI-green: Docker + rootless Podman (rootful unsupported)
`bin/sluice` is engine-agnostic; the Linux Docker leg is the CI gate, rootless Podman is best-effort.
**Rootful Podman is unsupported**: its `netavark` backend leaves the box's `dnsmasq` unable to
enumerate interfaces (`Permission denied`), so the firewall never comes up. Two Linux-only bugs the
nightly surfaced and fixed: bind mounts keeping the host uid (the entrypoint chowns to 1000), and a
squid Host-forgery 409 on rotating-CDN hosts (fixed by the in-box caching dnsmasq pinning a name to
one IP set per session). The real dev-box smoke ran clean 2026-06-02.

### 3. Agent-native wrapping (the wedge) - 9 presets verified, sessions persist
`sluice agent <name>` scaffolds a preset and drops you in; nine ship, all defaulting to skip-approvals
since the sandbox is the gate. Cred-free harness (`nightly-agents.bats` + a weekly drift smoke) plus
live keyed round-trips (manual, 2026-06-03). Sessions persist via `SLUICE_STATE_DIRS`. Running agents:
[docs/agents.md](docs/agents.md); the preset contract: [agents/README.md](agents/README.md).

### 4. Observability + learn-mode - LANDED
squid logs the SNI/Host of every blocked connection; `sluice learn` proposes the allowlist and applies
it live (no rebuild), every run prints an at-exit egress receipt and appends to a hash-chained audit
log (`egress --export`/`--verify`), and `learn --audit` covers trusted fetchers that abort on the first
block. Walkthrough: [examples/README.md](examples/README.md).

### 5. Distribution & trust - LANDED
Apache-2.0 (open-core; the control plane is the moat), `SECURITY.md`, `install.sh`, and a Homebrew tap
pinning the cosign-signed release tarball; released through v0.9.0. Signed GHCR base image (opt-in) with
an attested SBOM, plus the `lock` audit/drift/SBOM/scan surface. Honest scope: audit/drift, **not**
reproducibility (Wolfi apk is rolling) - the remaining depth is in the backlog above. Mechanics:
[docs/supply-chain.md](docs/supply-chain.md).

### 6. `sluice init` + a preset gallery - LANDED
`sluice init` detects 11 stacks and scaffolds a working config (POSIX-clean, no engine needed);
`init --update` re-detects without clobbering manual edits, and F2 dep prefetch fetches lockfile deps at
build. Build-verified end-to-end per stack via `nightly-runtimes.bats`; elixir detection ships but its
deps don't yet compile on Wolfi (an erlang-headers gap). The `examples/` gallery is six capability
demos - **webapp**, **overlay**, **firewall**, **database**, **jupyter**, **nix**.
