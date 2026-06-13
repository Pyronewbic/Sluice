# LEARN demo: the blocked -> review -> live-allow loop, REAL commands. A run hits a host the
# firewall blocks (red receipt line), `sluice learn` reviews it per-host ([a]llow / [s]kip /
# [d]omain / [q]uit), the pick applies LIVE (squid reconfigure, no rebuild), and the rerun
# reaches the host - receipt flips to green "all egress was allowlisted".
#
# Reproduce (from the repo root; .demos/ is gitignored recording scratch):
#   d=.demos/learn; rm -rf "$d"; mkdir -p "$d" .demos/render
#   cp assets/demos/learn-demo.config.sh "$d/sluice.config.sh"
#   ( cd "$d" && SLUICE_NO_BANNER=1 SLUICE_YES=1 sluice run true )   # build + warm
#   printf 'export PATH="$PWD/bin:$PATH"; export SLUICE_NO_BANNER=1 DOCKER_CLI_HINTS=false; export PS1="$ "; cd .demos/learn\n' > .demos/learn-setup.sh
#   vhs assets/demos/learn-demo.tape                                 # writes .demos/render/learn-demo.gif
#   cp .demos/render/learn-demo.gif assets/learn-demo.gif

Output ".demos/render/learn-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 640
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/learn-setup.sh; clear"
Enter
Sleep 1000ms
Show

# 1. the run trips the firewall: curl fails, the receipt names the blocked host.
Sleep 600ms
Type "sluice"
Sleep 700ms
Enter
Sleep 5000ms

# 2. review the block per-host; 'a' allows it - applied live, no rebuild.
Type "sluice learn"
Sleep 700ms
Enter
Sleep 3000ms
Type "a"
Sleep 800ms
Enter
Sleep 3200ms

# 3. rerun: the host is reachable and the receipt is green - learn closed the loop, live, no rebuild.
Type "sluice"
Sleep 700ms
Enter
Sleep 4500ms
Sleep 1000ms
