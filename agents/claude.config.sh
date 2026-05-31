# Claude Code - Anthropic's agentic coding CLI - run YOLO inside a sluice.
#
#   sluice agent claude
#
# Auth: export ANTHROPIC_API_KEY (or CLAUDE_CODE_OAUTH_TOKEN) on the HOST before running -
# it's forwarded into the box, never baked into the image. The browser OAuth login can't
# complete in a headless sandbox, so use a key/token.
SLUICE_EXTRA_NPM="@anthropic-ai/claude-code"
SLUICE_ALLOW_DOMAINS="api.anthropic.com console.anthropic.com statsig.anthropic.com"
SLUICE_ENV="ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN"
# --dangerously-skip-permissions = YOLO, and it's defensible *because* the sluice is the
# sandbox: non-root, only this project dir mounted, egress locked to the hosts above.
SLUICE_RUN_CMD="claude --dangerously-skip-permissions"
