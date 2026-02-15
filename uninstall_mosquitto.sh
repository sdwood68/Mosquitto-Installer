#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo ./uninstall_mosquitto.sh [path/to/mosquitto.env] [purge_packages=true|false] [remove_user=true|false]
#
# Defaults:
#   purge_packages=true  (remove mosquitto + clients packages)
#   remove_user=true     (remove mosquitto system user/group after purge)

ENV_FILE="${1:-./mosquitto.env}"
PURGE_PACKAGES="${2:-true}"
REMOVE_USER="${3:-true}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0 [path/to/mosquitto.env] [purge_packages=true|false] [remove_user=true|false]"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

MOSQ_ENABLE_ACL="${MOSQ_ENABLE_ACL:-false}"
MOSQ_ACL_FILE="${MOSQ_ACL_FILE:-/etc/mosquitto/aclfile}"
LETSENCRYPT_ENABLE="${LETSENCRYPT_ENABLE:-false}"

# --- Stop service (best-effort) ---
systemctl stop mosquitto >/dev/null 2>&1 || true
systemctl disable mosquitto >/dev/null 2>&1 || true
systemctl reset-failed mosquitto >/dev/null 2>&1 || true

# --- Remove our certbot deploy hook ---
rm -f /etc/letsencrypt/renewal-hooks/deploy/restart-mosquitto.sh

# --- Remove our managed config files (best-effort) ---
CONF_SNIPPET="${MOSQ_CONF_DIR:-/etc/mosquitto/conf.d}/99-vps.conf"
rm -f "$CONF_SNIPPET" "${CONF_SNIPPET}.disabled" >/dev/null 2>&1 || true

MAIN_CONF="${MOSQ_CONF_MAIN:-/etc/mosquitto/mosquitto.conf}"
if [[ -f "$MAIN_CONF" ]] && grep -q "Managed by install_mosquitto.sh" "$MAIN_CONF"; then
  rm -f "$MAIN_CONF"
fi

rm -f "${MOSQ_PASSWORD_FILE:-/etc/mosquitto/passwd}" >/dev/null 2>&1 || true
if [[ "$MOSQ_ENABLE_ACL" == "true" ]]; then
  rm -f "$MOSQ_ACL_FILE" >/dev/null 2>&1 || true
fi

rm -f "${MOSQ_LOG_FILE:-/var/log/mosquitto/mosquitto.log}" >/dev/null 2>&1 || true

if [[ -n "${MOSQ_PERSISTENCE_LOCATION:-}" && -d "${MOSQ_PERSISTENCE_LOCATION:-}" ]]; then
  rm -rf "${MOSQ_PERSISTENCE_LOCATION:-}" >/dev/null 2>&1 || true
fi

# --- Firewall cleanup (best-effort) ---
if command -v ufw >/dev/null 2>&1; then
  ufw delete allow "${MOSQ_LISTENER_PORT:-8883}"/tcp >/dev/null 2>&1 || true
  if [[ "${OPEN_PLAINTEXT_1883:-false}" == "true" ]]; then
    ufw delete allow 1883/tcp >/dev/null 2>&1 || true
  fi
  if [[ "$LETSENCRYPT_ENABLE" == "true" ]]; then
    ufw delete allow 80/tcp >/dev/null 2>&1 || true
  fi
fi

# --- Remove dirs we created/used (best-effort) ---
rm -rf /etc/mosquitto /var/lib/mosquitto /var/log/mosquitto /run/mosquitto >/dev/null 2>&1 || true

# --- Purge packages (this removes binaries + systemd units installed by packages) ---
if [[ "$PURGE_PACKAGES" == "true" ]]; then
  apt-get purge -y mosquitto mosquitto-clients >/dev/null || true
  apt-get autoremove -y >/dev/null || true
  apt-get autoclean -y >/dev/null || true
fi

# --- Remove mosquitto system user/group (optional; only makes sense after purge) ---
if [[ "$REMOVE_USER" == "true" ]]; then
  # Kill any stray processes
  pkill -x mosquitto >/dev/null 2>&1 || true

  # Remove user/group if they exist
  if getent passwd mosquitto >/dev/null 2>&1; then
    userdel mosquitto >/dev/null 2>&1 || true
  fi
  if getent group mosquitto >/dev/null 2>&1; then
    groupdel mosquitto >/dev/null 2>&1 || true
  fi
fi

# --- Reload systemd to forget removed units (especially after purge) ---
systemctl daemon-reload >/dev/null 2>&1 || true

echo "Uninstall complete."
echo "purge_packages=$PURGE_PACKAGES remove_user=$REMOVE_USER"
