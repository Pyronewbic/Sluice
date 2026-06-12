# AGENT hero demo (README hero): drop a coding agent into a locked box and watch it stay caged.
# REAL commands. `sluice agent` lists the real presets (claude row reads its live host auth status);
# `sluice run cat .env` prints NOTHING (SLUICE_MASK=".env*" shadows the seeded secret); `sluice
# egress` shows the ledger - api.anthropic.com reached (allowed), pypi.org blocked (off-allowlist).
# The egress rows come from a deterministic off-camera warm-up run (pypi/anthropic), so the ledger
# is real and survives the intervening cat .env beat.
#
# Reproduce (from the repo root; .demos/ is gitignored recording scratch):
#   d=.demos/agent; rm -rf "$d"; mkdir -p "$d" .demos/render
#   cp assets/demos/agent-demo.config.sh "$d/sluice.config.sh"
#   ( cd "$d" && echo 'OPENAI_API_KEY=sk-live-do-not-commit' > .env )
#   export PATH="$PWD/bin:$PATH" SLUICE_NO_BANNER=1 ANTHROPIC_API_KEY=sk-demo
#   ( cd "$d" && SLUICE_YES=1 sluice run true )                                   # build + warm
#   ( cd "$d" && SLUICE_YES=1 sluice run sh -c 'curl -s -m6 -o /dev/null https://pypi.org; curl -s -m6 -o /dev/null https://api.anthropic.com; true' )  # real reached/blocked rows
#   vhs assets/demos/agent-demo.tape                                             # writes .demos/render/agent-demo.gif
#   cp .demos/render/agent-demo.gif assets/agent-demo.gif

Output ".demos/render/agent-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 580
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/agent-setup.sh; clear"
Enter
Sleep 1000ms
Show

# 1. list the real coding-agent presets - claude row reads live host auth (green "(set)").
Sleep 600ms
Type "sluice agent"
Sleep 700ms
Enter
Sleep 4000ms

# 2. the agent can't read the seeded secret: SLUICE_MASK=".env*" shadows it (empty, 0 bytes).
Type "sluice run cat .env"
Sleep 700ms
Enter
Sleep 1500ms
Type "sluice run wc -c .env"
Sleep 700ms
Enter
Sleep 3000ms

# 3. the egress ledger: api.anthropic.com reached (allowed) green, pypi.org blocked (off-allowlist) red.
Type "sluice egress"
Sleep 700ms
Enter
Sleep 4000ms
Sleep 1000ms
