# POLICY-REFUSAL demo: the org policy that says no. A central egress policy (deny host +
# deny-ip 169.254.169.254/32, the cloud-metadata IP) that a developer's LOCAL sluice.config.sh
# cannot loosen. The local config crosses BOTH lines: it allowlists the denied host AND opens a
# direct-IP SUPERNET (169.254.169.0/24) that OVERLAPS the denied /32 - the #76 H1 bypass, where a
# supernet used to sail past a base-only /32 check and reach metadata. sluice REFUSES TO RUN
# PRE-BUILD (no box ever starts), naming the violated directive, and exits non-zero. Then a
# COMPLIANT config runs clean under the SAME policy.
#
# In production the policy is /etc/sluice/policy.conf (root-owned, MDM) or a signed
# SLUICE_POLICY_URL; the demo models it with a file:// SLUICE_POLICY_URL (see docs/policy.md).
#
# Reproduce (from the repo root; .demos/ is gitignored recording scratch):
#   d=.demos/policy-refusal; rm -rf "$d"; mkdir -p "$d" .demos/render
#   cp assets/demos/policy-refusal.policy.conf       "$d/policy.conf"
#   cp assets/demos/policy-refusal.refuse.config.sh  "$d/refuse.config.sh"
#   cp assets/demos/policy-refusal.compliant.config.sh "$d/compliant.config.sh"
#   cp "$d/refuse.config.sh" "$d/sluice.config.sh"          # active starts as the crossing config
#   cat > .demos/policy-refusal-setup.sh <<'EOF'
#   export PATH="$PWD/bin:$PATH"
#   export SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1 DOCKER_CLI_HINTS=false
#   export SLUICE_POLICY_URL="file://$PWD/.demos/policy-refusal/policy.conf"
#   export SLUICE_YES=1
#   export PS1="$ "
#   cd .demos/policy-refusal
#   EOF
#   ( cd "$d" && git init -q )                              # own .git => no git-common-dir warning on the compliant run
#   # warm the compliant box off-camera so the Hide-block build is a no-op:
#   ( cd "$d" && cp compliant.config.sh sluice.config.sh \
#       && PATH="$PWD/../../bin:$PATH" SLUICE_NO_BANNER=1 SLUICE_YES=1 \
#          SLUICE_POLICY_URL="file://$PWD/policy.conf" sluice build >/dev/null 2>&1 \
#       && cp refuse.config.sh sluice.config.sh )
#   vhs assets/demos/policy-refusal.tape                    # writes .demos/render/policy-refusal.gif
#   gifsicle -O3 --colors 128 .demos/render/policy-refusal.gif -o assets/policy-refusal.gif   # optimize into assets
# The Hide block below (re)builds the compliant box + stages the crossing config, then clears - off camera.

Output ".demos/render/policy-refusal.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 700
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/policy-refusal-setup.sh"
Enter
Sleep 1000ms
# build the COMPLIANT box off camera (warm if the reproduce pre-build ran) so beat 4 warm-starts.
Type "cp compliant.config.sh sluice.config.sh"
Enter
Sleep 400ms
Type "SLUICE_YES=1 sluice build >/dev/null 2>&1"
Enter
Sleep 12000ms
# stage the crossing config as the active sluice.config.sh for the on-camera refusal beats.
Type "cp refuse.config.sh sluice.config.sh"
Enter
Sleep 400ms
Type "clear"
Enter
Sleep 500ms
Show

# beat 1: the org's line. A denied host, and deny-ip 169.254.169.254/32 - the cloud-metadata IP.
Sleep 500ms
Type "cat policy.conf"
Sleep 600ms
Enter
Sleep 3500ms

# beat 2: the developer's local config crosses BOTH lines - allowlists the denied host, and opens
# a direct-IP SUPERNET (169.254.169.0/24) that contains the denied /32.
Type "cat sluice.config.sh"
Sleep 600ms
Enter
Sleep 3800ms

# beat 3: run it. sluice REFUSES before building - names the overlapping deny-ip, exits non-zero,
# no box ever starts. This is the #76 H1 supernet-overlap fix.
Type `sluice || echo "refused (exit $?), no box built"`
Sleep 600ms
Enter
Sleep 4800ms

# beat 4: swap to the COMPLIANT config. Same policy, and now it builds + runs clean (warm start).
Type "cp compliant.config.sh sluice.config.sh && sluice"
Sleep 600ms
Enter
Sleep 6500ms
