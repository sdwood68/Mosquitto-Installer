#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-./mosquitto.env}"

echo "Running end-to-end one-shot tests using env: $ENV_FILE"
echo

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

echo "== TLS =="
"$SCRIPT_DIR/test_oneshot_tls.sh" "$ENV_FILE" "test/tls"
echo
echo "== Local plaintext (127.0.0.1:1883) =="
"$SCRIPT_DIR/test_oneshot_local.sh" "$ENV_FILE" "test/baseline"
