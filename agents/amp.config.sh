# Amp (Sourcegraph) - run YOLO inside a sluice.
#
#   sluice agent amp
#
# YOLO is fine here: the sluice contains it (non-root, this dir only, egress locked). It can
# still rewrite this dir and use any forwarded creds, so commit your work first.
# Auth: export AMP_API_KEY (from ampcode.com/settings) on the HOST (forwarded, never baked).
SLUICE_EXTRA_NPM="@sourcegraph/amp"
# Amp proxies models through ampcode.com; static.ampcode.com is the update/version check.
SLUICE_ALLOW_DOMAINS="ampcode.com static.ampcode.com"
SLUICE_DESC="Amp (Sourcegraph)"
SLUICE_ENV="AMP_API_KEY"
# Persist amp's settings/auth across runs (host-side, per project).
SLUICE_STATE_DIRS=".config/amp"
# --dangerously-allow-all bypasses Amp's command allowlist (the sluice is the sandbox).
SLUICE_RUN_CMD="amp --dangerously-allow-all"
