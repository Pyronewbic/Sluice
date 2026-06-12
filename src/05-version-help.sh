sluice_version() {       # git tag if $ROOT is our own checkout, else the baked constant
  local v
  if [ -e "$ROOT/.git" ] && v="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null)" && [ -n "$v" ]; then
    printf '%s' "${v#v}"
  else
    printf '%s' "$SLUICE_VERSION"
  fi
}
# Passive "you're behind" notice for `sluice version`. Best-effort 2s GitHub check; silent on any
# failure/offline/opt-out (SLUICE_NO_UPDATE_CHECK=1), never aborts. Field-numeric compare (BSD sort
# has no -V); a dev build (X.Y.Z-N-g...) compares by its X.Y.Z base, so it won't nag.
check_update_notice() {
  [ -z "${SLUICE_NO_UPDATE_CHECK:-}" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local cur_base latest newest
  cur_base="$(sluice_version | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
  [ -n "$cur_base" ] || return 0
  latest="$(curl -fsS --max-time 2 https://api.github.com/repos/Pyronewbic/Sluice/releases/latest 2>/dev/null \
            | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
            | sed -E 's/.*"([^"]*)"$/\1/' 2>/dev/null || true)"
  latest="${latest#v}"
  [ -n "$latest" ] || return 0
  newest="$(printf '%s\n%s\n' "$cur_base" "$latest" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
  [ "$newest" = "$latest" ] && [ "$latest" != "$cur_base" ] \
    && printf '  update   v%s available (you have v%s) - update sluice: brew upgrade sluice (see README)\n' "$latest" "$cur_base"
  return 0
}
usage() {
  cat <<EOF
sluice $(sluice_version) - run any project in a sandboxed, egress-firewalled container.

Usage: sluice [-b <name>] [command]

  -b, --box <name>  target any box by name from anywhere (before the command; see 'sluice ls')

Common:
  (no command)     build (if needed) + run SLUICE_RUN_CMD; scaffold a config if there's none
  agent [name] [args]  run a coding agent; trailing args run it one-shot; no name lists them
  init [--force|--update]  scaffold a sluice.config.sh by detecting the project's stack
                   (--update re-detects but keeps your allowlist/env/hardening; confirms)
  learn            review the hosts the proxy blocked and allowlist the ones you pick, live
                   (per-host, last run by default; offers .domain wildcards; no rebuild)
                   --all everything since boot; --print emits the list; --apply allows all;
                   --audit opens egress for one trusted run to discover every reached host
  shell            a bash shell in the sandbox (as the non-root sluice user)
  run <cmd...>     an ad-hoc command instead of SLUICE_RUN_CMD

Protected workspace (SLUICE_WORKSPACE=overlay - host repo mounted read-only, box works on a copy):
  diff             show what the box changed vs your repo (unified diff, .git excluded)
  apply            write the box's changes back onto your repo (confirms first)

Build & lifecycle:
  build            build the image (if missing or the config changed)
  rebuild          build + recreate the container - apply config/allowlist edits
  update           rebuild from scratch (re-resolve packages to latest) + refresh sluice.lock
  stop             remove the project's container
  rm               remove the project's container AND image
  prune            remove every sluice container + image (or only orphans: --orphans); confirms

Inspect:
  doctor           health check: engine, image, allowlist, blocked egress (--json)
  ls               list all boxes + posture (status, stack, allow/ports/lock, path); --running/--orphans/--stack <name>/--egress/--json
  egress           show what this box reached vs. was blocked (--json | --export | --verify)
  logs             follow firewall + readiness logs
  lock             record installed apk+npm+pip+gem+go+cargo versions to sluice.lock (supply-chain audit)
                   --check fails on drift (CI gate, --json); --enforce is the strict variant; --diff shows it;
                   --sbom emits CycloneDX (--format spdx for SPDX); --scan vuln-checks via a host Grype/Trivy (--fail-on <sev>)
  smoke            build (if needed) + run the image smoke test

Meta:
  version          show version + host runtime (engine, OS)
  help             show this help

Env: SLUICE_ENGINE  SLUICE_RUNTIME=kata  SLUICE_NO_BANNER  SLUICE_YES  SLUICE_NO_UPDATE_CHECK  NO_COLOR
     SLUICE_PIDS_LIMIT (default 4096)  SLUICE_MEMORY (e.g. 4g; unset = no cap)
     SLUICE_SECCOMP=hardened|browser|audit (extra syscall filter; hardened >= engine default)
     SLUICE_READONLY_ROOT=1 (immutable rootfs; tmpfs + anon-volume the writable paths)
     SLUICE_WORKSPACE=overlay (host repo read-only; box edits a copy - see 'diff'/'apply')
     Config knobs (sluice.config.sh): see sluice.config.example.sh + docs/configuration.md
Docs: https://github.com/Pyronewbic/Sluice
EOF
}
# Per-command help (sluice <cmd> --help). Synopses mirror usage(); keeps `sluice run --help` etc. useful.
help_for() {
  case "$1" in
    run)     echo "sluice run <cmd...>     - run an ad-hoc command in the sandbox (builds/starts if needed)." ;;
    shell)   echo "sluice shell            - a bash shell in the sandbox (non-root sluice user)." ;;
    agent)   echo "sluice agent [name] [args] - scaffold + run a coding-agent preset; args after the name run it one-shot; no name lists them." ;;
    init)    echo "sluice init [--force|--update] - scaffold a sluice.config.sh by detecting the stack (--update re-detects, keeping your edits)." ;;
    learn)   echo "sluice learn [--all] [--print|--apply|--audit] - review blocked hosts, allowlist your picks." ;;
    build)   echo "sluice build            - build the image if missing or the config changed." ;;
    rebuild) echo "sluice rebuild          - build + recreate the container (apply config/allowlist edits)." ;;
    update)  echo "sluice update           - rebuild from scratch (re-resolve packages) + refresh sluice.lock." ;;
    diff)    echo "sluice diff             - (SLUICE_WORKSPACE=overlay) show what the box changed vs your repo." ;;
    apply)   echo "sluice apply            - (SLUICE_WORKSPACE=overlay) write the box's changes back onto your repo (confirms; SLUICE_YES=1 non-interactive, SLUICE_APPLY_NO_DELETE=1 keeps deleted host files)." ;;
    stop)    echo "sluice stop             - remove the project's container." ;;
    rm)      echo "sluice rm               - remove the project's container AND image." ;;
    prune)   echo "sluice prune [--orphans] - remove every sluice container + image (or only orphans); confirms." ;;
    doctor)  echo "sluice doctor [--json]  - health check: engine, image, allowlist, blocked egress." ;;
    ls)      echo "sluice ls [--running|--orphans|--stack <name>|--egress|--json] - list boxes + posture (allow/ports/lock; --egress adds live blocked counts). Posture populates after rebuild." ;;
    egress)  echo "sluice egress [--json | --export | --verify]  - reached vs. blocked; --export the append-only audit log (JSONL), --verify its hash chain." ;;
    logs)    echo "sluice logs             - follow firewall + readiness logs." ;;
    lock)    echo "sluice lock [--check [--json] | --diff [--json] | --enforce [--json] | --sbom [--format cyclonedx|spdx] | --scan [--json] [--fail-on <sev>]] - record/verify/vuln-scan the supply-chain inventory." ;;
    smoke)   echo "sluice smoke            - build (if needed) + run the image smoke test." ;;
    version) echo "sluice version [--json] - show version + host runtime." ;;
    *)       usage ;;
  esac
}
cmd_version() {
  [ "${1:-}" = --json ] && { cmd_version_json; return 0; }
  printf 'sluice %s\n' "$(sluice_version)"
  local eng=""
  if   [ -n "${SLUICE_ENGINE:-}" ]; then eng="$SLUICE_ENGINE"
  elif command -v docker >/dev/null 2>&1; then eng=docker
  elif command -v podman >/dev/null 2>&1; then eng=podman; fi
  if [ -n "$eng" ] && command -v "$eng" >/dev/null 2>&1; then
    printf '  engine   %s\n' "$("$eng" --version 2>/dev/null | head -1)"
  else
    printf '  engine   %snone%s (install docker or podman)\n' "$C_RED" "$C_RST"
  fi
  printf '  os       %s %s\n' "$(uname -s)" "$(uname -m)"
  printf '  install  %s\n' "$ROOT"
  check_update_notice
}
# Machine-readable version/runtime for scripts + the control plane.
cmd_version_json() {
  local eng=""
  if   [ -n "${SLUICE_ENGINE:-}" ]; then eng="$SLUICE_ENGINE"
  elif command -v docker >/dev/null 2>&1; then eng=docker
  elif command -v podman >/dev/null 2>&1; then eng=podman; fi
  [ -n "$eng" ] && command -v "$eng" >/dev/null 2>&1 && eng="$("$eng" --version 2>/dev/null | head -1)"
  printf '{"version":"%s","engine":"%s","os":"%s","install":"%s"}\n' \
    "$(_json_esc "$(sluice_version)")" "$(_json_esc "$eng")" "$(_json_esc "$(uname -s) $(uname -m)")" "$(_json_esc "$ROOT")"
}

# naming + diagnostics helpers (shared by run, learn, doctor)
