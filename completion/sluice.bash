# bash completion for sluice. Source it:  source /path/to/completion/sluice.bash
# (or symlink into /etc/bash_completion.d/). Completes commands, common flags, agent + box names.

# Built box names (sluice-* image repos, prefix stripped) for -b/--box completion.
_sluice_boxes() {
  local eng=""
  if   [ -n "${SLUICE_ENGINE:-}" ]; then eng="$SLUICE_ENGINE"
  elif command -v docker >/dev/null 2>&1; then eng=docker
  elif command -v podman >/dev/null 2>&1; then eng=podman; fi
  [ -n "$eng" ] || return 0
  "$eng" image ls --filter label=sluice.confighash --format '{{.Repository}}' 2>/dev/null \
    | grep '^sluice-' | sed 's/^sluice-//' | sort -u
}

_sluice() {
  local cur prev words cword
  _get_comp_words_by_ref -n : cur prev cword 2>/dev/null || {
    cur="${COMP_WORDS[COMP_CWORD]}"; prev="${COMP_WORDS[COMP_CWORD-1]}"; cword=$COMP_CWORD
  }

  local cmds="agent init learn shell run diff apply build rebuild update stop rm prune doctor ls egress logs lock smoke version help"

  # A box name right after the leading -b/--box.
  case "$prev" in -b|--box) COMPREPLY=( $(compgen -W "$(_sluice_boxes)" -- "$cur") ); return 0 ;; esac

  # Command index: 1 normally, shifted past a leading -b/--box <name>.
  local ci=1
  case "${COMP_WORDS[1]}" in -b|--box) ci=3 ;; --box=*) ci=2 ;; esac

  if [ "$cword" -eq "$ci" ]; then
    local extra=""; [ "$ci" -eq 1 ] && extra="-b --box"
    COMPREPLY=( $(compgen -W "$cmds $extra" -- "$cur") )
    return 0
  fi
  [ "$cword" -lt "$ci" ] && return 0

  local cmd="${COMP_WORDS[$ci]}"
  case "$cmd" in
    learn)   COMPREPLY=( $(compgen -W "--all --print --apply --audit --help" -- "$cur") ) ;;
    lock)    COMPREPLY=( $(compgen -W "--check --diff --enforce --sbom --scan --json --fail-on --format --help" -- "$cur") ) ;;
    ls)      COMPREPLY=( $(compgen -W "--running --orphans --stack --egress --json --help" -- "$cur") ) ;;
    prune)   COMPREPLY=( $(compgen -W "--orphans --help" -- "$cur") ) ;;
    doctor|egress|version) COMPREPLY=( $(compgen -W "--json --help" -- "$cur") ) ;;
    init)    COMPREPLY=( $(compgen -W "--force --update --help" -- "$cur") ) ;;
    agent)
      # Agent names from the install's agents/ dir (resolve via the sluice on PATH).
      local d names
      d="$(dirname "$(readlink -f "$(command -v sluice)" 2>/dev/null)" 2>/dev/null)/../agents"
      if [ -d "$d" ]; then
        names="$(for f in "$d"/*.config.sh; do [ -f "$f" ] && basename "$f" .config.sh; done)"
        COMPREPLY=( $(compgen -W "$names --help" -- "$cur") )
      fi
      ;;
    *)       COMPREPLY=( $(compgen -W "--help" -- "$cur") ) ;;
  esac
}
complete -F _sluice sluice
