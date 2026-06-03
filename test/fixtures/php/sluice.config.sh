# sluice config - scaffolded by 'sluice init' (detected: php).
SLUICE_EXTRA_PKGS="php composer"
SLUICE_PORTS="8000"            # ports to publish (the app MUST bind 0.0.0.0)
SLUICE_RUN_CMD="composer install && php -S 0.0.0.0:8000"
SLUICE_ALLOW_DOMAINS="repo.packagist.org packagist.org"    # runtime egress hosts (or run 'sluice learn')
