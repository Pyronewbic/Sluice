#!/usr/bin/env bats
# Central-policy pure helpers (unit; no engine). CIDR membership for deny-ip and the deny-host
# wildcard matcher are extracted from the built launcher and exercised in isolation - they decide
# what an org policy refuses, so they get direct coverage.
load test_helper/common

setup() {
  # Pull just the pure function defs out of bin/sluice (don't source it - that runs the whole CLI).
  eval "$(sed -n '/^_ip2int()/,/^}/p; /^_ip_in_cidr()/,/^}/p; /^_policy_denied_host()/,/^}/p; /^_allow_covers_denied()/,/^}/p' "$ROOT/bin/sluice")"
}

@test "cidr: an IP inside a /8 matches" { run _ip_in_cidr 10.0.0.5 10.0.0.0/8; assert_success; }
@test "cidr: an IP outside a /8 does not match" { run _ip_in_cidr 11.0.0.5 10.0.0.0/8; assert_failure; }
@test "cidr: a /24 boundary is respected" {
  run _ip_in_cidr 192.168.1.9 192.168.1.0/24; assert_success
  run _ip_in_cidr 192.168.2.9 192.168.1.0/24; assert_failure
}
@test "cidr: a bare IP matches only itself" {
  run _ip_in_cidr 1.2.3.4 1.2.3.4; assert_success
  run _ip_in_cidr 1.2.3.5 1.2.3.4; assert_failure
}

@test "deny-host: an exact host is denied" { run _policy_denied_host pastebin.com "pastebin.com gist.github.com"; assert_success; }
@test "deny-host: a leading-dot wildcard denies subdomains" { run _policy_denied_host x.pastebin.com ".pastebin.com"; assert_success; }
@test "deny-host: an unrelated host is not denied" { run _policy_denied_host safe.example.com "pastebin.com"; assert_failure; }

# An allow .parent wildcard that covers a denied host must be caught (else local config defeats the deny).
@test "allow-covers-deny: a .parent allow wildcard covering a denied host is flagged" { run _allow_covers_denied .githubusercontent.com "gist.githubusercontent.com"; assert_success; }
@test "allow-covers-deny: an exact allow host is never flagged (only wildcards over-admit)" { run _allow_covers_denied raw.githubusercontent.com "gist.githubusercontent.com"; assert_failure; }
@test "allow-covers-deny: a wildcard not covering the deny is not flagged" { run _allow_covers_denied .example.com "gist.githubusercontent.com"; assert_failure; }
@test "allow-covers-deny: a broad wildcard covering a deny-wildcard token is flagged" { run _allow_covers_denied .com ".evil.com"; assert_success; }

# learn_apply's policy fetch must fail CLOSED: an unreachable SLUICE_POLICY_URL must abort the apply
# (nothing added/written/reloaded) rather than proceed without the deny list, matching apply_policy.
# Build a self-contained script (stubs + the extracted function) and run it under the launcher's
# set -euo pipefail, the way the real launcher executes.
@test "policy: learn fails closed when SLUICE_POLICY_URL is configured but unreachable" {
  local t="$BATS_TEST_TMPDIR/learn_failclosed.sh"
  cat > "$t" <<'STUBS'
set -euo pipefail
policy_configured() { return 0; }                           # a policy IS configured
_policy_raw() { echo "policy unreachable" >&2; exit 1; }    # mimics the real die on a dead URL
apply_allowlist() { echo "MUTATED:apply"; }                 # tripwires: must NOT run
reload_allowlist() { echo "MUTATED:reload"; }
merge_allow() { printf '%s' "$1"; }
doh_listed() { return 1; }
laundering_host() { return 1; }
_policy_denied_host() { return 1; }
_allow_covers_denied() { return 1; }
_tilde() { printf '%s' "$1"; }
PROJECT_CONFIG=/dev/null; E_YEL=''; E_RST=''; C_GRN=''; C_RST=''; C_DIM=''
STUBS
  sed -n '/^learn_apply()/,/^}/p' "$ROOT/bin/sluice" >> "$t"
  echo 'learn_apply "pastebin.com"' >> "$t"
  run bash "$t"
  assert_failure
  refute_output --partial "MUTATED"
}

