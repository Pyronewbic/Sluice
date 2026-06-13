# OPERATOR demo: sluice as a fleet console, REAL commands - surface the OTHER demos don't show.
# `sluice ls --running` lists every running box + posture (stack/allow/ports/lock/path; one box is
# locked), `sluice ls --egress --running` adds the per-box blocked count, `sluice -b <box> egress
# --export` ships one box's tamper-evident audit log as JSONL (each record hash-links to the prior -
# the integrity half NOT shown by the firewall demo's --verify), and `sluice doctor` drills into one
# box's health. A 3-box fleet (node blog, python api [locked], claude bot) at shallow ~/sf paths so the
# wide table reads on camera; `--running` scopes the view to the fleet.
#
# Reproduce (from the repo root; .demos/ is gitignored recording scratch):
#   bash assets/demos/operator-fleet.sh          # stops other demo boxes, builds + runs ~/sf/{blog,api,bot}
#   printf 'export PATH="$PWD/bin:$PATH"; export SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1 DOCKER_CLI_HINTS=false ANTHROPIC_API_KEY=sk-demo; export PS1="$ "; cd ~/sf/bot\n' > .demos/op-setup.sh
#   vhs assets/demos/operator-demo.tape          # writes .demos/render/operator-demo.gif
#   cp .demos/render/operator-demo.gif assets/operator-demo.gif

Output ".demos/render/operator-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 760
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/op-setup.sh; clear"
Enter
Sleep 1000ms
Show

# 1. the fleet: every running box on the machine + its posture (api is locked).
Sleep 600ms
Type "sluice ls --running"
Sleep 700ms
Enter
Sleep 4500ms

# 2. add the per-box egress: how many hosts each box was blocked from reaching.
Type "sluice ls --egress --running"
Sleep 700ms
Enter
Sleep 4500ms

# 3. ship one box's tamper-evident audit log (each record hash-links to the previous).
Type "sluice -b sluice-api egress --export | tail -1 | jq '{box, totals, prev, self}'"
Sleep 700ms
Enter
Sleep 5500ms

# 4. drill into one box's health: the posture panel + in-box hazard warnings.
Type "sluice doctor"
Sleep 700ms
Enter
Sleep 6500ms
Sleep 1500ms
