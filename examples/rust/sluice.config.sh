# sluice config - scaffolded by 'sluice init' (detected: rust).
# Review the values, then run 'sluice' (or 'sluice learn' to discover the egress allowlist).

SLUICE_EXTRA_PKGS="rust build-base"
SLUICE_PORTS="8080"            # ports to publish (the app MUST bind 0.0.0.0)
SLUICE_RUN_CMD="cargo run"
SLUICE_ALLOW_DOMAINS="static.crates.io index.crates.io"    # runtime egress hosts (or run 'sluice learn')
