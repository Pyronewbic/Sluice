#!/usr/bin/env bats
# `sluice init` must SHELL-QUOTE every repo-derived value it writes: the generated sluice.config.sh is
# sourced ON THE HOST (pre-container) by `sluice` itself, so an unquoted metachar = arbitrary host-code
# execution from merely scaffolding an untrusted repo. Regression for the _init_q quoter (src/50-init.sh).
# A generic-stack repo (Procfile only, so the stack stays generic) carries the run command into
# SLUICE_RUN_CMD; the web line embeds the quoting metachars that broke the old quoter:
#   - a bare backtick command-sub with NO $ or " -> the old _init_q took its DOUBLE-quote branch, so the
#     backtick stayed LIVE and ran on host-source (the headline host-code-exec hole), and
#   - an embedded single quote alongside a $ -> the old single-quote branch did not escape it, so the
#     value broke out / got mangled.
# After init, sourcing the config must (a) leave SLUICE_RUN_CMD byte-identical to the web line and
# (b) cause NO host side effect (no marker file from the inert backtick / $()).
load test_helper/common

# run `sluice init` in a fresh generic repo whose Procfile web line is $1, exporting CFG + the repo dir.
_scaffold() {
  REPO="$WORK/repo"; mkdir -p "$REPO"
  printf 'web: %s\n' "$1" > "$REPO/Procfile"
  ( cd "$REPO" && "$SLUICE" init ) >/dev/null 2>&1
  CFG="$REPO/sluice.config.sh"
}
# source CFG with cwd=REPO (as the launcher does, from the project dir), print the resulting var.
_source_runcmd() { ( cd "$REPO" && . ./sluice.config.sh >/dev/null 2>&1; printf %s "$SLUICE_RUN_CMD" ); }

setup() { WORK="$(mktemp -d)"; }
teardown() { rm -rf "$WORK"; }

# --- the headline hole: a bare backtick (no $, no ") - old code double-quoted it, so it ran on source.
@test "init-quoting: bare-backtick web line sources to the literal value" {
  _scaffold 'node app.js `touch PWNED`'
  run _source_runcmd
  assert_success
  assert_output 'node app.js `touch PWNED`'
}
@test "init-quoting: bare-backtick web line runs NO host code on source (no marker)" {
  _scaffold 'node app.js `touch PWNED`'
  run _source_runcmd                      # sources with cwd=REPO; a live backtick would create REPO/PWNED
  assert_file_not_exists "$REPO/PWNED"
}

# --- the related hole: $ + embedded single quote - old single-quote branch didn't escape the quote.
@test "init-quoting: \$()+single-quote web line sources to the literal value" {
  local web='echo $(touch PWNED2); echo '"'"'$X'"'"' "y"'
  _scaffold "$web"
  run _source_runcmd
  assert_success
  assert_output "$web"
}
@test "init-quoting: \$()+single-quote web line runs NO host code on source (no marker)" {
  _scaffold 'echo $(touch PWNED2); echo '"'"'$X'"'"' "y"'
  run _source_runcmd
  assert_file_not_exists "$REPO/PWNED2"
}

# --- structural: the fix always single-quotes (a regression to the double-quote branch would emit ="...).
@test "init-quoting: the run-cmd value is single-quoted on disk" {
  _scaffold 'node app.js `touch PWNED`'
  run grep -E "^SLUICE_RUN_CMD='" "$CFG"
  assert_success
}
