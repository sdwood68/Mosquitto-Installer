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

require_bool() {
  local name="$1"
  local value="${!name:-}"
  if [[ "$value" != "true" && "$value" != "false" ]]; then
    echo "Boolean variable must be true or false: $name=$value"
    exit 1
  fi
}

verify_socket() {
  local addr="$1"
  local port="$2"
  ss -H -lnt | awk '{print $4}' | grep -Fxq "${addr}:${port}"
}

verify_listener_bindings() {
  if ! verify_socket "$MOSQ_BIND_ADDRESS" "$MOSQ_LISTENER_PORT"; then
    echo "ERROR: Expected TLS listener on ${MOSQ_BIND_ADDRESS}:${MOSQ_LISTENER_PORT} not found."
    ss -lntp || true
    exit 1
  fi

  if [[ "$OPEN_PLAINTEXT_1883" == "true" ]]; then
    if ! verify_socket "$MOSQ_PLAINTEXT_BIND_ADDRESS" 1883; then
      echo "ERROR: Expected plaintext listener on ${MOSQ_PLAINTEXT_BIND_ADDRESS}:1883 not found."
      ss -lntp || true
      exit 1
    fi

    if ss -H -lnt | awk '{print $4}' | grep -Eq '^0\.0\.0\.0:1883$|^\[::\]:1883$|^:::1883$'; then
      echo "ERROR: Plaintext port 1883 is exposed on a wildcard bind."
      ss -lntp || true
      exit 1
    fi
  fi

  echo "Listener verification passed."
}

# Required vars
req MOSQ_LISTENER_PORT
req MOSQ_BIND_ADDRESS
req MOSQ_CONF_MAIN
req MOSQ_CONF_DIR
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

# Booleans
require_bool MOSQ_ALLOW_ANONYMOUS
require_bool UFW_ALLOW
require_bool OPEN_PLAINTEXT_1883
require_bool REQUIRE_CLIENT_CERT
MOSQ_ENABLE_ACL="${MOSQ_ENABLE_ACL:-false}"
WRITE_DEFAULT_ACL="${WRITE_DEFAULT_ACL:-false}"
LETSENCRYPT_ENABLE="${LETSENCRYPT_ENABLE:-false}"
LETSENCRYPT_STAGING="${LETSENCRYPT_STAGING:-false}"
LETSENCRYPT_FIX_DIR_PERMS="${LETSENCRYPT_FIX_DIR_PERMS:-true}"
CREATE_LOCAL_USER="${CREATE_LOCAL_USER:-false}"
CREATE_DEVICE_USER="${CREATE_DEVICE_USER:-false}"

require_bool MOSQ_ENABLE_ACL
require_bool WRITE_DEFAULT_ACL
require_bool LETSENCRYPT_ENABLE
require_bool LETSENCRYPT_STAGING
require_bool LETSENCRYPT_FIX_DIR_PERMS
require_bool CREATE_LOCAL_USER
require_bool CREATE_DEVICE_USER

# Optional plaintext bind address
MOSQ_PLAINTEXT_BIND_ADDRESS="${MOSQ_PLAINTEXT_BIND_ADDRESS:-127.0.0.1}"

# Optional ACL
MOSQ_ACL_FILE="${MOSQ_ACL_FILE:-/etc/mosquitto/aclfile}"
ACL_TOPIC_PREFIX="${ACL_TOPIC_PREFIX:-watergauge/#}"

# Optional Let's Encrypt automation variables
LETSENCRYPT_DOMAIN="${LETSENCRYPT_DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"

echo "[1/13] Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y mosquitto mosquitto-clients ufw openssl certbot

if ! id mosquitto >/dev/null 2>&1; then
  echo "ERROR: mosquitto user does not exist after package installation."
  exit 1
fi

echo "[2/13] Creating directories..."
install -d -m 0755 "$MOSQ_CONF_DIR"
install -d -m 0755 "$(dirname "$MOSQ_LOG_FILE")"
install -d -m 0755 "$MOSQ_PERSISTENCE_LOCATION"
chown -R mosquitto:mosquitto "$MOSQ_PERSISTENCE_LOCATION"

echo "[3/13] Ensuring password file exists (mosquitto-owned, 0600)..."
install -m 0600 -o mosquitto -g mosquitto /dev/null "$MOSQ_PASSWORD_FILE"

create_user() {
  local user="$1"
  local pass="${2:-}"

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
  chmod 0600 "$MOSQ_PASSWORD_FILE"
}

if [[ "$CREATE_LOCAL_USER" == "true" ]]; then
  if [[ -z "${LOCAL_USER:-}" ]]; then
    echo "CREATE_LOCAL_USER=true but LOCAL_USER is empty in env file."
    exit 1
  fi
  create_user "$LOCAL_USER" "${LOCAL_PASSWORD:-}"
