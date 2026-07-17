# terraform - the sluice Linux test-runner (+ optional Kata micro-VM)

Codifies the GCP VM used to run sluice's suite on real Linux Docker - the environment `make test`
can't fully reproduce on macOS (e.g. an older `mawk` without `--re-interval`, iptables/nft backends,
the entrypoint's uid-1000 chown). Default is a cheap **e2 Docker runner**; `enable_kata=true` turns it
into the **nested-virt Kata micro-VM** rig that proved `SLUICE_RUNTIME=kata` (the old `spike/`).

## Provision

```bash
gcloud auth application-default login          # the account whose project this lives in
cp terraform.tfvars.example terraform.tfvars   # set project = "<your-gcp-project-id>" (gitignored)
terraform init
terraform apply                                # e2-standard-2 Docker runner (~$0.067/hr running)
```

Point the operate helper at it, then run the gate:

```bash
eval "$(terraform output -raw sluice_vm_env)"  # exports SLUICE_VM_PROJECT/_ZONE/_INSTANCE
../sluice-vm.sh test                            # sync local tree -> VM, run the full gate on Linux
../sluice-vm.sh stop                            # stop when idle (only disk is billed)
```

`sluice-vm.sh` (repo root) does `start|stop|status|ssh|sync|test`; it reads `SLUICE_VM_*` from the env,
so it carries no account/project ids. `test` tar-pipes the working tree over `gcloud ssh` (no external
SSH), preserving the VM's submodules, and runs the given make targets (default: the full gate).

## Kata micro-VM mode

```bash
terraform apply -var enable_kata=true          # n1-standard-4 + nested virt + Kata/nerdctl/CNI (~$0.19/hr)
terraform output -raw readiness_check | bash   # host vs guest kernel (own-kernel micro-VM => differ)
```

Nested virt is only on N1/N2/C2/C3 (never E2/AMD), hence the machine-type switch.

## Cost

Both modes are billed per running-hour; **stop when idle** and you pay only for the boot disk
(~$1-2/mo for 30 GB). `terraform destroy` removes everything.

## Kata findings (2026-06, historical - the spike this replaced)

- GCP nested virt works (N1; N2 was capacity-exhausted). `vmx` + `/dev/kvm` confirmed.
- Kata 3.31 runs own-kernel micro-VMs (guest `6.18.x` vs host `6.17-gcp`) with networking.
- Docker cannot drive Kata 3.x (legacy OCI runtime removed; Rust v2 shim rejects Docker's spec) - the
  supported path is containerd + nerdctl.
- **sluice runs UNCHANGED under Kata** (via nerdctl): the firewall comes up (`[sluice] ready`),
  `--sysctl` applies in the guest, the iptables NAT REDIRECT is present, and the egress matrix passes
  (example.com blocked, npmjs reached, direct-IP 1.1.1.1 blocked). "Policy travels with the box" holds.
- Negative result on a user-space-kernel runtime (`runsc`): no in-container iptables NAT, so the in-box
  firewall can't boot - no `SLUICE_RUNTIME` arm added. A second isolation track (Edera) is pending vendor access.
