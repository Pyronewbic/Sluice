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
