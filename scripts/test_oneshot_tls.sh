#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-./mosquitto.env}"
TOPIC="${2:-test/tls}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  echo "Usage: $0 [path/to/mosquitto.env] [topic]" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${LETSENCRYPT_DOMAIN:?LETSENCRYPT_DOMAIN must be set in env file for TLS tests}"
: "${MQTT_USERNAME:?MQTT_USERNAME must be set in env file for TLS tests}"
: "${MQTT_PASSWORD:?MQTT_PASSWORD must be set in env file for TLS tests}"

HOST="$LETSENCRYPT_DOMAIN"
PORT="${MOSQ_LISTENER_PORT:-8883}"
CAFILE="${TLS_CAFILE:-/etc/ssl/certs/ca-certificates.crt}"

SUB_ID="oneshot-tls-sub-$(date +%s)"
PUB_ID="oneshot-tls-pub-$(date +%s)"
MSG="ONE-SHOT TLS $(date -Is)"

echo "TLS one-shot test"
echo "  host : $HOST"
echo "  port : $PORT"
echo "  topic: $TOPIC"
echo

# Subscribe for 6 seconds, publish after 1 second, and show any received output.
( timeout 6 mosquitto_sub -h "$HOST" -p "$PORT" \
    --cafile "$CAFILE" \
    -i "$SUB_ID" \
    -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" \
    -t "$TOPIC" -v ) &

sleep 1

mosquitto_pub -h "$HOST" -p "$PORT" \
  --cafile "$CAFILE" \
  -i "$PUB_ID" \
  -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" \
  -t "$TOPIC" -m "$MSG" -q 1

wait
echo
echo "If you saw a '$TOPIC ...' line above, TLS pub/sub is working."
