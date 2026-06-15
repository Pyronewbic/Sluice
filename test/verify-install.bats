#!/usr/bin/env bats
# install.sh smoke (no Docker, PR gate): symlink the CLI into a throwaway HOME and confirm the
# installed `sluice` resolves + runs. Ported from verify-install.sh.
load test_helper/common

setup_file() {
  export TMP; TMP="$(mktemp -d)"
  HOME="$TMP" SLUICE_HOME="$TMP/share/sluice" sh "$ROOT/install.sh" > "$TMP/install.log" 2>&1
  echo "$?" > "$TMP/install.rc"
}

teardown_file() { rm -rf "$TMP"; }

@test "install.sh ran" {
  run cat "$TMP/install.rc"
  assert_output "0"
}

@test "symlink points at the checkout's bin/sluice" {
  local link="$TMP/.local/bin/sluice"
  [ -L "$link" ] && [ "$(readlink "$link")" = "$ROOT/bin/sluice" ]
}

@test "installed 'sluice version' runs (offline)" {
  run env SLUICE_NO_UPDATE_CHECK=1 "$TMP/.local/bin/sluice" version
  assert_success
  assert_output --partial "sluice "
}

@test "installed 'sluice help' runs" {
  run "$TMP/.local/bin/sluice" help
  assert_success
}

# Build a minimal bare "sluice repo" (bin/sluice that echoes a unique marker) and clone-install from it.
# Returns nothing; populates $1=dest, $2=marker via the named repo dir. Helper for the clone-path tests.
_mk_repo() {  # _mk_repo <work> <name>  -> creates <work>/<name>.git whose bin/sluice prints MARKER-<name>
  local w="$1" name="$2"
  mkdir -p "$w/src-$name/bin"
  printf '#!/bin/sh\necho "MARKER-%s"\n' "$name" > "$w/src-$name/bin/sluice"; chmod +x "$w/src-$name/bin/sluice"
  ( cd "$w/src-$name" && git init -q -b main && git config user.email t@t && git config user.name t \
      && git add -A && git commit -qm "$name" )
  git clone -q --bare "$w/src-$name" "$w/$name.git"
}

# PR6 #4a: re-running the clone-install with a CHANGED SLUICE_REPO must re-point origin and fetch the
# NEW repo. Old install.sh fetched from whatever the first clone set as origin (SLUICE_REPO ignored on
# update), so it kept serving the OLD repo - this @test is RED against pre-change install.sh.
@test "install.sh re-points origin when SLUICE_REPO changes on re-run" {
  command -v git >/dev/null 2>&1 || skip "git not present"
  local w; w="$(mktemp -d)"
  _mk_repo "$w" repoA
  _mk_repo "$w" repoB
  local dest="$w/home/.local/share/sluice"
  # Pipe install.sh via stdin AND run from a dir with no ./bin/sluice, so the CLONE branch runs (not the
  # local-checkout branch that fires when $0's dir or $PWD already holds a bin/sluice - e.g. the repo root).
  ( cd "$w" && HOME="$w/home" SLUICE_REPO="$w/repoA.git" SLUICE_HOME="$dest" sh < "$ROOT/install.sh" ) >/dev/null 2>&1
  run git -C "$dest" remote get-url origin
  assert_output "$w/repoA.git"
  run "$dest/bin/sluice"; assert_output "MARKER-repoA"
  ( cd "$w" && HOME="$w/home" SLUICE_REPO="$w/repoB.git" SLUICE_HOME="$dest" sh < "$ROOT/install.sh" ) >/dev/null 2>&1
  run git -C "$dest" remote get-url origin
  assert_output "$w/repoB.git"                 # origin re-pointed (old: still repoA.git)
  run "$dest/bin/sluice"; assert_output "MARKER-repoB"   # and the new repo's content landed
  rm -rf "$w"
}

# PR6 #4b: the printed zsh-completion one-liner must quote the site-functions dir as a single array
# element, so a $HOME with a space survives the paste. Old printed it raw ($zshc), which word-splits.
@test "install.sh prints a quoted fpath dir (survives a spaced HOME)" {
  local w; w="$(mktemp -d)"
  local home="$w/a b"   # a HOME with a space - the regression trigger
  mkdir -p "$home"
  HOME="$home" SLUICE_HOME="$home/.local/share/sluice" sh "$ROOT/install.sh" > "$w/log" 2>&1
  run cat "$w/log"
  # The dir lands inside double quotes as ONE word: ...site-functions" ... (not a bare spaced path).
  assert_output --partial "fpath=(\"$home/.local/share/zsh/site-functions\" \$fpath)"
  rm -rf "$w"
}
