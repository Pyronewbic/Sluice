# A developer's local config that tries to loosen the org policy on BOTH axes.
# sluice refuses PRE-BUILD (no box ever starts):
#   1) it allowlists the exact host the policy denies       -> deny is final (silently narrowed)
#   2) it opens a direct-IP SUPERNET that CONTAINS the denied metadata /32:
#      169.254.169.0/24 is a supernet of 169.254.169.254/32 -> OVERLAP -> hard refusal.
# This is the #76 H1 bypass: a supernet used to sail past a base-only /32 check and reach metadata.
SLUICE_ALLOW_DOMAINS="metadata.example.internal"
SLUICE_ALLOW_IPS="169.254.169.0/24:80"
SLUICE_RUN_CMD='echo "if you can read this, the box booted - it must not"'
