# bash completion for sluice. Source it:  source /path/to/completion/sluice.bash
# (or symlink into /etc/bash_completion.d/). Completes commands, common flags, and agent names.
_sluice() {
  local cur prev words cword
  _get_comp_words_by_ref -n : cur prev cword 2>/dev/null || {
    cur="${COMP_WORDS[COMP_CWORD]}"; prev="${COMP_WORDS[COMP_CWORD-1]}"; cword=$COMP_CWORD
  }

  local cmds="agent init learn shell run build rebuild update stop rm prune doctor ls egress logs lock smoke version help"

  if [ "$cword" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return 0
  fi

  local cmd="${COMP_WORDS[1]}"
  case "$cmd" in
    learn)   COMPREPLY=( $(compgen -W "--all --print --apply --audit --help" -- "$cur") ) ;;
    lock)    COMPREPLY=( $(compgen -W "--check --diff --sbom --json --help" -- "$cur") ) ;;
    doctor|ls|egress|version) COMPREPLY=( $(compgen -W "--json --help" -- "$cur") ) ;;
    init)    COMPREPLY=( $(compgen -W "--force --help" -- "$cur") ) ;;
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
