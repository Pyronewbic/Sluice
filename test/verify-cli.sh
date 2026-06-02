#!/usr/bin/env bash
# Unit tests for the CLI surface (no Docker: fast, never flaky): version --json, per-command --help,
# the public-suffix-aware parent_of/collapsible logic, and completion-script syntax.
#   ./test/verify-cli.sh
set -u

. "$(dirname "$0")/lib.sh"
export SLUICE_NO_UPDATE_CHECK=1

echo "== CLI surface =="

# version --json: valid JSON with the documented keys.
vj="$("$SLUICE" version --json 2>/dev/null)"
if printf '%s' "$vj" | python3 -m json.tool >/dev/null 2>&1; then ok "version --json is valid JSON"; else bad "version --json invalid: $vj"; fi
printf '%s' "$vj" | python3 -c "import sys,json
d=json.load(sys.stdin)
sys.exit(0 if all(k in d for k in ('version','engine','os','install')) and d['version'] else 1)" \
  && ok "version --json has version/engine/os/install" || bad "version --json missing keys ($vj)"

# Per-command --help: prints that command's synopsis, not the generic 'unknown command'.
for c in run lock learn rm prune; do
  h="$("$SLUICE" "$c" --help 2>/dev/null)"
  printf '%s' "$h" | grep -q "sluice $c" && ok "$c --help prints its synopsis" || bad "$c --help wrong: $h"
done

# parent_of (public-suffix aware): registrable parent below the longest matching suffix.
parent_is() { local got; got="$("$SLUICE" __parent "$1" 2>/dev/null)"; [ "$got" = "$2" ] && ok "parent_of($1) = $2" || bad "parent_of($1) = '$got' (want $2)"; }
parent_is a.example.com           example.com
parent_is x.y.example.com         example.com
parent_is foo.github.io           foo.github.io            # NOT github.io (the over-allow we fixed)
parent_is a.foo.github.io         foo.github.io
parent_is mybucket.s3.amazonaws.com mybucket.s3.amazonaws.com
parent_is host.co.uk              host.co.uk

# _collapsible: a public suffix is never offered as a .wildcard; a normal registrable domain is.
collapsible_is() { local got; got="$("$SLUICE" __collapsible "$1" 2>/dev/null)"; [ "$got" = "$2" ] && ok "collapsible($1) = $2" || bad "collapsible($1) = '$got' (want $2)"; }
collapsible_is github.io        no
collapsible_is co.uk            no
collapsible_is s3.amazonaws.com no
collapsible_is example.com      yes
collapsible_is foo.github.io    yes

# Two sibling multi-tenant hosts must NOT share a collapsible parent (so .s3.amazonaws.com is never offered).
pa="$("$SLUICE" __parent a.s3.amazonaws.com 2>/dev/null)"; pb="$("$SLUICE" __parent b.s3.amazonaws.com 2>/dev/null)"
[ "$pa" != "$pb" ] && ok "sibling buckets get distinct parents (no shared-apex wildcard)" || bad "siblings collapsed to '$pa'"

# Completion scripts parse.
bash -n "$ROOT/completion/sluice.bash" 2>/dev/null && ok "completion/sluice.bash parses (bash -n)" || bad "completion/sluice.bash bash -n failed"
if command -v zsh >/dev/null 2>&1; then
  zsh -n "$ROOT/completion/_sluice" 2>/dev/null && ok "completion/_sluice parses (zsh -n)" || bad "completion/_sluice zsh -n failed"
else
  printf '  note %s\n' "zsh not present - skipped zsh -n on completion/_sluice"
fi

finish
