# Laundering-cover demo: a REAL agent posture, not a contrived one. The claude preset must allow
# api.anthropic.com for the agent to work at all - and that host is POST-capable, so an attacker
# inside the box can write data OUT through it. sluice splices, never decrypts, so the request body
# is not inspected. Allowlisting cannot close this; the gate names it instead.
SLUICE_DESC="Claude Code (Anthropic)"
SLUICE_ALLOW_DOMAINS="api.anthropic.com"
SLUICE_MASK=".env*"
SLUICE_ENV="ANTHROPIC_API_KEY"
SLUICE_RUN_CMD="true"
