\
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-./mosquitto.env}"
PURGE_PACKAGES="${2:-false}"

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

MOSQ_ENABLE_ACL="${MOSQ_ENABLE_ACL:-false}"
MOSQ_ACL_FILE="${MOSQ_ACL_FILE:-/etc/mosquitto/aclfile}"
LETSENCRYPT_ENABLE="${LETSENCRYPT_ENABLE:-false}"

systemctl stop mosquitto >/dev/null 2>&1 || true
systemctl disable mosquitto >/dev/null 2>&1 || true

rm -f /etc/letsencrypt/renewal-hooks/deploy/restart-mosquitto.sh

CONF_SNIPPET="${MOSQ_CONF_DIR:-/etc/mosquitto/conf.d}/99-vps.conf"
rm -f "$CONF_SNIPPET"

MAIN_CONF="${MOSQ_CONF_MAIN:-/etc/mosquitto/mosquitto.conf}"
if [[ -f "$MAIN_CONF" ]] && grep -q "Managed by install_mosquitto.sh" "$MAIN_CONF"; then
  rm -f "$MAIN_CONF"
fi

rm -f "${MOSQ_PASSWORD_FILE:-/etc/mosquitto/passwd}"
if [[ "$MOSQ_ENABLE_ACL" == "true" ]]; then
  rm -f "$MOSQ_ACL_FILE"
fi

rm -f "${MOSQ_LOG_FILE:-/var/log/mosquitto/mosquitto.log}"

if [[ -n "${MOSQ_PERSISTENCE_LOCATION:-}" && -d "$MOSQ_PERSISTENCE_LOCATION" ]]; then
  rm -rf "$MOSQ_PERSISTENCE_LOCATION"
fi

if command -v ufw >/dev/null 2>&1; then
  ufw delete allow "${MOSQ_LISTENER_PORT:-8883}"/tcp >/dev/null 2>&1 || true
  if [[ "${OPEN_PLAINTEXT_1883:-false}" == "true" ]]; then
    ufw delete allow 1883/tcp >/dev/null 2>&1 || true
  fi
  if [[ "$LETSENCRYPT_ENABLE" == "true" ]]; then
    ufw delete allow 80/tcp >/dev/null 2>&1 || true
  fi
fi

# Remove mosquitto dirs (leave certbot state intact)
rm -rf /etc/mosquitto >/dev/null 2>&1 || true
rm -rf /var/lib/mosquitto /var/log/mosquitto /run/mosquitto >/dev/null 2>&1 || true

if [[ "$PURGE_PACKAGES" == "true" ]]; then
  apt-get purge -y mosquitto mosquitto-clients >/dev/null || true
  apt-get autoremove -y >/dev/null || true
fi

echo "Uninstall complete."
