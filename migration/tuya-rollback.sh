#!/bin/bash
# Undoes tuya-switch.sh: restores the 0x5e plugin (with local patches), config, accessory cache
# and package files from the newest pre-switch backup, then restarts Homebridge.
# Usage: bash ~/tuya-rollback.sh [backup.tgz]
set -euo pipefail

LIVE=/var/lib/homebridge
HBUSER=$(systemctl show -p User --value homebridge 2>/dev/null); HBUSER=${HBUSER:-homebridge}
# systemd may report a numeric uid (e.g. 1000); sudo -u and chown need the name
HBUSER=$(id -nu "$HBUSER" 2>/dev/null || echo "$HBUSER")
NEW=@zmanuel1234/homebridge-tuya
MIG=$HOME/tuya-migration
BACKUP=${1:-$(ls -1t "$MIG"/pre-switch-*.tgz 2>/dev/null | head -1 || true)}
[ -n "$BACKUP" ] && [ -f "$BACKUP" ] || { echo "No pre-switch backup found in $MIG"; exit 1; }

echo "Restoring from $BACKUP"
read -rp "Type yes to continue: " ANSWER
[ "$ANSWER" = yes ] || { echo "Cancelled."; exit 1; }

echo "[1/4] Stop Homebridge"
sudo systemctl stop homebridge

echo "[2/4] Remove $NEW"
sudo rm -rf "$LIVE/node_modules/$NEW"

echo "[3/4] Restore files"
sudo tar xzf "$BACKUP" -C "$LIVE"
sudo chown -R "$HBUSER:$HBUSER" "$LIVE/config.json" "$LIVE/accessories" "$LIVE/persist" "$LIVE/node_modules/@0x5e"
for f in package.json package-lock.json; do sudo test -f "$LIVE/$f" && sudo chown "$HBUSER:$HBUSER" "$LIVE/$f"; done
sudo systemctl enable --now garage-patch.path garage-patch.timer 2>/dev/null || true

echo "[4/4] Start Homebridge"
sudo systemctl start homebridge
echo "Waiting 60 seconds..."
sleep 60
sudo tail -n 40 "$LIVE/homebridge.log" | grep -Ei 'TuyaPlatform|Sensorless|error' || true
echo
echo "Rollback complete"
