# The banner's second line, computed live when a config is in scope: engine, allowlist size, the
# active hardening, and whether in-repo secrets are masked - so the launch moment doubles as a
# one-glance "what's the cage" check. Sets _POSTURE_TEXT + _POSTURE_RISK (risk = an allowlisted
# laundering host, or a DoH resolver allowed with SLUICE_ALLOW_DOH=1). Fast: no find/engine calls.
# $1 = separator (UTF-8 dot or ASCII dash).
_banner_posture() {
  local sep="$1" h hard=""
  _POSTURE_TEXT="$(basename "${RUNNER:-${ENGINE:-${SLUICE_ENGINE:-docker}}}")"
  _POSTURE_TEXT="$_POSTURE_TEXT${sep}$(allowed_domains | wc -w | tr -d ' ') hosts"
  [ -n "${SLUICE_SECCOMP:-}" ]          && hard="${hard:+$hard+}seccomp"
  [ "${SLUICE_READONLY_ROOT:-}" = 1 ]   && hard="${hard:+$hard+}readonly"
  [ "${SLUICE_WORKSPACE:-}" = overlay ] && hard="${hard:+$hard+}overlay"
  [ "${SLUICE_RUNTIME:-}" = kata ]      && hard="${hard:+$hard+}kata"
  [ -n "$hard" ]            && _POSTURE_TEXT="$_POSTURE_TEXT${sep}$hard"
  [ -n "${SLUICE_MASK:-}" ] && _POSTURE_TEXT="$_POSTURE_TEXT${sep}masked"
  _POSTURE_RISK=""
  for h in ${SLUICE_ALLOW_DOMAINS:-}; do laundering_host "$h" && { _POSTURE_RISK=1; break; }; done
  [ -z "$_POSTURE_RISK" ] && [ "${SLUICE_ALLOW_DOH:-}" = 1 ] && \
    for h in ${SLUICE_ALLOW_DOMAINS:-}; do doh_listed "$h" && { _POSTURE_RISK=1; break; }; done
  return 0
}

banner() {
  [ -z "${_BANNER_SHOWN:-}" ] || return 0
  [ -t 2 ] || return 0
  [ -z "${SLUICE_NO_BANNER:-}" ] || return 0
  _BANNER_SHOWN=1
  local d="" r="" gn="" yl="" ver utf sep line2 pc cols
  ver="v$(sluice_version)"
  [ -z "${NO_COLOR:-}" ] && { d=$'\033[2m'; r=$'\033[0m'; gn=$'\033[32m'; yl=$'\033[33m'; }
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *UTF-8*|*utf8*|*UTF8*) utf=1; sep=" · " ;; *) utf=""; sep=" - " ;; esac

  # Second line: the live posture when a config is sourced (run/shell), else the static tagline.
  if [ -n "${PROJECT_CONFIG:-}" ]; then
    _banner_posture "$sep"; line2="$_POSTURE_TEXT"; pc="$gn"
    [ -n "$_POSTURE_RISK" ] && { pc="$yl"; line2="$line2${sep}exfil risk"; }   # word, not just color (NO_COLOR/colorblind)
  else
    line2="sandboxed, firewalled, non-root"; pc="$d"
  fi

  # Narrow terminal (Option A): one compact line, no art.
  cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
  if [ "$cols" -lt 34 ]; then
    printf '%ssluice %s%s %s%s%s\n' "$d" "$ver" "$r" "$pc" "$line2" "$r" >&2
    return 0
  fi

  if [ -n "$utf" ]; then
    printf '%s   ◯\n ┌─┴─┐\n │ █ │   sluice %s\n │≈≈≈│   %s%s%s\n └───┘\n%s' \
      "$d" "$ver" "$pc" "$line2" "$d" "$r" >&2
  else
    printf '%s   o\n +-+-+\n | # |   sluice %s\n |~~~|   %s%s%s\n +---+\n%s' \
      "$d" "$ver" "$pc" "$line2" "$d" "$r" >&2
  fi
}

