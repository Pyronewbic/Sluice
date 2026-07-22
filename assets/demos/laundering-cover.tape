# LAUNDERING-COVER demo: the limit sluice cannot close by allowlisting, and the knob that turns it
# into a refusal. The fixture is a REAL agent posture - the claude preset allows api.anthropic.com
# because the agent needs it. That host is POST-capable, so data can be written OUT through it; we
# splice, never decrypt, so the request body is never inspected (THREAT_MODEL "allowed-host
# laundering"). Beat 2 runs and the box WORKS, with a yellow note naming the risk. Beat 3 sets
# SLUICE_STRICT_LAUNDERING=1 and the same command REFUSES, exit 1.
#
# Why the exit code is the whole point: `resolve_engine` runs ~725 lines BEFORE warn_laundering, and
# `die` also exits 1 - so a tape that renders `|| echo "refused (exit $?)"` on a host with no engine
# prints its success line for the WRONG reason and proves nothing. This tape shows the refusal text
# itself (which only warn_laundering emits) and requires a working engine, verified by beat 2 having
# just built and run the same box. Verified 2026-07-21 on docker-desktop: strict exit=1, plain exit=0.
#
# Honest limits: SLUICE_LAUNDERING_OK=1 silences the note (it does not add a control); the matcher is
# a curated host LIST (src/10-egress-helpers.sh laundering_host) - an allowed host it does not know
# is not flagged; and strict mode refuses the RUN, it does not inspect traffic. The guarantee is
# "you are told, and can hard-fail", not "laundering is prevented".
#
# Reproduce (from the repo root; .demos/ is gitignored recording scratch):
#   d=.demos/laundering; rm -rf "$d"; mkdir -p "$d" .demos/render
#   cp assets/demos/laundering-cover.config.sh "$d/sluice.config.sh"
#   ( cd "$d" && git init -q )                                                                  # own .git => no git-common-dir warning
#   printf 'export PATH="$PWD/bin:$PATH"\nexport SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1 DOCKER_CLI_HINTS=false\nexport PS1="$ "\ncd .demos/laundering\n' > .demos/laundering-setup.sh
#   ( cd "$d" && PATH="$PWD/../../bin:$PATH" SLUICE_NO_BANNER=1 SLUICE_YES=1 sluice build )      # build off-camera
#   vhs assets/demos/laundering-cover.tape                                                       # writes .demos/render/laundering-cover.gif
#   gifsicle -O3 --colors 128 .demos/render/laundering-cover.gif -o assets/laundering-cover.gif

Output ".demos/render/laundering-cover.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1400
Set Height 620
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/laundering-setup.sh"
Enter
Sleep 1000ms
Type "SLUICE_YES=1 sluice build >/dev/null 2>&1"
Enter
Sleep 8000ms
Type "clear"
Enter
Sleep 1000ms
Show

# beat 1: the fixture - a real agent posture. ONE allowed host, and it is the one the agent needs.
Sleep 500ms
Type "cat sluice.config.sh"
Sleep 600ms
Enter
Sleep 4000ms

# clear between beats (off camera) so each starts fresh - no scroll accumulation (bloats the gif).
Hide
Type "clear"
Enter
Sleep 200ms
Show

# beat 2: it RUNS (exit 0). The yellow note names the risk: an allowlisted host an attacker can also
# write to. Allowlisting cannot close this - we splice, not decrypt, so the body is never inspected.
Type "sluice run true; echo exit=$?"
Sleep 600ms
Enter
# the box boots on camera here - exit=0 only lands at ~5.5s, so dwell long enough to READ it.
Sleep 9000ms

Hide
Type "clear"
Enter
Sleep 200ms
Show

# beat 3: same command, strict mode. Now it REFUSES - red, exit 1, before the box ever boots. The
# refusal TEXT is the proof: only warn_laundering emits it, so this cannot pass for a die() elsewhere.
Type "SLUICE_STRICT_LAUNDERING=1 sluice run true; echo exit=$?"
Sleep 600ms
Enter
Sleep 6000ms
