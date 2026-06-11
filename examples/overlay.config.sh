# Protected workspace - let a tool edit a throwaway COPY, then review and apply.
#
# Usage: copy this file in, seed one file, then run `sluice`:
#   mkdir ov && cp examples/overlay.config.sh ov/sluice.config.sh
#   cd ov && echo original > notes.txt && sluice
# The box mounts your repo READ-ONLY and edits a throwaway overlay copy. After it exits,
# from your HOST shell:
#   cat notes.txt    # still "original" - and created.txt does NOT exist (repo untouched)
#   sluice diff      # the box's changes vs the original: notes.txt modified, created.txt added
#   sluice apply     # NOW write them back to the host repo: "1 added, 1 modified, 0 deleted"
# The gap between `diff` and `apply` is the human gate - run a YOLO agent or an untrusted
# tool, see what it did, and decide before anything touches your real files.

# --- protected workspace --------------------------------------------------------
# overlay: host repo read-only, the box writes to a per-box copy reviewed with diff/apply.
# It drops the git common-dir mount (see docs/hardening.md), so this demo edits a plain
# seeded file, not git refs.
SLUICE_WORKSPACE="overlay"

# A deterministic edit standing in for whatever the box does: modify the seeded file and
# add a new one. Both land in the overlay copy only - the host stays untouched until apply.
SLUICE_RUN_CMD='
echo "edited by the box" >> notes.txt
echo "new file written by the box" > created.txt
echo "== the box modified notes.txt and added created.txt - in its COPY only. =="
echo "On the host these are unchanged. Review with: sluice diff   then   sluice apply"
'
