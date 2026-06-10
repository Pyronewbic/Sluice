#!/usr/bin/env bats
# SLUICE_OVERLAY_DIRS: an overlaid dir is a box-local named volume - the host's contents are
# invisible in-box and untouched by in-box writes, the volume persists across container recreation,
# is owned by the sluice user, surfaces in ls --json, and is removed by `sluice rm`.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/ovl/node_modules"
  echo host-built > "$WORK/ovl/node_modules/host-marker.txt"
  cat > "$WORK/ovl/sluice.config.sh" <<CFG
SLUICE_NAME="sectest-ovl"
SLUICE_OVERLAY_DIRS="node_modules"
SLUICE_RUN_CMD="bash"
CFG
  ( cd "$WORK/ovl" && "$SLUICE" run true ) >/dev/null 2>&1 || true
}

teardown_file() {
  chown_back_tree sluice-sectest-ovl "$WORK"
  ( cd "$WORK/ovl" 2>/dev/null && "$SLUICE" rm ) >/dev/null 2>&1 || true
  "$ENG" rm -f -v sluice-sectest-ovl >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-sectest-ovl >/dev/null 2>&1 || true
  "$ENG" volume ls -q --filter label=sluice.box=sluice-sectest-ovl 2>/dev/null \
    | xargs -r "$ENG" volume rm -f >/dev/null 2>&1 || true
  rm -rf "$WORK"
}

@test "overlay: the host's dir contents are not visible in the box" {
  run bash -c "cd '$WORK/ovl' && '$SLUICE' run sh -c 'test -e node_modules/host-marker.txt && echo visible || echo hidden' 2>/dev/null"
  assert_output "hidden"
}

@test "overlay: the box can write its own contents (volume owned by the sluice user)" {
  run bash -c "cd '$WORK/ovl' && '$SLUICE' run sh -c 'echo box-built > node_modules/box-marker.txt && cat node_modules/box-marker.txt' 2>/dev/null"
  assert_output "box-built"
}

@test "overlay: in-box writes never reach the host dir" {
  [ ! -e "$WORK/ovl/node_modules/box-marker.txt" ]
}

@test "overlay: the host's own contents are untouched" {
  run cat "$WORK/ovl/node_modules/host-marker.txt"
  assert_output "host-built"
}

@test "overlay: the volume persists across container recreation" {
  ( cd "$WORK/ovl" && "$SLUICE" stop ) >/dev/null 2>&1 || true
  run bash -c "cd '$WORK/ovl' && '$SLUICE' run cat node_modules/box-marker.txt 2>/dev/null"
  assert_output "box-built"
}

@test "overlay: the volume is labeled for this box" {
  run bash -c "'$ENG' volume ls -q --filter label=sluice.box=sluice-sectest-ovl"
  assert_output --partial "sluice-sectest-ovl-ov-node-modules"
}

@test "overlay: ls --json surfaces overlay_dirs" {
  run bash -c "cd '$WORK/ovl' && '$SLUICE' ls --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
boxes = {b['name']: b for b in json.load(sys.stdin)}
assert boxes['sluice-sectest-ovl']['overlay_dirs'] == ['node_modules'], boxes['sluice-sectest-ovl']
"
}

@test "overlay: launch output names the overlaid dirs" {
  ( cd "$WORK/ovl" && "$SLUICE" stop ) >/dev/null 2>&1 || true
  run bash -c "cd '$WORK/ovl' && '$SLUICE' run true 2>&1"
  assert_output --partial "overlay dirs"
  assert_output --partial "node_modules"
}

@test "overlay: sluice rm removes the volume" {
  ( cd "$WORK/ovl" && "$SLUICE" rm ) >/dev/null 2>&1 || true
  run bash -c "'$ENG' volume ls -q --filter label=sluice.box=sluice-sectest-ovl"
  assert_output ""
}

@test "overlay: a '..' entry is rejected (die)" {
  mkdir -p "$WORK/ovl-bad"
  printf 'SLUICE_NAME="sectest-ovl-bad"\nSLUICE_OVERLAY_DIRS="../escape"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/ovl-bad/sluice.config.sh"
  run bash -c "cd '$WORK/ovl-bad' && '$SLUICE' run true"
  assert_failure
  assert_output --partial "SLUICE_OVERLAY_DIRS"
  "$ENG" rm -f -v sluice-sectest-ovl-bad >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-sectest-ovl-bad >/dev/null 2>&1 || true
}
