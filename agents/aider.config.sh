# aider - open-source terminal pair-programmer - run YOLO inside a sluice.
#
#   sluice agent aider
#
# YOLO is fine here: the sluice contains it (non-root, this dir only, egress locked). It can
# still rewrite this dir and use any forwarded creds, so commit your work first.
# Auth: export OPENAI_API_KEY and/or ANTHROPIC_API_KEY on the HOST (forwarded, never baked).
SLUICE_EXTRA_PKGS="python-3.12 py3.12-pip"
# Installed at build (free egress) as the sluice user; aider runs in your mounted git repo.
SLUICE_SETUP_CMDS='pip install --user --no-input aider-chat'
SLUICE_ALLOW_DOMAINS="api.openai.com api.anthropic.com"
SLUICE_DESC="Aider (pair programmer)"
# In-repo secrets: .env* files are shadowed (unreadable in the box); SLUICE_MASK="" to disable.
SLUICE_MASK=".env*"
SLUICE_ENV="OPENAI_API_KEY ANTHROPIC_API_KEY"
# Aider's chat history lives in-repo (.aider.*, already persisted via the mount); this keeps
# its model-metadata cache across runs too. (Not .local - that's where pip --user installs it.)
SLUICE_STATE_DIRS=".aider"
# --yes-always auto-confirms edits/commands; --no-check-update skips aider's pypi.org version ping;
# LITELLM_LOCAL_MODEL_COST_MAP uses litellm's bundled price map (else it fetches one off-allowlist). Drop --yes-always for interactive.
SLUICE_RUN_CMD='export PATH="$HOME/.local/bin:$PATH"; LITELLM_LOCAL_MODEL_COST_MAP=True aider --yes-always --no-check-update'
