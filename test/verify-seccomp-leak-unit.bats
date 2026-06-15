#!/usr/bin/env bats
# SLUICE_SECCOMP=audit must NOT leak a temp file per run. The old arm did `mktemp .../sluice-seccomp-
# audit.XXXXXX` with no reaper, so every `sluice run`/`shell` under audit dropped a /tmp file. An EXIT-
# trap reaper armed in start() would be clobbered by the receipt trap that run-default/shell arm later
# (bash EXIT traps don't stack - last wins), so the fix instead writes the profile to the stable per-box
# state dir and overwrites it IN PLACE. No-Docker unit: extracts the real `audit)` case arm from the
# built launcher, runs it twice, and asserts a single stable file (no /tmp accumulation) + ERRNO->LOG.
load test_helper/common

# Extract the audit) case arm AS SHIPPED in bin/sluice (everything between `audit)` and its `;;`),
# strip the case label/terminator + comments, stub run_args[], wire $slug/$CORE/$XDG_STATE_HOME and a
# fake seccomp.json to temp dirs, and run under the launcher's set -euo pipefail. Same harness runs
# against origin/main (mktemp) and the fix (stable path), so it is a real proven-RED guard. Echoes the
# resolved profile path on stdout. $1 = path to a launcher (defaults to the built bin/sluice).
_run_audit_arm() {
  local launcher="${1:-$ROOT/bin/sluice}" t="$BATS_TEST_TMPDIR/audit_arm.sh"
  {
    echo 'set -euo pipefail'
    printf 'XDG_STATE_HOME=%q\n' "$BATS_TEST_TMPDIR/state"
    printf 'HOME=%q\n' "$BATS_TEST_TMPDIR/home"           # backstop if a build ever drops XDG_STATE_HOME
    printf 'CORE=%q\n' "$BATS_TEST_TMPDIR/core"
    echo 'slug="leaktest"'
    echo 'run_args=()'                                     # the arm's trailing run_args+=(...) needs this
    # the body of the audit) arm, lifted from the launcher under test: drop the `audit)` label, the
    # trailing `;;`, and comment-only lines; keep the _sc assignment(s) + the sed transform verbatim.
    sed -n '/^    audit)/,/;;/p' "$launcher" \
      | sed -e 's/^    audit)//' -e 's/;;[[:space:]]*$//' \
      | grep -vE '^[[:space:]]*#'
    echo 'printf "%s\n" "$_sc"'
  } > "$t"
  run bash "$t"
}

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/core" "$BATS_TEST_TMPDIR/state" "$BATS_TEST_TMPDIR/home"
  printf '{ "defaultAction": "SCMP_ACT_ERRNO", "syscalls": [ { "names": ["userfaultfd"], "action": "SCMP_ACT_ERRNO" } ] }\n' \
    > "$BATS_TEST_TMPDIR/core/seccomp.json"
}

@test "seccomp-leak: audit writes the profile to the stable per-box state dir (not a fresh /tmp file)" {
  _run_audit_arm
  assert_success
  assert_output --partial "$BATS_TEST_TMPDIR/state/sluice/leaktest/seccomp-audit.json"
  refute_output --partial "/tmp/sluice-seccomp-audit."
  [ -f "$BATS_TEST_TMPDIR/state/sluice/leaktest/seccomp-audit.json" ]
}

@test "seccomp-leak: a second audit run overwrites in place - no temp accumulation" {
  _run_audit_arm   # run 1
  _run_audit_arm   # run 2 (same slug/state dir)
  assert_success
  # exactly one profile file under the per-box state dir; nothing piled up
  run bash -c "ls -1 '$BATS_TEST_TMPDIR/state/sluice/leaktest/' 2>/dev/null | wc -l | tr -d ' '"
  assert_output "1"
}

@test "seccomp-leak: the written profile is log-only (every ERRNO -> LOG)" {
  _run_audit_arm
  run bash -c "grep -c SCMP_ACT_ERRNO '$(ls "$BATS_TEST_TMPDIR"/state/sluice/leaktest/seccomp-audit.json)'"
  assert_output "0"
}
