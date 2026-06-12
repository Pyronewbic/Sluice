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

A configured `SLUICE_POLICY_URL` that cannot be fetched is **fatal** - a managed policy must never
silently fall back to local-only.

## Format

Plain text, one directive per line, `#` comments. A bare host is `allow` (back-compat with the v1
host-list). Unknown directives warn and are ignored.

```
# egress
allow  api.internal.example.com     # add a host (a bare line means the same)
deny   .pastebin.com                 # remove from the effective allowlist, even if local config added it

# ceilings - refuse to run if local config crosses them
deny-ip 0.0.0.0/0                    # forbid a SLUICE_ALLOW_IPS entry inside this CIDR
forbid SLUICE_DNS_OPEN               # refuse if the config sets this loosening knob
forbid SLUICE_ALLOW_DOH
forbid SLUICE_BUMP_DOMAINS
forbid-laundering                    # refuse any allowlisted host an attacker could also write to
max-allow-ips 2                      # cap the number of SLUICE_ALLOW_IPS entries
```

## Enforcement

Applied host-side on every `run`/`shell`/`build`/`rebuild`/`update`, as the final gate after the
config (and any `sluice learn` edits) - so policy wins:

- **Allowlist** (`allow`/`deny`): effective = (local + `allow`) - `deny`. The box receives the
  narrowed list at start, and `sluice learn` will not re-add a denied host. `deny` is non-fatal -
  the host is simply unreachable.
- **Ceilings** (`forbid`/`deny-ip`/`max-allow-ips`/`forbid-laundering`): a violation **refuses to
  run** (exit non-zero), naming the offending knob/host. `SLUICE_ALLOW_IPS` is refused rather than
  silently trimmed because the firewall reads the baked list - a host-side trim wouldn't reach a
  running box, so a hard refuse is the honest contract.

## Managed mode (the honest boundary)

sluice provides the **enforcement mechanism** (policy beats local config). It does **not** by itself
stop a developer who controls root on their own machine: the *can't-remove-it* property comes from
the org deploying `/etc/sluice/policy.conf` **root-owned** (so the dev can't edit it without root) and
shipping the sluice binary itself. Signed policies (v2.1) will let a non-root-owned source still be
trusted. See [THREAT_MODEL.md](../THREAT_MODEL.md).
