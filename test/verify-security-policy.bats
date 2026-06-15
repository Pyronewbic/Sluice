#!/usr/bin/env bats
# Central egress policy v2 (engine). A policy (here via a file:// URL) ADDS hosts (allow), NARROWS the
# live box allowlist (deny), and REFUSES to run on a violated ceiling (forbid knob / deny-ip /
# max-allow-ips / forbid-laundering) or an unfetchable required policy. The box test proves allow/deny
# reach the real /etc/squid/allowlist.txt; the die tests refuse before any build.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"
  printf 'allow added.example.com\ndeny drop.example.com\n' > "$WORK/policy.conf"
  mkdir -p "$WORK/box"
  printf 'SLUICE_NAME="sectest-policy"\nSLUICE_ALLOW_DOMAINS="keep.example.com drop.example.com"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/box/sluice.config.sh"
  ( cd "$WORK/box" && SLUICE_POLICY_URL="file://$WORK/policy.conf" "$SLUICE" run true ) >/dev/null 2>&1 || true
}
teardown_file() { destroy_box policy box; }

# Run `sluice build` with a throwaway policy+config; echo output, return sluice's status. Violations
# die in apply_policy before any image is built, so these are fast.
_polrun() {
  local d; d="$(mktemp -d)"
  printf '%b' "$1" > "$d/p.conf"; mkdir -p "$d/b"; printf '%b' "$2" > "$d/b/sluice.config.sh"
  local out rc; out="$( cd "$d/b" && SLUICE_POLICY_URL="file://$d/p.conf" "$SLUICE" build 2>&1 )"; rc=$?
  rm -rf "$d"; printf '%s\n' "$out"; return $rc
}

@test "policy: box image built" { run "$ENG" image inspect sluice-sectest-policy; assert_success; }

@test "policy: allow adds a host to the effective box allowlist" {
  run "$ENG" exec sluice-sectest-policy grep -qx added.example.com /etc/squid/allowlist.txt
  assert_success
}
@test "policy: deny removes a config host from the effective box allowlist" {
  run "$ENG" exec sluice-sectest-policy grep -qx drop.example.com /etc/squid/allowlist.txt
  assert_failure
}
@test "policy: a non-denied config host still reaches the box" {
  run "$ENG" exec sluice-sectest-policy grep -qx keep.example.com /etc/squid/allowlist.txt
  assert_success
}

@test "policy: forbid <knob> refuses a config that sets the knob" {
  run _polrun 'forbid SLUICE_DNS_OPEN\n' 'SLUICE_DNS_OPEN=1\nSLUICE_RUN_CMD="true"\n'
  assert_failure
  assert_output --partial "policy forbids"
}
@test "policy: deny-ip refuses a matching SLUICE_ALLOW_IPS entry" {
  run _polrun 'deny-ip 10.0.0.0/8\n' 'SLUICE_ALLOW_IPS="10.0.0.5:5432"\nSLUICE_RUN_CMD="true"\n'
  assert_failure
  assert_output --partial "deny-ip"
}
@test "policy: max-allow-ips caps the count" {
  run _polrun 'max-allow-ips 1\n' 'SLUICE_ALLOW_IPS="10.0.0.5:5432 10.0.0.6:6379"\nSLUICE_RUN_CMD="true"\n'
  assert_failure
  assert_output --partial "caps SLUICE_ALLOW_IPS"
}
@test "policy: forbid-laundering refuses a laundering-capable allowlisted host" {
  run _polrun 'forbid-laundering\n' 'SLUICE_ALLOW_DOMAINS="gist.github.com"\nSLUICE_RUN_CMD="true"\n'
  assert_failure
  assert_output --partial "laundering"
}
@test "policy: an unfetchable configured policy URL fails closed" {
  local d; d="$(mktemp -d)"; mkdir -p "$d/b"
  printf 'SLUICE_RUN_CMD="true"\n' > "$d/b/sluice.config.sh"
  run bash -c "cd '$d/b' && SLUICE_POLICY_URL='file://$d/nope.conf' '$SLUICE' build 2>&1"
  rm -rf "$d"
  assert_failure
  assert_output --partial "could not be fetched"
}

# --- v2.1 signing -----------------------------------------------------------------------------

