#!/bin/bash
# Places a real round-trip test call through the SignalWire PSTN trunk.
# Usage: ./test-pstn-call.sh [destination-number-in-E.164]
#   No argument: calls your own mobile number (MYMOBILEPHONENUMBERWITHPLUS in .env).
# Answering runs FreeSWITCH's echo app — talk, and you should hear your own
# voice echoed back. Hang up (or wait ~30s if unanswered) to end.
#
# This is the exact command from README.md's "Test outbound call" section,
# wrapped so you don't have to reconstruct it from memory each time.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ESL_PW_FILE="$PROJECT_DIR/configs/storage/esl-password.txt"
ENV_FILE="$PROJECT_DIR/.env"

if [ ! -r "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found" >&2
  exit 1
fi

ESL_PW=$(sudo head -1 "$ESL_PW_FILE") || { echo "ERROR: could not read $ESL_PW_FILE" >&2; exit 1; }
CALLER_ID=$(grep '^MYSIGNALWIREPHONENUMBERWITHPLUS=' "$ENV_FILE" | cut -d= -f2)
DEFAULT_DEST=$(grep '^MYMOBILEPHONENUMBERWITHPLUS=' "$ENV_FILE" | cut -d= -f2)
DEST="${1:-$DEFAULT_DEST}"

if [ -z "$CALLER_ID" ]; then
  echo "ERROR: MYSIGNALWIREPHONENUMBERWITHPLUS not set in .env" >&2
  exit 1
fi
if [ -z "$DEST" ]; then
  echo "ERROR: no destination given and MYMOBILEPHONENUMBERWITHPLUS not set in .env" >&2
  echo "Usage: $0 [destination-number-in-E.164]" >&2
  exit 1
fi

echo "Calling $DEST via SignalWire (caller ID $CALLER_ID)..."
echo "Answer and talk — you should hear your own voice echoed back."
docker exec freeswitch fs_cli -p "$ESL_PW" -x \
  "originate {origination_caller_id_number=${CALLER_ID},call_timeout=30}sofia/gateway/signalwire/${DEST} &echo"
