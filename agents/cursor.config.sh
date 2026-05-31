# Cursor CLI (cursor-agent) — inside a sluice.   [best-effort: confirm run cmd + hosts]
#
#   sluice agent cursor
#
# Auth: export CURSOR_API_KEY on the HOST before running (forwarded, never baked).
SLUICE_EXTRA_NPM="@cursor/cli"
# Cursor proxies models through its own backend; if a request is blocked, run `sluice learn`
# to discover the host and add it here.
SLUICE_ALLOW_DOMAINS="cursor.com api2.cursor.sh api.cursor.com"
SLUICE_ENV="CURSOR_API_KEY"
SLUICE_RUN_CMD="cursor-agent"
