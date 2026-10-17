#!/bin/bash
# Zabbix UserParameter script: freeswitch.gateway.state
# Returns 1 if the SignalWire gateway is REGED, 0 for anything else
# (NOREG, TRYING, FAILED, missing, or docker/ESL unreachable).
set -euo pipefail

OUTPUT=$(sudo -n /usr/local/bin/fs_cli_zabbix.sh gateway_status 2>/dev/null) || { echo 0; exit 0; }

STATE=$(echo "$OUTPUT" | awk -F'\t' '/^State/ {print $2}')

if [ "$STATE" = "REGED" ]; then
  echo 1
else
  echo 0
fi
