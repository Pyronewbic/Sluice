#!/usr/bin/env bats
# write_lock fail-closed (unit; no engine). current_inventory's in-image read is masked by a `sort -u`
# pipe and consumed via a command substitution, so a failed engine read can't trip set -e - it returns
# the base ref ONLY. write_lock must refuse to overwrite ./sluice.lock with that hollow inventory (a
# base-only artifact reported as success, then --check flags every real package as drift). A real Wolfi
# box always carries apks, so write_lock asserts at least one apk line before writing, else dies.
# Extracts write_lock from the built launcher and runs it under the real set -euo pipefail (the way the
# launcher executes), with current_inventory stubbed and the lock path pointed at a temp file.
load test_helper/common

# Build a self-contained script: stubs + the extracted write_lock + an invocation, run under the
# launcher's shell options. $1 = the body of the current_inventory stub (what the image read returns).
_run_write_lock() {
  local t="$BATS_TEST_TMPDIR/write_lock.sh"
  {
    echo 'set -euo pipefail'
    printf 'PROJECT_DIR=%q\n' "$BATS_TEST_TMPDIR"
    echo 'tag="sluice-locktest:latest"'
    echo 'die() { echo "[sluice] $*" >&2; exit 1; }'
    echo '_tilde() { printf "%s" "$1"; }'
    echo 'C_GRN=""; C_RED=""; C_YEL=""; C_RST=""; E_GRN=""; E_RED=""; E_YEL=""; E_RST=""'
    echo 'maybe_build() { :; }'                                  # no engine in the unit lane
    echo 'classify_drift() { :; }; lock_drift() { :; }; render_drift_human() { :; }'   # delta path (only fires if a lock pre-exists)
    printf 'current_inventory() { cat <<%s\n' "EOF_INV"
    printf '%s\n' "$1"
    echo 'EOF_INV'
    echo '}'
    sed -n '/^write_lock()/,/^}/p' "$ROOT/bin/sluice"
    echo 'write_lock'
  } > "$t"
  run bash "$t"
}

@test "write-lock: a base-only inventory (engine read failed) refuses to write a hollow sluice.lock" {
  _run_write_lock "base  cgr.dev/chainguard/wolfi-base@sha256:deadbeef"
  assert_failure
  assert_output --partial "hollow sluice.lock"
  refute [ -f "$BATS_TEST_TMPDIR/sluice.lock" ]   # nothing written
}

@test "write-lock: a base + apk inventory writes the lock and exits 0" {
  _run_write_lock "$(printf 'base  cgr.dev/chainguard/wolfi-base@sha256:deadbeef\napk  busybox 1.36.1 Q1xxx\napk  ca-certificates-bundle 20240705 Q1yyy')"
  assert_success
  assert [ -f "$BATS_TEST_TMPDIR/sluice.lock" ]
  assert_output --partial "2 apk"
  run cat "$BATS_TEST_TMPDIR/sluice.lock"
  assert_output --partial "apk  busybox"
}

# --- classify_drift (pure awk; no engine) ----------------------------------------------------------
# classify_drift turns raw lock_drift ("< old" / "> new") lines into "<op>\t<type>\t<name>\t<old>\t<new>"
# rows. It is pure awk, so we extract it from the built launcher, stub lock_drift, and feed crafted raw
# drift via its $1 arg - exercising the keying (A7) and the apk checksum-in-value (A6) without Docker.
_run_classify() {
  local t="$BATS_TEST_TMPDIR/classify.sh"
  {
    echo 'set -euo pipefail'
    echo 'lock_drift() { :; }'   # never reached: we always pass $1
    sed -n '/^classify_drift()/,/^}/p' "$ROOT/bin/sluice"
    echo 'classify_drift "$1"'
  } > "$t"
  run bash "$t" "$1"
}

@test "classify_drift A6: an apk rebuilt at the SAME version (new checksum) renders a legible chg, not X->X" {
  # lock had busybox 1.36.1 with checksum Q1aaa; image has the same version but Q1bbb (a rebuild).
  _run_classify "$(printf '< apk  busybox 1.36.1 Q1aaa\n> apk  busybox 1.36.1 Q1bbb')"
  assert_success
  # exactly one chg row for busybox (a same-version rebuild is a change, not del+add).
  assert_line --regexp '^chg.*apk.*busybox'
  refute_output --partial "del"
  refute_output --partial "add"
  # the fix: the checksum is carried into the value, so the change is legible (both hashes present on
  # the row). The bug was a version-only value -> a bare "1.36.1 -> 1.36.1" with NEITHER checksum.
  assert_line --regexp 'busybox.*Q1aaa.*Q1bbb'
}

