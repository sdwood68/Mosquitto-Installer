\
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
WRITE_DEFAULT_ACL="${WRITE_DEFAULT_ACL:-false}"
ACL_TOPIC_PREFIX="${ACL_TOPIC_PREFIX:-test/#}"

# Optional Let's Encrypt automation variables
LETSENCRYPT_ENABLE="${LETSENCRYPT_ENABLE:-false}"
LETSENCRYPT_DOMAIN="${LETSENCRYPT_DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
LETSENCRYPT_STAGING="${LETSENCRYPT_STAGING:-false}"
LETSENCRYPT_FIX_DIR_PERMS="${LETSENCRYPT_FIX_DIR_PERMS:-true}"

# Managed snippet filename
CONF_SNIPPET="$MOSQ_CONF_DIR/99-vps.conf"

echo "[1/12] Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y mosquitto mosquitto-clients ufw openssl certbot

echo "[2/12] Creating directories..."
install -d -m 0755 "$MOSQ_CONF_DIR"
install -d -m 0755 "$(dirname "$MOSQ_LOG_FILE")"
install -d -m 0755 "$MOSQ_PERSISTENCE_LOCATION"
chown -R mosquitto:mosquitto "$MOSQ_PERSISTENCE_LOCATION"

echo "[3/12] Ensuring password file exists (root-owned, mosquitto-readable)..."
install -m 0640 /dev/null "$MOSQ_PASSWORD_FILE"
chown root:mosquitto "$MOSQ_PASSWORD_FILE"
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
  # enforce perms after edits
  chown root:mosquitto "$MOSQ_PASSWORD_FILE"
  chmod 0640 "$MOSQ_PASSWORD_FILE"
}

if [[ "${CREATE_MQTT_USER:-false}" == "true" ]]; then
  if [[ -z "${MQTT_USERNAME:-}" ]]; then
    echo "CREATE_MQTT_USER=true but MQTT_USERNAME is empty in env file."
    exit 1
  fi
  create_user "$MQTT_USERNAME" "${MQTT_PASSWORD:-}"
fi

echo "[4/12] Firewall (UFW)..."
if [[ "$UFW_ALLOW" == "true" ]]; then
  ufw allow OpenSSH >/dev/null || true
  if [[ "$LETSENCRYPT_ENABLE" == "true" ]]; then
    ufw allow 80/tcp >/dev/null || true
  fi
  ufw allow "${MOSQ_LISTENER_PORT}"/tcp >/dev/null || true
  # do NOT open 1883 unless explicitly requested
  if [[ "$OPEN_PLAINTEXT_1883" == "true" ]]; then
    ufw allow 1883/tcp >/dev/null || true
  fi
  ufw --force enable >/dev/null || true
fi

echo "[5/12] (Optional) Obtaining/refreshing Let's Encrypt cert..."
if [[ "$LETSENCRYPT_ENABLE" == "true" ]]; then
  if [[ -z "$LETSENCRYPT_DOMAIN" || -z "$LETSENCRYPT_EMAIL" ]]; then
    echo "LETSENCRYPT_ENABLE=true but LETSENCRYPT_DOMAIN and/or LETSENCRYPT_EMAIL are empty in env file."
    exit 1
  fi

  CB_ARGS=(certonly --standalone -d "$LETSENCRYPT_DOMAIN" -m "$LETSENCRYPT_EMAIL" --agree-tos --non-interactive)
  if [[ "$LETSENCRYPT_STAGING" == "true" ]]; then
    CB_ARGS+=(--staging)
  fi

  # If cert isn't due for renewal, certbot returns success with a message.
  certbot "${CB_ARGS[@]}" || true
fi