fi

if [[ "$CREATE_DEVICE_USER" == "true" ]]; then
  if [[ -z "${DEVICE_USER:-}" ]]; then
    echo "CREATE_DEVICE_USER=true but DEVICE_USER is empty in env file."
    exit 1
  fi
  create_user "$DEVICE_USER" "${DEVICE_PASSWORD:-}"
fi

echo "[4/13] Firewall (UFW)..."
if [[ "$UFW_ALLOW" == "true" ]]; then
  ufw allow OpenSSH >/dev/null || true
  if [[ "$LETSENCRYPT_ENABLE" == "true" ]]; then
    ufw allow 80/tcp >/dev/null || true
  fi
  ufw allow "${MOSQ_LISTENER_PORT}/tcp" >/dev/null || true
  ufw --force enable >/dev/null || true
fi

echo "[5/13] (Optional) Obtaining/refreshing Let's Encrypt cert..."
if [[ "$LETSENCRYPT_ENABLE" == "true" ]]; then
  if [[ -z "$LETSENCRYPT_DOMAIN" || -z "$LETSENCRYPT_EMAIL" ]]; then
    echo "LETSENCRYPT_ENABLE=true but LETSENCRYPT_DOMAIN and/or LETSENCRYPT_EMAIL are empty in env file."
    exit 1
  fi

  CB_ARGS=(
    certonly --standalone
    -d "$LETSENCRYPT_DOMAIN"
    -m "$LETSENCRYPT_EMAIL"
    --agree-tos
    --non-interactive
  )

  if [[ "$LETSENCRYPT_STAGING" == "true" ]]; then
    CB_ARGS+=(--staging)
  fi

  certbot "${CB_ARGS[@]}"
fi

echo "[6/13] Fixing Let's Encrypt directory traversal permissions..."
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

HOOK_PATH=""
if [[ "$LETSENCRYPT_ENABLE" == "true" ]]; then
  echo "[7/13] Installing renewal deploy hook (fix perms + restart)..."
  HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
  HOOK_PATH="$HOOK_DIR/restart-mosquitto.sh"
  install -d -m 0755 "$HOOK_DIR"
  cat > "$HOOK_PATH" <<'__HOOK__'
#!/usr/bin/env bash
set -euo pipefail

if [[ -d /etc/letsencrypt/live ]]; then
  chgrp mosquitto /etc/letsencrypt/live || true
  chmod 0750 /etc/letsencrypt/live || true
fi
if [[ -d /etc/letsencrypt/archive ]]; then
  chgrp mosquitto /etc/letsencrypt/archive || true
  chmod 0750 /etc/letsencrypt/archive || true
fi

systemctl restart mosquitto
__HOOK__
  chmod 0755 "$HOOK_PATH"
else
  echo "[7/13] Skipping renewal deploy hook (Let's Encrypt disabled)..."
fi

echo "[8/13] (Optional) Ensuring ACL file exists..."
if [[ "$MOSQ_ENABLE_ACL" == "true" ]]; then
  install -m 0600 -o mosquitto -g mosquitto /dev/null "$MOSQ_ACL_FILE"

  {
    echo "# Mosquitto ACL file"
    echo "# Generated by install_mosquitto.sh"
    echo

    if [[ "$WRITE_DEFAULT_ACL" == "true" ]]; then
      echo "# Starter rules (generated by installer)"

      if [[ "$CREATE_DEVICE_USER" == "true" && -n "${DEVICE_USER:-}" ]]; then
        echo "user ${DEVICE_USER}"
        echo "topic readwrite ${ACL_TOPIC_PREFIX}"
        echo
      fi

      if [[ "$CREATE_LOCAL_USER" == "true" && -n "${LOCAL_USER:-}" ]]; then
        echo "user ${LOCAL_USER}"
        echo "topic read ${ACL_TOPIC_PREFIX}"
        echo
      fi
    else
      echo "# Example publisher"
      echo "# user watergauge"
      echo "# topic readwrite watergauge/#"
      echo
      echo "# Example local MQTTPlot subscriber"
      echo "# user MQTTPlot"
      echo "# topic read watergauge/#"
      echo
      echo "# NOTE: If MOSQ_ENABLE_ACL=true, add real rules or clients"
      echo "# will connect successfully but be denied publish/subscribe."
      echo
    fi
  } > "$MOSQ_ACL_FILE"

  chown mosquitto:mosquitto "$MOSQ_ACL_FILE"
  chmod 0644 "$MOSQ_ACL_FILE"
else
  echo "[8/13] ACL disabled."
fi

echo "[9/13] Writing Mosquitto configuration..."
if [[ ! -f "$MOSQ_CERT_FILE" ]]; then
  echo "Certificate file not found: $MOSQ_CERT_FILE"
  exit 1
