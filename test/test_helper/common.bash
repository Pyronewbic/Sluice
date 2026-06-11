#!/usr/bin/env bash
# Shared bats helper for the sluice suites.  In a .bats file:  load test_helper/common
# Provides ROOT / SLUICE / ENG, bats-assert/support/file, and the box helpers: make_box/destroy_box
# (the canonical engine-suite setup_file/teardown_file), host_own, nuke_tree, egress assertions. bats
# gives each @test process isolation + a real failure on a failed assert - no silent ok/bad counter.

ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
SLUICE="$ROOT/bin/sluice"
ENG="${SLUICE_ENGINE:-docker}"
export SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1

load "${BATS_TEST_DIRNAME}/test_helper/bats-support/load"
load "${BATS_TEST_DIRNAME}/test_helper/bats-assert/load"
load "${BATS_TEST_DIRNAME}/test_helper/bats-file/load"

# host_own <container> <dir>: chown a mount back to the host uid (the entrypoint chowned it to 1000 at
# run) so a host-side rewrite under it succeeds on Linux (runner uid != 1000). Container must be up.
host_own() { "$ENG" exec --user root "$1" chown -R "$(id -u):$(id -g)" "$2" >/dev/null 2>&1 || true; }

# make_box <slug> <subdir> [extra config lines...]: the canonical engine-suite setup_file. mktemp a
# WORK dir, write WORK/<subdir>/sluice.config.sh with SLUICE_NAME="sectest-<slug>" plus any extra
# lines, then build + warm the box by running it once. Exports WORK. The box is sluice-sectest-<slug>.
# A suite that calls make_box IS an engine suite (belongs in ENGINE_BATS / a Docker CI job).
make_box() {
  local slug="$1" sub="$2"; shift 2
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/$sub"
  { printf 'SLUICE_NAME="sectest-%s"\n' "$slug"; [ "$#" -gt 0 ] && printf '%s\n' "$@"; } > "$WORK/$sub/sluice.config.sh"
  ( cd "$WORK/$sub" && "$SLUICE" run true ) >/dev/null 2>&1 || true
}

# destroy_box <slug> <subdir>: the canonical teardown_file. Stop the box, drop its container, nuke the
# (uid-1000-chowned) WORK tree, then drop the image. Routes through nuke_tree so it is correct under
# BOTH docker and rootless podman (a bare host rm -rf EACCESes on the box's subuid'd files). Order
# matters: nuke_tree runs a throwaway container FROM the image, so rmi comes last.
destroy_box() {
  local c="sluice-sectest-$1"
  ( cd "$WORK/$2" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f -v "$c" >/dev/null 2>&1 || true
  nuke_tree "$c" "$WORK" || true
  "$ENG" rmi -f "$c" >/dev/null 2>&1 || true
}

# chown_back_tree <image> <dir>: chown a whole tree back to the host uid via a throwaway root
# container (boxes chown their mounts to uid 1000, so on Linux the host can't rm $dir otherwise).
# Use in teardown_file before rm -rf. The image only needs to exist (any sluice image works).
chown_back_tree() {
  "$ENG" run --rm --user root -v "$2:$2" --entrypoint chown "$1" -R "$(id -u):$(id -g)" "$2" >/dev/null 2>&1 || true
}

# nuke_tree <image> <dir>: delete a tree the box chowned to uid 1000, working under BOTH docker and
# rootless podman. A throwaway root container rm's the contents - container-root can unlink them even
# under rootless podman, where the box's uid-1000 files land on a host SUBUID the runner can't delete
# directly (so a bare `rm -rf` EACCESes). The host then removes the now-empty top dir. Override the
# entrypoint (the real one configures the firewall) so the throwaway just runs rm.
nuke_tree() {
  "$ENG" run --rm --user root -v "$2:$2" --entrypoint sh "$1" -c "cd '$2' && rm -rf -- ..?* .[!.]* * 2>/dev/null; true" >/dev/null 2>&1 || true
  rm -rf "$2" 2>/dev/null || true
}

# egress_reaches <box-dir> <url>: 0 if the box reached the host (4xx still counts), with retries.
egress_reaches() {
  local d="$1" url="$2" n=1
  until ( cd "$d" && "$SLUICE" run curl -sS --max-time 15 -o /dev/null "$url" ) >/dev/null 2>&1; do
    [ "$n" -ge 3 ] && return 1; n=$((n+1)); sleep 2
  done
}
# egress_blocked <box-dir> <url>: 0 when the firewall blocks it (curl -f fails).
egress_blocked() {
  local d="$1" url="$2"
  ! ( cd "$d" && "$SLUICE" run curl -fsS --max-time 8 -o /dev/null "$url" ) >/dev/null 2>&1
}
