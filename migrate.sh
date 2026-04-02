#!/bin/bash

set -euo pipefail

LEGACY_CONFIG="/etc/SimpleSaferServer/config.conf"
LEGACY_MSMTP="/etc/msmtprc"
NEW_INSTALL_URL="https://sss.chrismin13.com/install.sh"
NEW_INSTALL_FALLBACK_URL="https://raw.githubusercontent.com/chrismin13/SimpleSaferServer/main/install.sh"
IMPORTER_PATH="/opt/SimpleSaferServer/scripts/import_legacy.py"
IMPORTER_PYTHON="/opt/SimpleSaferServer/venv/bin/python"

if [ "$EUID" -ne 0 ]; then
  printf "\nThis migration script must be run as root.\n"
  printf "Use: curl -fsSL https://raw.githubusercontent.com/chrismin13/SimpleSaferServer-old/main/migrate.sh | sudo bash\n\n"
  exit 1
fi

if [ ! -f "$LEGACY_CONFIG" ]; then
  printf "\nLegacy config not found at %s\n\n" "$LEGACY_CONFIG"
  exit 1
fi

# shellcheck disable=SC1090
source "$LEGACY_CONFIG"

required_vars=(EMAIL_ADDRESS SERVER_NAME UUID MOUNT_POINT RCLONE_DIR BACKUP_CLOUD_TIME)
for var_name in "${required_vars[@]}"; do
  if [ -z "${!var_name:-}" ]; then
    printf "\nLegacy config is missing required value: %s\n\n" "$var_name"
    exit 1
  fi
done

if [ ! -f "$LEGACY_MSMTP" ]; then
  printf "\nLegacy SMTP config not found at %s\n\n" "$LEGACY_MSMTP"
  exit 1
fi

resolve_legacy_rclone_config() {
  local candidate=""
  local legacy_home=""

  if [ -n "${USERNAME:-}" ]; then
    legacy_home=$(getent passwd "$USERNAME" | cut -d: -f6 || true)
    if [ -n "$legacy_home" ]; then
      candidate="$legacy_home/.config/rclone/rclone.conf"
      if [ -f "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  fi

  candidate="/root/.config/rclone/rclone.conf"
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

LEGACY_RCLONE="$(resolve_legacy_rclone_config || true)"
if [ -z "$LEGACY_RCLONE" ] || [ ! -f "$LEGACY_RCLONE" ]; then
  printf "\nCould not locate the legacy rclone.conf file.\n"
  printf "Expected it under the legacy service user's home directory or /root/.config/rclone/rclone.conf.\n\n"
  exit 1
fi

prompt_admin_username() {
  local default_username="${USERNAME:-admin}"
  local input=""
  while true; do
    read -r -p "Enter the new SimpleSaferServer admin username [${default_username}]: " input </dev/tty
    input="${input:-$default_username}"
    if [[ "$input" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
      printf '%s\n' "$input"
      return 0
    fi
    printf "Username must be 3-32 characters and contain only letters, numbers, underscores, and hyphens.\n" >&2
  done
}

prompt_admin_password() {
  local password=""
  local confirm=""
  while true; do
    read -r -s -p "Enter the new SimpleSaferServer admin password: " password </dev/tty
    printf "\n" >&2
    read -r -s -p "Confirm the new admin password: " confirm </dev/tty
    printf "\n" >&2

    if [ -z "$password" ]; then
      printf "Password cannot be empty.\n" >&2
      continue
    fi

    if [ ${#password} -lt 4 ]; then
      printf "Password must be at least 4 characters long.\n" >&2
      continue
    fi

    if [ "$password" != "$confirm" ]; then
      printf "Passwords did not match. Please try again.\n" >&2
      continue
    fi

    printf '%s\n' "$password"
    return 0
  done
}

ADMIN_USERNAME="$(prompt_admin_username)"
ADMIN_PASSWORD="$(prompt_admin_password)"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_ROOT="/var/backups/SimpleSaferServer/legacy-migration-${TIMESTAMP}"
BUNDLE_DIR="$BACKUP_ROOT/bundle"
mkdir -p "$BUNDLE_DIR"

cp "$LEGACY_CONFIG" "$BACKUP_ROOT/legacy-config.conf"
cp "$LEGACY_MSMTP" "$BACKUP_ROOT/legacy-msmtprc"
cp "$LEGACY_RCLONE" "$BACKUP_ROOT/legacy-rclone.conf"

cp "$LEGACY_CONFIG" "$BUNDLE_DIR/config.conf"
cp "$LEGACY_MSMTP" "$BUNDLE_DIR/msmtprc"
cp "$LEGACY_RCLONE" "$BUNDLE_DIR/rclone.conf"

cat > "$BUNDLE_DIR/manifest.json" <<EOF
{
  "format_version": 1,
  "source": "SimpleSaferServer-old",
  "created_at": "${TIMESTAMP}"
}
EOF

printf "\nLegacy state copied to %s\n" "$BACKUP_ROOT"
printf "Installing the new SimpleSaferServer release...\n\n"

INSTALL_SCRIPT="$(mktemp)"
if ! curl -fsSL "$NEW_INSTALL_URL" -o "$INSTALL_SCRIPT"; then
  printf "Primary install URL failed, retrying with GitHub raw...\n"
  curl -fsSL "$NEW_INSTALL_FALLBACK_URL" -o "$INSTALL_SCRIPT"
fi

bash "$INSTALL_SCRIPT"
rm -f "$INSTALL_SCRIPT"

if [ ! -x "$IMPORTER_PATH" ]; then
  printf "\nNew legacy importer was not found at %s\n\n" "$IMPORTER_PATH"
  exit 1
fi

if [ ! -x "$IMPORTER_PYTHON" ]; then
  IMPORTER_PYTHON="python3"
fi

printf "\nImporting the legacy configuration into the new installation...\n\n"
printf '%s\n' "$ADMIN_PASSWORD" | "$IMPORTER_PYTHON" "$IMPORTER_PATH" \
  --bundle-dir "$BUNDLE_DIR" \
  --admin-username "$ADMIN_USERNAME" \
  --admin-password-stdin

unset ADMIN_PASSWORD

printf "\nDisabling old timers and services...\n"
systemctl disable --now backup_cloud.timer check_mount.timer check_hdsentinel_health.timer || true
systemctl disable backup_cloud.service check_mount.service check_hdsentinel_health.service || true

printf "\nMigration complete.\n"
printf "Legacy backups: %s\n" "$BACKUP_ROOT"
printf "New web UI service: simple_safer_server_web.service\n"
printf "Access URLs:\n"

IP_LIST=$(hostname -I | tr ' ' '\n' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.' || true)
if [ -n "$IP_LIST" ]; then
  FIRST_IP=$(printf '%s\n' "$IP_LIST" | sed -n '1p')
  printf "  Recommended: http://%s:5000\n" "$FIRST_IP"
  for ip in $IP_LIST; do
    if [ "$ip" != "$FIRST_IP" ]; then
      printf "  http://%s:5000\n" "$ip"
    fi
  done
else
  printf "  No non-loopback IPv4 addresses were detected.\n"
fi
