#!/bin/sh
# core/replay.sh -> baked as /usr/local/bin/sluice-replay. Pinned-replay build helper (SLUICE_PIN=1):
# converge the installed package versions onto the closure recorded in sluice.pin. CONVERGES, never
# floats - exact-version installs no-op under the digest-pinned base, a project addition fetches the
# pinned version, and an aged-out apk version makes `apk add` ERROR so the build FAILS CLOSED (Wolfi is
# a rolling repo). Runs only when SLUICE_PIN=1 (guarded by the Dockerfile build-arg too); the claim it
# supports is EARNED by build()'s post-build inventory check, not by this script alone.
#
# $1 = phase: 'root' (apk / global npm / gem) or 'user' (pip --user / go / cargo). POSIX sh, busybox-safe.
set -eu

PIN=/usr/local/share/sluice-pin/sluice.pin
phase="${1:-root}"

[ "${SLUICE_PIN:-}" = 1 ] || exit 0    # only in pin mode; a normal build never reaches the install legs
# Fail closed on an arg/payload desync: SLUICE_PIN=1 was passed but no pin was copied into the context.
[ -s "$PIN" ] || { echo "[replay] FATAL: SLUICE_PIN=1 but $PIN is missing or empty - run 'sluice lock --pin'." >&2; exit 1; }

# Collect the pinned coordinates per ecosystem. Pin lines are "<eco>  <name>  <version> [checksum]";
# comment/blank/base lines fall through the case and are ignored.
_apk=""; _npm=""; _pip=""; _gem=""; _go=""; _cargo=""
while read -r eco name ver _rest; do
  case "$eco" in
    apk)   _apk="$_apk $name=$ver" ;;
    npm)   _npm="$_npm $name@$ver" ;;
    pip)   _pip="$_pip $name==$ver" ;;
    gem)   _gem="$_gem $name:$ver" ;;
    go)    _go="$_go $name@$ver" ;;
    cargo) _cargo="$_cargo $name=$ver" ;;
    *)     : ;;
  esac
done < "$PIN"

if [ "$phase" = root ]; then
  # apk: the security-relevant pin. Exact-version add; an aged-out version errors -> build fails closed.
  # shellcheck disable=SC2086  # deliberate word-split of the coordinate list
  [ -n "$_apk" ] && apk add --no-cache $_apk
  # shellcheck disable=SC2086
  [ -n "$_npm" ] && npm install -g $_npm
  if [ -n "$_gem" ]; then
    for g in $_gem; do gem install --conservative "${g%%:*}" -v "${g#*:}"; done
  fi
  exit 0
fi

# user phase (as the sluice user): pip --user, go install, cargo install. Best-effort for go/cargo (their
# coordinate can't always round-trip); build()'s post-build inventory check is the real gate on drift.
if [ -n "$_pip" ]; then
  # shellcheck disable=SC2086
  pip install --user --break-system-packages $_pip 2>/dev/null \
    || pip install --user $_pip
fi
if [ -n "$_go" ]; then
  for m in $_go; do go install "$m" 2>/dev/null || echo "[replay] note: could not replay go $m (path/version may not round-trip)" >&2; done
fi
if [ -n "$_cargo" ]; then
  for c in $_cargo; do cargo install "${c%%=*}" --version "${c#*=}" --locked 2>/dev/null \
    || echo "[replay] note: could not replay cargo $c" >&2; done
fi
exit 0
