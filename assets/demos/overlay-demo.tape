# OVERLAY demo: review-and-apply. The box edits a THROWAWAY COPY of your repo; the host files
# stay untouched until you read the diff and apply it yourself. The diff-then-apply gap is the
# human gate for a YOLO agent - `sluice apply` shows a [y/N] confirm before anything touches
# your real files.
#
# Reproduce (from the repo root; .demos/ is gitignored recording scratch):
#   d=.demos/overlay; rm -rf "$d"; mkdir -p "$d" .demos/render
#   cp examples/overlay.config.sh "$d/sluice.config.sh"
#   ( cd "$d" && echo original > notes.txt )
#   ( cd "$d" && PATH="$PWD/../../bin:$PATH" SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1 \
#       DOCKER_CLI_HINTS=false SLUICE_YES=1 sluice )   # build + warm, box left RUNNING
#   printf 'export PATH="$PWD/bin:$PATH"\nexport SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1 DOCKER_CLI_HINTS=false\nexport PS1="$ "\ncd .demos/overlay\n' > .demos/overlay-setup.sh
#   vhs assets/demos/overlay-demo.tape   # writes assets/overlay-demo.gif (apply WRITES the host seed)
# NOTE the host seed (.demos/overlay/notes.txt + created.txt) is mutated by the on-camera apply;
# re-seed before re-recording.

Output "assets/overlay-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1300
Set Height 640
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/overlay-setup.sh; clear"
Enter
Sleep 1000ms
Show

# 1. the host baseline: notes.txt is still "original" and created.txt does NOT exist.
#    The box edited a throwaway copy - the real repo is provably untouched.
Sleep 600ms
Type "cat notes.txt"
Sleep 500ms
Enter
Sleep 1200ms
Type "ls created.txt"
Sleep 500ms
Enter
Sleep 3000ms

# 2. review what the box did: a unified diff of its copy vs the original.
#    notes.txt modified (+edited by the box), created.txt added. .git excluded.
Type "sluice diff"
Sleep 700ms
Enter
Sleep 4000ms

# 3. apply it yourself - the [y/N] gate is the human checkpoint. Answer y; NOW the host changes.
Type "sluice apply"
Sleep 700ms
Enter
Sleep 1500ms
Type "y"
Sleep 600ms
Enter
Sleep 4000ms
