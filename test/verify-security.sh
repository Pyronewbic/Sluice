#!/usr/bin/env bash
# Verify the security "danger knobs" behave as THREAT_MODEL.md claims: the SLUICE_ALLOW_IPS direct-egress
# escape hatch, the config_hash rebuild trigger, the SLUICE_PRELAUNCH host hook, SLUICE_STATE_DIRS
# persistence, worktree git-common-dir mounting, and read-only SLUICE_MOUNTS. Builds throwaway boxes
# (empty config) - heavy-ish, but the layer cache makes the repeats fast.
#   ./test/verify-security.sh
set -u

. "$(dirname "$0")/lib.sh"

BASE="$(mktemp -d)"
STORE="${XDG_STATE_HOME:-$HOME/.local/state}/sluice/sectest-state"   # host-side, OUTSIDE the temp tree
CONTAINERS="sluice-sectest-ips sluice-sectest-hash sluice-sectest-pre sluice-sectest-state sluice-sectest-wt sluice-sectest-mnt sluice-sectest-harden sluice-sectest-doh sluice-sectest-seccomp sluice-sectest-ro sluice-sectest-ws"
cleanup() {
  # The entrypoint chowns the project + state mounts to uid 1000; chown the host tree back (via a
  # root container off a built sectest image - wolfi-base may lack chown) so the host can rm it.
  local img=""
  for i in $CONTAINERS; do "$ENG" image inspect "$i" >/dev/null 2>&1 && { img="$i"; break; }; done
  [ -n "$img" ] && "$ENG" run --rm --user root -v "$BASE:$BASE" -v "$STORE:$STORE" \
    --entrypoint chown "$img" -R "$(id -u):$(id -g)" "$BASE" "$STORE" >/dev/null 2>&1 || true
  for c in $CONTAINERS; do "$ENG" rm -f -v "$c" >/dev/null 2>&1 || true; "$ENG" rmi -f "$c" >/dev/null 2>&1 || true; done
  rm -rf "$BASE" "$STORE" 2>/dev/null || true
}
trap cleanup EXIT

echo "== security escape-hatches =="

# --- SLUICE_ALLOW_IPS: a listed IP gets a direct-egress ACCEPT rule (bypassing squid) ---------------
ips="$BASE/ips"; mkdir -p "$ips"
printf 'SLUICE_NAME="sectest-ips"\nSLUICE_ALLOW_IPS="1.1.1.1"\nSLUICE_RUN_CMD="bash"\n' > "$ips/sluice.config.sh"
( cd "$ips" && "$SLUICE" build ) >/dev/null 2>&1 && ok "allow-ips: build" || bad "allow-ips: build"
( cd "$ips" && "$SLUICE" run true ) >/dev/null 2>&1   # bring the box up
rules="$("$ENG" exec --user root sluice-sectest-ips iptables -S OUTPUT 2>/dev/null)"
printf '%s\n' "$rules" | grep -qE -- '-A OUTPUT -d 1\.1\.1\.1(/32)? -j ACCEPT' \
  && ok "allow-ips: direct-egress ACCEPT rule present for the listed IP" \
  || bad "allow-ips: no ACCEPT rule for 1.1.1.1 (got: $rules)"
printf '%s\n' "$rules" | grep -q '8\.8\.8\.8' \
  && bad "allow-ips: an unlisted IP (8.8.8.8) unexpectedly has a rule" \
  || ok "allow-ips: no rule for an unlisted IP"
# Best-effort live confirmation (non-gating): direct egress reaches a non-HTTP port (1.1.1.1:853 DoT).
rc=0; ( cd "$ips" && "$SLUICE" run curl -sS --connect-timeout 6 --max-time 10 -o /dev/null https://1.1.1.1:853 ) >/dev/null 2>&1 || rc=$?
case "$rc" in
  7|28) note "allow-ips: live 1.1.1.1:853 not reachable from this runner (rc=$rc) - the rule assertion gates" ;;
  *)    ok "allow-ips: live - 1.1.1.1:853 reached (direct egress on a non-HTTP port)" ;;
esac
( cd "$ips" && "$SLUICE" stop ) >/dev/null 2>&1