fi

if [[ ! -f "$MOSQ_KEY_FILE" ]]; then
  echo "Key file not found: $MOSQ_KEY_FILE"
  exit 1
fi

MAIN_TMP="$(mktemp)"
cleanup() { rm -f "$MAIN_TMP"; }
trap cleanup EXIT

if [[ "$MOSQ_LOG_DEST" == "file" ]]; then
  if [[ -z "$MOSQ_LOG_FILE" ]]; then
    echo "MOSQ_LOG_DEST=file requires MOSQ_LOG_FILE to be set."
    exit 1
  fi
  LOG_DEST_LINE="log_dest file $MOSQ_LOG_FILE"
else
  LOG_DEST_LINE="log_dest $MOSQ_LOG_DEST"
fi

cat > "$MAIN_TMP" <<EOF
# Managed by install_mosquitto.sh

# -------------------------------------------------------------------
# Baseline hardening
# -------------------------------------------------------------------
allow_zero_length_clientid false

# -------------------------------------------------------------------
# Persistence
# -------------------------------------------------------------------
persistence ${MOSQ_PERSISTENCE}
persistence_location ${MOSQ_PERSISTENCE_LOCATION}

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
${LOG_DEST_LINE}
log_type error
log_type warning
log_type notice
connection_messages true

# -------------------------------------------------------------------
# AuthN/AuthZ
# -------------------------------------------------------------------
allow_anonymous ${MOSQ_ALLOW_ANONYMOUS}
password_file ${MOSQ_PASSWORD_FILE}
EOF

if [[ "$MOSQ_ENABLE_ACL" == "true" ]]; then
  cat >> "$MAIN_TMP" <<EOF
acl_file ${MOSQ_ACL_FILE}
EOF
fi

cat >> "$MAIN_TMP" <<EOF

# -------------------------------------------------------------------
# Internet-facing TLS listener
# -------------------------------------------------------------------
listener ${MOSQ_LISTENER_PORT} ${MOSQ_BIND_ADDRESS}
protocol mqtt

certfile ${MOSQ_CERT_FILE}
keyfile ${MOSQ_KEY_FILE}

tls_version tlsv1.2
EOF

if [[ "$REQUIRE_CLIENT_CERT" == "true" ]]; then
  if [[ -z "${MOSQ_CA_FILE:-}" ]]; then
    echo "REQUIRE_CLIENT_CERT=true requires MOSQ_CA_FILE to be set."
    exit 1
  fi
  if [[ ! -f "${MOSQ_CA_FILE}" ]]; then
    echo "CA file not found: ${MOSQ_CA_FILE}"
    exit 1
  fi
  cat >> "$MAIN_TMP" <<EOF
cafile ${MOSQ_CA_FILE}
require_certificate true
use_identity_as_username true
EOF
else
  cat >> "$MAIN_TMP" <<'EOF'
require_certificate false
EOF
fi

if [[ "$OPEN_PLAINTEXT_1883" == "true" ]]; then
  cat >> "$MAIN_TMP" <<EOF

# -------------------------------------------------------------------
# Localhost plaintext listener (MQTTPlot)
# -------------------------------------------------------------------
listener 1883 ${MOSQ_PLAINTEXT_BIND_ADDRESS}
protocol mqtt
EOF
fi

cat >> "$MAIN_TMP" <<'EOF'

pid_file /run/mosquitto/mosquitto.pid
user mosquitto
EOF

install -m 0644 -o root -g root "$MAIN_TMP" "$MOSQ_CONF_MAIN"

echo "[10/13] Validating configuration syntax..."
mosquitto -c "$MOSQ_CONF_MAIN" -t

echo "[11/13] Enabling & restarting mosquitto..."
systemctl enable mosquitto
systemctl reset-failed mosquitto || true
systemctl restart mosquitto

echo "[12/13] Verifying listener bindings..."
verify_listener_bindings

echo "[13/13] Summary:"
echo "Main config:    $MOSQ_CONF_MAIN"
echo "Password file:  $MOSQ_PASSWORD_FILE"
if [[ "$MOSQ_ENABLE_ACL" == "true" ]]; then
  echo "ACL file:       $MOSQ_ACL_FILE"
else
  echo "ACL file:       disabled"
fi
if [[ -n "$HOOK_PATH" ]]; then
  echo "Renew hook:     $HOOK_PATH"
else
  echo "Renew hook:     disabled"
fi
if [[ "$CREATE_DEVICE_USER" == "true" ]]; then
  echo "Device user:    ${DEVICE_USER}"
fi
if [[ "$CREATE_LOCAL_USER" == "true" ]]; then
  echo "Local user:     ${LOCAL_USER}"
fi
ss -lntp | grep mosquitto || true