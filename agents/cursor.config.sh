# Cursor CLI (cursor-agent) - run YOLO inside a sluice.
#
#   sluice agent cursor
#
# YOLO is fine here: the sluice contains it (non-root, this dir only, egress locked). It can
# still rewrite this dir and use any forwarded creds, so commit your work first.
# Auth: export CURSOR_API_KEY on the HOST before running (forwarded, never baked).
# cursor-agent installs via Cursor's own script (it is NOT an npm package); the installer drops
# the binary under ~/.local, so we symlink it onto PATH. Runs at build, pre-firewall (free egress).
SLUICE_SETUP_CMDS='curl https://cursor.com/install -fsS | bash && mkdir -p "$HOME/.npm-global/bin" && ln -sf "$HOME/.local/bin/cursor-agent" "$HOME/.npm-global/bin/cursor-agent"'
# Cursor proxies models through its own backend; downloads.cursor.com is the binary self-update.
SLUICE_ALLOW_DOMAINS="cursor.com api2.cursor.sh api.cursor.com downloads.cursor.com"
SLUICE_ENV="CURSOR_API_KEY"
# --force enables auto-run (no per-command confirmation). Drop it for interactive.
SLUICE_RUN_CMD="cursor-agent --force"
