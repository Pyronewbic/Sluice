#!/usr/bin/env bash
# Verify install.sh: symlink the CLI into a throwaway HOME and confirm the installed `sluice`
# resolves + runs. Fast - no image build, no Docker (PR gate).
#   ./test/verify-install.sh
set -u

. "$(dirname "$0")/lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "== install.sh smoke =="

# Install into a throwaway HOME so the real ~/.local/bin is untouched.
if HOME="$tmp" SLUICE_HOME="$tmp/share/sluice" sh "$ROOT/install.sh" >"$tmp/install.log" 2>&1; then
  ok "install.sh ran"
else
  bad "install.sh failed"; cat "$tmp/install.log"
fi

link="$tmp/.local/bin/sluice"
if [ -L "$link" ] && [ "$(readlink "$link")" = "$ROOT/bin/sluice" ]; then
  ok "symlink points at the checkout's bin/sluice"
else
  bad "symlink missing/wrong (got '$(readlink "$link" 2>/dev/null)')"
fi

# The installed CLI runs. SLUICE_NO_UPDATE_CHECK=1 keeps `version` offline + non-flaky.
if v="$(SLUICE_NO_UPDATE_CHECK=1 "$link" version 2>/dev/null)" && printf '%s' "$v" | grep -q '^sluice '; then
  ok "installed 'sluice version' runs ($(printf '%s' "$v" | head -1))"
else
  bad "installed 'sluice version' failed (got: ${v:-<empty>})"
fi
"$link" help >/dev/null 2>&1 && ok "installed 'sluice help' runs" || bad "installed 'sluice help' failed"

finish
