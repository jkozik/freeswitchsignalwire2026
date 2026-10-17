#!/bin/bash
# Zabbix UserParameter script: freeswitch.ext1001.registered
# Returns 1 if extension 1001 has an active registration, 0 otherwise
# (not registered, or docker/ESL unreachable).
#
# Verified 2026-09-09 against both real states: registered (after the
# client's stale password was fixed) and not-registered.
set -euo pipefail

OUTPUT=$(sudo -n /usr/local/bin/fs_cli_zabbix.sh ext_1001_reg 2>/dev/null) || { echo 0; exit 0; }

# Registration entries are multi-line blocks; find the one for 1001@... and
# check whether its Status line contains "Registered".
MATCH=$(echo "$OUTPUT" | awk '
  /^User:[[:space:]]+1001@/ { found=1 }
  found && /^Status:/ { print; exit }
')

if echo "$MATCH" | grep -q "Registered"; then
  echo 1
else
  echo 0
fi
