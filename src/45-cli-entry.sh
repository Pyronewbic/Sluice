SLUICE_BOX_TARGET=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -b|--box) [ -n "${2:-}" ] || die "--box needs a box name - run 'sluice ls'"; SLUICE_BOX_TARGET="$2"; shift 2 ;;
    --box=*)  SLUICE_BOX_TARGET="${1#--box=}"; [ -n "$SLUICE_BOX_TARGET" ] || die "--box needs a box name - run 'sluice ls'"; shift ;;
    *)        break ;;
  esac
done

# Per-command help (sluice <cmd> --help) + hidden helpers - before config (they need none).
case "${2:-}" in -h|--help) help_for "${1:-}"; exit 0 ;; esac
case "${1:-}" in
  __parent)      parent_of "${2:-}"; exit 0 ;;          # registrable parent (tests/completion)
  __collapsible) _collapsible "${2:-}" && echo yes || echo no; exit 0 ;;
  __sbom)        [ -n "${2:-}" ] || die "usage: sluice __sbom <image-ref>"; resolve_engine; _sbom_for "$2"; exit $? ;;
  __posture)     [ -f "$PWD/sluice.config.sh" ] && . "$PWD/sluice.config.sh"   # banner posture for $PWD's config (tests; no engine; find_config isn't defined this early)
                 _banner_posture ' - '; printf '%s%s\n' "$_POSTURE_TEXT" "${_POSTURE_RISK:+ [risk]}"; exit 0 ;;
esac

# init + info commands need no engine; resolve one only for the rest. `egress ... --all` is a
# host-side, file-only fleet audit (no engine, no config), so it must survive the daemon being down
# or absent - skip resolve_engine for it too, matching doctor's leniency.
case "${1:-}" in
  init|help|-h|--help|version|-v|--version|doctor) ;;
  egress) case " $* " in *" --all "*) ;; *) resolve_engine ;; esac ;;
  *) resolve_engine ;;
esac

# --box targeting: resolve the named box up front so every config lookup below routes to it. Reject
# the commands that have no single-box meaning; explicit by design - echo the target to stderr.
if [ -n "$SLUICE_BOX_TARGET" ]; then
  case "${1:-}" in
    init|help|-h|--help|version|-v|--version|ls|prune|agent) die "--box doesn't apply to '${1:-}'" ;;
    egress) case " $* " in *" --all "*) die "--box doesn't apply to 'egress --all' (it spans every box)" ;; esac ;;
  esac
  # doctor is the lenient path (reports, never dies, since it's what you run when the runtime is broken):
  # mirror line 22 and skip the strict resolve_engine. resolve_box_target still needs $ENGINE for its
  # image inspect, so set it leniently (docker/podman/SLUICE_ENGINE, no runtime preflight) - matching
  # cmd_doctor's own engine probe. Every other -b command keeps the strict resolve_engine.
  case "${1:-}" in
    doctor)
      if   [ -n "${SLUICE_ENGINE:-}" ]; then ENGINE="$SLUICE_ENGINE"
      elif command -v docker >/dev/null 2>&1; then ENGINE=docker
      elif command -v podman >/dev/null 2>&1; then ENGINE=podman
      else ENGINE="" ; fi ;;
    *) resolve_engine ;;   # idempotent; the line-22 case skipped it for doctor
  esac
  resolve_box_target "$SLUICE_BOX_TARGET"
  echo "${E_DIM}[sluice]${E_RST} targeting ${SLUICE_BOX_SLUG} (${BOX_PROJECT:-<dir gone>})" >&2
fi

# `sluice init` helpers: best-effort manifest parsing (no jq), each returns 0
