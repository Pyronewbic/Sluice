#!/usr/bin/env bash
# Pinned + checksum-verified container-structure-test (CI, linux-amd64; no sudo). The verifier that
# attests the base image gates a cosign sign+push in publish-base.yml, so it must itself be pinned: the
# committed digest fails closed if a release is re-published with a swapped binary. Bump VER+SHA together.
set -euo pipefail

CST_VER=v1.22.1
CST_SHA256=fa35e89512a8978585f76cf41397956d2e3a30c62c2ad3fb857b1597074d14ca   # linux-amd64
asset=container-structure-test-linux-amd64

curl -fsSL "https://github.com/GoogleContainerTools/container-structure-test/releases/download/${CST_VER}/${asset}" -o cst
echo "${CST_SHA256}  cst" | sha256sum -c -
chmod +x cst
mkdir -p "$HOME/.local/bin"
mv cst "$HOME/.local/bin/container-structure-test"
if [ -n "${GITHUB_PATH:-}" ]; then echo "$HOME/.local/bin" >> "$GITHUB_PATH"; fi
