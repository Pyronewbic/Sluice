# sluice config - scaffolded by 'sluice init' (detected: dotnet).
SLUICE_EXTRA_PKGS="dotnet-10-sdk"
SLUICE_PORTS="8080"            # ports to publish (the app MUST bind 0.0.0.0)
SLUICE_RUN_CMD="dotnet run --urls http://0.0.0.0:8080"
SLUICE_ALLOW_DOMAINS="api.nuget.org www.nuget.org"    # runtime egress hosts (or run 'sluice learn')
