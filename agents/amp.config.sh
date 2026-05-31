# Amp (Sourcegraph) — inside a sluice.   [best-effort: confirm host(s)]
#
#   sluice agent amp
#
# Auth: export AMP_API_KEY (from ampcode.com/settings) on the HOST (forwarded, never baked).
SLUICE_EXTRA_NPM="@sourcegraph/amp"
# Amp proxies models through its own backend; if a request is blocked, run `sluice learn`.
SLUICE_ALLOW_DOMAINS="ampcode.com"
SLUICE_ENV="AMP_API_KEY"
SLUICE_RUN_CMD="amp"