@test "classify_drift A7: one name at two versions yields del + add, not a single bogus chg" {
  # lodash present at 4.17.4 in the lock and 4.17.21 in the image - two distinct versions of one name.
  _run_classify "$(printf '< npm  lodash 4.17.4\n> npm  lodash 4.17.21')"
  assert_success
  assert_line --regexp '^del.*npm.*lodash.*4\.17\.4'
  assert_line --regexp '^add.*npm.*lodash.*4\.17\.21'
  refute_output --partial "chg"   # must NOT collapse the two versions into one change row
}

# --- cmd_scan A8: the temp SBOM is trapped, so a cmd_sbom failure under pipefail can't leak it --------
@test "cmd_scan A8: registers an EXIT trap so the temp SBOM is removed even when cmd_sbom fails" {
  local t="$BATS_TEST_TMPDIR/scan.sh" leak="$BATS_TEST_TMPDIR/sbom-leak.tmp"
  {
    echo 'set -euo pipefail'
    echo 'E_YEL=""; E_RST=""; E_DIM=""'
    echo 'die() { echo "[sluice] $*" >&2; exit 1; }'
    echo 'maybe_build() { :; }'
    printf 'mktemp() { printf %%s %q; }\n' "$leak"     # deterministic temp path we can assert on
    echo 'cmd_sbom() { echo junk; return 1; }'          # the SBOM build fails -> pipefail aborts before the trailing rm
    sed -n '/^cmd_scan()/,/^}/p' "$ROOT/bin/sluice"
    echo 'cmd_scan'                                     # report-only (no --fail-on); a fake grype is on PATH
  } > "$t"
  # a fake grype so cmd_scan picks scanner=grype and reaches mktemp (it won't run: cmd_sbom aborts first)
  mkdir -p "$BATS_TEST_TMPDIR/bin"; printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/grype"; chmod +x "$BATS_TEST_TMPDIR/bin/grype"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$t"
  assert_failure                                        # cmd_sbom's non-zero propagated (pipefail)
  refute [ -f "$leak" ]                                 # the EXIT trap removed the temp despite the abort
  # belt-and-suspenders: the trap is wired right after the mktemp in the assembled launcher
  run sed -n '/^cmd_scan()/,/^}/p' "$ROOT/bin/sluice"
  assert_output --partial 'trap "rm -f'
}

# --- A3: the drift verbs reject an unknown flag (no Docker; the lock-missing die is pre-empted) -------
# _drift_report forwards ALL user positionals and rejects an unknown flag with die, so a typo'd gate
# flag can't silently run a plain check. We extract it + the cmd_lock_* wrappers and stub the engine
# probes; a sluice.lock exists so the "no lock" die doesn't fire first.
@test "lock --check A3: an unknown flag (e.g. --fail-on) is rejected, not silently ignored" {
  local t="$BATS_TEST_TMPDIR/drift.sh"
  : > "$BATS_TEST_TMPDIR/sluice.lock"
  {
    echo 'set -euo pipefail'
    printf 'PROJECT_DIR=%q\n' "$BATS_TEST_TMPDIR"
    echo 'C_GRN=""; C_RED=""; E_RED=""; E_YEL=""; E_RST=""; E_DIM=""; C_RST=""'
    echo 'die() { echo "[sluice] $*" >&2; exit 1; }'
    echo 'image_missing() { return 1; }; image_stale() { return 1; }; build() { :; }'
    echo 'classify_drift() { :; }; render_drift_human() { cat >/dev/null; }; render_drift_json() { cat >/dev/null; }'
    sed -n '/^_drift_report()/,/^}/p' "$ROOT/bin/sluice"
    grep -E '^cmd_lock_(check|diff|enforce)\(\)' "$ROOT/bin/sluice"
    echo 'cmd_lock_check "$@"'
  } > "$t"
  run bash "$t" --fail-on high
  assert_failure
  assert_output --partial "usage: sluice lock"
  # and a bare --check (no flag) still succeeds (in sync) - the strict parse didn't break the happy path
  run bash "$t"
  assert_success
}
