# Central egress policy

A policy an organization controls that the running box's local `sluice.config.sh` cannot loosen:
it can **add** and **deny** allowlist hosts and **refuse to run** when local config crosses a ceiling.
Inert unless a policy is configured. Signing is planned (v2.1); today integrity rests on the source
(see [the managed-mode boundary](#managed-mode-the-honest-boundary)).

## Sources and precedence

Read from up to three places, lowest trust first. A `deny`/`forbid` from **any** source is final.

| Source | Who controls it | Trust |
|---|---|---|
| `SLUICE_POLICY_URL` (env: `http`/`https`/`file`) | the developer / CI | advisory-to-self |
| `~/.config/sluice/policy.conf` | the developer | advisory-to-self |
| `/etc/sluice/policy.conf` (**root-owned**) | the org (pushed via MDM) | enforced |

A configured `SLUICE_POLICY_URL` that cannot be fetched is **fatal** on any command that consults the
policy - `run`/`shell`/`build`/`rebuild`/`update`/`diff` and `sluice learn` - a managed policy must never
silently fall back to local-only.

## Format

Plain text, one directive per line, `#` comments. A bare host is `allow` (back-compat with the v1
host-list). Unknown directives warn and are ignored (or refuse, under `strict-unknown`).

```
# egress
allow  api.internal.example.com     # add a host (a bare line means the same)
deny   .pastebin.com                 # remove from the effective allowlist, even if local config added it

# ceilings - refuse to run if local config crosses them
deny-ip 169.254.169.254/32           # forbid any SLUICE_ALLOW_IPS entry that OVERLAPS this CIDR
                                     #   (an entry inside it, or a supernet that contains it)
forbid SLUICE_DNS_OPEN               # refuse if the config sets this loosening knob
forbid SLUICE_ALLOW_DOH
forbid SLUICE_BUMP_DOMAINS
forbid-laundering                    # refuse any allowlisted host an attacker could also write to
max-allow-ips 2                      # cap the number of SLUICE_ALLOW_IPS entries
max-allow-ips-bytes 10485760         # mandate a direct-IP volume bound: refuse if SLUICE_ALLOW_IPS is
                                     #   set without a SLUICE_ALLOW_IPS_MAX_BYTES <= this
max-hard-cap-bytes 10485760          # mandate a preventive (proxied-lane) egress ceiling: refuse if the
                                     #   box sets no SLUICE_EGRESS_HARD_CAP_BYTES, or one larger than this

# policy-level
strict-unknown                       # make an unknown directive a hard refusal, not a warning
require-signed-base                  # mandate SLUICE_REQUIRE_SIGNED=1 for every box under this policy
```

## Enforcement

Applied host-side on every box bring-up (`run`/`shell`/`build`/`rebuild`/`update`/`diff` - `diff` builds
and starts a box too), as the final gate after the
config (and any `sluice learn` edits) - so policy wins:

- **Allowlist** (`allow`/`deny`): effective = (local + `allow`) - `deny`. The box receives the
  narrowed list at start, and `sluice learn` will not re-add a denied host (it fails closed, like `run`,
  if the policy URL is unreachable). `deny` is non-fatal -
  the host is simply unreachable. One exception is fatal: a local `allow` **wildcard** that would
  cover a denied host (e.g. `.githubusercontent.com` against `deny gist.githubusercontent.com`)
  **refuses to run** rather than let the wildcard silently re-admit it - narrow it to exact hosts.
  Wildcard entries (e.g. `*.s3.amazonaws.com`) are matched **literally**: the effective list is
  computed independently of the invocation directory, so a glob-shaped host is never expanded against
  the working directory's filenames.
- **Ceilings** (`forbid`/`deny-ip`/`max-allow-ips`/`max-allow-ips-bytes`/`forbid-laundering`/`max-hard-cap-bytes`): a
  violation **refuses to run** (exit non-zero), naming the offending knob/host. `deny-ip` refuses an
  `SLUICE_ALLOW_IPS` entry that OVERLAPS the CIDR in either direction (inside it, or a supernet
  containing it). `max-hard-cap-bytes N` mandates a preventive volume ceiling on the proxied lane and
  `max-allow-ips-bytes N` mandates one on the direct-IP lane (`SLUICE_ALLOW_IPS_MAX_BYTES <= N` when
  `SLUICE_ALLOW_IPS` is set) - a box that sets no `SLUICE_EGRESS_HARD_CAP_BYTES`, or one
  above `N`, is refused, so a developer can't opt out of the bound. A malformed (non-numeric) ceiling
  arg is itself a hard refusal, not a silent no-op. (A verb-with-arg directive, so a
  pre-directive client warns-and-ignores it rather than mis-reading it as an allowlist host.) `SLUICE_ALLOW_IPS` is refused rather than
  silently trimmed because the firewall reads the baked list - a host-side trim wouldn't reach a
  running box, so a hard refuse is the honest contract.

## Signing

A `SLUICE_POLICY_URL` body is fetched over the network, so it can be **authenticated** before use
(the local files are filesystem-trusted; the `/etc` one is root-owned). All env-only:

- `SLUICE_POLICY_SHA256` - pin the policy body's sha256. No cosign needed; a mismatch refuses.
- `SLUICE_POLICY_SIG` - path/URL to a cosign `sign-blob` bundle for the body; `SLUICE_POLICY_IDENTITY`
  is the expected signer (a `--certificate-identity-regexp`), `SLUICE_POLICY_ISSUER` the OIDC issuer
  (default GitHub Actions). Verified with `cosign verify-blob`; a bad signature refuses.
- `SLUICE_POLICY_REQUIRE=1` - the policy is unusable unless a sig or pin verifies (fails closed even if
  neither is set). The body hashed is what `curl` returns with trailing newlines stripped - sign/pin
  the same bytes (`printf '%s' "$(cat policy.conf)" | sha256sum`).

Sign a policy (org side, keyless):
`cosign sign-blob --yes policy.conf --bundle policy.conf.cosign.bundle`, publish both, and have clients
set `SLUICE_POLICY_URL` + `SLUICE_POLICY_SIG` + `SLUICE_POLICY_IDENTITY`.

## Managed mode (the honest boundary)

sluice provides the **enforcement mechanism** (policy beats local config). It does **not** by itself
stop a developer who controls root on their own machine: the *can't-remove-it* property comes from
the org deploying `/etc/sluice/policy.conf` **root-owned** (so the dev can't edit it without root) and
shipping the sluice binary itself. A signed `SLUICE_POLICY_URL` (above) lets a network-served policy be
trusted without the root-owned file. See [THREAT_MODEL.md](../THREAT_MODEL.md).
