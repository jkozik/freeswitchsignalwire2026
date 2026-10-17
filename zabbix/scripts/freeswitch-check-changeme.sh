#!/bin/bash
# Zabbix UserParameter script: freeswitch.secrets.placeholder_detected
# Returns 1 if entrypoint.sh's secrets-templating generation silently failed
# (a checked var is still on its vars.xml CHANGEME placeholder), 0 if healthy.
#
# SECURITY: the underlying check reads real secret values (the ESL password,
# an extension password). This script MUST NEVER print $OUTPUT or any part
# of it — only the 0/1 verdict below. Zabbix's history/dashboard would
# otherwise store the actual ESL password in plaintext.
set -euo pipefail

OUTPUT=$(sudo -n /usr/local/bin/fs_cli_zabbix.sh changeme_check 2>/dev/null) || { echo 0; exit 0; }

if echo "$OUTPUT" | grep -q "CHANGEME"; then
  echo 1
else
  echo 0
fi
