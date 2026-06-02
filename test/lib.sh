#!/usr/bin/env bash
# Shared harness for the sluice test suites - removes the boilerplate every suite used to copy.
# Source it right after `set -u`:   . "$(dirname "$0")/lib.sh"
# Provides: ROOT / SLUICE / ENG, the PASS/FAIL/SKIP counters + ok/bad/note/skip, finish (summary +
# exit status), teardown_box (chown the mount back, stop, drop the image), and assert_egress_*.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUICE="$ROOT/bin/sluice"
ENG="${SLUICE_ENGINE:-docker}"
PASS=0 FAIL=0 SKIP=0
export SLUICE_NO_BANNER=1

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
note() { printf '  note %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s\n' "$1"; }

# Print the summary and set the exit status (non-zero on any FAIL). Use as the suite's last line.
finish() {
  if [ "$SKIP" -gt 0 ]; then echo "== $PASS passed, $FAIL failed, $SKIP skipped =="
  else                       echo "== $PASS passed, $FAIL failed =="; fi
  [ "$FAIL" -eq 0 ]
}

# host_own <container> <dir>: chown a mount back to the host uid (the entrypoint chowned it to 1000
# at run), so a host-side rewrite of files under it - e.g. `learn --apply` editing sluice.config.sh -
# succeeds on Linux (where the runner uid != 1000). The container must be running.
host_own() { "$ENG" exec --user root "$1" chown -R "$(id -u):$(id -g)" "$2" >/dev/null 2>&1 || true; }

# teardown_box <container> <workdir>: chown the mount back so the host can rm it, stop the container,
# then drop its image. The caller removes its own temp dir (suites differ on $work vs its parent).
teardown_box() {
  host_own "$1" "$2"
  ( cd "$2" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rmi -f "$1" >/dev/null 2>&1 || true
}

# assert_egress_allow <box-dir> <url> <label>: curl from inside the box; pass if the host is reached
# (4xx still counts - it got through), with a retry for transient CI/CDN flake.
assert_egress_allow() {
  local d="$1" url="$2" label="$3" n=1
  until ( cd "$d" && "$SLUICE" run curl -sS --max-time 15 -o /dev/null "$url" ) >/dev/null 2>&1; do
    [ "$n" -ge 3 ] && { bad "$label"; return; }; n=$((n+1)); sleep 2
  done
  ok "$label"
}
# assert_egress_deny <box-dir> <url> <label>: pass when the firewall blocks it (curl -f fails).
assert_egress_deny() {
  local d="$1" url="$2" label="$3"
  if ( cd "$d" && "$SLUICE" run curl -fsS --max-time 8 -o /dev/null "$url" ) >/dev/null 2>&1; then
    bad "$label (was reachable!)"
  else ok "$label"; fi
}
