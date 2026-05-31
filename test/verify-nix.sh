#!/usr/bin/env bash
# Verify the Nix example (examples/nix.config.sh): Nix composed inside a sluice. Builds the example
# - which installs single-user Nix and bakes a pinned tool, ~1.5GB - then checks the baked tool
# runs, the box is non-root, Nix itself works offline against the baked store, and runtime egress is
# still locked. Heavy (downloads Nix + the closure) - runs nightly/manual, not the PR gate.
#
#   ./test/verify-nix.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUICE="$ROOT/bin/sluice"
ENG="${SLUICE_ENGINE:-docker}"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf '    ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '    FAIL  %s\n' "$1"; }

echo "== sluice nix example verification (build-time Nix, contained at runtime) =="
work="$(mktemp -d)/nix"; mkdir -p "$work"
cp "$ROOT/examples/nix.config.sh" "$work/sluice.config.sh"
container="sluice-nix"

echo "-- building (installs Nix + bakes the pinned tool; this is the slow part) --"
if ! ( cd "$work" && "$SLUICE" build ) >"/tmp/verify-nix-build.log" 2>&1; then
  bad "build failed (see /tmp/verify-nix-build.log)"; tail -25 /tmp/verify-nix-build.log
  rm -rf "$(dirname "$work")"; echo "== $PASS passed, $FAIL failed =="; exit 1
fi
ok "example image built (Nix installed + tool baked)"

# 1. The baked tool runs - mirrors the example's SLUICE_RUN_CMD (profile bin on PATH, run the tool).
out="$( cd "$work" && "$SLUICE" run sh -lc 'export PATH="$HOME/.nix-profile/bin:$PATH"; hello' 2>/dev/null )"
case "$out" in
  *"Hello, world!"*) ok "baked tool runs (no runtime egress): $out" ;;
  *)                 bad "baked tool did not run (got: ${out:-<empty>})" ;;
esac

# 2. Non-root (uid 1000).
uid="$( cd "$work" && "$SLUICE" run id -u 2>/dev/null | tr -d '\r\n' )"
[ "$uid" = 1000 ] && ok "non-root (uid 1000)" || bad "expected uid 1000, got '${uid:-<empty>}'"

# 3. Nix itself is functional in the box (offline, against the baked store).
nv="$( cd "$work" && "$SLUICE" run sh -lc '"$HOME/.nix-profile/bin/nix" --version' 2>/dev/null )"
case "$nv" in
  *[Nn]ix*) ok "nix works in the box: $nv" ;;
  *)        bad "nix not functional in the box (got: ${nv:-<empty>})" ;;
esac

# 4. Runtime egress is still locked - a non-allowlisted host must be blocked.
if ( cd "$work" && "$SLUICE" run sh -lc 'curl -sS -o /dev/null --max-time 8 https://example.com' ) >/dev/null 2>&1; then
  bad "deny example.com NOT blocked - runtime egress is not locked!"
else
  ok "runtime egress locked (example.com blocked)"
fi

# Teardown: chown the mount back so the host can clean up (see verify-agents.sh).
"$ENG" exec --user root "$container" chown -R "$(id -u):$(id -g)" "$work" >/dev/null 2>&1 || true
( cd "$work" && "$SLUICE" stop ) >/dev/null 2>&1
rm -rf "$(dirname "$work")" 2>/dev/null || true

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
