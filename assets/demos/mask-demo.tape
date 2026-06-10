# MASK demo: SLUICE_MASK in one contrast - the host reads the secret, the box cannot. REAL
# commands: `cat .env` on the host shows the key; the same cat inside the box prints nothing,
# and `wc -c .env` proves the path still exists but holds 0 bytes (an empty read-only bind
# shadows it).
#
# Reproduce (from the repo root; .demos/ is gitignored recording scratch):
#   d=.demos/mask; rm -rf "$d"; mkdir -p "$d" .demos/render
#   cp assets/demos/mask-demo.config.sh "$d/sluice.config.sh"
#   echo 'OPENAI_API_KEY=sk-live-do-not-commit' > "$d/.env"
#   ( cd "$d" && SLUICE_NO_BANNER=1 SLUICE_YES=1 sluice run true )   # build + warm
#   printf 'export PATH="$PWD/bin:$PATH"; export SLUICE_NO_BANNER=1 DOCKER_CLI_HINTS=false; export PS1="$ "; cd .demos/mask\n' > .demos/mask-setup.sh
#   vhs assets/demos/mask-demo.tape                                  # writes .demos/render/mask-demo.gif
#   cp .demos/render/mask-demo.gif assets/mask-demo.gif

Output ".demos/render/mask-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 420
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/mask-setup.sh; clear"
Enter
Sleep 1000ms
Show

# 1. the config masks .env*; the host of course still reads it.
Sleep 600ms
Type "grep MASK sluice.config.sh"
Sleep 700ms
Enter
Sleep 1800ms
Type "cat .env"
Sleep 700ms
Enter
Sleep 2200ms

# 2. the box cannot - same path, no contents.
Type "sluice run cat .env"
Sleep 700ms
Enter
Sleep 3200ms

# 3. the path still exists in the box; it just holds nothing.
Type "sluice run wc -c .env"
Sleep 700ms
Enter
Sleep 3500ms
Sleep 1500ms
