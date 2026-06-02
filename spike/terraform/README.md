# Micro-VM isolation spike (Kata, then Edera) - infra

Codifies the GCP nested-virt VM used to test the question: **does sluice's in-box egress stack
(iptables REDIRECT -> squid + the sysctls) come up when the "container" is a micro-VM with its own
kernel?** `startup.sh` installs Docker + Kata + nerdctl + CNI so the box boots ready to test.

## Use

```bash
# auth as the personal account (the VM lives in its project)
gcloud auth application-default login   # account: kan.nam.dev2@gmail.com
terraform init
terraform apply                          # creates the VM (~$0.19/hr, n1-standard-4)

# wait ~2-3 min for the startup script, then:
terraform output -raw readiness_check | bash    # prints /var/log/spike-ready (host vs kata kernel)
eval "$(terraform output -raw ssh)"             # SSH in over IAP

terraform destroy                        # tear it all down
```

## Running the sluice-under-Kata test (on the box)

```bash
git clone --depth 1 https://github.com/Pyronewbic/Sluice.git
# Docker 29.5.x bug workaround: COPY --chmod=0644 sets the auto-created /usr/local/share to 0644
# (no execute -> uid 1000 can't traverse it). Force the dir mode:
sed -i 's|COPY --chmod=0644 sluice.config.sh /usr/local/share/sluice.config.sh|&\nRUN chmod 0755 /usr/local/share|' Sluice/core/Dockerfile

mkdir -p /tmp/empty && printf 'SLUICE_RUN_CMD="bash"\n' > /tmp/empty/sluice.config.sh && chmod 644 /tmp/empty/sluice.config.sh
( cd /tmp/empty && sudo ~/Sluice/bin/sluice build )          # build with docker
sudo docker save sluice-empty | sudo nerdctl load            # docker -> containerd (nerdctl ns)

sudo nerdctl run -d --name sk --runtime io.containerd.kata.v2 \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  --sysctl net.ipv4.conf.all.route_localnet=1 \
  --sysctl net.ipv6.conf.all.disable_ipv6=1 \
  --sysctl net.ipv6.conf.default.disable_ipv6=1 sluice-empty
sudo nerdctl logs sk                                         # expect "[sluice] ready"
sudo nerdctl exec sk uname -r                                # differs from host => own kernel
sudo nerdctl exec sk curl -fsS --max-time 8 https://example.com   # blocked (good)
sudo nerdctl exec sk curl -sS  --max-time 15 https://registry.npmjs.org/   # reached (good)
```

## Findings (2026-06-02)

- **GCP nested virt works** for this (N1; N2 was capacity-exhausted across zones). `vmx` + `/dev/kvm` confirmed.
- **Kata 3.31 runs own-kernel micro-VMs** (guest kernel `6.18.28` vs host `6.17.0-gcp`) with networking.
- **Docker cannot drive Kata 3.x** (legacy OCI runtime removed; Rust v2 shim rejects Docker's OCI spec:
  "invalid namespace type", even with the qemu config / `--cgroupns=host`). The supported path is
  **containerd + nerdctl**.
- **sluice runs UNCHANGED under Kata** (via nerdctl): the firewall comes up (`[sluice] ready`), `--sysctl`
  applies in the guest, the iptables nat REDIRECT is present, and the egress matrix passes (example.com
  blocked, npmjs reached, direct-IP 1.1.1.1 blocked). The "policy travels with the box" property holds.
- **Two real sluice follow-ups surfaced:**
  1. `core/Dockerfile`: the `COPY --chmod=0644 sluice.config.sh ...` breaks on Docker 29.5.x (parent dir
     gets 0644). Pre-create `/usr/local/share` (0755) before the COPY.
  2. A future `SLUICE_RUNTIME` knob can't be a plain Docker `--runtime` flag - it needs a containerd/nerdctl
     run path (or Edera's `protect` launch interface). The core stack itself needs no change.

## Next: Edera (Track B)

Same VM. Request access at edera.dev/contact for the GAR installer key, install Edera standalone, then
`protect workload launch` the sluice image with the same caps/sysctls and re-run the egress matrix.
