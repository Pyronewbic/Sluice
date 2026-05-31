#!/bin/sh
# Install the global `sluice` CLI by symlinking bin/sluice onto PATH.
#
#   from a checkout:   ./install.sh
#   one-liner:         curl -fsSL https://raw.githubusercontent.com/Pyronewbic/Sluice/main/install.sh | sh
#
# Env overrides: SLUICE_REPO (git URL), SLUICE_HOME (clone dir, default ~/.local/share/sluice).
set -eu

REPO="${SLUICE_REPO:-https://github.com/Pyronewbic/Sluice.git}"
DEST="${SLUICE_HOME:-$HOME/.local/share/sluice}"
BIN="$HOME/.local/bin"

# Use the checkout we're run from if it has bin/sluice; piped via curl|sh, clone instead.
self_dir=""
case "${0:-}" in */*) self_dir="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)" || self_dir="" ;; esac
if [ -n "$self_dir" ] && [ -f "$self_dir/bin/sluice" ]; then
  src="$self_dir"
elif [ -f "./bin/sluice" ] && [ -f "./install.sh" ]; then
  src="$(pwd)"
else
  command -v git >/dev/null 2>&1 || { echo "sluice: git is required to install" >&2; exit 1; }
  if [ -d "$DEST/.git" ]; then
    echo "Updating $DEST ..."; git -C "$DEST" pull --ff-only --quiet
  else
    echo "Cloning $REPO -> $DEST ..."; git clone --depth 1 --quiet "$REPO" "$DEST"
  fi
  src="$DEST"
fi

mkdir -p "$BIN"
ln -sf "$src/bin/sluice" "$BIN/sluice"
echo "Linked $BIN/sluice -> $src/bin/sluice"

case ":$PATH:" in
  *":$BIN:"*) echo "Ready — run 'sluice init' in a project, or 'sluice agent claude'." ;;
  *) echo "Add ~/.local/bin to PATH:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.profile" ;;
esac
