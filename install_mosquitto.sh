#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-./mosquitto.env}"

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

# Required vars
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

# Optional ACL
MOSQ_ENABLE_ACL="${MOSQ_ENABLE_ACL:-false}"
MOSQ_ACL_FILE="${MOSQ_ACL_FILE:-/etc/mosquitto/aclfile}"

# Optional Let's Encrypt automation variables
LETSENCRYPT_ENABLE="${LETSENCRYPT_ENABLE:-false}"
LETSENCRYPT_DOMAIN="${LETSENCRYPT_DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
LETSENCRYPT_STAGING="${LETSENCRYPT_STAGING:-false}"

# Managed snippet filename (kept as 99-vps.conf for backwards compatibility)
CONF_SNIPPET="$MOSQ_CONF_DIR/99-vps.conf"

echo "[1/11] Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y mosquitto mosquitto-clients ufw openssl certbot

echo "[2/11] Creating directories..."
install -d -m 0755 "$MOSQ_CONF_DIR"
install -d -m 0750 "$MOSQ_TLS_DIR"
install -d -m 0755 "$(dirname "$MOSQ_LOG_FILE")"
install -d -m 0755 "$MOSQ_PERSISTENCE_LOCATION"

chown -R mosquitto:mosquitto "$MOSQ_PERSISTENCE_LOCATION"

echo "[3/11] Ensuring password file exists (root-owned)..."
install -m 0640 /dev/null "$MOSQ_PASSWORD_FILE"
chown root:root "$MOSQ_PASSWORD_FILE"
chmod 0640 "$MOSQ_PASSWORD_FILE"

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
  chown root:root "$MOSQ_PASSWORD_FILE"
  chmod 0640 "$MOSQ_PASSWORD_FILE"
}

if [[ "${CREATE_MQTT_USER:-false}" == "true" ]]; then
  if [[ -z "${MQTT_USERNAME:-}" ]]; then
    echo "CREATE_MQTT_USER=true but MQTT_USERNAME is empty in env file."
    exit 1
  fi
  create_user "$MQTT_USERNAME" "${MQTT_PASSWORD:-}"
fi

echo "[4/11] Firewall (UFW)..."
if [[ "$UFW_ALLOW" == "true" ]]; then
  ufw allow OpenSSH >/dev/null || true
  if [[ "$LETSENCRYPT_ENABLE" == "true" ]]; then
    ufw allow 80/tcp >/dev/null || true
  fi
  ufw allow "${MOSQ_LISTENER_PORT}"/tcp >/dev/null || true
  if [[ "$OPEN_PLAINTEXT_1883" == "true" ]]; then
    ufw allow 1883/tcp >/dev/null || true
  fi
  ufw --force enable >/dev/null || true
fi

echo "[5/11] (Optional) Obtaining/refreshing Let's Encrypt cert..."
if [[ "$LETSENCRYPT_ENABLE" == "true" ]]; then
  if [[ -z "$LETSENCRYPT_DOMAIN" || -z "$LETSENCRYPT_EMAIL" ]]; then
    echo "LETSENCRYPT_ENABLE=true but LETSENCRYPT_DOMAIN and/or LETSENCRYPT_EMAIL are empty in env file."
    exit 1
  fi

  CB_ARGS=(certonly --standalone -d "$LETSENCRYPT_DOMAIN" -m "$LETSENCRYPT_EMAIL" --agree-tos --non-interactive)
  if [[ "$LETSENCRYPT_STAGING" == "true" ]]; then
    CB_ARGS+=(--staging)
  fi

  certbot "${CB_ARGS[@]}"
fi

echo "[6/11] Installing renewal deploy hook to restart Mosquitto..."
HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
HOOK_PATH="$HOOK_DIR/restart-mosquitto.sh"
install -d -m 0755 "$HOOK_DIR"
cat > "$HOOK_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail
systemctl restart mosquitto
EOF
chmod 0755 "$HOOK_PATH"