echo "[6/12] Fixing Let's Encrypt directory traversal permissions (if enabled)..."
# On some systems /etc/letsencrypt/{live,archive} are 0700 root:root, which
# prevents mosquitto from traversing symlinks to privkey*.pem.
if [[ "$LETSENCRYPT_FIX_DIR_PERMS" == "true" ]]; then
  if [[ -d /etc/letsencrypt/live ]]; then
    chgrp mosquitto /etc/letsencrypt/live || true
    chmod 0750 /etc/letsencrypt/live || true
  fi
  if [[ -d /etc/letsencrypt/archive ]]; then
    chgrp mosquitto /etc/letsencrypt/archive || true
    chmod 0750 /etc/letsencrypt/archive || true
  fi
  if [[ -n "$LETSENCRYPT_DOMAIN" ]]; then
    if [[ -d "/etc/letsencrypt/live/$LETSENCRYPT_DOMAIN" ]]; then
      chgrp mosquitto "/etc/letsencrypt/live/$LETSENCRYPT_DOMAIN" || true
      chmod 0750 "/etc/letsencrypt/live/$LETSENCRYPT_DOMAIN" || true
    fi
    if [[ -d "/etc/letsencrypt/archive/$LETSENCRYPT_DOMAIN" ]]; then
      chgrp mosquitto "/etc/letsencrypt/archive/$LETSENCRYPT_DOMAIN" || true
      chmod 0750 "/etc/letsencrypt/archive/$LETSENCRYPT_DOMAIN" || true
    fi
  fi
fi

echo "[7/12] Installing renewal deploy hook (fix perms + restart Mosquitto)..."
HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
HOOK_PATH="$HOOK_DIR/restart-mosquitto.sh"
install -d -m 0755 "$HOOK_DIR"
cat > "$HOOK_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail

# Ensure mosquitto can traverse LE symlinks on hardened hosts
if [[ -d /etc/letsencrypt/live ]]; then
  chgrp mosquitto /etc/letsencrypt/live || true
  chmod 0750 /etc/letsencrypt/live || true
fi
if [[ -d /etc/letsencrypt/archive ]]; then
  chgrp mosquitto /etc/letsencrypt/archive || true
  chmod 0750 /etc/letsencrypt/archive || true
fi

systemctl restart mosquitto
EOF
chmod 0755 "$HOOK_PATH"

echo "[8/12] (Optional) Ensuring ACL file exists..."
if [[ "$MOSQ_ENABLE_ACL" == "true" ]]; then
  install -m 0640 /dev/null "$MOSQ_ACL_FILE"
  chown root:mosquitto "$MOSQ_ACL_FILE"
  chmod 0640 "$MOSQ_ACL_FILE"
fi

if [[ "$MOSQ_ENABLE_ACL" == "true" && "$WRITE_DEFAULT_ACL" == "true" && "${CREATE_MQTT_USER:-false}" == "true" ]]; then
  echo "[9/12] Writing starter ACL for initial user..."
  cat > "$MOSQ_ACL_FILE" <<EOF
user ${MQTT_USERNAME}
topic readwrite ${ACL_TOPIC_PREFIX}
EOF
  chown root:mosquitto "$MOSQ_ACL_FILE"
  chmod 0640 "$MOSQ_ACL_FILE"
else
  echo "[9/12] Skipping starter ACL (MOSQ_ENABLE_ACL=$MOSQ_ENABLE_ACL, WRITE_DEFAULT_ACL=$WRITE_DEFAULT_ACL)."
fi

echo "[10/12] Writing Mosquitto configuration (atomic writes)..."

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

# Prevent any default listener on 1883 (defensive hardening).
PORT0_LINE="port 0"

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

${PORT0_LINE}

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

echo "[11/12] Enabling & restarting mosquitto..."
systemctl enable mosquitto
systemctl reset-failed mosquitto || true
systemctl restart mosquitto

echo "[12/12] Listening sockets:"
ss -lntp | grep mosquitto || true

echo "Done."
echo "Main config: $MOSQ_CONF_MAIN"
echo "Snippet:     $CONF_SNIPPET"
echo "Renew hook:  $HOOK_PATH"
