# sluice config - scaffolded by 'sluice init' (detected: ruby-3.3).
# Review the values, then run 'sluice' (or 'sluice learn' to discover the egress allowlist).
# NOTE: ruby is best-effort - set SLUICE_RUN_CMD/SLUICE_PORTS for your app.

SLUICE_EXTRA_PKGS="ruby-3.3 ruby-3.3-dev build-base linux-headers"
SLUICE_SETUP_CMDS='mkdir -p "$HOME/.local/bin" "$HOME/.gem/ruby" && gem install --no-document --bindir "$HOME/.local/bin" --install-dir "$HOME/.gem/ruby" bundler'   # build-time, free egress, before the firewall
SLUICE_PORTS="4567"            # ports to publish (the app MUST bind 0.0.0.0)
SLUICE_RUN_CMD='export GEM_HOME="$HOME/.gem/ruby"; export PATH="$HOME/.local/bin:$PATH"; bundle install && ruby app.rb'
SLUICE_ALLOW_DOMAINS="rubygems.org index.rubygems.org"    # runtime egress hosts (or run 'sluice learn')
