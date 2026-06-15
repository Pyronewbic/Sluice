#!/usr/bin/env bats
# set -f discipline (B1/B3): the launcher (start()/build()) and the in-container entrypoint word-split
# unquoted config strings - `for p in ${SLUICE_PORTS:-}`, `for d in ${SLUICE_ALLOW_DOMAINS:-}`, etc. With
# glob ON (the launcher runs under bash 3.2 + glob; the entrypoint under ash + glob, CWD=/), a glob
# metachar (* ? [) in those vars pathname-expands against CWD before the loop body. The fix wraps the
# launcher loops in set -f/set +f and turns set -f on once in the entrypoint after the config source.
# No-Docker unit: extract a representative loop AS SHIPPED, run it in a CWD seeded with glob-matching
# files, and assert the value stays literal. Same harness runs against origin/main -> proven RED.
load test_helper/common

# Seed a scratch CWD with files a bare `*` would expand to.
setup() { cd "$BATS_TEST_TMPDIR"; : > 8080; : > 9090; : > evil.txt; : > 'a*b'; }

@test "setf-noglob: launcher SLUICE_PORTS='*' is NOT expanded against CWD (B1)" {
  local t="$BATS_TEST_TMPDIR/ports.sh"
  {
    echo 'set -euo pipefail'
    echo 'SLUICE_PORTS="*"; run_args=()'
    # the ports loop WITH the line above + below it, lifted from the built launcher: on the fix that
    # captures the `set -f`/`set +f` guard; on origin/main it captures the bare loop (which globs) - so
    # this is a real proven-RED guard, not a tautology.
    grep -B1 -A3 'for p in ${SLUICE_PORTS' "$ROOT/bin/sluice" \
      | grep -E 'set -f|set \+f|for p in|run_args|done'
    echo 'set +f'   # backstop so the harness shell is left glob-on regardless (the loop already ran)
    echo 'printf "%s\n" "${run_args[@]}"'
  } > "$t"
  run bash "$t"
  assert_success
  # literal star survives; no filename leaked in
  assert_output --partial "127.0.0.1:*:*"
  refute_output --partial "127.0.0.1:8080:8080"
  refute_output --partial "evil.txt"
}

@test "setf-noglob: launcher wraps the ports loop in set -f (structural)" {
  # set -f appears on the line immediately preceding `for p in ${SLUICE_PORTS`
  run bash -c "grep -B1 'for p in \${SLUICE_PORTS' '$ROOT/bin/sluice' | head -1"
  assert_output --partial "set -f"
}

@test "setf-noglob: entrypoint SLUICE_ALLOW_DOMAINS='*' is NOT expanded against CWD (B3)" {
  local t="$BATS_TEST_TMPDIR/allow.sh"
  {
    echo 'set -e'
    echo 'SLUICE_ALLOW_DOMAINS="*"'
    # Lift the entrypoint's OWN protection: every `set -f` line plus the allowlist loop, in file order.
    # On the fix that prefixes the loop with set -f (literal *); on origin/main no set -f exists, so the
    # loop runs glob-on and expands - a real proven-RED guard, not a tautology. The loop is reduced to
    # printing $d (drop the surrounding allowlist redirect, which needs /etc/squid paths).
    grep -nE '^set -f$|for d in \$\{SLUICE_ALLOW_DOMAINS' "$ROOT/core/entrypoint.sh" \
      | sort -t: -n -k1 | cut -d: -f2- \
      | sed -E 's/.*for d in (\$\{SLUICE_ALLOW_DOMAINS[^}]*\}).*/for d in \1; do printf "%s\\n" "$d"; done/'
  } > "$t"
  run bash "$t"
  assert_success
  assert_output "*"            # literal star, not the seeded filenames
  refute_output --partial "evil.txt"
}

@test "setf-noglob: entrypoint turns set -f on before the first config-driven loop (structural)" {
  # the line number of `set -f` must precede the first `for d in ${SLUICE_ALLOW_DOMAINS` loop
  local setf_ln allow_ln
  setf_ln="$(grep -n '^set -f$' "$ROOT/core/entrypoint.sh" | head -1 | cut -d: -f1)"
  allow_ln="$(grep -n 'for d in \${SLUICE_ALLOW_DOMAINS' "$ROOT/core/entrypoint.sh" | head -1 | cut -d: -f1)"
  [ -n "$setf_ln" ]
  [ -n "$allow_ln" ]
  [ "$setf_ln" -lt "$allow_ln" ]
}
