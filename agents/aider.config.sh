# aider — open-source terminal pair-programmer — inside a sluice.
#
#   sluice agent aider
#
# Auth: export OPENAI_API_KEY and/or ANTHROPIC_API_KEY on the HOST (forwarded, never baked).
SLUICE_EXTRA_PKGS="python-3.12 py3.12-pip"
# Installed at build (free egress) as the node user; aider runs in your mounted git repo.
SLUICE_SETUP_CMDS='pip install --user --no-input aider-chat'
SLUICE_ALLOW_DOMAINS="api.openai.com api.anthropic.com"
SLUICE_ENV="OPENAI_API_KEY ANTHROPIC_API_KEY"
# --yes-always auto-confirms edits (the sluice is the safety net). Drop it for interactive.
SLUICE_RUN_CMD='export PATH="$HOME/.local/bin:$PATH"; aider --yes-always'
