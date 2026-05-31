# Claude Code - Anthropic's agentic coding CLI - run YOLO inside a sluice.
#
#   sluice agent claude
#
# YOLO is fine here: the sluice contains it (non-root, this dir only, egress locked). It can
# still rewrite this dir and use any forwarded creds, so commit your work first.
# Auth: export ANTHROPIC_API_KEY (or CLAUDE_CODE_OAUTH_TOKEN) on the HOST before running -
# it's forwarded into the box, never baked. Browser OAuth can't complete headless, use a key.
SLUICE_EXTRA_NPM="@anthropic-ai/claude-code"
SLUICE_ALLOW_DOMAINS="api.anthropic.com console.anthropic.com statsig.anthropic.com"
SLUICE_ENV="ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN"
# --dangerously-skip-permissions = YOLO. Drop it for interactive approvals.
SLUICE_RUN_CMD="claude --dangerously-skip-permissions"
