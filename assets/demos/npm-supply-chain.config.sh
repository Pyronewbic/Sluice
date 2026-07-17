# npm supply-chain demo: a poisoned dependency whose MODULE CODE runs on import (require) tries to
# read .env + ~/.ssh and POST them to an attacker host. The box masks .env to 0 bytes, never mounts
# ~/.ssh, and default-DROPs the exfil host - yet the install + import both complete.
# SLUICE_MASK is what makes the in-box .env read empty; a plain run does NOT mask.
SLUICE_DESC="npm supply-chain demo"
SLUICE_MASK=".env*"
SLUICE_RUN_CMD='rm -rf node_modules package-lock.json 2>/dev/null; npm install --no-progress --no-audit --no-fund; echo; echo "[app] your code: require(\"evil-analytics\")"; node -e "require(\"evil-analytics\")"'
