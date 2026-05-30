#!/usr/bin/env bash
# Install the global `sluice` CLI: symlink bin/sluice into ~/.local/bin.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.local/bin"
ln -sf "$ROOT/bin/sluice" "$HOME/.local/bin/sluice"
echo "Linked $HOME/.local/bin/sluice -> $ROOT/bin/sluice"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) echo "~/.local/bin is on PATH — run 'sluice' from any project with a sluice.config.sh." ;;
  *) echo "Add ~/.local/bin to PATH (or: sudo ln -sf '$ROOT/bin/sluice' /usr/local/bin/sluice)." ;;
esac