# container engine (docker, else podman; override SLUICE_ENGINE). $ENGINE always BUILDS the image; $RUNNER
# runs/execs the box. They're the same binary unless SLUICE_RUNTIME asks for an own-kernel micro-VM (Kata),
# which Docker can't drive - then the box runs under nerdctl/containerd while $ENGINE still builds it and
# the image is loaded across. Default (unset SLUICE_RUNTIME): RUNNER==ENGINE, so every run path is unchanged.
resolve_engine() {
  ENGINE="${SLUICE_ENGINE:-}"
  if [ -z "$ENGINE" ]; then
    if command -v docker >/dev/null 2>&1; then ENGINE=docker
    elif command -v podman >/dev/null 2>&1; then ENGINE=podman
    else die "no container engine found - install docker or podman, or set SLUICE_ENGINE"; fi
  fi
  command -v "$ENGINE" >/dev/null 2>&1 || die "SLUICE_ENGINE=$ENGINE not found on PATH"
  # SLUICE_RUNTIME=kata: preflight the containerd/nerdctl/Kata stack (run commands need it working).
  if [ "${SLUICE_RUNTIME:-}" = kata ]; then
    command -v nerdctl >/dev/null 2>&1 || die "SLUICE_RUNTIME=kata needs nerdctl (containerd) on PATH - install nerdctl + Kata Containers (Linux only)"
    nerdctl info >/dev/null 2>&1 || die "SLUICE_RUNTIME=kata: nerdctl/containerd is not reachable - is containerd running, and do you have privileges? (Kata wants a rootful containerd; try running sluice as root)"
    command -v containerd-shim-kata-v2 >/dev/null 2>&1 || echo "[sluice] note: containerd-shim-kata-v2 not on PATH - SLUICE_RUNTIME=kata needs the Kata shim installed for containerd" >&2
  fi
  resolve_runner
}

# $RUNNER (the run/exec engine) + Kata run opts from SLUICE_RUNTIME, given $ENGINE (the build engine).
# Shared by resolve_engine (which preflights first) and the lenient `doctor` probe. Default -> RUNNER==ENGINE.
resolve_runner() {
  RUNNER="$ENGINE"; RUNTIME_RUN_OPTS=()
  case "${SLUICE_RUNTIME:-}" in
    kata) RUNNER=nerdctl; RUNTIME_RUN_OPTS=(--runtime io.containerd.kata.v2) ;;
    ""|docker|podman|"$ENGINE") ;;
    *) die "SLUICE_RUNTIME='${SLUICE_RUNTIME:-}' is not supported (use 'kata', or leave it unset for docker/podman)" ;;
  esac
}

# SLUICE_RUNTIME=kata builds with $ENGINE but runs under nerdctl/containerd, which keeps its own image
# store; cross the built image over. No-op when builder == runner. $1=force reloads even if present (after
# a rebuild the runtime's copy is stale).
runtime_sync_image() {
  [ "$RUNNER" = "$ENGINE" ] && return 0
  if [ "${1:-}" != force ] && "$RUNNER" image inspect "$tag" >/dev/null 2>&1; then return 0; fi
  echo "[sluice] loading $tag into the $RUNNER runtime ..." >&2
  "$ENGINE" save "$tag" | "$RUNNER" load >/dev/null 2>&1 \
    || die "SLUICE_RUNTIME=${SLUICE_RUNTIME:-} - failed to load $tag into $RUNNER (check containerd privileges)"
}

# Launch a detached box under $RUNNER with the runtime's extra run flags (Kata's --runtime). Empty-array
# expansion is guarded so it stays set -u-safe on bash 3.2 (macOS), where SLUICE_RUNTIME is never kata.
runtime_run() {
  if [ "${#RUNTIME_RUN_OPTS[@]}" -gt 0 ]; then "$RUNNER" run -d "${RUNTIME_RUN_OPTS[@]}" "$@"; else "$RUNNER" run -d "$@"; fi
}

# Remove the box's per-dir overlay volumes (SLUICE_OVERLAY_DIRS; labeled sluice.box=<container> at
# creation, so no config sourcing is needed - prune and orphan rm work too). Echoes the count removed.
remove_box_volumes() {
  local v n=0
  for v in $("$RUNNER" volume ls -q --filter "label=sluice.box=$1" 2>/dev/null || true); do
    "$RUNNER" volume rm -f "$v" >/dev/null 2>&1 && n=$((n+1)) || true
  done
  echo "$n"
}

# Map a -b/--box <name> to a built box: accept the short slug (qwen) or the full image (sluice-qwen),
# verify it's a real sluice box, and stash its recorded project dir for the box-aware find_config below.
resolve_box_target() {
  local name="$1" img hash
  case "$name" in sluice-*) img="$name" ;; *) img="sluice-$name" ;; esac
  hash="$("$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.confighash" }}' "$img" 2>/dev/null || true)"
  case "$hash" in ""|"<no value>") die "no sluice box named '$name' - run 'sluice ls'" ;; esac
  SLUICE_BOX_IMAGE="$img"
  SLUICE_BOX_SLUG="${img#sluice-}"
  BOX_PROJECT="$("$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.project" }}' "$img" 2>/dev/null || true)"
  case "$BOX_PROJECT" in "<no value>") BOX_PROJECT="" ;; esac
}

# Leading global -b/--box <name>: explicit, per-invocation targeting of any box from anywhere. Parsed
# ONLY before the subcommand, so a --box that's an argument to `sluice run` is never swallowed.
