# KATA demo: an own-kernel proof. `uname -r` on the HOST, then `SLUICE_RUNTIME=kata sluice run uname
# -r` INSIDE the box - a DIFFERENT kernel version, because Kata runs the box as a micro-VM with its
# OWN kernel (containerd + nerdctl + the containerd-shim-kata-v2 shim), not a namespace over the host
# kernel. Then the same cage under that different kernel: `sluice run id` is still uid=1000(sluice)
# (non-root), and an off-allowlist fetch (pypi.org) is still BLOCKED while the workload keeps going.
# The at-exit egress receipt is the box's own ledger of that block - proven, not claimed.
#
# LINUX-ONLY, NEEDS A LIVE KATA BOX. Render on the terraform VM with enable_kata=true (nested virt,
# n1): containerd + nerdctl + Kata installed, `containerd-shim-kata-v2` on PATH, rootful containerd.
# The host and in-box `uname -r` MUST actually differ or the demo is void (terraform/startup.sh
# prints "host <k> vs guest <k>" after provisioning - confirm they differ before rendering).
#
# Reproduce (on the Kata VM, from the repo root; .demos/ is gitignored recording scratch):
#   d=.demos/kata; rm -rf "$d"; mkdir -p "$d" .demos/render
#   cp assets/demos/kata-demo.config.sh "$d/sluice.config.sh"
#   printf 'export PATH="$PWD/bin:$PATH"\nexport SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1 DOCKER_CLI_HINTS=false\nexport PS1="$ "\ncd .demos/kata\n' > .demos/kata-setup.sh
#   # off-camera: $ENGINE builds the image, sluice loads it into containerd and boots the micro-VM.
#   ( cd "$d" && PATH="$PWD/../../bin:$PATH" SLUICE_RUNTIME=kata SLUICE_YES=1 sluice run true )
#   vhs assets/demos/kata-demo.tape                                       # writes .demos/render/kata-demo.gif
#   cp .demos/render/kata-demo.gif assets/kata-demo.gif
# The Hide block re-sources env and ensures the (already-built + loaded) micro-VM is up, then clears.

Output ".demos/render/kata-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 700
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/kata-setup.sh"
Enter
Sleep 1000ms
# ensure the Kata micro-VM is up (built by $ENGINE + loaded into containerd off-camera by the recipe).
Type "SLUICE_RUNTIME=kata SLUICE_YES=1 sluice run true >/dev/null 2>&1"
Enter
Sleep 8000ms
Type "clear"
Enter
Sleep 500ms
Show

# beat 1: the HOST kernel - what a plain shared-kernel container would run under.
Sleep 500ms
Type "uname -r"
Sleep 500ms
Enter
Sleep 2500ms

# beat 2 (the proof): the box's OWN kernel. SLUICE_RUNTIME=kata runs it as a Kata micro-VM with its
# own Linux kernel - a DIFFERENT version than the host, so this is a real VM boundary, not a namespace.
Type "SLUICE_RUNTIME=kata sluice run uname -r"
Sleep 700ms
Enter
Sleep 4000ms

# beat 3: the cage is unchanged under Kata - the session is still the non-root uid-1000 'sluice' user.
Type "SLUICE_RUNTIME=kata sluice run id"
Sleep 700ms
Enter
Sleep 3500ms

# beat 4: default-drop egress still holds inside the micro-VM - an off-allowlist fetch is BLOCKED and
# the workload keeps going (fails soft). The at-exit receipt is the box's own ledger of that block.
Type `SLUICE_RUNTIME=kata sluice run sh -c 'curl -fsS -o /dev/null --max-time 8 https://pypi.org 2>/dev/null && echo "reached pypi.org - NOT blocked" || echo "pypi.org BLOCKED - off-allowlist, fetch refused"; echo "workload continued past the block"'`
Sleep 700ms
Enter
Sleep 6000ms
