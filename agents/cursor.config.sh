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
# api2.cursor.sh = most API; .api5.cursor.sh = agent requests + regional agent.* subdomains; authenticate/
# authenticator/.authentication.cursor.sh = login; downloads.cursor.com = self-update. cursor.sh carries the model/agent stream (laundering surface, THREAT_MODEL #2/#4).
SLUICE_ALLOW_DOMAINS="cursor.com api2.cursor.sh .api5.cursor.sh authenticate.cursor.sh authenticator.cursor.sh .authentication.cursor.sh downloads.cursor.com"
SLUICE_DESC="Cursor CLI (cursor-agent)"
SLUICE_ENV="CURSOR_API_KEY"
# Persist cursor-agent's config/auth across runs (.cursor holds cli-config.json). NOT .local -
# that's where the installed binary lives, and a mount would shadow it.
SLUICE_STATE_DIRS=".cursor"
# --force enables auto-run (no per-command confirmation). Drop it for interactive.
SLUICE_RUN_CMD="cursor-agent --force"
