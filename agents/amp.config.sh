# Amp (Sourcegraph) - run YOLO inside a sluice.
#
#   sluice agent amp
#
# YOLO is fine here: the sluice contains it (non-root, this dir only, egress locked). It can
# still rewrite this dir and use any forwarded creds, so commit your work first.
# Auth: export AMP_API_KEY (from ampcode.com/settings) on the HOST (forwarded, never baked).
SLUICE_EXTRA_NPM="@ampcode/cli"
# ampcode.com = service + installer; static.ampcode.com = binary/version updates; auth.ampcode.com =
# auth handshake; production.ampworkers.com = the Amp client's WebSocket (all per ampcode.com/security).
SLUICE_ALLOW_DOMAINS="ampcode.com static.ampcode.com auth.ampcode.com production.ampworkers.com"
SLUICE_DESC="Amp (Sourcegraph)"
# In-repo secrets: .env* files are shadowed (unreadable in the box); SLUICE_MASK="" to disable.
SLUICE_MASK=".env*"
SLUICE_ENV="AMP_API_KEY"
# Persist amp's settings/auth across runs (host-side, per project).
SLUICE_STATE_DIRS=".config/amp"
# --dangerously-allow-all bypasses Amp's command allowlist (the sluice is the sandbox).
SLUICE_RUN_CMD="amp --dangerously-allow-all"