# --- config_hash: hashed fields trigger a rebuild; SLUICE_ALLOW_DOMAINS is excluded -----------------
hash="$BASE/hash"; mkdir -p "$hash"
hashlabel() { "$ENG" image inspect -f '{{ index .Config.Labels "sluice.confighash" }}' sluice-sectest-hash 2>/dev/null; }
printf 'SLUICE_NAME="sectest-hash"\nSLUICE_DESC="one"\nSLUICE_RUN_CMD="bash"\n' > "$hash/sluice.config.sh"
( cd "$hash" && "$SLUICE" build ) >/dev/null 2>&1 && ok "config-hash: initial build" || bad "config-hash: initial build"
h1="$(hashlabel)"
printf 'SLUICE_NAME="sectest-hash"\nSLUICE_DESC="two"\nSLUICE_RUN_CMD="bash"\n' > "$hash/sluice.config.sh"
( cd "$hash" && "$SLUICE" build ) >/dev/null 2>&1; h2="$(hashlabel)"
{ [ -n "$h1" ] && [ "$h1" != "$h2" ]; } \
  && ok "config-hash: editing a hashed field (SLUICE_DESC) changed the hash" \
  || bad "config-hash: hash did not change on a hashed-field edit ($h1 -> $h2)"
printf 'SLUICE_NAME="sectest-hash"\nSLUICE_DESC="two"\nSLUICE_ALLOW_DOMAINS="example.org"\nSLUICE_RUN_CMD="bash"\n' > "$hash/sluice.config.sh"
( cd "$hash" && "$SLUICE" build ) >/dev/null 2>&1; h3="$(hashlabel)"
[ "$h2" = "$h3" ] \
  && ok "config-hash: SLUICE_ALLOW_DOMAINS edit did NOT change the hash (runtime override)" \
  || bad "config-hash: allowlist edit changed the hash ($h2 -> $h3)"

# --- SLUICE_PRELAUNCH: a host-side hook runs; a non-function value is rejected -----------------------
pre="$BASE/pre"; mkdir -p "$pre"; marker="$pre/prelaunch-ran"
cat > "$pre/sluice.config.sh" <<CFG
SLUICE_NAME="sectest-pre"
SLUICE_RUN_CMD="bash"
stage_marker() { touch "$marker"; }
SLUICE_PRELAUNCH="stage_marker"
CFG
( cd "$pre" && "$SLUICE" run true ) >/dev/null 2>&1
[ -f "$marker" ] && ok "prelaunch: host hook ran (marker created)" || bad "prelaunch: hook did not run"
( cd "$pre" && "$SLUICE" stop ) >/dev/null 2>&1
# Negative case in a FRESH dir: after the run above, the entrypoint chowned $pre to uid 1000 (on Linux),
# so rewriting its config in place would hit "Permission denied". A new dir stays host-owned. The
# non-function value is rejected host-side in start() (before any docker run), so the dir's image is moot.
prebad="$BASE/pre-bad"; mkdir -p "$prebad"
printf 'SLUICE_NAME="sectest-pre"\nSLUICE_RUN_CMD="bash"\nSLUICE_PRELAUNCH="definitely_not_a_function_xyz"\n' > "$prebad/sluice.config.sh"
if ( cd "$prebad" && "$SLUICE" run true ) >/dev/null 2>&1; then
  bad "prelaunch: a non-function value was NOT rejected"
else
  ok "prelaunch: a non-function value is rejected (die)"
fi
( cd "$prebad" && "$SLUICE" stop ) >/dev/null 2>&1

# --- SLUICE_STATE_DIRS: a persisted dir survives container recreation; abs/.. entries are rejected --
st="$BASE/state"; mkdir -p "$st"
printf 'SLUICE_NAME="sectest-state"\nSLUICE_STATE_DIRS=".cache"\nSLUICE_RUN_CMD="bash"\n' > "$st/sluice.config.sh"
( cd "$st" && "$SLUICE" run sh -c 'echo persisted-ok > "$HOME/.cache/marker.txt"' ) >/dev/null 2>&1
( cd "$st" && "$SLUICE" stop ) >/dev/null 2>&1   # remove the container
( cd "$st" && "$SLUICE" run true ) >/dev/null 2>&1   # recreate it cleanly (no start noise on the capture)
got="$( cd "$st" && "$SLUICE" run cat /home/sluice/.cache/marker.txt 2>/dev/null )"
[ "$got" = persisted-ok ] && ok "state-dirs: file survived container recreation" || bad "state-dirs: not persisted (got '$got')"
[ -f "$STORE/.cache/marker.txt" ] && ok "state-dirs: host store lives outside the project ($STORE)" || bad "state-dirs: host store missing at $STORE"
( cd "$st" && "$SLUICE" stop ) >/dev/null 2>&1
# Negative case in a FRESH dir (same reason as prelaunch: $st is now uid-1000-owned on Linux). The
# absolute path is rejected host-side in start() before any mount, so STORE/the image are untouched.
statebad="$BASE/state-bad"; mkdir -p "$statebad"
printf 'SLUICE_NAME="sectest-state"\nSLUICE_STATE_DIRS="/etc"\nSLUICE_RUN_CMD="bash"\n' > "$statebad/sluice.config.sh"
if ( cd "$statebad" && "$SLUICE" run true ) >/dev/null 2>&1; then
  bad "state-dirs: an absolute path was NOT rejected"
