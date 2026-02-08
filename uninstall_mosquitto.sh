#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-./mosquitto.env}"
PURGE_PACKAGES="${2:-false}"   # set true to apt-get purge

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0 [path/to/mosquitto.env] [purge_packages=true|false]"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# Stop/disable service (if present)
systemctl stop mosquitto >/dev/null 2>&1 || true
systemctl disable mosquitto >/dev/null 2>&1 || true

# Remove renewal hook (we manage only our named hook)
HOOK_PATH="/etc/letsencrypt/renewal-hooks/deploy/restart-mosquitto.sh"
echo "Removing renewal deploy hook (if present): $HOOK_PATH"
rm -f "$HOOK_PATH"

# Remove the specific snippet installed by installer
CONF_SNIPPET="${MOSQ_CONF_DIR:-/etc/mosquitto/conf.d}/99-vps.conf"
echo "Removing managed config snippet (if present): $CONF_SNIPPET"
rm -f "$CONF_SNIPPET"

# Remove main config only if marked as managed
MAIN_CONF="${MOSQ_CONF_MAIN:-/etc/mosquitto/mosquitto.conf}"
if [[ -f "$MAIN_CONF" ]] && grep -q "Managed by install_mosquitto_vps.sh" "$MAIN_CONF"; then
  echo "Removing managed main config: $MAIN_CONF"
  rm -f "$MAIN_CONF"
else
  echo "Main config not removed (either missing or not marked as managed)."
fi

# Remove auth file
if [[ -n "${MOSQ_PASSWORD_FILE:-}" ]]; then
  echo "Removing password file (if present): $MOSQ_PASSWORD_FILE"
  rm -f "$MOSQ_PASSWORD_FILE"
fi

# Remove TLS dir ONLY if it matches the configured TLS dir (but do NOT delete /etc/letsencrypt)
if [[ -n "${MOSQ_TLS_DIR:-}" && -d "$MOSQ_TLS_DIR" ]]; then
  # Extra safety: refuse to delete if MOSQ_TLS_DIR points at letsencrypt
  if [[ "$MOSQ_TLS_DIR" == /etc/letsencrypt* ]]; then
    echo "Refusing to remove MOSQ_TLS_DIR because it points into /etc/letsencrypt: $MOSQ_TLS_DIR"
  else
    echo "Removing TLS directory (if present): $MOSQ_TLS_DIR"
    rm -rf "$MOSQ_TLS_DIR"
  fi
fi

# Remove log file (not the whole directory)
if [[ -n "${MOSQ_LOG_FILE:-}" ]]; then
  echo "Removing log file (if present): $MOSQ_LOG_FILE"
  rm -f "$MOSQ_LOG_FILE"
fi

# Remove persistence data (WARNING: deletes retained messages)
if [[ -n "${MOSQ_PERSISTENCE_LOCATION:-}" && -d "$MOSQ_PERSISTENCE_LOCATION" ]]; then
  echo "Removing persistence directory (if present): $MOSQ_PERSISTENCE_LOCATION"
  rm -rf "$MOSQ_PERSISTENCE_LOCATION"
fi

# Firewall rules removal (best-effort)
if command -v ufw >/dev/null 2>&1; then
  if [[ "${UFW_ALLOW:-false}" == "true" && -n "${MOSQ_LISTENER_PORT:-}" ]]; then
    echo "Removing UFW rule for ${MOSQ_LISTENER_PORT}/tcp (best effort)..."
    ufw delete allow "${MOSQ_LISTENER_PORT}"/tcp >/dev/null 2>&1 || true
  fi
  if [[ "${OPEN_PLAINTEXT_1883:-false}" == "true" ]]; then
    echo "Removing UFW rule for 1883/tcp (best effort)..."
    ufw delete allow 1883/tcp >/dev/null 2>&1 || true
  fi
  # If you enabled LE in your env, you may have opened port 80
  if [[ "${LETSENCRYPT_ENABLE:-false}" == "true" ]]; then
    echo "Removing UFW rule for 80/tcp (best effort)..."
    ufw delete allow 80/tcp >/dev/null 2>&1 || true
  fi
fi

# Optionally purge packages
if [[ "$PURGE_PACKAGES" == "true" ]]; then
  echo "Purging packages mosquitto + mosquitto-clients..."
  apt-get purge -y mosquitto mosquitto-clients >/dev/null || true
  apt-get autoremove -y >/dev/null || true
else
  echo "Packages NOT purged. (Pass 'true' as 2nd arg to purge.)"
fi

echo "Uninstall complete."
