# Own-kernel demo (SLUICE_RUNTIME=kata): the answer to "containers share the host kernel, so they
# aren't a real boundary." No extra allowlist and no runtime setting live here on purpose - the tape
# sets SLUICE_RUNTIME=kata inline so the container->micro-VM toggle stays on camera. Default-drop
# egress, the non-root uid-1000 'sluice' user, and the project-dir-only mount are always on and are
# unchanged under Kata; the recording proves each still holds while the box runs its own kernel.
SLUICE_RUN_CMD='uname -r'