else
  ok "state-dirs: an absolute path is rejected (die)"
fi
( cd "$statebad" && "$SLUICE" stop ) >/dev/null 2>&1

# --- worktree: the git common dir is mounted, so git resolves inside the box ------------------------
repo="$BASE/repo"; mkdir -p "$repo"
( cd "$repo" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init ) >/dev/null 2>&1
wt="$BASE/wt"
( cd "$repo" && git worktree add -q "$wt" ) >/dev/null 2>&1
printf 'SLUICE_NAME="sectest-wt"\nSLUICE_RUN_CMD="bash"\n' > "$wt/sluice.config.sh"
if ( cd "$wt" && "$SLUICE" run git -C "$wt" status ) >/dev/null 2>&1; then
  ok "worktree: git resolves inside the box (common dir mounted)"
else
  bad "worktree: git failed inside the box (common dir not mounted?)"
fi
gitdir="$( cd "$wt" && "$SLUICE" run printenv SLUICE_GITDIR 2>/dev/null )"
[ -n "$gitdir" ] && ok "worktree: SLUICE_GITDIR is set ($gitdir)" || bad "worktree: SLUICE_GITDIR not set"
( cd "$wt" && "$SLUICE" stop ) >/dev/null 2>&1

# --- SLUICE_MOUNTS: a :ro bind is readable but not writable -----------------------------------------
mnt="$BASE/mnt"; mkdir -p "$mnt"; src="$mnt/ro-source.txt"; echo ro-content > "$src"
cat > "$mnt/sluice.config.sh" <<CFG
SLUICE_NAME="sectest-mnt"
SLUICE_MOUNTS="$src:/home/sluice/ro-mounted.txt:ro"
SLUICE_RUN_CMD="bash"
CFG
( cd "$mnt" && "$SLUICE" run true ) >/dev/null 2>&1   # bring the box up before capturing
got="$( cd "$mnt" && "$SLUICE" run cat /home/sluice/ro-mounted.txt 2>/dev/null )"
[ "$got" = ro-content ] && ok "mounts: a :ro bind is readable in the box" || bad "mounts: :ro bind not readable (got '$got')"
if ( cd "$mnt" && "$SLUICE" run sh -c 'echo x > /home/sluice/ro-mounted.txt' ) >/dev/null 2>&1; then
  bad "mounts: a :ro bind was writable (read-only not enforced)"
else
  ok "mounts: a :ro bind is read-only (write rejected)"
fi
( cd "$mnt" && "$SLUICE" stop ) >/dev/null 2>&1

# --- container hardening: no-new-privileges, pids-limit, narrowed caps, no in-box sudo -------------
hd="$BASE/harden"; mkdir -p "$hd"
printf 'SLUICE_NAME="sectest-harden"\nSLUICE_RUN_CMD="bash"\n' > "$hd/sluice.config.sh"
( cd "$hd" && "$SLUICE" run true ) >/dev/null 2>&1   # build + bring the box up
secopt="$("$ENG" inspect sluice-sectest-harden --format '{{.HostConfig.SecurityOpt}}' 2>/dev/null)"
printf '%s' "$secopt" | grep -q 'no-new-privileges' \
  && ok "harden: no-new-privileges set" || bad "harden: no-new-privileges missing ($secopt)"
