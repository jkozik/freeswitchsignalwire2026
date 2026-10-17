#!/bin/bash
# Root-owned wrapper so the zabbix user never sees the ESL password and never
# gets docker-group (host-root-equivalent) access. Runs via a scoped sudoers
# NOPASSWD rule — see /etc/sudoers.d/zabbix-freeswitch.
#
# Deliberately whitelist-only: takes a check NAME, not a raw fs_cli command
# string, so a compromised zabbix agent can't pass arbitrary text through to
# FreeSWITCH's `system` API (shell escape). Add new checks as new case arms,
# never as free-form pass-through.
set -euo pipefail

ESL_PW_FILE=/home/jkozik/projects/freeswitchsignalwire2026/configs/storage/esl-password.txt
CONTAINER=freeswitch

if [ ! -r "$ESL_PW_FILE" ]; then
  echo "ERROR: $ESL_PW_FILE not readable" >&2
  exit 1
fi
ESL_PW=$(head -1 "$ESL_PW_FILE")

fs_cli() {
  docker exec "$CONTAINER" fs_cli -p "$ESL_PW" -x "$1"
}

case "${1:-}" in
  gateway_status)
    fs_cli 'sofia status gateway signalwire'
    ;;
  ext_1001_reg)
    fs_cli 'sofia status profile internal reg'
    ;;
  loopback_test)
    # Originates a self-contained test call into the dedicated 9999 no-ring
    # extension (dialplan/default/01_acZabbixHealthcheck.xml) — never rings
    # a real phone. Success/failure is the +OK/-ERR prefix on originate's
    # own response (confirmed empirically, see freeswitch_zabbix_monitoring
    # memory), not anything parsed from call state.
    fs_cli 'originate loopback/9999/default &park'
    ;;
  changeme_check)
    # Checks one representative var from each independently-generated file
    # (vars.local.xml and ext-passwords.local.xml) — see
    # freeswitch_secrets_templating memory. Caller must treat this output as
    # sensitive: it is literally the real ESL password if things are healthy.
    # NOTE: fs_cli only returns the LAST -x result when given multiple -x
    # flags in one invocation (confirmed empirically) — so this runs two
    # separate docker exec calls instead of one with two -x flags.
    fs_cli 'global_getvar esl_password'
    fs_cli 'global_getvar ext_1001_password'
    ;;
    
  *)
    echo "ERROR: unknown check '${1:-}'" >&2
    exit 1
    ;;
esac
