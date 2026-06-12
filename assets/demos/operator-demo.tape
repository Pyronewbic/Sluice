# OPERATOR demo: sluice as a fleet console, REAL commands. `sluice ls --running` shows every running
# box on the machine + its posture (stack/allow/ports/lock/path), `sluice ls --egress --running` adds
# the per-box blocked count (it execs into each box), and `sluice doctor` drills into one box's health
# (engine, mount, the in-box hazard warnings, allowlist, the last run's blocked egress with a learn
# hint). A small 3-box fleet (a node blog, a python api, a claude agent) at shallow ~/sf paths so the
# wide table reads on camera; `--running` scopes the view to the fleet.
#
# Reproduce (from the repo root; .demos/ is gitignored recording scratch):
#   bash assets/demos/operator-fleet.sh          # stops other demo boxes, builds ~/sf/{blog,api,bot}
#   printf 'export PATH="$PWD/bin:$PATH"; export SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1 DOCKER_CLI_HINTS=false ANTHROPIC_API_KEY=sk-demo; export PS1="$ "; cd ~/sf/bot\n' > .demos/op-setup.sh
#   vhs assets/demos/operator-demo.tape          # writes .demos/render/operator-demo.gif
#   cp .demos/render/operator-demo.gif assets/operator-demo.gif

Output ".demos/render/operator-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 700
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/op-setup.sh; clear"
Enter
Sleep 1000ms
Show

# 1. the fleet: every running box on the machine + its posture.
Sleep 600ms
Type "sluice ls --running"
Sleep 700ms
Enter
Sleep 5000ms

# 2. add the per-box egress: how many hosts each box was blocked from reaching.
Type "sluice ls --egress --running"
Sleep 700ms
Enter
Sleep 4500ms

# 3. drill into one box's health (run from the claude agent box).
Type "sluice doctor"
Sleep 700ms
Enter
Sleep 7000ms
Sleep 1500ms
