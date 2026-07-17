# The compliant config: it stays under the org policy - no direct-IP hatch into the metadata
# range, no allowlist entry the policy denies. Same policy, same box, builds and runs clean.
SLUICE_RUN_CMD='echo "compliant workload: reachable set is exactly what the org allows"'
