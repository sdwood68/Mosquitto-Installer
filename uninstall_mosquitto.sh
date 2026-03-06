#!/usr/bin/env bash
set -euo pipefail

PURGE_PACKAGES=true
REMOVE_USER=true
ASSUME_YES=false

usage() {
  cat <<'EOF'
Usage: uninstall_mosquitto.sh [options]

Options:
  --keep-packages   Stop/disable Mosquitto and remove config/data, but do not
                    purge mosquitto packages.
  --keep-user       Do not remove the mosquitto system user/group.
  -y, --yes         Non-interactive mode.
  -h, --help        Show this help.

Examples:
  sudo bash uninstall_mosquitto.sh
  sudo bash uninstall_mosquitto.sh --keep-packages --keep-user
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "Please run as root (sudo)."
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-packages)
        PURGE_PACKAGES=false
        ;;
      --keep-user)
        REMOVE_USER=false
        ;;
      -y|--yes)
        ASSUME_YES=true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done
}

confirm() {
  if [[ "$ASSUME_YES" == true ]]; then
    return 0
  fi

  echo
  echo "This will uninstall Mosquitto-related components from this host."
  echo "  purge_packages=$PURGE_PACKAGES"
  echo "  remove_user=$REMOVE_USER"
  echo
  read -r -p "Continue? [y/N]: " reply
  case "$reply" in
    y|Y|yes|YES)
      ;;
    *)
      die "Aborted."
      ;;
  esac
}

check_apt_lock() {
  local lock_files=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/cache/apt/archives/lock
  )

  local holders=""
  for lock in "${lock_files[@]}"; do
    if command -v fuser >/dev/null 2>&1; then
      local out
      out="$(fuser "$lock" 2>/dev/null || true)"
      if [[ -n "$out" ]]; then
        holders+="$lock held by PID(s): $out"$'\n'
      fi
    fi
  done

  if [[ -n "$holders" ]]; then
    printf '%s' "$holders" >&2
    die "apt/dpkg appears to be in use. Wait for it to finish, then retry."
  fi
}

stop_service() {
  if systemctl list-unit-files | grep -q '^mosquitto\.service'; then
    log "Stopping mosquitto service"
    systemctl stop mosquitto || true
    systemctl disable mosquitto || true
  else
    log "Mosquitto service not installed"
  fi
}

purge_packages() {
  if [[ "$PURGE_PACKAGES" != true ]]; then
    log "Keeping mosquitto packages (--keep-packages)"
    return 0
  fi

  check_apt_lock

  log "Purging mosquitto packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y mosquitto mosquitto-clients
  apt-get autoremove -y
}

remove_paths() {
  log "Removing Mosquitto config/data/log directories"
  rm -rf /etc/mosquitto
  rm -rf /var/lib/mosquitto
  rm -rf /var/log/mosquitto

  log "Removing possible systemd unit leftovers"
  rm -f /etc/systemd/system/mosquitto.service
  rm -f /lib/systemd/system/mosquitto.service
  systemctl daemon-reload || true
}

remove_user() {
  if [[ "$REMOVE_USER" != true ]]; then
    log "Keeping mosquitto user/group (--keep-user)"
    return 0
  fi

  if id mosquitto >/dev/null 2>&1; then
    log "Removing mosquitto system user"
    userdel mosquitto || true
  fi

  if getent group mosquitto >/dev/null 2>&1; then
    log "Removing mosquitto system group"
    groupdel mosquitto || true
  fi
}

post_check() {
  local failed=false

  if systemctl list-unit-files | grep -q '^mosquitto\.service'; then
    warn "mosquitto.service still exists after uninstall"
    failed=true
  fi

  if dpkg -l | awk '{print $2}' | grep -qx mosquitto; then
    warn "mosquitto package still installed"
    failed=true
  fi

  if dpkg -l | awk '{print $2}' | grep -qx mosquitto-clients; then
    warn "mosquitto-clients package still installed"
    failed=true
  fi

  if ss -tln 2>/dev/null | grep -Eq '(:1883|:8883)\b'; then
    warn "A listener still exists on 1883 or 8883"
    failed=true
  fi

  if [[ -d /etc/mosquitto ]]; then
    warn "/etc/mosquitto still exists"
    failed=true
  fi

  if [[ "$failed" == true ]]; then
    die "Uninstall verification failed."
  fi
}

main() {
  require_root
  parse_args "$@"
  confirm

  stop_service
  purge_packages
  remove_paths
  remove_user
  post_check

  echo "Uninstall complete."
  echo "purge_packages=$PURGE_PACKAGES remove_user=$REMOVE_USER"
}

main "$@"