@test "policy: learn applies normally when no policy is configured (deny fetch skipped)" {
  local t="$BATS_TEST_TMPDIR/learn_nopolicy.sh"
  cat > "$t" <<'STUBS'
set -euo pipefail
policy_configured() { return 1; }                           # no policy -> no fetch
_policy_raw() { echo "SHOULD-NOT-FETCH"; exit 1; }          # tripwire: must NOT be called
apply_allowlist() { echo "APPLIED:$1"; }
reload_allowlist() { return 0; }
merge_allow() { printf '%s' "$1"; }
doh_listed() { return 1; }
laundering_host() { return 1; }
_policy_denied_host() { return 1; }
_allow_covers_denied() { return 1; }
_tilde() { printf '%s' "$1"; }
PROJECT_CONFIG=/dev/null; E_YEL=''; E_RST=''; C_GRN=''; C_RST=''; C_DIM=''
STUBS
  sed -n '/^learn_apply()/,/^}/p' "$ROOT/bin/sluice" >> "$t"
  echo 'learn_apply "example.org"' >> "$t"
  run bash "$t"
  assert_success
  assert_output --partial "APPLIED:example.org"
  refute_output --partial "SHOULD-NOT-FETCH"
}

# --- apply_policy run-path invariant vs the pure policy_evaluator (doctor-A1 refactor) -------------
# apply_policy is the security-critical managed-egress gate ("deny is final"). It was split into a PURE
# policy_evaluate (doctor calls it report-only) + a die-mode apply_policy (the run path). These tests
# PIN the invariant per violation class: apply_policy must STILL die with the exact message, while
# policy_evaluate must NOT die or mutate for the same input (it records the refusal in _PEVAL_REFUSALS).
#
# Build a self-contained script: real policy_evaluate + apply_policy + the pure helpers + laundering_host
# extracted from the launcher, a stubbed _policy_raw emitting a crafted policy ($POLICY_BODY), a stubbed
# die that records + exits, run under the launcher's own `set -euo pipefail`. $1 = the call to make.
_poleval_script() {
  local t="$1" call="$2"
  cat > "$t" <<'STUBS'
set -euo pipefail
policy_configured() { return 0; }                 # a policy IS configured (run path is armed)
_policy_raw() { printf '%s\n' "$POLICY_BODY"; }    # crafted policy body; never dies here (reachable)
_tilde() { printf '%s' "$1"; }
die() { printf 'DIE:%s\n' "$*" >&2; exit 7; }      # record + exit, like the real die
E_RED=''; E_YEL=''; E_DIM=''; E_RST=''
STUBS
  sed -n '/^_ip2int()/,/^}/p; /^_ip_in_cidr()/,/^}/p; /^_policy_denied_host()/,/^}/p; /^_allow_covers_denied()/,/^}/p; /^laundering_host()/,/^}/p; /^policy_evaluate()/,/^}/p; /^apply_policy()/,/^}/p' "$ROOT/bin/sluice" >> "$t"
  printf '%s\n' "$call" >> "$t"
}

# apply_policy DIES on each violation class; policy_evaluate records the same refusal WITHOUT dying or
# mutating. The crafted POLICY_BODY + the triggering SLUICE_* config var are EXPORTED by the caller
# (each @test), so the generated script inherits them - no `env VAR=val` word-splitting (a value with a
# space, e.g. two SLUICE_ALLOW_IPS, would otherwise be mis-parsed). $1=name $2=expected refusal substring.
_assert_violation() {
  local name="$1" want="$2" t

  t="$BATS_TEST_TMPDIR/apply_$name.sh"
  _poleval_script "$t" 'apply_policy; echo "NO-DIE"'
  run bash "$t"
  assert_failure 7                       # apply_policy died (the stub die exits 7)
  assert_output --partial "DIE:"
  assert_output --partial "$want"        # ... with the exact run-path reason
  refute_output --partial "NO-DIE"

  t="$BATS_TEST_TMPDIR/eval_$name.sh"
  _poleval_script "$t" 'policy_evaluate
printf "EVAL-OK ALLOW=[%s] EXPORT=[%s]\n" "${SLUICE_ALLOW_DOMAINS:-}" "${SLUICE_REQUIRE_SIGNED:-<unset>}"
printf "REFUSALS<<%sEOL\n" "$_PEVAL_REFUSALS"'
  run bash "$t"
  assert_success                         # policy_evaluate NEVER dies for a reachable policy
  assert_output --partial "EVAL-OK"
  assert_output --partial "EXPORT=[<unset>]"   # it must not export SLUICE_REQUIRE_SIGNED
  assert_output --partial "$want"              # the refusal is collected (between the REFUSALS markers)
  refute_output --partial "DIE:"               # ... but never acted on
}

