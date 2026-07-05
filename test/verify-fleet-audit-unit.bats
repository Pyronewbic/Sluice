#!/usr/bin/env bats
# Fleet-wide egress audit (unit; no engine). `sluice egress --verify --all` / `--export --all` walk
# EVERY box's hash-chained egress-log.jsonl with pure host-side file reads - no container engine, no
# per-project config - so they cover orphaned boxes and run with the daemon down. This suite seeds
# several slug dirs via _persist_receipt (the same chain writer verify-receipt-unit exercises) and
# asserts: an all-intact fleet passes, a tampered box fails alone, unreadable is not a silent pass, an
# empty fleet is trivially intact, non-box entries are skipped, export is slug-sorted + per-record
# attributable, and the launcher path never resolves an engine (works with a bogus SLUICE_ENGINE) while
# `-b <box> egress --all` is rejected as spanning every box.
load test_helper/common

setup() {
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  SLUICE_BIN="${src%/src}/bin/sluice"   # capture before sourcing: the prelude re-derives ROOT from $0
  # shellcheck disable=SC1090
  source "$src/00-prelude.sh"; source "$src/10-egress-helpers.sh"
  source "$src/20-lock-sbom-scan.sh"; source "$src/80-learn.sh"
  export XDG_STATE_HOME; XDG_STATE_HOME="$(mktemp -d)"
  SLUICE_ALLOW_DOMAINS=""
  config_hash() { echo deadbeef; }   # no core/ or project config in the unit lane
}
teardown() { rm -rf "$XDG_STATE_HOME"; }

# seed one box: $1 = slug, remaining args = one reached-host record each (chained).
_seed() {
  local sl="$1"; shift
  slug="$sl"; container="sluice-$sl"
  local TAB h; TAB="$(printf '\t')"
  for h in "$@"; do _persist_receipt "$(printf 'reached%s%s%s1%s100' "$TAB" "$h" "$TAB" "$TAB")" ok; done
}

@test "fleet-verify --all: an all-intact fleet reports verified:true, boxes_total:N, exit 0" {
  _seed api a.example.com b.example.com
  _seed web c.example.com
  _seed db  d.example.com e.example.com f.example.com
  run cmd_egress_verify_all --json
  assert_success
  jq -e '.schema=="sluice.fleet-verify/v1" and .verified==true and .boxes_total==3 and .boxes_broken==0' <<<"$output"
  jq -e '[.boxes[].verified]|all' <<<"$output"
  jq -e '.boxes[]|select(.slug=="db")|.records==3' <<<"$output"
}

@test "fleet-verify --all: tampering one box fails that box only (self-hash), exit 1" {
  _seed api a.example.com b.example.com
  _seed web c.example.com
  sed -i.bak '1s/a\.example\.com/a.evil.com/' "$XDG_STATE_HOME/sluice/api/egress-log.jsonl"
  run cmd_egress_verify_all --json
  assert_failure
  jq -e '.verified==false and .boxes_broken==1' <<<"$output"
  jq -e '.boxes[]|select(.slug=="api")|.reason=="self-hash" and .verified==false' <<<"$output"
  jq -e '.boxes[]|select(.slug=="web")|.verified==true and .reason==null' <<<"$output"
}

@test "fleet-verify --all: a dropped middle record is a prev-link break" {
  _seed api a.example.com b.example.com c.example.com
  sed -i.bak '2d' "$XDG_STATE_HOME/sluice/api/egress-log.jsonl"
  run cmd_egress_verify_all --json
  assert_failure
  jq -e '.boxes[]|select(.slug=="api")|.reason=="prev-link"' <<<"$output"
}

@test "fleet-verify --all: an unreadable log reports reason:unreadable, never a silent pass" {
  if [ "$(id -u)" = 0 ]; then skip "running as root - chmod 000 is not enforced"; fi
  _seed api a.example.com
  chmod 000 "$XDG_STATE_HOME/sluice/api/egress-log.jsonl"
  run cmd_egress_verify_all --json
  assert_failure
  jq -e '.boxes[]|select(.slug=="api")|.reason=="unreadable" and .verified==false' <<<"$output"
  chmod 644 "$XDG_STATE_HOME/sluice/api/egress-log.jsonl"   # let teardown clean up
}

@test "fleet-verify --all: an empty fleet is trivially intact, exit 0" {
  run cmd_egress_verify_all --json
  assert_success
  jq -e '.verified==true and .boxes_total==0 and (.boxes|length)==0' <<<"$output"
}

@test "fleet-verify --all: non-box entries (.policy-cache, .mask-empty, a log-less dir) are skipped" {
  _seed api a.example.com
  mkdir -p "$XDG_STATE_HOME/sluice/.policy-cache"; : > "$XDG_STATE_HOME/sluice/.policy-cache/egress-log.jsonl"
  : > "$XDG_STATE_HOME/sluice/.mask-empty"
  mkdir -p "$XDG_STATE_HOME/sluice/emptybox"   # a dir with no egress-log.jsonl
  run cmd_egress_verify_all --json
  assert_success
  jq -e '.boxes_total==1 and (.boxes[0].slug=="api")' <<<"$output"
}

@test "fleet-export --all: concatenates every box slug-sorted; each record is attributable by .box" {
  _seed web c.example.com
  _seed api a.example.com b.example.com
  run cmd_egress_export_all
  assert_success
  [ "$(printf '%s\n' "$output" | grep -c .)" = 3 ]
  # every line is valid JSON carrying a box field
  printf '%s\n' "$output" | while IFS= read -r ln; do [ -n "$ln" ] || continue; jq -e '.box' <<<"$ln" >/dev/null; done
  # slug order: api's records lead, web's trail (api < web)
  [ "$(printf '%s\n' "$output" | head -1 | jq -r '.box')" = "sluice-api" ]
  [ "$(printf '%s\n' "$output" | tail -1 | jq -r '.box')" = "sluice-web" ]
}

@test "fleet-verify --all: strict flag parse - a typo'd flag is rejected" {
  _seed api a.example.com
  run cmd_egress_verify_all --jsonn
  assert_failure
  assert_output --partial "usage: sluice egress --verify --all"
}

# --- launcher path (bin/sluice): engine-free dispatch + -b rejection -------------------------------
@test "fleet-verify --all: the launcher never resolves an engine (works with a bogus SLUICE_ENGINE)" {
  _seed api a.example.com
  SLUICE_ENGINE="/nonexistent/engine-xyz" run "$SLUICE_BIN" egress --verify --all --json
  assert_success
  jq -e '.boxes_total==1 and .verified==true' <<<"$output"
}

@test "fleet: bare 'egress --all' defaults to --verify (launcher)" {
  _seed api a.example.com
  SLUICE_ENGINE="/nonexistent/engine-xyz" run "$SLUICE_BIN" egress --all --json
  assert_success
  jq -e '.schema=="sluice.fleet-verify/v1"' <<<"$output"
}

@test "fleet: '-b <box> egress --all' is rejected - it spans every box" {
  _seed api a.example.com
  run "$SLUICE_BIN" -b api egress --verify --all
  assert_failure
  assert_output --partial "doesn't apply to 'egress --all'"
}
