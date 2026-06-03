# sluice config - scaffolded by 'sluice init' (detected: go (prefetched)).
SLUICE_EXTRA_PKGS="go"
SLUICE_PORTS="8080"            # ports to publish (the app MUST bind 0.0.0.0)
SLUICE_PREFETCH_FILES="go.mod go.sum"   # manifests copied into the build for the prefetch
SLUICE_PREFETCH_CMD="go mod download"   # fetch deps at build (free egress) so runtime egress can drop the registry
SLUICE_RUN_CMD="GOPROXY=off go run ."
SLUICE_ALLOW_DOMAINS=""        # runtime egress hosts (or run 'sluice learn')
