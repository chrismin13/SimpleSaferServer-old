#!/bin/bash

set -euo pipefail

LEGACY_CONFIG="/etc/SimpleSaferServer/config.conf"
LEGACY_MSMTP="/etc/msmtprc"
LEGACY_SMB_CONF="/etc/samba/smb.conf"
NEW_INSTALL_URL="https://raw.githubusercontent.com/chrismin13/SimpleSaferServer/main/install.sh"
IMPORTER_PATH="/opt/SimpleSaferServer/scripts/import_legacy.py"
IMPORTER_PYTHON="/opt/SimpleSaferServer/venv/bin/python"
LEGACY_TIMER_UNITS="backup_cloud.timer check_mount.timer check_hdsentinel_health.timer"
LEGACY_SERVICE_UNITS="backup_cloud.service check_mount.service check_hdsentinel_health.service"
LEGACY_ONLY_UNITS="check_hdsentinel_health.timer check_hdsentinel_health.service"
LEGACY_ONLY_FILES="/etc/systemd/system/check_hdsentinel_health.timer /etc/systemd/system/check_hdsentinel_health.service /usr/local/bin/check_hdsentinel_health.sh"

log() {
  printf '%s\n' "$1"
}

warn() {
  printf '%s\n' "$1" >&2
}

migrate_legacy_backup_share() {
  local smb_conf_path="$1"
  local mount_point="$2"
  local admin_username="$3"
  local managed_comment="Default backup share created by SimpleSaferServer migration"
  local temp_output=""
  local backup_path=""

  if [ ! -f "$smb_conf_path" ]; then
    log "Legacy Samba config not found at $smb_conf_path. The importer will create the managed backup share."
    return 0
  fi

  temp_output="$(mktemp)"
  backup_path="$BACKUP_ROOT/legacy-smb.conf.before-managed-migration"

  # The current importer refuses to take ownership of an unmanaged [backup]
  # block, so legacy migration has to rewrite that one block into the managed
  # format before import begins.
  if ! python3 - "$smb_conf_path" "$temp_output" "$mount_point" "$admin_username" "$managed_comment" <<'PY'
from pathlib import Path
import re
import sys

smb_conf_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
mount_point = sys.argv[3]
admin_username = sys.argv[4]
comment = sys.argv[5]

begin_marker = "# BEGIN SimpleSaferServer share: backup"
end_marker = "# END SimpleSaferServer share: backup"
section_re = re.compile(r"^\s*\[([^\]]+)\]\s*$")

lines = smb_conf_path.read_text(encoding="utf-8").splitlines(keepends=True)

for line in lines:
    if line.strip() == begin_marker:
        output_path.write_text("".join(lines), encoding="utf-8")
        raise SystemExit(0)

backup_start = None
backup_end = None
backup_count = 0

index = 0
while index < len(lines):
    match = section_re.match(lines[index])
    if not match:
        index += 1
        continue

    section_name = match.group(1).strip()
    block_start = index
    index += 1
    while index < len(lines):
        if section_re.match(lines[index]):
            break
        index += 1
    block_end = index

    if section_name == "backup":
        backup_count += 1
        backup_start = block_start
        backup_end = block_end

if backup_count == 0:
    output_path.write_text("".join(lines), encoding="utf-8")
    raise SystemExit(0)

if backup_count > 1:
    raise SystemExit("Found multiple [backup] Samba share blocks. Refusing automatic migration.")

replacement = [
    f"{begin_marker}\n",
    "[backup]\n",
    f"   path = {mount_point}\n",
    "   writeable = Yes\n",
    "   create mask = 0777\n",
    "   directory mask = 0777\n",
    "   public = no\n",
    f"   comment = {comment}\n",
    f"   valid users = {admin_username}\n",
    f"{end_marker}\n",
]

new_lines = list(lines)
new_lines[backup_start:backup_end] = replacement
output_path.write_text("".join(new_lines), encoding="utf-8")
PY
  then
    rm -f "$temp_output"
    warn ""
    warn "Failed to prepare the legacy [backup] Samba share for migration."
    warn "No changes were made to $smb_conf_path."
    warn ""
    return 1
  fi

  if cmp -s "$smb_conf_path" "$temp_output"; then
    rm -f "$temp_output"
    log "Legacy [backup] Samba share does not need pre-migration changes."
    return 0
  fi

  cp "$smb_conf_path" "$backup_path"
  mv "$temp_output" "$smb_conf_path"
  chmod 644 "$smb_conf_path"
  log "Converted the legacy [backup] Samba share into the SimpleSaferServer-managed format."
}