# `sluice build` with a file:// policy + signing env ($2 = literal KEY=val assignments, no shell
# expansion). Verification runs before any build, so the die paths are fast.
_polsign() {
  local d; d="$(mktemp -d)"; mkdir -p "$d/b"
  printf '%b' "$1" > "$d/p.conf"
  printf 'SLUICE_RUN_CMD="true"\n' > "$d/b/sluice.config.sh"
  local out rc; out="$( cd "$d/b" && env $2 SLUICE_POLICY_URL="file://$d/p.conf" "$SLUICE" build 2>&1 )"; rc=$?
  rm -rf "$d"; printf '%s\n' "$out"; return $rc
}

@test "policy-sig: a sha256 pin mismatch refuses" {
  run _polsign 'allow ok.example.com\n' 'SLUICE_POLICY_SHA256=deadbeef'
  assert_failure
  assert_output --partial "sha256"
}
@test "policy-sig: SLUICE_POLICY_REQUIRE=1 with no signature/pin refuses" {
  run _polsign 'allow ok.example.com\n' 'SLUICE_POLICY_REQUIRE=1'
  assert_failure
  assert_output --partial "unverifiable"
}
@test "policy-sig: strict-unknown turns a typo'd directive into a refusal" {
  run _polsign 'allow ok.example.com\nfrobnicate x\nstrict-unknown\n' ''
  assert_failure
  assert_output --partial "unknown directive"
}
@test "policy-sig: a failed cosign signature check refuses" {
  local d; d="$(mktemp -d)"; mkdir -p "$d/b" "$d/bin"
  printf 'allow ok.example.com\n' > "$d/p.conf"; printf '{}' > "$d/sig.bundle"
  printf '#!/bin/sh\nexit 1\n' > "$d/bin/cosign"; chmod +x "$d/bin/cosign"   # stub: verification fails
  printf 'SLUICE_RUN_CMD="true"\n' > "$d/b/sluice.config.sh"
  run bash -c "cd '$d/b' && PATH='$d/bin:$PATH' SLUICE_POLICY_URL='file://$d/p.conf' SLUICE_POLICY_SIG='$d/sig.bundle' SLUICE_POLICY_IDENTITY='^https://x' '$SLUICE' build 2>&1"
  rm -rf "$d"
  assert_failure
  assert_output --partial "signature verification failed"
}

# The refusal tests above only prove the die paths. These prove the ACCEPT path runs - a matching pin
# or a passing signature lets apply_policy proceed (it prints "managed egress policy"). A stub docker
# exits the build right after, so we never do a real build but we've passed the signature gate.
@test "policy-sig: a MATCHING sha256 pin is accepted (proceeds past the signature gate)" {
  local d; d="$(mktemp -d)"; mkdir -p "$d/b" "$d/bin"
  printf 'allow ok.example.com\n' > "$d/p.conf"
  printf '#!/bin/sh\nexit 1\n' > "$d/bin/docker"; chmod +x "$d/bin/docker"   # build fails fast, AFTER the gate
  printf 'SLUICE_RUN_CMD="true"\n' > "$d/b/sluice.config.sh"
  # hash the body the way _verify_policy_sig sees it: command-substitution strips the trailing newline,
  # so printf '%s' "$(curl ...)" (no trailing NL) to match - piping curl raw would hash one byte more.
  local sha; sha="$(printf '%s' "$(curl -fsSL "file://$d/p.conf")" | shasum -a 256 | awk '{print $1}')"
  run bash -c "cd '$d/b' && PATH='$d/bin:$PATH' SLUICE_ENGINE=docker SLUICE_POLICY_URL='file://$d/p.conf' SLUICE_POLICY_SHA256='$sha' '$SLUICE' build 2>&1"
  rm -rf "$d"
  assert_output --partial "managed egress policy"   # apply_policy ran past _verify_policy_sig
  refute_output --partial "sha256"                   # not the mismatch-refusal
}

