#!/usr/bin/env bash
# Verify `sluice ls` on real built images: both boxes listed with name + description + path, status
# reflects running vs built, and the box matching $PWD is marked '*'. Heavy (builds 2 images) -
# manual, not the PR gate.
#
#   ./test/verify-ls.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUICE="$ROOT/bin/sluice"
ENG="${SLUICE_ENGINE:-docker}"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

base="$(mktemp -d)"
mkdir -p "$base/a" "$base/b"
cat > "$base/a/sluice.config.sh" <<'CFG'
SLUICE_NAME="lstest-a"
SLUICE_DESC="alpha box for ls test"
SLUICE_RUN_CMD=true
CFG
cat > "$base/b/sluice.config.sh" <<'CFG'
SLUICE_NAME="lstest-b"
SLUICE_DESC="beta box for ls test"
SLUICE_RUN_CMD=true
CFG
export SLUICE_NO_BANNER=1

echo "== sluice ls =="
if ! ( cd "$base/a" && "$SLUICE" build ) >/tmp/verify-ls-a.log 2>&1 \
   || ! ( cd "$base/b" && "$SLUICE" build ) >/tmp/verify-ls-b.log 2>&1; then
  bad "build"; tail -20 /tmp/verify-ls-a.log /tmp/verify-ls-b.log; rm -rf "$base"
  echo "== $PASS passed, $FAIL failed =="; exit 1
fi
ok "build (both boxes)"

# Start box A only (leaves it running); B stays merely built.
( cd "$base/a" && "$SLUICE" run true ) >/dev/null 2>&1 || true

out="$( "$SLUICE" ls 2>/dev/null )"

# 1. Both boxes listed.
{ printf '%s' "$out" | grep -q 'sluice-lstest-a' && printf '%s' "$out" | grep -q 'sluice-lstest-b'; } \
  && ok "lists both boxes" || bad "a box is missing from ls (got: $out)"

# 2. Descriptions shown (proves the new sluice.desc label is baked + read).
{ printf '%s' "$out" | grep -q 'alpha box' && printf '%s' "$out" | grep -q 'beta box'; } \
  && ok "shows each box's description" || bad "a description is missing"

# 3. Status: A running, B built.
printf '%s' "$out" | grep 'sluice-lstest-a' | grep -q 'running' \
  && ok "started box reads 'running'" || bad "box A not 'running'"
printf '%s' "$out" | grep 'sluice-lstest-b' | grep -q 'built' \
  && ok "unstarted box reads 'built'" || bad "box B not 'built'"

# 4. Path label: box A's row shows its project dir.
printf '%s' "$out" | grep 'sluice-lstest-a' | grep -qF "$base/a" \
  && ok "box A row shows its project path" || bad "box A path label missing"

# 5. Current-box marker: from inside A, A's row starts with '*' and B's does not.
out_a="$( cd "$base/a" && "$SLUICE" ls 2>/dev/null )"
printf '%s' "$out_a" | grep 'sluice-lstest-a' | grep -q '^\*' \
  && ok "current box (A) marked '*' from inside its dir" || bad "current-box marker missing on A"
printf '%s' "$out_a" | grep 'sluice-lstest-b' | grep -q '^\* ' \
  && bad "non-current box (B) wrongly marked '*'" || ok "non-current box (B) unmarked"

# Teardown: chown the started mount back so the host can clean up; stop + remove both images.
"$ENG" exec --user root sluice-lstest-a chown -R "$(id -u):$(id -g)" "$base/a" >/dev/null 2>&1 || true
"$ENG" rm -f sluice-lstest-a sluice-lstest-b >/dev/null 2>&1 || true
"$ENG" rmi -f sluice-lstest-a sluice-lstest-b >/dev/null 2>&1 || true
rm -rf "$base" 2>/dev/null || true

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
