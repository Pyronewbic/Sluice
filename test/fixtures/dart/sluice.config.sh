# sluice config - scaffolded by 'sluice init' (detected: dart).
SLUICE_EXTRA_PKGS="dart"
SLUICE_PORTS="8080"            # ports to publish (the app MUST bind 0.0.0.0)
SLUICE_RUN_CMD="dart pub get && dart run"
SLUICE_ALLOW_DOMAINS="pub.dev pub.dartlang.org"    # runtime egress hosts (or run 'sluice learn')
