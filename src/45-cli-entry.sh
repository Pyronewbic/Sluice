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

# init + info commands need no engine; resolve one only for the rest.
case "${1:-}" in
  init|help|-h|--help|version|-v|--version|doctor) ;;
  *) resolve_engine ;;
esac

# --box targeting: resolve the named box up front so every config lookup below routes to it. Reject
# the commands that have no single-box meaning; explicit by design - echo the target to stderr.
if [ -n "$SLUICE_BOX_TARGET" ]; then
  case "${1:-}" in
    init|help|-h|--help|version|-v|--version|ls|prune|agent) die "--box doesn't apply to '${1:-}'" ;;
  esac
  resolve_engine   # idempotent; doctor skipped it in the case above
  resolve_box_target "$SLUICE_BOX_TARGET"
  echo "${E_DIM}[sluice]${E_RST} targeting ${SLUICE_BOX_SLUG} (${BOX_PROJECT:-<dir gone>})" >&2
fi

# `sluice init` helpers: best-effort manifest parsing (no jq), each returns 0
