# Nix inside a sluice - a reproducible toolchain, contained at runtime.
#
#   mkdir nixdemo && cp examples/nix.config.sh nixdemo/sluice.config.sh
#   cd nixdemo && sluice            # builds (installs Nix + bakes the tool), then runs it
#
# The "they compose, not merge" demo: Nix gives a reproducible, pinned toolchain; sluice gives the
# security boundary - you run the former inside the latter. Nix does ALL its fetching at BUILD time
# (the installer, cache.nixos.org, the nixpkgs flake from GitHub), where the sluice has free egress.
# At RUNTIME the box is fully locked (default-DROP egress, non-root, this-dir-only) and the baked
# tool is just a binary in the store - it needs no network. Heavy: the /nix store is ~1.2GB, so the
# image is ~1.5GB; the first build downloads Nix + the closure.

# xz is what the Nix installer needs to unpack; coreutils/curl/bash are already in the base.
SLUICE_EXTRA_PKGS="xz"

# Root build step (free egress): give single-user Nix a /nix store the sluice user can write.
SLUICE_SETUP_ROOT_CMDS='mkdir -p /nix && chown sluice:sluice /nix'

# As the sluice user (free egress at build): install single-user Nix, then bake a PINNED tool into
# the image. Swap nixpkgs#hello for your real toolchain; the pinned commit makes it reproducible
# (bump it if cache.nixos.org ever GCs that rev).
SLUICE_SETUP_CMDS='curl -L https://nixos.org/nix/install -o /tmp/nix-install &&
  sh /tmp/nix-install --no-daemon --yes &&
  export USER=sluice &&
  . "$HOME/.nix-profile/etc/profile.d/nix.sh" &&
  nix profile add --extra-experimental-features "nix-command flakes" "github:NixOS/nixpkgs/e9a7635a57597d9754eccebdfc7045e6c8600e6b#hello"'

# Runtime needs NO egress - the tool is already in the store. (We add the profile bin to PATH
# directly; sourcing nix.sh works too, but only if USER is exported - Docker exec sets HOME, not USER.)
SLUICE_RUN_CMD='export PATH="$HOME/.nix-profile/bin:$PATH"; hello'

# Live-Nix variant (optional): to run `nix run nixpkgs#...` LIVE inside the box at runtime, allow
# Nix's substituter + channel below (the nixpkgs flake source comes from GitHub, already base-allowed).
# SLUICE_ALLOW_DOMAINS="cache.nixos.org channels.nixos.org releases.nixos.org"
