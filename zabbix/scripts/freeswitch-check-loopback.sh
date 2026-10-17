#!/bin/bash
# Zabbix UserParameter script: freeswitch.loopback.ok
# Places a self-contained test call into the 9999 no-ring extension (never
# rings a real phone). Returns 1 if origination succeeded, 0 otherwise
# (call setup failed, dialplan missing, or docker/ESL unreachable).
set -euo pipefail

OUTPUT=$(sudo -n /usr/local/bin/fs_cli_zabbix.sh loopback_test 2>/dev/null) || { echo 0; exit 0; }

if echo "$OUTPUT" | grep -q '^+OK'; then
  echo 1
else
  echo 0
fi
