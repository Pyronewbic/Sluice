#!/usr/bin/env bash
# Operate the sluice Linux test-runner VM (provisioned by terraform/).
#   sluice-vm.sh start|stop|status|ssh [cmd...]|sync|test [make-targets...]
#
# `test` syncs the local working tree to the VM and runs the given make targets (default: the full
# CI-equivalent gate). The tree is tar-piped over `gcloud ssh`, so no external-IP SSH rule or key
# wrangling is needed; the VM's git submodules + .git are preserved (excluded from the sync).
#
# Config comes from the environment (so no account/project ids live in the repo). Point it at your
# runner with:  eval "$(cd terraform && terraform output -raw sluice_vm_env)"
#   SLUICE_VM_PROJECT   (required)  GCP project id
#   SLUICE_VM_ACCOUNT   (optional)  gcloud account; unset = the active one
#   SLUICE_VM_ZONE      (default us-central1-a)
#   SLUICE_VM_INSTANCE  (default sluice-ci)
#   SLUICE_LOCAL        (default: this repo's root)
set -euo pipefail

PROJECT="${SLUICE_VM_PROJECT:?set SLUICE_VM_PROJECT (eval terraform output -raw sluice_vm_env)}"
ZONE="${SLUICE_VM_ZONE:-us-central1-a}"
VM="${SLUICE_VM_INSTANCE:-sluice-ci}"
if [ -n "${SLUICE_LOCAL:-}" ]; then
  LOCAL="$SLUICE_LOCAL"
else
  LOCAL="$(cd "$(dirname "$0")" && git rev-parse --show-toplevel 2>/dev/null)" || LOCAL="$(cd "$(dirname "$0")" && pwd)"
fi
DEFAULT_TARGETS="lint build-check test-unit test-engine test-acceptance test-security structure"

gc()       { gcloud "$@" --project="$PROJECT" ${SLUICE_VM_ACCOUNT:+--account="$SLUICE_VM_ACCOUNT"}; }
vmssh()    { gc compute ssh "$VM" --zone="$ZONE" --quiet "$@"; }
vmstatus() { gc compute instances describe "$VM" --zone="$ZONE" --format='value(status)' 2>/dev/null || echo ABSENT; }

sync_tree() {
  [ "$(vmstatus)" = RUNNING ] || { echo "VM is $(vmstatus) - run: sluice-vm.sh start" >&2; exit 1; }
  # MIRROR, not overlay: clear the previous sync before extracting, so a file that no longer exists
  # locally cannot linger on the VM. `tar -x` alone left a stale test/*.bats from whichever branch was
  # synced last, which then ran as an orphan (and trips the lane-membership check). Only the VM-only
  # paths survive - .git and the vendored bats submodules, all three excluded from the tar below.
  tar -cf - -C "$LOCAL" --exclude='.git' --exclude='test/bats' --exclude='test/test_helper' . \
    | vmssh --command 'set -e
        mkdir -p ~/sluice/test
        find ~/sluice      -mindepth 1 -maxdepth 1 ! -name .git ! -name test        -exec rm -rf {} +
        find ~/sluice/test -mindepth 1 -maxdepth 1 ! -name bats ! -name test_helper -exec rm -rf {} +
        tar -xf - -C ~/sluice'
}

cmd="${1:-}"; shift || true
case "$cmd" in
  start)  gc compute instances start "$VM" --zone="$ZONE" ;;
  stop)   gc compute instances stop "$VM" --zone="$ZONE" ;;
  status) echo "$VM: $(vmstatus)" ;;
  ssh)    vmssh ${1:+--command "$*"} ;;
  sync)   sync_tree; echo "synced $LOCAL -> $VM:~/sluice" ;;
  test)
    sync_tree
    vmssh --command "cd ~/sluice && export SLUICE_NO_UPDATE_CHECK=1
      for t in ${*:-$DEFAULT_TARGETS}; do echo \"########## make \$t ##########\"; make \$t; echo \"##### RC[\$t]=\$? #####\"; done"
    ;;
  *) echo "usage: sluice-vm.sh {start|stop|status|ssh [cmd...]|sync|test [make-targets...]}" >&2; exit 1 ;;
esac
