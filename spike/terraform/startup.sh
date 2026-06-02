#!/bin/bash
# GCE startup script (runs as root on first boot): installs Docker + Kata Containers + nerdctl + CNI,
# wiring Kata as a containerd runtime so `nerdctl run --runtime io.containerd.kata.v2 ...` boots an
# own-kernel micro-VM. Mirrors the working spike setup.
#
# NOTE (learned the hard way): Docker CANNOT drive Kata 3.x - the legacy OCI runtime is gone and the
# Rust v2 shim rejects Docker's OCI spec ("invalid namespace type"). Use nerdctl/containerd, which
# generate Kata-friendly specs. Docker is installed only to BUILD images (then `docker save | nerdctl load`).
set -eux

KATA_VER="3.31.0"     # bump as releases land (assets are .tar.zst)
NERDCTL_VER="2.3.1"
CNI_VER="1.9.1"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y zstd curl

# --- Docker (for building images; containerd comes with it) ---
curl -fsSL https://get.docker.com | sh

# --- Kata Containers (static bundle: shim + QEMU/cloud-hypervisor/firecracker + guest kernel/rootfs) ---
base="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VER}"
for a in kata-static kata-tools-static; do
  curl -fsSL "${base}/${a}-${KATA_VER}-amd64.tar.zst" -o "/tmp/${a}.tar.zst"
  tar --zstd -xf "/tmp/${a}.tar.zst" -C /
done
# containerd finds the shim by name on PATH (runtime "io.containerd.kata.v2" -> containerd-shim-kata-v2).
ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2

# --- nerdctl (CLI) + CNI plugins (for container networking under Kata) ---
curl -fsSL "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VER}/nerdctl-${NERDCTL_VER}-linux-amd64.tar.gz" -o /tmp/nerdctl.tgz
tar -C /usr/local/bin -xzf /tmp/nerdctl.tgz nerdctl
mkdir -p /opt/cni/bin
curl -fsSL "https://github.com/containernetworking/plugins/releases/download/v${CNI_VER}/cni-plugins-linux-amd64-v${CNI_VER}.tgz" -o /tmp/cni.tgz
tar -C /opt/cni/bin -xzf /tmp/cni.tgz

# Smoke: an own-kernel micro-VM should report a kernel different from the host.
host_k="$(uname -r)"
guest_k="$(nerdctl run --runtime io.containerd.kata.v2 --rm alpine uname -r 2>/dev/null || echo FAILED)"

{
  echo "spike-ready $(date -u +%FT%TZ)"
  echo "docker:   $(docker --version)"
  echo "kata:     ${KATA_VER}   nerdctl: ${NERDCTL_VER}   cni: ${CNI_VER}"
  echo "host kernel:  ${host_k}"
  echo "kata kernel:  ${guest_k}   (differs from host => own-kernel micro-VM OK)"
} > /var/log/spike-ready
