#!/bin/bash
# Installs a newer build of @zmanuel1234/homebridge-tuya from the fork and restarts Homebridge.
# Usage: bash ~/tuya-update.sh [git ref, default zman-patches]
# Undo:  bash ~/tuya-update.sh --previous
set -euo pipefail

LIVE=/var/lib/homebridge
HBUSER=$(systemctl show -p User --value homebridge 2>/dev/null); HBUSER=${HBUSER:-homebridge}
# systemd may report a numeric uid (e.g. 1000); sudo -u and chown need the name
HBUSER=$(id -nu "$HBUSER" 2>/dev/null || echo "$HBUSER")
NEW=@zmanuel1234/homebridge-tuya
DIR=$LIVE/zman
REF=${1:-zman-patches}
hbnpm() { sudo -u "$HBUSER" env PATH=/opt/homebridge/bin:/usr/bin:/bin HOME=$LIVE npm --prefix "$LIVE" --no-audit --no-fund --loglevel=error "$@"; }
ver() { /opt/homebridge/bin/node -p "require('$LIVE/node_modules/$NEW/package.json').version"; }

[ -d "$LIVE/node_modules/$NEW" ] || { echo "$NEW is not installed (run the switch first)."; exit 1; }
echo "Installed now: $(ver)"

if [ "$REF" = --previous ]; then
  sudo test -f "$DIR/homebridge-tuya-zman.prev.tgz" || { echo "No previous build kept."; exit 1; }
  sudo cp "$DIR/homebridge-tuya-zman.prev.tgz" "$DIR/homebridge-tuya-zman.tgz"
else
  TMP=$(mktemp --suffix=.tgz)
  curl -fsSLo "$TMP" "https://raw.githubusercontent.com/zmanuel1234/homebridge-tuya/$REF/migration/homebridge-tuya-zman.tgz"
  sudo cp "$DIR/homebridge-tuya-zman.tgz" "$DIR/homebridge-tuya-zman.prev.tgz"
  sudo cp "$TMP" "$DIR/homebridge-tuya-zman.tgz"
  rm -f "$TMP"
fi
sudo chown -R "$HBUSER:$HBUSER" "$DIR"

hbnpm install "$DIR/homebridge-tuya-zman.tgz"
echo "Installed now: $(ver)"
sudo systemctl restart homebridge
echo "Homebridge restarting. If anything is wrong: bash ~/tuya-update.sh --previous"
