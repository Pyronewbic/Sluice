# OpenAI Codex CLI — run inside a sluice.
#
#   sluice agent codex
#
# Auth: export OPENAI_API_KEY on the HOST before running (forwarded, never baked). The
# ChatGPT browser login can't complete headless, so use an API key.
SLUICE_EXTRA_NPM="@openai/codex"
SLUICE_ALLOW_DOMAINS="api.openai.com auth.openai.com chatgpt.com"
SLUICE_ENV="OPENAI_API_KEY"
# Plain `codex` is interactive. For unattended/YOLO (the sluice is the sandbox) add Codex's
# bypass flag, e.g.  codex --dangerously-bypass-approvals-and-sandbox
SLUICE_RUN_CMD="codex"