echo "[7/11] (Optional) Ensuring ACL file exists..."
if [[ "$MOSQ_ENABLE_ACL" == "true" ]]; then
  install -m 0640 /dev/null "$MOSQ_ACL_FILE"
  chown root:root "$MOSQ_ACL_FILE"
  chmod 0640 "$MOSQ_ACL_FILE"
fi

echo "[8/11] Writing Mosquitto configuration (atomic writes; prevents empty conf snippet)..."

MAIN_TMP="$(mktemp)"
SNIP_TMP="$(mktemp)"
cleanup() { rm -f "$MAIN_TMP" "$SNIP_TMP"; }
trap cleanup EXIT

cat > "$MAIN_TMP" <<EOF
# Managed by install_mosquitto.sh
pid_file /run/mosquitto/mosquitto.pid
user mosquitto
include_dir $MOSQ_CONF_DIR
EOF

install -m 0644 -o root -g root "$MAIN_TMP" "$MOSQ_CONF_MAIN"

if [[ "$MOSQ_LOG_DEST" == "file" ]]; then
  if [[ -z "$MOSQ_LOG_FILE" ]]; then
    echo "MOSQ_LOG_DEST=file requires MOSQ_LOG_FILE to be set."
    exit 1
  fi
  LOG_DEST_LINE="log_dest file $MOSQ_LOG_FILE"
else
  LOG_DEST_LINE="log_dest $MOSQ_LOG_DEST"
fi

cat > "$SNIP_TMP" <<EOF
# Managed by install_mosquitto.sh

# --- Baseline hardening ---
per_listener_settings true
allow_zero_length_clientid false

# --- Persistence ---
persistence ${MOSQ_PERSISTENCE}
persistence_location ${MOSQ_PERSISTENCE_LOCATION}

# --- Logging ---
${LOG_DEST_LINE}
log_type error
log_type warning
log_type notice
connection_messages true

# --- AuthN ---
allow_anonymous ${MOSQ_ALLOW_ANONYMOUS}
password_file ${MOSQ_PASSWORD_FILE}
EOF

if [[ "$MOSQ_ENABLE_ACL" == "true" ]]; then
  cat >> "$SNIP_TMP" <<EOF

# --- AuthZ (ACL) ---
acl_file ${MOSQ_ACL_FILE}
EOF
fi

cat >> "$SNIP_TMP" <<EOF

# --- Internet-facing listener (TLS) ---
listener ${MOSQ_LISTENER_PORT} ${MOSQ_BIND_ADDRESS}
protocol mqtt

cafile ${MOSQ_CA_FILE}
certfile ${MOSQ_CERT_FILE}
keyfile ${MOSQ_KEY_FILE}

tls_version tlsv1.2
EOF

if [[ "$REQUIRE_CLIENT_CERT" == "true" ]]; then
  cat >> "$SNIP_TMP" <<'EOF'
require_certificate true
use_identity_as_username true
EOF
else
  cat >> "$SNIP_TMP" <<'EOF'
require_certificate false
EOF
fi

if [[ "$OPEN_PLAINTEXT_1883" == "true" ]]; then
  cat >> "$SNIP_TMP" <<EOF

# --- OPTIONAL plaintext listener (NOT recommended on internet) ---
listener 1883 ${MOSQ_BIND_ADDRESS}
protocol mqtt
EOF
fi

install -m 0644 -o root -g root "$SNIP_TMP" "$CONF_SNIPPET"

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

echo "[9/11] Enabling & restarting mosquitto..."
systemctl enable mosquitto
systemctl restart mosquitto

echo "[10/11] Listening sockets:"
ss -lntp | grep mosquitto || true

echo "[11/11] Done."
echo "Main config: $MOSQ_CONF_MAIN"
echo "Snippet:     $CONF_SNIPPET"
echo "Renew hook:  $HOOK_PATH"
