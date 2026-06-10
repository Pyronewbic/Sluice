# Supply chain

What is in the box, and where the base came from. Knob reference:
[configuration.md](configuration.md).

## `sluice lock`: image inventory

`sluice lock` builds the image if needed and writes a committable `./sluice.lock`: the base image
ref (digest when available) plus every package the image carries - apk, global npm, pip (system,
the project's `--user` site, and pipx apps), gem, go binaries, cargo installs - sorted for stable
diffs. Re-locking prints the supply-chain delta since the last lock.

```bash
sluice lock              # write ./sluice.lock, commit it
sluice lock --diff       # local drift review, always exits 0
sluice lock --check      # CI: exit 1 when the built image drifted from the committed lock
sluice lock --enforce    # strict CI gate: refuses to build or to tolerate a stale image
sluice update            # rebuild --no-cache, then refresh the lock
```

All three report forms take `--json`.

<p align="center"><img src="../assets/lock-demo.gif" width="700" alt="sluice lock --check reports the inventory in sync; after a dependency is added and the box rebuilt, lock --check catches the drift (classified: + apk tree, exit 1); re-lock records the supply-chain delta, then a CycloneDX SBOM carries the new package with its purl and SHA-1 integrity hash; finally lock --scan --fail-on high runs that SBOM through a host grype and gates the build on the lodash CVEs (non-zero exit)"></p>

### Audit, not reproducibility

Wolfi apk is a rolling repo, so the same config builds different versions on different days.
`sluice.lock` is a drift/audit artifact - it tells you exactly what changed between builds; it
does not pin a bit-for-bit rebuild. The lock header says so.

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
sluice lock --scan --fail-on high   # non-zero on a finding at high or above
```

Severities: `negligible|low|medium|high|critical`. With no scanner installed it prints a note and
exits 0 - but dies if `--fail-on` was given.

## Base image identity

A local build constructs everything from `cgr.dev/chainguard/wolfi-base`
([core/Dockerfile](../core/Dockerfile)) - an unpinned, rolling base, the same honesty as the lock.
To build your project layer on the published, signed core instead:

```bash
SLUICE_BASE_IMAGE=ghcr.io/pyronewbic/sluice-base:latest
SLUICE_REQUIRE_SIGNED=1   # die unless the signature AND SBOM attestation verify
```

The published base is multi-arch (`linux/amd64` + `linux/arm64`), built from the Dockerfile's
`base` stage on every version tag, cosign-signed keyless via GitHub OIDC, and carries a CycloneDX
SBOM attestation ([publish-base.yml](../.github/workflows/publish-base.yml)). Before pushing, CI
asserts the base invariants: uid 1000, no sudo, the firewall packages, no baked key.

When `SLUICE_BASE_IMAGE` points at a `sluice-base` ref and cosign is installed, the launcher
verifies the signature and attestation automatically - warn-and-continue by default, fatal with
`SLUICE_REQUIRE_SIGNED=1`.

## Verify it yourself

The same checks the launcher runs:

```bash
cosign verify ghcr.io/pyronewbic/sluice-base:latest \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity-regexp='^https://github.com/Pyronewbic/Sluice/'

cosign verify-attestation --type cyclonedx ghcr.io/pyronewbic/sluice-base:latest \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity-regexp='^https://github.com/Pyronewbic/Sluice/'
```

## No key in the image

The TLS splice certificate is minted per container at start
([core/entrypoint.sh](../core/entrypoint.sh)); neither your built image nor the published base
carries a private key, so a leaked image leaks nothing to impersonate. The cert only lets squid
bind its port - sluice splices, it does not forge, unless you opt into
[scoped TLS interception](../THREAT_MODEL.md#scoped-tls-interception-opt-in-off-by-default).
