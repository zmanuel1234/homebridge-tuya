#!/bin/bash
# Switches the live Homebridge from @0x5e/homebridge-tuya-platform to @zmanuel1234/homebridge-tuya.
# Usage: bash ~/tuya-switch.sh ~/tuya-migration/homebridge-tuya-zman.tgz
# Undo:  bash ~/tuya-rollback.sh
set -euo pipefail

PKG=$(readlink -f "${1:?usage: tuya-switch.sh <homebridge-tuya-zman.tgz>}")
[ -f "$PKG" ] || { echo "Package not found: $PKG"; exit 1; }

NODE=/opt/homebridge/bin/node
LIVE=/var/lib/homebridge
OLD=@0x5e/homebridge-tuya-platform
NEW=@zmanuel1234/homebridge-tuya
MIG=$HOME/tuya-migration
BASE=https://raw.githubusercontent.com/zmanuel1234/homebridge-tuya/zman-patches/migration
STAMP=$(date +%F-%H%M)
BACKUP=$MIG/pre-switch-$STAMP.tgz
HBUSER=$(systemctl show -p User --value homebridge 2>/dev/null); HBUSER=${HBUSER:-homebridge}
# systemd may report a numeric uid (e.g. 1000); sudo -u and chown need the name
HBUSER=$(id -nu "$HBUSER" 2>/dev/null || echo "$HBUSER")
hbnpm() { sudo -u "$HBUSER" env PATH=/opt/homebridge/bin:/usr/bin:/bin HOME=$LIVE npm --prefix "$LIVE" --no-audit --no-fund --loglevel=error "$@"; }

mkdir -p "$MIG"

# Safety checks
[ -d "$LIVE/node_modules/$OLD" ] || { echo "$OLD is not installed; nothing to switch."; exit 1; }
if ! sudo grep -qs '"keepOrphans": *true' "$LIVE"/.uix-hb-service-homebridge-startup.json; then
  echo "Could not confirm that Keep Accessories Of Uninstalled Plugins is on (runbook step 7.2)."
  read -rp "Type on if you have switched it on in the Homebridge UI: " KO
  [ "$KO" = on ] || { echo "Cancelled. Switch it on first."; exit 1; }
fi

MAC=$(sudo "$NODE" -p "(require('$LIVE/config.json').platforms.find(p=>p.platform==='TuyaPlatform')._bridge||{}).username||''" | tr -d ':' | tr a-z A-Z)
CACHE=$LIVE/accessories/cachedAccessories${MAC:+.$MAC}
sudo test -f "$CACHE" || { echo "Tuya accessory cache not found: $CACHE"; exit 1; }

cat <<EOF
This will:
  1. back up config.json, accessories/, persist/, package files and $OLD to $BACKUP
  2. save the Tuya accessory list to $MIG/accessories-before.json
  3. stop garage-patch.path and garage-patch.timer
  4. remove empty schema entries from the Tuya deviceOverrides
  5. replace $OLD with $NEW
  6. restart Homebridge (all accessories show No Response for about a minute)
EOF
read -rp "Type yes to continue: " ANSWER
[ "$ANSWER" = yes ] || { echo "Cancelled."; exit 1; }

echo "[1/6] Backup"
FILES="config.json accessories persist node_modules/$OLD"
for f in package.json package-lock.json; do sudo test -f "$LIVE/$f" && FILES="$FILES $f"; done
# shellcheck disable=SC2086
sudo tar czf "$BACKUP" -C "$LIVE" $FILES
echo "      $BACKUP ($(du -h "$BACKUP" | cut -f1))"

echo "[2/6] Accessory list"
sudo cat "$CACHE" > "$MIG/accessories-before.json"
curl -fsSLo "$MIG/tuya-compare.js" "$BASE/tuya-compare.js"

echo "[3/6] Patch watchers"
sudo systemctl disable --now garage-patch.path garage-patch.timer 2>/dev/null || true

echo "[4/6] Config clean-up"
sudo "$NODE" -e '
const fs = require("fs"); const f = process.argv[1];
const c = JSON.parse(fs.readFileSync(f, "utf8"));
const t = c.platforms.find(p => p.platform === "TuyaPlatform");
let n = 0;
for (const o of (t.options && t.options.deviceOverrides) || []) {
  if (!Array.isArray(o.schema)) continue;
  const before = o.schema.length;
  o.schema = o.schema.filter(s => s && s.code);
  n += before - o.schema.length;
  if (!o.schema.length) delete o.schema;
}
fs.writeFileSync(f + ".tmp", JSON.stringify(c, null, 4));
fs.renameSync(f + ".tmp", f);
console.log(`      removed ${n} empty schema entries`);
' "$LIVE/config.json"
sudo chown "$HBUSER:$HBUSER" "$LIVE/config.json"

echo "[5/6] Plugin swap"
# Files left over from manual patching can belong to root or pi; npm runs as the Homebridge user.
for p in "$LIVE/node_modules" "$LIVE/package.json" "$LIVE/package-lock.json" "$LIVE/.npm"; do
  sudo test -e "$p" && sudo chown -R "$HBUSER:$HBUSER" "$p"
done
sudo mkdir -p "$LIVE/zman"
sudo cp "$PKG" "$LIVE/zman/homebridge-tuya-zman.tgz"
sudo chown -R "$HBUSER:$HBUSER" "$LIVE/zman"
hbnpm uninstall "$OLD"
hbnpm install "$LIVE/zman/homebridge-tuya-zman.tgz"
[ -d "$LIVE/node_modules/$NEW" ] || { echo "Install failed. Run: bash ~/tuya-rollback.sh"; exit 1; }

echo "[6/6] Restart"
LOG=$LIVE/homebridge.log
START=$(sudo wc -l < "$LOG")
sudo systemctl restart homebridge
echo "      waiting 90 seconds for Homebridge and the Tuya bridge..."
sleep 90
echo
echo "--- Log lines about the plugin change ---"
sudo tail -n +"$((START + 1))" "$LOG" | grep -Ei 'plugin name changed|Removing orphaned|TuyaPlatform.*(error|fail)|zmanuel1234' | head -40 || true
echo
echo "--- Accessories before vs. now ---"
TMP=$(mktemp); sudo cat "$CACHE" > "$TMP"
if HAP_SEARCH=$LIVE/node_modules "$NODE" "$MIG/tuya-compare.js" "$MIG/accessories-before.json" "$TMP" before now; then
  echo; echo "Switch complete"
else
  echo; echo "Switch done, but accessories are missing. Check the Home app; if they really are gone, run: bash ~/tuya-rollback.sh"
fi
rm -f "$TMP"