@test "policy: (1) unknown directive under strict-unknown - apply dies, eval records" {
  export POLICY_BODY=$'frobnicate x\nstrict-unknown\nallow ok.example.com' SLUICE_ALLOW_DOMAINS="ok.example.com"
  _assert_violation strict-unknown "policy: unknown directive(s): frobnicate - refusing (strict-unknown)."
}
@test "policy: (2a) forbidden knob SLUICE_DNS_OPEN=1 - apply dies, eval records" {
  export POLICY_BODY=$'forbid SLUICE_DNS_OPEN' SLUICE_DNS_OPEN=1
  _assert_violation forbid-dns "policy forbids SLUICE_DNS_OPEN=1 (your config sets it)"
}
@test "policy: (2b) forbidden generic knob set non-empty - apply dies, eval records" {
  export POLICY_BODY=$'forbid SLUICE_EXTRA_PKGS' SLUICE_EXTRA_PKGS=curl
  _assert_violation forbid-generic "policy forbids setting SLUICE_EXTRA_PKGS (your config sets it)"
}
@test "policy: (3) allow wildcard covering a deny token - apply dies, eval records" {
  export POLICY_BODY=$'deny gist.githubusercontent.com' SLUICE_ALLOW_DOMAINS=".githubusercontent.com"
  _assert_violation conflict "would re-admit a host the policy denies"
}
@test "policy: (4) forbid-laundering with a risky host on the effective list - apply dies, eval records" {
  export POLICY_BODY=$'forbid-laundering' SLUICE_ALLOW_DOMAINS="gist.github.com"
  _assert_violation laundering "policy forbids laundering-capable allowlisted host(s): gist.github.com"
}
@test "policy: (5) SLUICE_ALLOW_IPS matching a deny-ip - apply dies, eval records" {
  export POLICY_BODY=$'deny-ip 10.0.0.0/8' SLUICE_ALLOW_IPS="10.0.0.5:5432"
  _assert_violation deny-ip "policy denies SLUICE_ALLOW_IPS '10.0.0.5:5432' (matches deny-ip 10.0.0.0/8)"
}
@test "policy: (6) SLUICE_ALLOW_IPS over max-allow-ips - apply dies, eval records" {
  export POLICY_BODY=$'max-allow-ips 1' SLUICE_ALLOW_IPS="10.0.0.5:5432 10.0.0.6:6379"
  _assert_violation max-ips "policy caps SLUICE_ALLOW_IPS at 1 (your config has 2)"
}

# The CLEAN path: apply_policy mutates SLUICE_ALLOW_DOMAINS to (local + allow) - deny EXACTLY as before,
# exports SLUICE_REQUIRE_SIGNED on require-signed-base, and prints the policy line; policy_evaluate
# computes the same effective list but mutates/exports NOTHING.
@test "policy: clean policy - apply_policy mutates the allowlist + exports, eval is side-effect-free" {
  export POLICY_BODY=$'allow added.example.com\ndeny drop.example.com\nrequire-signed-base'
  export SLUICE_ALLOW_DOMAINS="keep.example.com drop.example.com"
  local t="$BATS_TEST_TMPDIR/apply_clean.sh"
  _poleval_script "$t" 'apply_policy
printf "ALLOW=[%s] RSIGNED=[%s]\n" "$SLUICE_ALLOW_DOMAINS" "${SLUICE_REQUIRE_SIGNED:-<unset>}"'
  run bash "$t"
  assert_success
  assert_output --partial "managed egress policy"             # the policy line still prints
  assert_output --partial "ALLOW=[added.example.com keep.example.com]"   # drop removed, added unioned, sorted
  assert_output --partial "RSIGNED=[1]"                       # require-signed-base exported
  refute_output --partial "DIE:"                              # (sanity: no refusal)

  t="$BATS_TEST_TMPDIR/eval_clean.sh"
  _poleval_script "$t" 'policy_evaluate
printf "EFF=[%s] ALLOW=[%s] EXPORT=[%s]\n" "$_PEVAL_EFFECTIVE" "$SLUICE_ALLOW_DOMAINS" "${SLUICE_REQUIRE_SIGNED:-<unset>}"'
  run bash "$t"
  assert_success
  assert_output --partial "EFF=[added.example.com keep.example.com]"     # same effective list, computed
  assert_output --partial "ALLOW=[keep.example.com drop.example.com]"    # but SLUICE_ALLOW_DOMAINS untouched
  assert_output --partial "EXPORT=[<unset>]"                             # and nothing exported
}