pl="$("$ENG" inspect sluice-sectest-harden --format '{{.HostConfig.PidsLimit}}' 2>/dev/null)"
[ "${pl:-0}" -gt 0 ] && ok "harden: pids-limit set ($pl)" || bad "harden: pids-limit missing ($pl)"
ce="$("$ENG" exec --user sluice sluice-sectest-harden sh -c 'grep CapEff /proc/self/status | tr -d "\t "' 2>/dev/null)"
[ "$ce" = "CapEff:0000000000000000" ] && ok "harden: session has zero effective caps" || bad "harden: session caps ($ce)"
cb="$("$ENG" exec --user root sluice-sectest-harden sh -c 'grep CapBnd /proc/self/status | awk "{print \$2}"' 2>/dev/null)"
na=$(( 0x${cb:-0} & 0x1000 )); sa=$(( 0x${cb:-0} & 0x200000 )); mk=$(( 0x${cb:-0} & 0x8000000 ))  # NET_ADMIN keep; SYS_ADMIN/MKNOD drop
if [ "$na" -ne 0 ] && [ "$sa" -eq 0 ] && [ "$mk" -eq 0 ]; then
  ok "harden: cap bounding set narrowed (CapBnd=0x$cb; net_admin kept, sys_admin/mknod dropped)"
else
  bad "harden: cap set not narrowed as expected (CapBnd=0x$cb)"
fi
if "$ENG" exec sluice-sectest-harden sh -c 'command -v sudo' >/dev/null 2>&1; then
  bad "harden: setuid sudo still present in the image"
else
  ok "harden: no in-box sudo (privilege-escalation primitive removed)"
fi
( cd "$hd" && "$SLUICE" stop ) >/dev/null 2>&1

# --- DoH/DoT closure: a DoH resolver is denied even when allowlisted; SLUICE_ALLOW_DOH=1 opts in ---
doh="$BASE/doh"; mkdir -p "$doh"
printf 'SLUICE_NAME="sectest-doh"\nSLUICE_ALLOW_DOMAINS="cloudflare-dns.com"\nSLUICE_RUN_CMD="bash"\n' > "$doh/sluice.config.sh"
( cd "$doh" && "$SLUICE" run true ) >/dev/null 2>&1   # build + bring up
"$ENG" exec sluice-sectest-doh sh -c 'test -s /etc/squid/doh-endpoints.txt' \
  && ok "doh: denylist baked in the box" || bad "doh: denylist missing/empty"
"$ENG" exec sluice-sectest-doh grep -q '^http_access deny doh_host' /etc/squid.conf \
  && ok "doh: squid denies DoH hosts ahead of the allowlist" || bad "doh: deny rule missing from squid.conf"
if "$ENG" exec --user sluice sluice-sectest-doh curl -s -o /dev/null --max-time 8 https://cloudflare-dns.com/ 2>/dev/null; then
  bad "doh: an allowlisted DoH resolver was reachable (block failed)"
else
  ok "doh: an allowlisted DoH resolver is blocked (live)"
fi
# SLUICE_ALLOW_DOH=1 clears the denylist (opt back in)
printf 'SLUICE_NAME="sectest-doh"\nSLUICE_ALLOW_DOMAINS="cloudflare-dns.com"\nSLUICE_ALLOW_DOH=1\nSLUICE_RUN_CMD="bash"\n' > "$doh/sluice.config.sh"
( cd "$doh" && "$SLUICE" rebuild ) >/dev/null 2>&1
if "$ENG" exec sluice-sectest-doh sh -c 'test -s /etc/squid/doh-endpoints.txt'; then
  bad "doh: SLUICE_ALLOW_DOH=1 did not clear the denylist"
else
  ok "doh: SLUICE_ALLOW_DOH=1 clears the denylist (opt-in)"
fi
( cd "$doh" && "$SLUICE" stop ) >/dev/null 2>&1

# --- SLUICE_SECCOMP=hardened: the namespace/userns syscall class is blocked (opt-in) -------------
sc="$BASE/seccomp"; mkdir -p "$sc"
printf 'SLUICE_NAME="sectest-seccomp"\nSLUICE_EXTRA_PKGS="util-linux-misc"\nSLUICE_RUN_CMD="bash"\n' > "$sc/sluice.config.sh"   # util-linux-misc ships /usr/bin/unshare
( cd "$sc" && SLUICE_SECCOMP=hardened "$SLUICE" run true ) >/dev/null 2>&1   # build + up WITH the profile
"$ENG" exec sluice-sectest-seccomp sh -c 'command -v unshare >/dev/null' 2>/dev/null \
  && ok "seccomp: unshare binary present (real syscall test)" || bad "seccomp: unshare binary missing - test would false-pass"
"$ENG" inspect sluice-sectest-seccomp --format '{{.HostConfig.SecurityOpt}}' 2>/dev/null | grep -q seccomp \
  && ok "seccomp: hardened profile applied" || bad "seccomp: profile not applied"
# unshare(CLONE_NEWUSER) is allowed for an unprivileged user normally; the profile must EPERM it.
if "$ENG" exec --user sluice sluice-sectest-seccomp unshare -Ur true 2>/dev/null; then
  bad "seccomp: unshare(NEWUSER) succeeded (profile not blocking the userns vector)"
