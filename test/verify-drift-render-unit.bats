#!/usr/bin/env bats
# render_drift_json / render_drift_human (pure awk; no engine). Both turn classify_drift's tab-separated
# rows (op<TAB>type<TAB>name<TAB>old<TAB>new, op in add/del/chg) into output - JSON for CI, an aligned
# +/-/~ table for humans. Every OTHER unit suite stubs these two out (verify-lock-unit stubs them to
# /dev/null), so their real output had ZERO assertions anywhere. Extract each from the built launcher and
# feed crafted rows on stdin - exercising the JSON object shapes, the j() escaping guard (the regression
# value), the empty-stdin in_sync:true, and the human symbol/`->` rendering, all without Docker.
load test_helper/common

# Build a self-contained script that extracts render_drift_json and pipes a rows file into it. $1 = the
# raw tab-separated rows (may carry backslashes/doublequotes); empty string => truly empty stdin.
_run_json() {
  local t="$BATS_TEST_TMPDIR/json.sh" in="$BATS_TEST_TMPDIR/rows.txt"
  printf '%s' "$1" > "$in"
  {
    echo 'set -euo pipefail'
    sed -n '/^render_drift_json()/,/^}/p' "$ROOT/bin/sluice"
    echo 'render_drift_json < "$1"'
  } > "$t"
  run bash "$t" "$in"
}

@test "render_drift_json: add+del+chg rows -> the exact object shapes and in_sync:false" {
  _run_json "$(printf 'add\tapk\taddpkg\t\t2.0\ndel\tnpm\tdelpkg\t1.0\t\nchg\tapk\tbusybox\t1.36.1\t1.36.2')"
  assert_success
  # add pulls its version from the NEW column ($5), del from the OLD ($4), chg carries from/to ($4/$5).
  assert_output --partial '{"type":"apk","name":"addpkg","version":"2.0"}'
  assert_output --partial '{"type":"npm","name":"delpkg","version":"1.0"}'
  assert_output --partial '{"type":"apk","name":"busybox","from":"1.36.1","to":"1.36.2"}'
  # and the whole document, exactly (top-level in_sync:false + the three named arrays in order).
  assert_output '{"in_sync":false,"added":[{"type":"apk","name":"addpkg","version":"2.0"}],"removed":[{"type":"npm","name":"delpkg","version":"1.0"}],"changed":[{"type":"apk","name":"busybox","from":"1.36.1","to":"1.36.2"}]}'
}

@test "render_drift_json: j() escapes an embedded doublequote and backslash (backslash first)" {
  # add name has a bare " ; add version has a bare \ ; del name has BOTH (\ then ") in one field. j()
  # must gsub \ -> \\ BEFORE " -> \" , or the backslash it injects for the quote gets double-escaped.
  _run_json "$(printf 'add\tapk\twe"rd\t\t1\\x\ndel\tnpm\ta\\"b\tx.y\t')"
  assert_success
  assert_output --partial 'we\"rd'      # " escaped
  assert_output --partial '1\\x'        # \ escaped
  # a\"b (backslash,quote) -> a\\\"b : the \ doubled, then the " escaped - the ordering regression.
  assert_output --partial 'a\\\"b'
  assert_output --partial '{"type":"apk","name":"we\"rd","version":"1\\x"}'
  assert_output --partial '{"type":"npm","name":"a\\\"b","version":"x.y"}'
  assert_output --partial '"in_sync":false'
}

@test "render_drift_json: truly empty stdin -> in_sync:true and three empty arrays" {
  _run_json ""
  assert_success
  assert_output '{"in_sync":true,"added":[],"removed":[],"changed":[]}'
}

# Same extraction for render_drift_human, but predefine the color vars it dereferences (C_*/E_*) as
# empty so we assert on plain text (an unset var would trip the launcher's set -u).
_run_human() {
  local t="$BATS_TEST_TMPDIR/human.sh" in="$BATS_TEST_TMPDIR/rows.txt"
  printf '%s' "$1" > "$in"
  {
    echo 'set -euo pipefail'
    echo 'C_GRN=""; C_RED=""; C_YEL=""; C_RST=""; E_GRN=""; E_RED=""; E_YEL=""; E_RST=""'
    sed -n '/^render_drift_human()/,/^}/p' "$ROOT/bin/sluice"
    echo 'render_drift_human < "$1"'
  } > "$t"
  run bash "$t" "$in"
}

@test "render_drift_human: add/del/chg render as +/-/~ lines with 'old  ->  new' for a change" {
  # Equal-width type (3) and name (6) columns, so the %-*s alignment adds no padding and the assertions
  # can match the rendered text exactly. add shows the new value, del the old, chg both via '  ->  '.
  _run_human "$(printf 'add\tapk\taddpkg\t\t2.0\ndel\tnpm\tdelpkg\t1.0\t\nchg\tapk\tchgpkg\t1.0\t2.0')"
  assert_success
  assert_line --partial '+ apk addpkg 2.0'
  assert_line --partial '- npm delpkg 1.0'
  assert_line --partial '~ apk chgpkg 1.0  ->  2.0'
}
