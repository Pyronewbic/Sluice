# Amp (Sourcegraph) - run YOLO inside a sluice.   [best-effort: confirm host(s)]
#
#   sluice agent amp
#
# YOLO is fine here: the sluice contains it (non-root, this dir only, egress locked). It can
# still rewrite this dir and use any forwarded creds, so commit your work first.
# Auth: export AMP_API_KEY (from ampcode.com/settings) on the HOST (forwarded, never baked).
SLUICE_EXTRA_NPM="@sourcegraph/amp"
# Amp proxies models through its own backend; if a request is blocked, run `sluice learn`.
SLUICE_ALLOW_DOMAINS="ampcode.com"
SLUICE_ENV="AMP_API_KEY"
# --dangerously-allow-all bypasses Amp's command allowlist (the sluice is the sandbox).
SLUICE_RUN_CMD="amp --dangerously-allow-all"