@test "policy-sig: a passing cosign signature is accepted and threads SLUICE_POLICY_IDENTITY/_ISSUER" {
  local d; d="$(mktemp -d)"; mkdir -p "$d/b" "$d/bin"
  printf 'allow ok.example.com\n' > "$d/p.conf"; printf '{}' > "$d/sig.bundle"
  printf '#!/bin/sh\necho "$@" >> "%s/cosign-args"\nexit 0\n' "$d" > "$d/bin/cosign"; chmod +x "$d/bin/cosign"
  printf '#!/bin/sh\nexit 1\n' > "$d/bin/docker"; chmod +x "$d/bin/docker"
  printf 'SLUICE_RUN_CMD="true"\n' > "$d/b/sluice.config.sh"
  run bash -c "cd '$d/b' && PATH='$d/bin:$PATH' SLUICE_ENGINE=docker SLUICE_POLICY_URL='file://$d/p.conf' SLUICE_POLICY_SIG='$d/sig.bundle' SLUICE_POLICY_IDENTITY='^https://acme/' SLUICE_POLICY_ISSUER='https://issuer.example' '$SLUICE' build 2>&1"
  local args; args="$(cat "$d/cosign-args" 2>/dev/null)"
  rm -rf "$d"
  assert_output --partial "managed egress policy"            # signature accepted, policy applied
  refute_output --partial "signature verification failed"
  [[ "$args" == *"--certificate-identity-regexp ^https://acme/"* ]]
  [[ "$args" == *"--certificate-oidc-issuer https://issuer.example"* ]]
}

# --- doctor report-only (doctor-A1) -----------------------------------------------------------
# `sluice doctor` evaluates the policy REPORT-ONLY: it must show what run/build WOULD refuse + the
# effective (post-deny) allowlist, while never dying itself. The run-path die tests above prove the
# refusal still aborts a build; these prove doctor SURFACES the same verdict without aborting - the
# gap doctor-A1 closed (doctor used to green-light a config the run path dies on).
@test "policy: doctor surfaces 'policy would refuse' + the effective allowlist, never dies" {
  local d; d="$(mktemp -d)"; mkdir -p "$d/b"
  printf 'SLUICE_RUN_CMD="true"\nSLUICE_ALLOW_DOMAINS="keep.example.com drop.example.com gist.github.com"\n' > "$d/b/sluice.config.sh"
  printf 'allow added.example.com\ndeny drop.example.com\nforbid-laundering\n' > "$d/p.conf"
  run bash -c "cd '$d/b' && SLUICE_POLICY_URL='file://$d/p.conf' NO_COLOR=1 '$SLUICE' doctor"
  rm -rf "$d"
  assert_success                                             # doctor stays non-dying (exit 0)
  assert_output --partial "policy would refuse:"
  assert_output --partial "laundering-capable allowlisted host(s): gist.github.com"
  assert_output --partial "added.example.com"               # policy-added host shows on the effective list
  assert_output --partial "effective, post-policy"
}

@test "policy: doctor --json carries policy.effective_allowlist + policy.refusals[]" {
  local d; d="$(mktemp -d)"; mkdir -p "$d/b"
  printf 'SLUICE_RUN_CMD="true"\nSLUICE_ALLOW_DOMAINS="keep.example.com drop.example.com"\n' > "$d/b/sluice.config.sh"
  printf 'allow added.example.com\ndeny drop.example.com\nforbid-laundering\n' > "$d/p.conf"
  run bash -c "cd '$d/b' && SLUICE_POLICY_URL='file://$d/p.conf' '$SLUICE' doctor --json"
  rm -rf "$d"
  assert_success
  assert_output --partial '"policy":{'
  assert_output --partial '"effective_allowlist":["added.example.com","keep.example.com"]'
  assert_output --partial '"refusals":['
  assert_output --partial '"reachable":true'
}

@test "policy: doctor completes on an unreachable policy URL (surfaces 'unreachable', exit 0)" {
  local d; d="$(mktemp -d)"; mkdir -p "$d/b"
  printf 'SLUICE_RUN_CMD="true"\nSLUICE_ALLOW_DOMAINS="keep.example.com"\n' > "$d/b/sluice.config.sh"
  run bash -c "cd '$d/b' && SLUICE_POLICY_URL='file://$d/nope.conf' NO_COLOR=1 '$SLUICE' doctor"
  rm -rf "$d"
  assert_success
  assert_output --partial "unreachable"
}