# A glob-leading allowlist wildcard (`*.s3.amazonaws.com`, a documented form) must reach the EFFECTIVE
# list LITERALLY - policy_evaluate must not pathname-expand it against the invocation $PWD. apply_policy
# assigns SLUICE_ALLOW_DOMAINS from _PEVAL_EFFECTIVE, so an expansion would corrupt the ENFORCED egress
# allowlist on the run path. DETERMINISTIC: a planted file named exactly `evil.s3.amazonaws.com` in the
# CWD makes the old (no set -f) behavior reliably wrong - the glob expands to that one filename - so this
# does not depend on find/glob order. With the fix (set -f over the merge loop) the entry stays literal.
@test "policy: a glob-leading allow wildcard stays literal - no \$PWD pathname expansion (the major)" {
  local plant="$BATS_TEST_TMPDIR/plant-cwd"; mkdir -p "$plant"
  : > "$plant/evil.s3.amazonaws.com"          # the file the bare glob WOULD expand to
  : > "$plant/also.s3.amazonaws.com"          # a second match, so an expansion is unmistakably wrong
  export PLANTDIR="$plant"
  export POLICY_BODY=$'allow other.example.com'   # minimal policy so policy_evaluate runs (policy_configured stubbed true)
  export SLUICE_ALLOW_DOMAINS="*.s3.amazonaws.com"
  local t="$BATS_TEST_TMPDIR/eval_noglob.sh"
  _poleval_script "$t" 'cd "$PLANTDIR" || exit 99
policy_evaluate
printf "EFF=[%s]\n" "$_PEVAL_EFFECTIVE"'
  run bash "$t"
  assert_success
  assert_output --partial "EFF=[*.s3.amazonaws.com other.example.com]"   # the wildcard is LITERAL, not the planted filename(s)
  refute_output --partial "evil.s3.amazonaws.com"                        # the bug would substitute the planted file
  refute_output --partial "also.s3.amazonaws.com"
}

# doctor report-only (no engine, no Docker): a config the policy would REFUSE must make `sluice doctor`
# surface "policy would refuse: <reason>" + the EFFECTIVE (post-deny) allowlist, and still exit 0 (doctor
# never dies). This is the doctor-A1 fix - doctor used to green-light a config run/build would die on.
@test "doctor: report-only surfaces 'policy would refuse' + the effective allowlist, exit 0" {
  local d; d="$BATS_TEST_TMPDIR/doctor-refuse"; mkdir -p "$d"
  printf 'SLUICE_RUN_CMD="true"\nSLUICE_ALLOW_DOMAINS="keep.example.com drop.example.com gist.github.com"\n' > "$d/sluice.config.sh"
  printf 'allow added.example.com\ndeny drop.example.com\nforbid-laundering\n' > "$d/policy.conf"
  # No engine: point SLUICE_ENGINE at a missing binary so doctor skips engine checks but still reaches
  # the policy section. The policy is reachable via file:// so policy_evaluate runs (no _policy_raw die).
  run env SLUICE_ENGINE=/nonexistent-engine-xyz SLUICE_POLICY_URL="file://$d/policy.conf" NO_COLOR=1 \
    bash -c "cd '$d' && '$SLUICE' doctor"
  assert_success                                              # doctor MUST stay non-dying (exit 0)
  assert_output --partial "policy would refuse:"
  assert_output --partial "laundering-capable allowlisted host(s): gist.github.com"
  assert_output --partial "added.example.com"                # effective list shows the policy-added host
  refute_output --partial "drop.example.com gist.github.com (effective"   # drop.example.com removed by deny
  assert_output --partial "effective, post-policy"
}

# If the policy URL is unfetchable, doctor must still COMPLETE (guard _policy_raw's fail-closed die) and
# surface "unreachable" - it must NOT abort the report (the run path's die is preserved separately).
@test "doctor: an unreachable policy URL does not abort doctor (surfaces 'unreachable', exit 0)" {
  local d; d="$BATS_TEST_TMPDIR/doctor-unreach"; mkdir -p "$d"
  printf 'SLUICE_RUN_CMD="true"\nSLUICE_ALLOW_DOMAINS="keep.example.com"\n' > "$d/sluice.config.sh"
  run env SLUICE_ENGINE=/nonexistent-engine-xyz SLUICE_POLICY_URL="file://$d/does-not-exist.conf" NO_COLOR=1 \
    bash -c "cd '$d' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "unreachable"
  assert_output --partial "keep.example.com"                 # falls back to the pre-policy allowlist
}

# doctor --json carries the report-only result: policy.effective_allowlist + policy.refusals[].
@test "doctor --json: policy object carries effective_allowlist + refusals" {
  local d; d="$BATS_TEST_TMPDIR/doctor-json"; mkdir -p "$d"
  printf 'SLUICE_RUN_CMD="true"\nSLUICE_ALLOW_DOMAINS="keep.example.com drop.example.com"\n' > "$d/sluice.config.sh"
  printf 'allow added.example.com\ndeny drop.example.com\nforbid-laundering\n' > "$d/policy.conf"
  run env SLUICE_ENGINE=/nonexistent-engine-xyz SLUICE_POLICY_URL="file://$d/policy.conf" \
    bash -c "cd '$d' && '$SLUICE' doctor --json"
  assert_success
  assert_output --partial '"policy":{'
  assert_output --partial '"effective_allowlist":["added.example.com","keep.example.com"]'
  assert_output --partial '"refusals":['
  assert_output --partial '"reachable":true'
}
