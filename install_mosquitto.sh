#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-./mosquitto.env}"  # you will likely pass ./mosquitto.env.example copied to ./mosquitto.env

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0 [path/to/mosquitto.env]"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

req() {
  local v="$1"
  if [[ -z "${!v:-}" ]]; then
    echo "Required variable not set in env file: $v"
    exit 1
  fi
}

# Required vars (existing)
req MOSQ_LISTENER_PORT
req MOSQ_BIND_ADDRESS
req MOSQ_CONF_MAIN
req MOSQ_CONF_DIR
req MOSQ_TLS_DIR
req MOSQ_CA_FILE
req MOSQ_CERT_FILE
req MOSQ_KEY_FILE
req MOSQ_PASSWORD_FILE
req MOSQ_ALLOW_ANONYMOUS
req MOSQ_LOG_DEST
req MOSQ_LOG_FILE
req MOSQ_PERSISTENCE
req MOSQ_PERSISTENCE_LOCATION
req UFW_ALLOW
req OPEN_PLAINTEXT_1883
req REQUIRE_CLIENT_CERT

# Optional Let's Encrypt automation variables
LETSENCRYPT_ENABLE="${LETSENCRYPT_ENABLE:-false}"
LETSENCRYPT_DOMAIN="${LETSENCRYPT_DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
LETSENCRYPT_STAGING="${LETSENCRYPT_STAGING:-false}"

echo "[1/10] Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y mosquitto mosquitto-clients ufw openssl certbot

echo "[2/10] Creating directories..."
install -d -m 0755 "$MOSQ_CONF_DIR"
install -d -m 0750 "$MOSQ_TLS_DIR"
install -d -m 0755 "$(dirname "$MOSQ_LOG_FILE")"
install -d -m 0755 "$MOSQ_PERSISTENCE_LOCATION"

chown -R mosquitto:mosquitto "$MOSQ_PERSISTENCE_LOCATION"

echo "[3/10] Ensuring password file exists (no anonymous by default)..."
install -m 0640 /dev/null "$MOSQ_PASSWORD_FILE"
chown mosquitto:mosquitto "$MOSQ_PASSWORD_FILE"

create_user() {
  local user="$1"
  local pass="$2"

  if [[ -z "$pass" ]]; then
    echo -n "Enter password for MQTT user '$user': "
    read -r -s pass
    echo
    echo -n "Confirm password: "
    local pass2
    read -r -s pass2
    echo
    if [[ "$pass" != "$pass2" ]]; then
      echo "Passwords do not match."
      exit 1
    fi
  fi

  mosquitto_passwd -b "$MOSQ_PASSWORD_FILE" "$user" "$pass"
  chown mosquitto:mosquitto "$MOSQ_PASSWORD_FILE"
  chmod 0640 "$MOSQ_PASSWORD_FILE"
}

if [[ "${CREATE_MQTT_USER:-false}" == "true" ]]; then
  if [[ -z "${MQTT_USERNAME:-}" ]]; then
    echo "CREATE_MQTT_USER=true but MQTT_USERNAME is empty in env file."
    exit 1
  fi
  create_user "$MQTT_USERNAME" "${MQTT_PASSWORD:-}"
fi

echo "[4/10] Firewall (UFW)..."
if [[ "$UFW_ALLOW" == "true" ]]; then
  ufw allow OpenSSH >/dev/null || true

  # For Let's Encrypt standalone HTTP-01 challenge (needed only during issuance/renew)
  if [[ "$LETSENCRYPT_ENABLE" == "true" ]]; then
    ufw allow 80/tcp >/dev/null || true
  fi

  ufw allow "${MOSQ_LISTENER_PORT}"/tcp >/dev/null || true
  if [[ "$OPEN_PLAINTEXT_1883" == "true" ]]; then
    ufw allow 1883/tcp >/dev/null || true
  fi
  ufw --force enable >/dev/null || true
fi

echo "[5/10] (Optional) Obtaining/refreshing Let's Encrypt cert..."
if [[ "$LETSENCRYPT_ENABLE" == "true" ]]; then
  if [[ -z "$LETSENCRYPT_DOMAIN" || -z "$LETSENCRYPT_EMAIL" ]]; then
    echo "LETSENCRYPT_ENABLE=true but LETSENCRYPT_DOMAIN and/or LETSENCRYPT_EMAIL are empty in env file."
    exit 1
  fi

  # Build certbot args
  CB_ARGS=(certonly --standalone -d "$LETSENCRYPT_DOMAIN" -m "$LETSENCRYPT_EMAIL" --agree-tos --non-interactive)
  if [[ "$LETSENCRYPT_STAGING" == "true" ]]; then
    CB_ARGS+=(--staging)
  fi

  # If a cert already exists, this will renew only if needed (unless you add --force-renewal yourself)
  certbot "${CB_ARGS[@]}"
fi

echo "[6/10] Installing renewal deploy hook to restart Mosquitto..."
HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
HOOK_PATH="$HOOK_DIR/restart-mosquitto.sh"
install -d -m 0755 "$HOOK_DIR"

