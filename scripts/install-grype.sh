#!/usr/bin/env bash
# Pinned + checksum-verified grype (CI, linux-amd64; no sudo) for the nightly lock --scan leg.
# Replaces piping anchore's main-branch installer to the shell: the committed digest fails closed if
# a release is re-published with a swapped binary. Bump VER+SHA together (from the _checksums.txt).
set -euo pipefail

GRYPE_VER=v0.115.0
GRYPE_SHA256=3fad92940650e514c0aa2dad83526942a055e210cec09a8a59d9c024adc2b90e   # linux_amd64.tar.gz
asset="grype_${GRYPE_VER#v}_linux_amd64.tar.gz"

curl -fsSL "https://github.com/anchore/grype/releases/download/${GRYPE_VER}/${asset}" -o grype.tgz
echo "${GRYPE_SHA256}  grype.tgz" | sha256sum -c -
tar -xzf grype.tgz grype
rm -f grype.tgz
mkdir -p "$HOME/.local/bin"
mv grype "$HOME/.local/bin/grype"
if [ -n "${GITHUB_PATH:-}" ]; then echo "$HOME/.local/bin" >> "$GITHUB_PATH"; fi
