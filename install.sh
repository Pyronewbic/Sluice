#!/bin/sh
# Install the `sluice` CLI by symlinking bin/sluice onto PATH (from a checkout, or curl|sh).
# Env: SLUICE_REPO (git URL), SLUICE_HOME (clone dir, default ~/.local/share/sluice),
#      SLUICE_REF (commit/branch/tag to install; default main - the install reports the exact sha).
set -eu

REPO="${SLUICE_REPO:-https://github.com/Pyronewbic/Sluice.git}"
DEST="${SLUICE_HOME:-$HOME/.local/share/sluice}"
REF="${SLUICE_REF:-main}"
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
  [ -d "$DEST/.git" ] && echo "Updating $DEST ($REF) ..." || { echo "Cloning $REPO ($REF) -> $DEST ..."; git clone --depth 1 --quiet "$REPO" "$DEST"; }
  # Re-point origin to $REPO before fetching: an existing clone's origin is whatever the FIRST install
  # set, so re-running with a changed SLUICE_REPO would otherwise keep fetching the OLD repo.
  git -C "$DEST" remote set-url origin "$REPO"
  # Resolve REF (a commit sha, branch, or tag) and check it out detached - so the install is pinned to
  # an exact commit, not a floating branch ref. Default REF=main pins to main's current tip; re-run to
  # advance. GitHub serves arbitrary shas (allowAnySHA1InWant), so a sha pin works too.
  git -C "$DEST" fetch --depth 1 --quiet origin "$REF" \
    || { echo "sluice: could not fetch SLUICE_REF=$REF from $REPO" >&2; exit 1; }
  git -C "$DEST" checkout --quiet --force FETCH_HEAD
  src="$DEST"
fi

mkdir -p "$BIN"
ln -sf "$src/bin/sluice" "$BIN/sluice"
sha="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || true)"
echo "Linked $BIN/sluice -> $src/bin/sluice${sha:+  (sluice @ $sha, ref: $REF)}"

# Shell completion (best-effort). bash: XDG dir is auto-loaded by bash-completion. zsh: needs the
# dir on fpath, so we symlink + print the one-liner.
bashc="$HOME/.local/share/bash-completion/completions"
zshc="$HOME/.local/share/zsh/site-functions"
mkdir -p "$bashc" "$zshc"
ln -sf "$src/completion/sluice.bash" "$bashc/sluice"
ln -sf "$src/completion/_sluice" "$zshc/_sluice"
# Quote the dir as one array element so a spaced $HOME survives the paste (an unquoted $zshc would word-split).
echo "Completion: bash auto-loads; zsh needs  fpath=(\"$zshc\" \$fpath)  before compinit."

case ":$PATH:" in
  *":$BIN:"*) echo "Ready - run 'sluice init' in a project, or 'sluice agent claude'." ;;
  *) echo "Add ~/.local/bin to PATH:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.profile" ;;
esac
