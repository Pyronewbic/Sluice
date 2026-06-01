# HERO demo (probe + learn combined): prove the cage with real probes (non-root, no host secrets),
# then watch the egress receipt change across a `sluice learn`. One run is blocked from google + openai;
# learn collapses the two google subdomains to a .google.com wildcard and skips openai (live, no rebuild);
# the next run's receipt shows google reached while openai stays blocked. All real commands.
#
# Reproduce (from the repo root):
#   d=/tmp/sluice-cage-demo; rm -rf "$d"; mkdir -p "$d"
#   cp assets/demos/cage-demo.config.sh "$d/sluice.config.sh"
#   ( cd "$d" && SLUICE_NO_BANNER=1 SLUICE_YES=1 sluice run true )   # build + warm the box
#   printf 'export SLUICE_NO_BANNER=1 DOCKER_CLI_HINTS=false; export PS1="$ "; cd %s\n' "$d" > /tmp/cage-setup.sh
#   vhs assets/demos/cage-demo.tape                                  # writes /tmp/cage-demo.gif
#   cp /tmp/cage-demo.gif assets/cage-demo.gif

Output "/tmp/cage-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 620
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source /tmp/cage-setup.sh; clear"
Enter
Sleep 1200ms
Show

# 1. prove the cage: non-root uid, and the host SSH key isn't mounted.
Sleep 600ms
Type "sluice run id -u"
Sleep 700ms
Enter
Sleep 1500ms

Type "sluice run sh -c 'cat ~/.ssh/id_rsa'"
Sleep 700ms
Enter
Sleep 1800ms

# 2. run the app: the receipt shows github reached, google + openai blocked by the firewall.
Type "sluice"
Sleep 700ms
Enter
Sleep 5000ms

# 3. learn is a per-host review: collapse the two google subdomains to a .google.com wildcard, skip openai.
Type "sluice learn"
Sleep 700ms
Enter
Sleep 2600ms
Type "y"
Enter
Sleep 2000ms
Type "s"
Enter
Sleep 2600ms

# 4. applied live, no rebuild: the next run reaches google while openai stays blocked.
Type "sluice"
Sleep 700ms
Enter
Sleep 5500ms
Sleep 1200ms
