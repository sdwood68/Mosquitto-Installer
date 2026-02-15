#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-./mosquitto.env}"
TOPIC="${2:-test/baseline}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  echo "Usage: $0 [path/to/mosquitto.env] [topic]" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${MQTT_USERNAME:?MQTT_USERNAME must be set in env file for local tests}"
: "${MQTT_PASSWORD:?MQTT_PASSWORD must be set in env file for local tests}"

HOST="127.0.0.1"
PORT="1883"

SUB_ID="oneshot-local-sub-$(date +%s)"
PUB_ID="oneshot-local-pub-$(date +%s)"
MSG="ONE-SHOT LOCAL $(date -Is)"

echo "Local one-shot test (plaintext)"
echo "  host : $HOST"
echo "  port : $PORT"
echo "  topic: $TOPIC"
echo

( timeout 6 mosquitto_sub -h "$HOST" -p "$PORT" \
    -i "$SUB_ID" \
    -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" \
    -t "$TOPIC" -v ) &

sleep 1

mosquitto_pub -h "$HOST" -p "$PORT" \
  -i "$PUB_ID" \
  -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" \
  -t "$TOPIC" -m "$MSG" -q 1

wait
echo
echo "If you saw a '$TOPIC ...' line above, local pub/sub is working."
