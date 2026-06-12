#!/usr/bin/env bats
# Root-context maintenance execs (receipt / learn reload / apply) run as the container's ROOT with no
# --user. If the image PATH let a uid-1000-writable dir shadow a system tool, a planted
# ~/.npm-global/bin/tail would execute as root the moment `sluice egress` / the at-exit receipt shells
# out - single-session privesc, and with NET_ADMIN a full `iptables -F` firewall teardown. Two layers
# close it: _root_exec forces a clean system PATH on every such exec, and the Dockerfile APPENDS (not
# prepends) the npm bin so /usr/bin always wins. Legit egress maintenance must keep working.
load test_helper/common

setup_file() { make_box rootexec rootexec 'SLUICE_RUN_CMD="bash"'; }
teardown_file() { destroy_box rootexec rootexec; }

@test "rootexec: box image built" {
  run "$ENG" image inspect sluice-sectest-rootexec
  assert_success
}

@test "rootexec: image PATH puts system bins before the uid-1000 npm dir (append, not prepend)" {
  # Plant a tail in the user-writable npm bin, then resolve `tail` under the image PATH (root context).
  "$ENG" exec --user sluice sluice-sectest-rootexec sh -c \
    'mkdir -p "$HOME/.npm-global/bin"; printf "#!/bin/sh\ntrue\n" > "$HOME/.npm-global/bin/tail"; chmod +x "$HOME/.npm-global/bin/tail"'
  run "$ENG" exec --user root sluice-sectest-rootexec sh -c 'command -v tail'
  assert_success
  refute_output --partial '.npm-global'   # a system tail must win, not the planted one
}

@test "rootexec: a uid-1000-planted 'tail' does not run as root when the receipt path shells out" {
  # Malicious tail: marks /tmp/sluice-pwned (with the running uid) if it is ever executed, then chains
  # to the real tail so egress still functions either way - so the marker is the ONLY signal.
  "$ENG" exec --user sluice sluice-sectest-rootexec sh -c \
    'mkdir -p "$HOME/.npm-global/bin"; printf "#!/bin/sh\nid -u > /tmp/sluice-pwned 2>/dev/null\nexec /usr/bin/tail \"\$@\"\n" > "$HOME/.npm-global/bin/tail"; chmod +x "$HOME/.npm-global/bin/tail"'
  # `sluice egress` shells out via _squid_log -> _root_exec ... tail. The clean PATH must skip the plant.
  run bash -c "cd '$WORK/rootexec' && '$SLUICE' egress"
  assert_success
  run "$ENG" exec --user root sluice-sectest-rootexec sh -c 'test -f /tmp/sluice-pwned'
  assert_failure   # the planted tail never executed
}
