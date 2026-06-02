# DOCTOR demo: the one-screen posture panel. Off-camera the box is locked and a real run hits a
# blocked host, then `sluice doctor` shows the whole health view - engine, the mounted project dir
# (the box's only host path), image freshness, the supply-chain lock (in sync), published ports,
# auth env, and the LAST run's blocked egress with a learn hint. All real, colorized to the sluice
# convention (green ok, red blocked, dim neutral, bold header).
#
# Reproduce (from the repo root):
#   d=/tmp/sluice-doctor-demo; rm -rf "$d"; mkdir -p "$d"
#   cp assets/demos/doctor-demo.config.sh "$d/sluice.config.sh"
#   ( cd "$d" && SLUICE_NO_BANNER=1 SLUICE_YES=1 OPENAI_API_KEY=sk-demo sluice run true )  # build + warm
#   printf 'export SLUICE_NO_BANNER=1 DOCKER_CLI_HINTS=false OPENAI_API_KEY=sk-demo; export PS1="$ "; cd %s\n' "$d" > /tmp/doctor-setup.sh
#   vhs assets/demos/doctor-demo.tape                                # writes /tmp/doctor-demo.gif
#   cp /tmp/doctor-demo.gif assets/doctor-demo.gif

Output "/tmp/doctor-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 460
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source /tmp/doctor-setup.sh; clear"
Enter
Sleep 1000ms
# off-camera: lock the box so the panel shows a green supply-chain 'in sync' line
Type "sluice lock"
Enter
Sleep 6000ms
# off-camera: a real run so the egress line is populated (openai isn't allowlisted -> blocked)
Type "sluice run sh -c 'curl -s -m6 -o /dev/null https://api.openai.com; true'"
Enter
Sleep 3500ms
Type "clear"
Enter
Sleep 300ms
Show

Sleep 600ms
Type "sluice doctor"
Sleep 700ms
Enter
Sleep 4500ms
Sleep 1200ms
