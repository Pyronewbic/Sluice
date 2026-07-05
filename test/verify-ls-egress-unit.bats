#!/usr/bin/env bats
# `ls --egress` blocked-count fail-closed (unit; no engine). box_blocked_count feeds the fleet
# overview's BLOCKED column; an unreadable in-box audit (pids-cgroup exhaustion blocks `exec`) must
# render unknown (empty -> ? / null), never a false all-clear 0 - the same class doctor/learn close.
load test_helper/common

setup() {
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  BIN="${src%/src}/bin/sluice"   # capture before sourcing: the prelude re-derives ROOT from $0
  # shellcheck disable=SC1090
  source "$src/00-prelude.sh"; source "$src/10-egress-helpers.sh"; source "$src/30-doctor-ls.sh"
}

@test "ls-egress: an unreadable in-box audit yields an empty (unknown) count, not 0" {
  _root_exec() { return 1; }
  run box_blocked_count sluice-x
  assert_success
  assert_output ""
}

@test "ls-egress: a readable audit with nothing denied still reports a real 0" {
  _root_exec() { return 0; }; blocked_hosts() { :; }
  run box_blocked_count sluice-x
  assert_success
  assert_output "0"
}

@test "ls-egress: a real denial still counts" {
  _root_exec() { return 0; }; blocked_hosts() { printf 'denied.example.io\n'; }
  run box_blocked_count sluice-x
  assert_success
  assert_output "1"
}

@test "ls-egress: the JSON render's defaulted-0 fail-open is gone (structural)" {
  # no render may default an empty (unknown) count to 0
  run grep -F 'blocks[$i]:-' "$BIN"
  assert_failure
}

@test "ls-egress: box_blocked_count consults _audit_readable before trusting a zero (structural)" {
  run bash -c "sed -n '/^box_blocked_count()/,/^}/p' '$BIN' | grep -q _audit_readable"
  assert_success
}

# --- ls --json versioned data contract (F2): schema stamp + confighash + state_dir + last_receipt ---
# cmd_ls reads only labels + files (no config sourcing), so a function-named engine stub drives it with
# no daemon. The stub answers image-ls (one box) and the per-label image-inspect calls; ps says stopped.
_stub_engine_one_box() {
  export XDG_STATE_HOME; XDG_STATE_HOME="$(mktemp -d)"
  ENGINE=eng; RUNNER=eng
  find_config() { return 1; }   # not inside any box's project dir -> current=false, engine "up"
  eng() {
    case "$*" in
      "image ls --filter label=sluice.confighash --format {{.Repository}}") printf 'sluice-api\n' ;;
      "info") return 0 ;;
      *"sluice.project"*)    printf '/nonexistent/proj\n' ;;
      *"sluice.stack"*)      printf 'node\n' ;;
      *"sluice.desc"*)       printf 'my api box\n' ;;
      *"sluice.allowcount"*) printf '3\n' ;;
      *"sluice.ports"*)      printf '<no value>\n' ;;
      *"sluice.overlays"*)   printf '<no value>\n' ;;
      *"sluice.confighash"*) printf 'abc123def456\n' ;;
      *) : ;;   # ps (stopped) + anything else
    esac
  }
}

@test "ls --json: each element carries schema, confighash, and an absolute state_dir" {
  _stub_engine_one_box
  run cmd_ls --json
  assert_success
  jq -e '.[0].schema=="sluice.box/v1"' <<<"$output"
  jq -e '.[0].confighash=="abc123def456"' <<<"$output"
  jq -e '.[0].state_dir|endswith("/sluice/api")' <<<"$output"
  rm -rf "$XDG_STATE_HOME"
}

@test "ls --json: a well-formed egress-receipt.json embeds verbatim into last_receipt" {
  _stub_engine_one_box
  mkdir -p "$XDG_STATE_HOME/sluice/api"
  printf '{"schema":"sluice.egress/v1","box":"sluice-api","status":"ok","totals":{"reached":1,"blocked":0,"bytes":42}}\n' \
    > "$XDG_STATE_HOME/sluice/api/egress-receipt.json"
  run cmd_ls --json
  assert_success
  jq -e '.[0].last_receipt.schema=="sluice.egress/v1" and .[0].last_receipt.totals.bytes==42' <<<"$output"
  rm -rf "$XDG_STATE_HOME"
}

@test "ls --json: a malformed (multi-line) receipt yields last_receipt:null (fail-closed embed)" {
  _stub_engine_one_box
  mkdir -p "$XDG_STATE_HOME/sluice/api"
  printf '{"schema":"sluice.egress/v1",\n"box":"sluice-api"}\n' > "$XDG_STATE_HOME/sluice/api/egress-receipt.json"
  run cmd_ls --json
  assert_success
  jq -e '.[0].last_receipt==null' <<<"$output"
  rm -rf "$XDG_STATE_HOME"
}

@test "ls --json: no receipt file yields last_receipt:null, still valid JSON" {
  _stub_engine_one_box
  run cmd_ls --json
  assert_success
  jq -e '.[0].last_receipt==null' <<<"$output"
  rm -rf "$XDG_STATE_HOME"
}

@test "ls --json: podman's localhost/ image prefix is stripped so name + state_dir stay canonical" {
  _stub_engine_one_box
  eng() {
    case "$*" in
      "image ls --filter label=sluice.confighash --format {{.Repository}}") printf 'localhost/sluice-api\n' ;;
      "info") return 0 ;;
      *"sluice.project"*)    printf '/nonexistent/proj\n' ;;
      *"sluice.confighash"*) printf 'abc123def456\n' ;;
      *) : ;;
    esac
  }
  run cmd_ls --json
  assert_success
  jq -e '.[0].name=="sluice-api"' <<<"$output"                 # not localhost/sluice-api
  jq -e '.[0].state_dir|endswith("/sluice/api")' <<<"$output"  # not /sluice/localhost/sluice-api
  rm -rf "$XDG_STATE_HOME"
}

@test "ls/prune: both image-ls seeds strip podman's localhost/ prefix (structural)" {
  [ "$(grep -cF "sed 's,^localhost/,,'" "$BIN")" -ge 2 ]
}

@test "ls --json: a pre-posture image without a confighash label yields confighash:null" {
  _stub_engine_one_box
  eng() {
    case "$*" in
      "image ls --filter label=sluice.confighash --format {{.Repository}}") printf 'sluice-api\n' ;;
      "info") return 0 ;;
      *"sluice.confighash"*) printf '<no value>\n' ;;
      *"sluice.project"*)    printf '/nonexistent/proj\n' ;;
      *) : ;;
    esac
  }
  run cmd_ls --json
  assert_success
  jq -e '.[0].confighash==null' <<<"$output"
  rm -rf "$XDG_STATE_HOME"
}