cat > "$HOOK_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail
# Restart Mosquitto after a successful certificate renewal.
# This makes Mosquitto pick up the newly renewed key/cert.
systemctl restart mosquitto
EOF

chmod 0755 "$HOOK_PATH"

echo "[7/10] TLS checks..."
missing_tls=false
for f in "$MOSQ_CA_FILE" "$MOSQ_CERT_FILE" "$MOSQ_KEY_FILE"; do
  if [[ ! -f "$f" ]]; then
    echo "WARNING: TLS file missing: $f"
    missing_tls=true
  fi
done

if $missing_tls; then
  cat <<'EOF'

TLS files are missing for Mosquitto.
If you're using Let's Encrypt, set these in your env file to:

  MOSQ_CA_FILE=/etc/letsencrypt/live/<domain>/fullchain.pem
  MOSQ_CERT_FILE=/etc/letsencrypt/live/<domain>/fullchain.pem
  MOSQ_KEY_FILE=/etc/letsencrypt/live/<domain>/privkey.pem

Otherwise provide your own CA/cert/key at the configured paths.

EOF
fi

echo "[8/10] Writing Mosquitto configuration (secure defaults)..."
CONF_SNIPPET="$MOSQ_CONF_DIR/99-vps.conf"

cat > "$MOSQ_CONF_MAIN" <<EOF
# Managed by install_mosquitto_vps.sh
pid_file /run/mosquitto/mosquitto.pid
user mosquitto
include_dir $MOSQ_CONF_DIR
EOF

cat > "$CONF_SNIPPET" <<EOF
# Managed by install_mosquitto_vps.sh

# --- Persistence ---
persistence ${MOSQ_PERSISTENCE}
persistence_location ${MOSQ_PERSISTENCE_LOCATION}

# --- Logging ---
log_dest ${MOSQ_LOG_DEST}
log_dest file ${MOSQ_LOG_FILE}
log_type error
log_type warning
log_type notice
connection_messages true

# --- Security baseline ---
allow_anonymous ${MOSQ_ALLOW_ANONYMOUS}
password_file ${MOSQ_PASSWORD_FILE}

# --- Internet-facing listener (TLS) ---
listener ${MOSQ_LISTENER_PORT} ${MOSQ_BIND_ADDRESS}
protocol mqtt

cafile ${MOSQ_CA_FILE}
certfile ${MOSQ_CERT_FILE}
keyfile ${MOSQ_KEY_FILE}

# Harden TLS baseline (adjust only if you have legacy clients)
tls_version tlsv1.2

# Optional: require client certs (mTLS)
EOF

if [[ "$REQUIRE_CLIENT_CERT" == "true" ]]; then
  cat >> "$CONF_SNIPPET" <<'EOF'
require_certificate true
use_identity_as_username true
EOF
else
  cat >> "$CONF_SNIPPET" <<'EOF'
require_certificate false
EOF
fi

if [[ "$OPEN_PLAINTEXT_1883" == "true" ]]; then
  cat >> "$CONF_SNIPPET" <<EOF

# --- OPTIONAL plaintext listener (NOT recommended on internet) ---
listener 1883 ${MOSQ_BIND_ADDRESS}
protocol mqtt
EOF
fi

chown root:root "$MOSQ_CONF_MAIN" "$CONF_SNIPPET"
chmod 0644 "$MOSQ_CONF_MAIN" "$CONF_SNIPPET"

# TLS permissions (key must be private)
if [[ -f "$MOSQ_KEY_FILE" ]]; then
  chown mosquitto:mosquitto "$MOSQ_KEY_FILE" || true
  chmod 0640 "$MOSQ_KEY_FILE" || true
fi
if [[ -f "$MOSQ_CERT_FILE" ]]; then
  chown mosquitto:mosquitto "$MOSQ_CERT_FILE" || true
  chmod 0644 "$MOSQ_CERT_FILE" || true
fi
if [[ -f "$MOSQ_CA_FILE" ]]; then
  chown mosquitto:mosquitto "$MOSQ_CA_FILE" || true
  chmod 0644 "$MOSQ_CA_FILE" || true
fi

echo "[9/10] Validating config..."
mosquitto -c "$MOSQ_CONF_MAIN" -t >/dev/null

echo "[10/10] Enabling & restarting mosquitto..."
systemctl enable mosquitto
systemctl restart mosquitto
systemctl --no-pager --full status mosquitto || true

echo
echo "Done."
echo "Config:     $MOSQ_CONF_MAIN (includes $MOSQ_CONF_DIR)"
echo "Snippet:    $CONF_SNIPPET"
echo "Password:   $MOSQ_PASSWORD_FILE"
echo "TLS dir:    $MOSQ_TLS_DIR"
echo "Renew hook: $HOOK_PATH"
echo
echo "Client test example:"
echo "  mosquitto_sub -h <your-vps-host> -p ${MOSQ_LISTENER_PORT} \\"
echo "    --cafile <CA.crt> -u <user> -P <pass> -t 'test/#' -v"