print_config_debug_help() {
  warn "No changes were made. The migration stopped before copying files or installing anything."

  if [ -d "/etc/SimpleSaferServer" ]; then
    warn ""
    warn "Contents of /etc/SimpleSaferServer/:"
    ls -la /etc/SimpleSaferServer >&2 || true
  fi

  warn ""
  warn "Searching common locations for a legacy config file..."
  if ! grep -Rsl '^BACKUP_CLOUD_TIME=' /etc /root /home 2>/dev/null >&2; then
    warn "No config file with BACKUP_CLOUD_TIME was found under /etc, /root, or /home."
  fi
}

if [ "$EUID" -ne 0 ]; then
  printf "\nThis migration script must be run as root.\n"
  printf "Use: curl -fsSL https://raw.githubusercontent.com/chrismin13/SimpleSaferServer-old/main/migrate.sh | sudo bash\n\n"
  exit 1
fi

if [ ! -f "$LEGACY_CONFIG" ]; then
  warn ""
  warn "Legacy config not found at $LEGACY_CONFIG"
  print_config_debug_help
  warn ""
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
  warn ""
  warn "Legacy SMTP config not found at $LEGACY_MSMTP"
  warn "No changes were made. The migration stopped before installing anything."
  warn ""
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
  warn ""
  warn "Could not locate the legacy rclone.conf file."
  warn "Expected it under the legacy service user's home directory or /root/.config/rclone/rclone.conf."
  warn "No changes were made. The migration stopped before installing anything."
  warn ""
  exit 1
fi

prompt_admin_username() {
  local default_username="${USERNAME:-admin}"
  local input=""
  while true; do
    read -r -p "Enter the new SimpleSaferServer admin username [${default_username}]: " input </dev/tty
    input="${input:-$default_username}"
    if [[ "$input" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      printf '%s\n' "$input"
      return 0
    fi
    printf "Username may only contain letters, numbers, underscores, and hyphens.\n" >&2
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
if [ -f "$LEGACY_SMB_CONF" ]; then
  cp "$LEGACY_SMB_CONF" "$BACKUP_ROOT/legacy-smb.conf"
fi

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

log ""
log "Legacy config: $LEGACY_CONFIG"
log "Legacy SMTP config: $LEGACY_MSMTP"
log "Legacy rclone config: $LEGACY_RCLONE"
log "Legacy state copied to $BACKUP_ROOT"
log "Stopping and disabling legacy timers and services before migration..."
systemctl disable --now $LEGACY_TIMER_UNITS || true
systemctl stop $LEGACY_SERVICE_UNITS || true
systemctl disable $LEGACY_SERVICE_UNITS || true
log "Installing the new SimpleSaferServer release..."
log ""

INSTALL_SCRIPT="$(mktemp)"
curl -fsSL "$NEW_INSTALL_URL" -o "$INSTALL_SCRIPT"

bash "$INSTALL_SCRIPT"
rm -f "$INSTALL_SCRIPT"

log ""
log "Preparing the legacy [backup] Samba share for migration..."
migrate_legacy_backup_share "$LEGACY_SMB_CONF" "$MOUNT_POINT" "$ADMIN_USERNAME"

if [ ! -x "$IMPORTER_PATH" ]; then
  warn ""
  warn "New legacy importer was not found at $IMPORTER_PATH"
  warn ""
  exit 1
fi

if [ ! -x "$IMPORTER_PYTHON" ]; then
  IMPORTER_PYTHON="python3"
fi

log ""
log "Importing the legacy configuration into the new installation..."
log ""
printf '%s\n' "$ADMIN_PASSWORD" | "$IMPORTER_PYTHON" "$IMPORTER_PATH" \
  --bundle-dir "$BUNDLE_DIR" \
  --admin-username "$ADMIN_USERNAME" \
  --admin-password-stdin

unset ADMIN_PASSWORD

log ""
log "Cleaning up legacy-only timers, services, and scripts..."
systemctl disable --now $LEGACY_ONLY_UNITS || true
rm -f $LEGACY_ONLY_FILES
systemctl daemon-reload || true

log ""
log "Migration complete."
log "Legacy backups: $BACKUP_ROOT"
log "New web UI service: simple_safer_server_web.service"
log "Access URLs:"

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
