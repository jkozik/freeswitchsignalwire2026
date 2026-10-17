#!/bin/bash
set -e

# Generate vars.local.xml from .env (via env_file) so secrets never sit in the
# git-tracked vars.xml. Fails loudly if .env is missing an entry, rather than
# writing a blank value into the XML.
for v in ESLPASSWORD MYMOBILEPHONENUMBERWITHPLUS MYSIGNALWIREPHONENUMBERWITHPLUS RTPSTARTPORT RTPENDPORT; do
  if [ -z "${!v}" ]; then
    echo "ERROR: $v is not set (check .env against .env.example)" >&2
    exit 1
  fi
done

sed \
  -e "s|__ESL_PASSWORD__|${ESLPASSWORD}|g" \
  -e "s|__MY_MOBILE_NUMBER__|${MYMOBILEPHONENUMBERWITHPLUS}|g" \
  -e "s|__MY_SIGNALWIRE_NUMBER__|${MYSIGNALWIREPHONENUMBERWITHPLUS}|g" \
  -e "s|__RTP_START_PORT__|${RTPSTARTPORT}|g" \
  -e "s|__RTP_END_PORT__|${RTPENDPORT}|g" \
  /etc/freeswitch/vars.local.xml.template > /etc/freeswitch/vars.local.xml

# Generate per-extension SIP passwords from configs/storage/extension-passwords.txt
# (gitignored; that file is the source of truth, not .env — see README.md
# "Restricted extensions"). Same fail-loudly approach: no file, no boot.
EXT_PW_FILE=/var/lib/freeswitch/storage/extension-passwords.txt
if [ ! -f "$EXT_PW_FILE" ]; then
  echo "ERROR: $EXT_PW_FILE not found — generate extension passwords first" >&2
  exit 1
fi
{
  echo "<include>"
  # NOTE: spelled out [0-9][0-9][0-9] rather than [0-9]{3} — this runs under
  # the container's mawk, which silently matches nothing on {n} interval
  # syntax (confirmed empirically 2026-09-09; gawk on the host had masked
  # this for months since testing happened there, not in the container).
  awk '$1 ~ /^1[0-9][0-9][0-9]$/ { printf "  <X-PRE-PROCESS cmd=\"set\" data=\"ext_%s_password=%s\"/>\n", $1, $2 }' "$EXT_PW_FILE"
  echo "</include>"
} > /etc/freeswitch/ext-passwords.local.xml

# Sanity check: fail loudly if the awk pattern matched suspiciously few
# entries, instead of silently booting with extensions on their CHANGEME
# placeholder (exactly the failure mode freeswitch.secrets.placeholder_detected
# in Zabbix exists to catch — but this catches it at boot time instead).
EXT_COUNT=$(grep -c 'X-PRE-PROCESS' /etc/freeswitch/ext-passwords.local.xml || true)
if [ "$EXT_COUNT" -lt 1 ]; then
  echo "ERROR: ext-passwords.local.xml generation produced 0 entries — check the awk pattern against $EXT_PW_FILE" >&2
  exit 1
fi

# Ensure FreeSwitch owns its directories in case volumes are mounted as root
chown -R freeswitch:freeswitch /etc/freeswitch /var/lib/freeswitch /var/log/freeswitch 2>/dev/null || true

exec "$@"
