# Homebrew formula for sluice.
#
# This lives in a tap (e.g. github.com/Pyronewbic/homebrew-tap) so users can:
#   brew install Pyronewbic/tap/sluice
# At release time, point `url` at the tag tarball and fill `sha256`:
#   shasum -a 256 <(curl -fsSL <url>)
class Sluice < Formula
  desc "Sandboxed, egress-firewalled container runner for projects and coding agents"
  homepage "https://github.com/Pyronewbic/Sluice"
  url "https://github.com/Pyronewbic/Sluice/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # TODO: fill at release
  license "Apache-2.0"

  # Runtime needs docker or podman, which Homebrew shouldn't manage - documented, not a dep.

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/sluice"
  end

  test do
    # Runs without docker/podman: a bogus engine forces a deterministic, well-defined error.
    output = shell_output("SLUICE_ENGINE=__nope__ #{bin}/sluice 2>&1", 1)
    assert_match "SLUICE_ENGINE=__nope__ not found", output
  end
end
