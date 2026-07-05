#!/usr/bin/env bats
# resolve_podman_userns (unit; no engine). Rootless podman re-owns a bind-mounted repo to a subuid when
# the entrypoint chowns it to uid 1000; keep-id:uid=1000,gid=1000 maps the host user onto the sluice uid
# instead. This is the only local coverage - rootless podman itself runs only on the best-effort CI leg -
# so it pins the version gate (>= 4.3), the rootful/docker no-ops, and the compose-with-kata append.
load test_helper/common

setup() {
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  BIN="${src%/src}/bin/sluice"   # capture before sourcing: the prelude re-derives ROOT from $0
  # shellcheck disable=SC1090
  source "$src/00-prelude.sh"; source "$src/40-runtime.sh"
}

# stub: $1 = Rootless (true/false), $2 = client version string
_podman_stub() { eval "podman() { case \"\$1 \$2\" in 'info --format') echo '$1';; 'version --format') echo '$2';; esac; }"; }

@test "podman-userns: rootless podman 4.9.3 injects keep-id:uid=1000,gid=1000" {
  RUNNER=podman; RUNTIME_RUN_OPTS=(); _podman_stub true 4.9.3
  resolve_podman_userns
  [ "${RUNTIME_RUN_OPTS[*]}" = "--userns=keep-id:uid=1000,gid=1000" ]
}

@test "podman-userns: rootless podman 5.0.0 injects (major > 4)" {
  RUNNER=podman; RUNTIME_RUN_OPTS=(); _podman_stub true 5.0.0
  resolve_podman_userns
  [ "${RUNTIME_RUN_OPTS[*]}" = "--userns=keep-id:uid=1000,gid=1000" ]
}

@test "podman-userns: rootless podman 4.2.0 does NOT inject and warns with the recovery command" {
  RUNNER=podman; RUNTIME_RUN_OPTS=(); _podman_stub true 4.2.0
  resolve_podman_userns 2> "$BATS_TEST_TMPDIR/warn"
  [ "${#RUNTIME_RUN_OPTS[@]}" -eq 0 ]
  grep -q "needs >= 4.3" "$BATS_TEST_TMPDIR/warn"
  grep -q "podman unshare chown" "$BATS_TEST_TMPDIR/warn"
}

@test "podman-userns: rootful podman is a no-op (Rootless=false)" {
  RUNNER=podman; RUNTIME_RUN_OPTS=(); _podman_stub false 4.9.3
  resolve_podman_userns
  [ "${#RUNTIME_RUN_OPTS[@]}" -eq 0 ]
}

@test "podman-userns: docker engine is a no-op and never probes podman" {
  RUNNER=docker; RUNTIME_RUN_OPTS=()
  podman() { echo "podman must not be called for docker" >&2; return 1; }
  resolve_podman_userns
  [ "${#RUNTIME_RUN_OPTS[@]}" -eq 0 ]
}

@test "podman-userns: appends to RUNTIME_RUN_OPTS (composes with the kata --runtime opt)" {
  RUNNER=podman; RUNTIME_RUN_OPTS=(--runtime foo); _podman_stub true 4.9.3
  resolve_podman_userns
  [ "${RUNTIME_RUN_OPTS[*]}" = "--runtime foo --userns=keep-id:uid=1000,gid=1000" ]
}

@test "podman-userns: start() calls resolve_podman_userns before runtime_run (structural)" {
  # extract the start() body, then assert the call precedes the actual `runtime_run --name` launch
  run bash -c "
    body=\$(sed -n '/^start()/,/^}/p' '$BIN')
    cln=\$(printf '%s\n' \"\$body\" | grep -n 'resolve_podman_userns\$' | head -1 | cut -d: -f1)
    rln=\$(printf '%s\n' \"\$body\" | grep -n 'runtime_run --name' | head -1 | cut -d: -f1)
    [ -n \"\$cln\" ] && [ -n \"\$rln\" ] && [ \"\$cln\" -lt \"\$rln\" ]
  "
  assert_success
}
