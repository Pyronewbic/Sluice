# Cursor CLI (cursor-agent) - run YOLO inside a sluice.   [best-effort: confirm flag + hosts]
#
#   sluice agent cursor
#
# YOLO is fine here: the sluice contains it (non-root, this dir only, egress locked). It can
# still rewrite this dir and use any forwarded creds, so commit your work first.
# Auth: export CURSOR_API_KEY on the HOST before running (forwarded, never baked).
SLUICE_EXTRA_NPM="@cursor/cli"
# Cursor proxies models through its own backend; if a request is blocked, run `sluice learn`.
SLUICE_ALLOW_DOMAINS="cursor.com api2.cursor.sh api.cursor.com"
SLUICE_ENV="CURSOR_API_KEY"
# --force enables auto-run (no per-command confirmation). Drop it for interactive.
SLUICE_RUN_CMD="cursor-agent --force"
