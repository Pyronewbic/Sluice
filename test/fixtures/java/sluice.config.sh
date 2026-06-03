# sluice config - scaffolded by 'sluice init' (detected: java/maven).
SLUICE_EXTRA_PKGS="openjdk-21 maven"
SLUICE_PORTS="8080"            # ports to publish (the app MUST bind 0.0.0.0)
SLUICE_RUN_CMD="export JAVA_HOME=/usr/lib/jvm/java-21-openjdk; export PATH=\"\$JAVA_HOME/bin:\$PATH\"; mvn -q compile exec:java"
SLUICE_ALLOW_DOMAINS="repo.maven.apache.org repo1.maven.org"    # runtime egress hosts (or run 'sluice learn')
