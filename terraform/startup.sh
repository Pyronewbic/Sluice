#!/bin/bash
# GCE startup script (root, first boot). Base: Docker + the toolchain to run `make test` on Linux
# (git, make, shellcheck, jq, container-structure-test). If instance metadata enable-kata=1 it also
# installs the Kata micro-VM stack (containerd/nerdctl + CNI) to exercise SLUICE_RUNTIME=kata.
set -eux

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git make jq shellcheck curl ca-certificates rsync zstd

# --- Docker: builds + runs the sandbox; containerd ships with it ---
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# --- container-structure-test (base-image invariants: `make structure`) ---
curl -fsSLo /usr/local/bin/container-structure-test \
  https://storage.googleapis.com/container-structure-test/latest/container-structure-test-linux-amd64
chmod +x /usr/local/bin/container-structure-test

kata_line="kata: disabled (enable_kata=false)"
enable_kata="$(curl -fsS -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/enable-kata 2>/dev/null || echo 0)"

if [ "$enable_kata" = "1" ]; then
  # NOTE (learned the hard way): Docker CANNOT drive Kata 3.x - the legacy OCI runtime is gone and the
  # Rust v2 shim rejects Docker's OCI spec ("invalid namespace type"). Use nerdctl/containerd, which
  # generate Kata-friendly specs. Docker (above) only BUILDS images (then `docker save | nerdctl load`).
  KATA_VER="3.31.0" # bump as releases land (assets are .tar.zst)
  NERDCTL_VER="2.3.1"
  CNI_VER="1.9.1"

  # Kata static bundle: shim + QEMU/cloud-hypervisor/firecracker + guest kernel/rootfs.
  base="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VER}"
  for a in kata-static kata-tools-static; do
    curl -fsSL "${base}/${a}-${KATA_VER}-amd64.tar.zst" -o "/tmp/${a}.tar.zst"
    tar --zstd -xf "/tmp/${a}.tar.zst" -C /
  done
  # containerd finds the shim by name on PATH (runtime "io.containerd.kata.v2" -> containerd-shim-kata-v2).
  ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2

  # nerdctl (CLI) + CNI plugins (container networking under Kata).
  curl -fsSL "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VER}/nerdctl-${NERDCTL_VER}-linux-amd64.tar.gz" -o /tmp/nerdctl.tgz
  tar -C /usr/local/bin -xzf /tmp/nerdctl.tgz nerdctl
  mkdir -p /opt/cni/bin
  curl -fsSL "https://github.com/containernetworking/plugins/releases/download/v${CNI_VER}/cni-plugins-linux-amd64-v${CNI_VER}.tgz" -o /tmp/cni.tgz
  tar -C /opt/cni/bin -xzf /tmp/cni.tgz

  # Smoke: an own-kernel micro-VM reports a kernel different from the host.
  guest_k="$(nerdctl run --runtime io.containerd.kata.v2 --rm alpine uname -r 2>/dev/null || echo FAILED)"
  kata_line="kata: ${KATA_VER} nerdctl ${NERDCTL_VER} cni ${CNI_VER}; host $(uname -r) vs guest ${guest_k}"
fi

# --- VHS render stack: vhs + ttyd + ffmpeg + headless chromium + fonts, to record assets/demos/*.tape
# on this VM (used for the Kata demo, which is Linux-only). Gated on enable-vhs so the plain test-runner
# stays lean. vhs is pinned to the SAME version rendered locally so the VM gif matches the macOS set. ---
vhs_line="vhs: disabled (enable_vhs=false)"
enable_vhs="$(curl -fsS -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/enable-vhs 2>/dev/null || echo 0)"

if [ "$enable_vhs" = "1" ]; then
  VHS_VER="0.11.0"  # keep == the local vhs used for the other demos, for identical rendering
  TTYD_VER="1.7.7"
  apt-get install -y ffmpeg chromium fonts-jetbrains-mono gifsicle
  curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VER}/ttyd.x86_64" -o /usr/local/bin/ttyd
  chmod +x /usr/local/bin/ttyd
  curl -fsSL "https://github.com/charmbracelet/vhs/releases/download/v${VHS_VER}/vhs_${VHS_VER}_Linux_x86_64.tar.gz" -o /tmp/vhs.tgz
  tar -C /tmp -xzf /tmp/vhs.tgz
  install -m755 "$(find /tmp -type f -name vhs | head -1)" /usr/local/bin/vhs
  vhs_line="vhs: ${VHS_VER} ttyd ${TTYD_VER} chromium $(chromium --version 2>/dev/null | awk '{print $2}')"
fi

{
  echo "sluice-provision-done $(date -u +%FT%TZ)"
  echo "docker:   $(docker --version)"
  echo "$kata_line"
  echo "$vhs_line"
} > /var/log/sluice-provision-done
