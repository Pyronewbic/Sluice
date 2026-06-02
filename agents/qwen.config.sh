# Qwen Code - Alibaba's terminal coding agent - run YOLO inside a sluice.
#
#   sluice agent qwen
#
# YOLO is fine here: the sluice contains it (non-root, this dir only, egress locked). It can
# still rewrite this dir and use any forwarded creds, so commit your work first.
# Auth: export OPENAI_API_KEY with your DashScope (Model Studio) key on the HOST (forwarded,
# never baked). The run cmd points it at DashScope's OpenAI-compatible endpoint.
SLUICE_EXTRA_NPM="@qwen-code/qwen-code"
# DashScope's OpenAI-compatible API. The intl endpoint is the default; for mainland China swap
# OPENAI_BASE_URL to dashscope.aliyuncs.com (drop -intl). Both hosts are allowlisted.
SLUICE_ALLOW_DOMAINS="dashscope-intl.aliyuncs.com dashscope.aliyuncs.com"
SLUICE_ENV="OPENAI_API_KEY DASHSCOPE_API_KEY"
# Persist Qwen Code's sessions/settings across runs (host-side, per project).
SLUICE_STATE_DIRS=".qwen"
# --yolo auto-approves all actions. Drop it for interactive. The exports select DashScope's
# OpenAI-compatible endpoint + the coder model.
SLUICE_RUN_CMD='export OPENAI_BASE_URL="https://dashscope-intl.aliyuncs.com/compatible-mode/v1" OPENAI_MODEL="${OPENAI_MODEL:-qwen3-coder-plus}"; qwen --yolo'
