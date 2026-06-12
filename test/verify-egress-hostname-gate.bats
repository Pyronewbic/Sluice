#!/usr/bin/env bats
# Hostname charset gate (unit; no engine). A raw SNI/Host the box logs is attacker-controlled. The
# egress extractors must drop anything that isn't a clean hostname BEFORE `learn` can write it into the
# (host-SOURCED) config -> command execution, or a receipt can print it to the terminal -> escape
# injection. Stubs the box-reading layer (_squid_log) with a synthetic squid log, so it runs in the
# no-Docker UNIT lane.
load test_helper/common

setup() {
  # 00-prelude.sh recomputes ROOT from $0 (-> bats libexec under test), so capture the slice dir first.
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  # shellcheck disable=SC1090
  source "$src/00-prelude.sh"
  source "$src/10-egress-helpers.sh"
  SLUICE_ALLOW_DOMAINS=""
  # Synthetic access.log: a shell-substitution SNI, a terminal-escape SNI (\033 = ESC, baked by printf
  # at call time so the byte is literal in the function), and one clean host. Two blocked, one reached.
  _squid_log() {
    printf '1.0 10.0.0.2 NONE_NONE/503 CONNECT - ssl_sni=evil$(id)".example.com tx=10 rx=0\n'
    printf '1.0 10.0.0.2 TCP_DENIED/200 CONNECT - ssl_sni=bad\033]0;pwn\033.example.org tx=5 rx=0\n'
    printf '1.0 10.0.0.2 TCP_TUNNEL/200 CONNECT - ssl_sni=good.example.net tx=99 rx=1\n'
  }
}

@test "hostname-gate: blocked_hosts drops a host carrying shell-substitution / quote bytes" {
  run blocked_hosts
  refute_output --partial '$(id)'
  refute_output --partial '"'
  refute_output --partial 'example.com'   # that host was the $(id) carrier - gone entirely
}

@test "hostname-gate: blocked_hosts drops a host carrying a terminal-escape sequence" {
  run blocked_hosts
  refute_output --partial ']0;pwn'        # the OSC payload must not survive
  [[ "$output" != *$'\033'* ]]            # and no raw ESC byte either
}

@test "hostname-gate: egress_rows keeps only the clean hostname" {
  run egress_rows
  assert_output --partial "good.example.net"
  refute_output --partial "example.com"   # the $(id) host
  refute_output --partial "example.org"   # the escape host
}

@test "hostname-gate: a clean blocked host still passes through (no over-blocking)" {
  _squid_log() { printf '1.0 10.0.0.2 TCP_DENIED/200 CONNECT - ssl_sni=api.real-host.co.uk tx=1 rx=0\n'; }
  run blocked_hosts
  assert_output "api.real-host.co.uk"
}

@test "json-esc: strips C0 control bytes (ESC/BEL) so receipts can't inject escapes" {
  run _json_esc "$(printf 'a\033[31mb\007c')"
  assert_output "a[31mbc"                  # ESC (033) and BEL (007) removed; inert text remains
}

@test "json-esc: still escapes the JSON-structural backslash and quote" {
  run _json_esc 'a\b"c'
  assert_output 'a\\b\"c'
}

@test "term-esc: flattens whitespace + strips control bytes so a crafted filename can't inject escapes" {
  run _term_esc "$(printf 'a\033[31m\tb\rc\007')"
  assert_output "a[31m b c"                 # ESC/BEL removed; tab/CR flattened to space; text inert
}

@test "term-esc: leaves backslash and quote intact (human display, not JSON)" {
  run _term_esc 'a\b"c'
  assert_output 'a\b"c'
}
