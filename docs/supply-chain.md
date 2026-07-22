# Supply chain

What is in the box, and where the base came from. Knob reference:
[configuration.md](configuration.md).

## `sluice lock`: image inventory

`sluice lock` builds the image if needed and writes a committable `./sluice.lock`: the base image
ref (digest when available) plus every package the image carries - apk, global npm, pip (system,
the project's `--user` site, and pipx apps), gem, go binaries, cargo installs - sorted for stable
diffs. Re-locking prints the supply-chain delta since the last lock.

`sluice lock` fails closed: if the image inventory read fails it refuses to write a base-only (hollow)
`sluice.lock` rather than emit a misleading audit artifact reported as success.

```bash
sluice lock              # write ./sluice.lock, commit it
sluice lock --diff       # local drift review, always exits 0
sluice lock --check      # CI: exit 1 when the built image drifted from the committed lock
sluice lock --enforce    # strict CI gate: refuses to build or to tolerate a stale image
sluice update            # rebuild --no-cache, then refresh the lock
```

All three report forms take `--json`.

### Reproducibility, in tiers (be honest)

Wolfi apk is a rolling repo, so the same config builds different versions on different days. sluice
offers three honest tiers - pick the one you need:

| Tier | Command | What it guarantees |
|---|---|---|
| **Audit / drift** (default) | `sluice lock` | Records exactly what got built; `--check`/`--enforce` gate on any change since. **Not** a rebuild guarantee - the lock header says so. |
| **Verified replay** | `sluice lock --pin` + `SLUICE_PIN=1` | Rebuilds from the recorded base **digest** and exact package versions, then **verifies** the result matches `sluice.lock` (fails closed on drift). Inventory-identical, **not** bit-for-bit. |
| never claimed | — | Bit-for-bit reproducibility; replay of an apk version Wolfi has aged out (rolling repo); or `SLUICE_SETUP_CMDS` side effects outside the six inventoried ecosystems. |

The default `sluice.lock` disclaimer stays true for the audit tier; `SLUICE_PIN=1` earns the stronger
(but still bounded) replay claim by verification, not by assertion.

## `sluice lock --pin`: a replay manifest

`sluice lock --pin` writes a committable `./sluice.pin`: the base image pinned by **`@sha256` digest**
plus every apk/npm/pip/gem/go/cargo name and version - the coordinates a `SLUICE_PIN=1` build replays to
converge on those exact versions.

```bash
sluice lock --pin        # write ./sluice.pin (also refreshes ./sluice.lock from the same image)
```

`--pin` reads one built image, so it refreshes `sluice.lock` in the same pass - the two can never
disagree. It fails **closed** two ways: a hollow inventory (the masked-read case, like `lock`) refuses to
write, and a base that cannot be resolved to a digest refuses too - a pin that cannot freeze its base is
worse than none (it pulls the base once to resolve the digest if the local engine has none yet).

**Honest scope.** Pinning narrows, it does not fully reproduce: an apk pin **fails closed** once Wolfi
stops serving that exact version (a rolling repo garbage-collects old versions), and the pin header says
so. It is a stronger guarantee than `sluice.lock`'s drift audit, not a bit-for-bit reproducibility claim.

## SBOM

`sluice lock --sbom` emits a deterministic SBOM to stdout - no timestamp or serial, purl-sorted,
so it is byte-stable and diffs cleanly in CI:

```bash
sluice lock --sbom                  # CycloneDX 1.6 (default)
sluice lock --sbom --format spdx    # the same package set as SPDX 2.3
```

It covers the same six ecosystems as the lock; apk components carry their SHA-1 integrity hash.

## Vulnerability scan

`sluice lock --scan` feeds that SBOM to a scanner on the host (never baked into the image) -
Grype preferred, Trivy as a fallback. Report-only by default; `--fail-on` makes it a CI gate:

```bash
sluice lock --scan
sluice lock --scan --fail-on high   # gate: exits 3 on a finding at high or above
```

Severities: `negligible|low|medium|high|critical`. Report-only by default (exits 0 regardless and
says so on stderr); `--fail-on <sev>` turns it into a gate.

**Exit contract.** Grype and Trivy disagree on their raw exit codes (Grype exits 2 on a gated
finding but 1 on a DB/catalog error; Trivy exits 1 on a gated finding), so "a CVE gate tripped" and
"the scanner broke" are otherwise indistinguishable and scanner-specific. `sluice lock --scan`
normalizes them to one contract:

| exit | meaning |
|------|---------|
| `0`  | clean (no finding at/above `--fail-on`, or report-only) |
| `3`  | gate tripped - a finding at or above `--fail-on` |
| `4`  | the scanner failed to run (DB/catalog/parse error) - the scan did **not** complete |

With no scanner installed it prints a note and exits 0 - but dies if `--fail-on` was given.
`--scan --json` passes the scanner's own JSON through verbatim (Grype's or Trivy's schema), so unlike
the other `--json` outputs its shape is the scanner's, not sluice's.

Note: `sluice doctor` reports lock drift but never gates on it (it always exits 0); use `sluice lock
--check` / `--enforce` for the CI gate.

## Base image identity

A local build constructs everything from `cgr.dev/chainguard/wolfi-base`
([core/Dockerfile](../core/Dockerfile)) - an unpinned, rolling base, the same honesty as the lock.
To build your project layer on the published, signed core instead:

```bash
SLUICE_BASE_IMAGE=ghcr.io/pyronewbic/sluice-base:latest
SLUICE_REQUIRE_SIGNED=1   # die unless the signature AND SBOM attestation verify
```

For a reproducible pin, point `SLUICE_BASE_IMAGE` at an immutable ref instead of `:latest` - a version
tag (`sluice-base:v0.10.0`, pushed alongside `:latest` on every release) or a `@sha256:...` digest.

The published base is multi-arch (`linux/amd64` + `linux/arm64`), built from the Dockerfile's
`base` stage on every version tag, cosign-signed keyless via GitHub OIDC, and carries a CycloneDX
SBOM attestation ([publish-base.yml](../.github/workflows/publish-base.yml)). Before pushing, CI
structure-tests the base invariants (uid 1000, no sudo, the firewall packages, no baked key) on the
**amd64** build; arm64 shares the same Dockerfile (the invariants are arch-invariant), and the
CycloneDX SBOM is derived from the amd64 image.

When `SLUICE_BASE_IMAGE` points at a `sluice-base` ref and cosign is installed, the launcher
verifies the signature and attestation automatically - warn-and-continue by default, fatal with
`SLUICE_REQUIRE_SIGNED=1`.

## Verify it yourself

The same checks the launcher runs:

```bash
cosign verify ghcr.io/pyronewbic/sluice-base:latest \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity-regexp='^https://github\.com/Pyronewbic/Sluice/\.github/workflows/publish-base\.yml@refs/tags/v'

cosign verify-attestation --type cyclonedx ghcr.io/pyronewbic/sluice-base:latest \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity-regexp='^https://github\.com/Pyronewbic/Sluice/\.github/workflows/publish-base\.yml@refs/tags/v'
```

## No key in the image

The TLS splice certificate is minted per container at start
([core/entrypoint.sh](../core/entrypoint.sh)); neither your built image nor the published base
carries a private key, so a leaked image leaks nothing to impersonate. The cert only lets squid
bind its port - sluice splices, it does not forge, unless you opt into
[scoped TLS interception](../THREAT_MODEL.md#scoped-tls-interception-opt-in-off-by-default).