else
  ok "seccomp: unshare(NEWUSER) blocked"
fi
# normal fork/exec (clone without NEWUSER) is untouched by the masked filter
"$ENG" exec --user sluice sluice-sectest-seccomp sh -c 'echo hi | cat >/dev/null && echo ok' >/dev/null 2>&1 \
  && ok "seccomp: normal fork/exec still works" || bad "seccomp: normal fork/exec broke"
# default (no SLUICE_SECCOMP) leaves the engine profile - no sluice seccomp override
( cd "$sc" && "$SLUICE" stop ) >/dev/null 2>&1
( cd "$sc" && "$SLUICE" run true ) >/dev/null 2>&1
"$ENG" inspect sluice-sectest-seccomp --format '{{.HostConfig.SecurityOpt}}' 2>/dev/null | grep -q 'seccomp=' \
  && bad "seccomp: a sluice profile was applied without SLUICE_SECCOMP" \
  || ok "seccomp: default run uses the engine profile (no override)"
( cd "$sc" && "$SLUICE" stop ) >/dev/null 2>&1

# --- SLUICE_READONLY_ROOT=1: immutable rootfs, writable only where the box needs it ---------------
ro="$BASE/ro"; mkdir -p "$ro"
printf 'SLUICE_NAME="sectest-ro"\nSLUICE_RUN_CMD="bash"\n' > "$ro/sluice.config.sh"
( cd "$ro" && SLUICE_READONLY_ROOT=1 "$SLUICE" run true ) >/dev/null 2>&1   # build + bring up read-only
[ "$("$ENG" inspect sluice-sectest-ro --format '{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null)" = true ] \
  && ok "readonly: rootfs is read-only" || bad "readonly: ReadonlyRootfs not set"
if "$ENG" exec sluice-sectest-ro sh -c 'touch /evil' 2>/dev/null; then
  bad "readonly: the rootfs was writable (--read-only not enforced)"
else
  ok "readonly: a write to / is rejected"
fi
"$ENG" exec --user sluice sluice-sectest-ro sh -c 'touch /home/sluice/.p && rm /home/sluice/.p' 2>/dev/null \
  && ok "readonly: /home/sluice still writable (anon volume)" || bad "readonly: /home/sluice not writable"
# the box reaching 'ready' under read-only means the firewall + dnsmasq (--dns/upstream path) came up
"$ENG" exec sluice-sectest-ro sh -c 'grep -q registry.npmjs.org /etc/squid/allowlist.txt' 2>/dev/null \
  && ok "readonly: firewall/DNS came up under read-only (allowlist live)" || bad "readonly: firewall/DNS failed under read-only"
( cd "$ro" && "$SLUICE" stop ) >/dev/null 2>&1   # rm -v cleans the anon volumes

# --- SLUICE_WORKSPACE=overlay: host repo protected (read-only), box edits a copy, diff/apply -------
ws="$BASE/ws"; mkdir -p "$ws"
printf 'SLUICE_NAME="sectest-ws"\nSLUICE_WORKSPACE=overlay\nSLUICE_RUN_CMD="bash"\n' > "$ws/sluice.config.sh"
echo original > "$ws/file.txt"
( cd "$ws" && "$SLUICE" run sh -c 'echo MODIFIED > file.txt; echo NEWFILE > added.txt' ) >/dev/null 2>&1   # box edits its copy
[ "$(cat "$ws/file.txt")" = original ] \
  && ok "workspace: host repo protected (box edit didn't reach it)" || bad "workspace: host file.txt changed ($(cat "$ws/file.txt"))"
[ ! -f "$ws/added.txt" ] && ok "workspace: box's new file stayed in the copy" || bad "workspace: box's added.txt leaked to the host"
( cd "$ws" && "$SLUICE" diff 2>/dev/null ) | grep -q '^+MODIFIED' \
  && ok "workspace: diff shows the box's change" || bad "workspace: diff missing the change"
( cd "$ws" && SLUICE_YES=1 "$SLUICE" apply ) >/dev/null 2>&1
{ [ "$(cat "$ws/file.txt")" = MODIFIED ] && [ -f "$ws/added.txt" ]; } \
  && ok "workspace: apply wrote the changes back to the host" || bad "workspace: apply didn't update the host"
( cd "$ws" && "$SLUICE" stop ) >/dev/null 2>&1

finish
