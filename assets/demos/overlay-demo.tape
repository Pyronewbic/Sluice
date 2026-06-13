# OVERLAY demo (docs/hardening + examples 'review-and-apply'): the human gate for a YOLO agent.
# REAL commands. SLUICE_WORKSPACE=overlay mounts the repo READ-ONLY; the box edits a throwaway COPY.
# beat 1 RUNS the box (it edits notes.txt + adds created.txt IN ITS COPY, and the workspace nudge
# points at diff/apply); beat 2 proves the HOST is untouched; beat 3 `sluice diff` reviews the box's
# changes; beat 4 `sluice apply` is the [y/N] human gate that finally writes them back. Showing the
# box run first is the fix for the old cut, where the diff's changes appeared from nowhere.
#
# Recorded OUTSIDE the repo (~/ov, a short non-git path) so `sluice diff` shows READABLE paths (the
# deep in-repo worktree path wrapped across lines and buried the diff) and prints no git-common-dir
# notice. `sluice apply` MUTATES the seed - the recipe re-seeds before each record.
#
# Reproduce (from the repo root; .demos/ is gitignored render scratch):
#   R="$PWD"; P=~/ov; rm -rf "$P"; mkdir -p "$P" .demos/render
#   cp examples/overlay.config.sh "$P/sluice.config.sh"
#   echo original > "$P/notes.txt"
#   ( cd "$P" && PATH="$R/bin:$PATH" SLUICE_NO_BANNER=1 SLUICE_YES=1 sluice build ) >/dev/null 2>&1  # build off-camera (NO run: beat 1 is the first run -> one append)
#   docker rm -f sluice-ov >/dev/null 2>&1   # fresh box+overlay so beat 1 is a clean first edit
#   printf 'export PATH="$PWD/bin:$PATH"; export SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1 DOCKER_CLI_HINTS=false; export PS1="$ "; cd ~/ov\n' > .demos/overlay-setup.sh
#   vhs assets/demos/overlay-demo.tape   # writes .demos/render/overlay-demo.gif
#   cp .demos/render/overlay-demo.gif assets/overlay-demo.gif
#   ( echo original > "$P/notes.txt"; rm -f "$P/created.txt" )   # re-seed before re-recording

Output ".demos/render/overlay-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 700
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/overlay-setup.sh; clear"
Enter
Sleep 1000ms
Show

# 1. run the box: it edits notes.txt + adds created.txt IN ITS COPY; the workspace nudge points at diff/apply.
Sleep 600ms
Type "sluice"
Sleep 700ms
Enter
Sleep 4500ms

# 2. the host is provably untouched: notes.txt still 'original', created.txt absent.
Type "cat notes.txt; ls created.txt"
Sleep 700ms
Enter
Sleep 3000ms

# 3. review what the box did: a unified diff of its copy vs the original (.git excluded).
Type "sluice diff"
Sleep 700ms
Enter
Sleep 4000ms

# 4. the [y/N] human gate - answer y, and ONLY NOW the host changes.
Type "sluice apply"
Sleep 700ms
Enter
Sleep 1200ms
Type "y"
Sleep 600ms
Enter
Sleep 3500ms
