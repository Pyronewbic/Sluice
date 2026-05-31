# OpenAI Codex CLI - run YOLO inside a sluice.
#
#   sluice agent codex
#
# YOLO is fine here: the sluice contains it (non-root, this dir only, egress locked). It can
# still rewrite this dir and use any forwarded creds, so commit your work first.
# Auth: export OPENAI_API_KEY on the HOST before running (forwarded, never baked).
SLUICE_EXTRA_NPM="@openai/codex"
SLUICE_ALLOW_DOMAINS="api.openai.com auth.openai.com chatgpt.com"
SLUICE_ENV="OPENAI_API_KEY"
# --dangerously-bypass-approvals-and-sandbox (alias --yolo): no approvals, no Codex sandbox
# (the sluice IS the sandbox). Drop it for interactive approvals.
SLUICE_RUN_CMD="codex --dangerously-bypass-approvals-and-sandbox"
