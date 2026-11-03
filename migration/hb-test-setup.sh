#!/bin/bash
# Sets up a temporary second Homebridge in ~/hb-test with only the zman Tuya plugin
# and its own web UI (127.0.0.1:8582, published by nginx on port 1908).
# Usage: bash ~/hb-test-setup.sh ~/tuya-migration/homebridge-tuya-zman.tgz
set -euo pipefail

PKG=$(readlink -f "${1:?usage: hb-test-setup.sh <homebridge-tuya-zman.tgz>}")
[ -f "$PKG" ] || { echo "Package not found: $PKG"; exit 1; }

export PATH=/opt/homebridge/bin:/usr/bin:/bin
NODE=/opt/homebridge/bin/node
NPM=/opt/homebridge/bin/npm
LIVE=/var/lib/homebridge
T=$HOME/hb-test
BASE=https://raw.githubusercontent.com/zmanuel1234/homebridge-tuya/zman-patches/migration
UI_PORT=8582
BRIDGE_PORT=51899

if [ -e "$T" ]; then
  echo "$T already exists. Remove it first: ~/hb-test/stop.sh; rm -rf ~/hb-test"
  exit 1
fi

pkgver() {  # version of an installed package, searched in the usual places
  for d in "$LIVE/node_modules/$1" "/opt/homebridge/lib/node_modules/$1"; do
    [ -f "$d/package.json" ] && { "$NODE" -p "require('$d/package.json').version"; return; }
  done
  echo latest
}
HB_VER=$(pkgver homebridge)
UI_VER=$(pkgver homebridge-config-ui-x)
echo "Live Homebridge $HB_VER, UI $UI_VER"

read -rp "Second Smart Life account email: " TUYA_USER
read -rsp "Second Smart Life account password: " TUYA_PASS; echo
[ -n "$TUYA_USER" ] && [ -n "$TUYA_PASS" ] || { echo "Email and password are required."; exit 1; }

mkdir -p "$T/storage" "$T/plugins"
echo "Installing Homebridge, UI and plugin into $T (a few minutes)..."
cd "$T/plugins"
"$NPM" init -y >/dev/null
"$NPM" install --no-audit --no-fund --loglevel=error \
  "homebridge@$HB_VER" "homebridge-config-ui-x@$UI_VER" "$PKG"

curl -fsSLo "$T/tuya-compare.js" "$BASE/tuya-compare.js"

# Test config: Tuya block copied from the live config, second account, no child bridge,
# code-less schema entries removed (the new settings screen requires a code).
sudo cat "$LIVE/config.json" | TUYA_USER="$TUYA_USER" TUYA_PASS="$TUYA_PASS" \
  UI_PORT=$UI_PORT BRIDGE_PORT=$BRIDGE_PORT "$NODE" -e '
const live = JSON.parse(require("fs").readFileSync(0, "utf8"));
const tuya = JSON.parse(JSON.stringify(live.platforms.find(p => p.platform === "TuyaPlatform")));
if (!tuya) { console.error("No TuyaPlatform block in the live config"); process.exit(1); }
delete tuya._bridge;
tuya.name = "Tuya Test";
tuya.options.username = process.env.TUYA_USER;
tuya.options.password = process.env.TUYA_PASS;
for (const o of tuya.options.deviceOverrides || []) {
  if (Array.isArray(o.schema)) {
    o.schema = o.schema.filter(s => s && s.code);
    if (!o.schema.length) delete o.schema;
  }
}
const hex = () => Math.floor(Math.random() * 256).toString(16).padStart(2, "0").toUpperCase();
const d = () => Math.floor(Math.random() * 10);
let pin;
do { pin = `${d()}${d()}${d()}-${d()}${d()}-${d()}${d()}${d()}`; } while (/^(\d)\1\1-\1\1-\1\1\1$/.test(pin) || pin === "123-45-678" || pin === "876-54-321");
const config = {
  bridge: { name: "Tuya Test", username: ["0E", hex(), hex(), hex(), hex(), hex()].join(":"), port: Number(process.env.BRIDGE_PORT), pin },
  plugins: ["@zmanuel1234/homebridge-tuya", "homebridge-config-ui-x"],
  platforms: [
    { platform: "config", name: "Config", port: Number(process.env.UI_PORT), host: "127.0.0.1", log: { method: "systemd", service: "hb-test" } },
    tuya,
  ],
};
console.log(JSON.stringify(config, null, 2));
' > "$T/storage/config.json"
chmod 600 "$T/storage/config.json"

# nginx page for port 1908: same certificate and remote gate as 1907.
cat > "$T/nginx-1908.conf" <<EOF
# Temporary: Homebridge test instance UI (remove in runbook step 6)
server {
  listen 1908 ssl;
  listen [::]:1908 ssl;
  server_name _;

  ssl_certificate /etc/letsencrypt/live/zarathustra.ddns.net/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/zarathustra.ddns.net/privkey.pem;
  include snippets/remote-gate.conf;
  ssl_protocols TLSv1.2 TLSv1.3;

  client_max_body_size 2G;

  location / {
    proxy_pass                  http://127.0.0.1:$UI_PORT;
    proxy_http_version          1.1;
    proxy_buffering             off;
    proxy_set_header            Host \$host;
    proxy_set_header            Upgrade \$http_upgrade;
    proxy_set_header            Connection "Upgrade";
    proxy_set_header            X-Real-IP \$remote_addr;
    proxy_set_header            X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}
EOF

cat > "$T/start.sh" <<EOF
#!/bin/bash
sudo systemctl reset-failed hb-test 2>/dev/null || true
sudo systemd-run --unit=hb-test --uid=$(id -u) --gid=$(id -g) --working-directory=$T \\
  -E PATH=/opt/homebridge/bin:/usr/bin:/bin -E HOME=$HOME \\
  $NODE $T/plugins/node_modules/homebridge/bin/homebridge -I -U $T/storage -P $T/plugins/node_modules
# The UI (v5) runs as its own process; the plugin inside Homebridge does not start it.
sudo systemctl reset-failed hb-test-ui 2>/dev/null || true
sudo systemd-run --unit=hb-test-ui --uid=$(id -u) --gid=$(id -g) --working-directory=$T \\
  -E PATH=/opt/homebridge/bin:/usr/bin:/bin -E HOME=$HOME \\
  -E UIX_BASE_PATH=$T/plugins/node_modules/homebridge-config-ui-x \\
  $NODE $T/plugins/node_modules/homebridge-config-ui-x/dist/bin/standalone.js -I -U $T/storage -P $T/plugins/node_modules
echo "Started. Watch it with: ~/hb-test/log.sh"
EOF

cat > "$T/log.sh" <<'EOF'
#!/bin/bash
journalctl -u hb-test -f -n 200 -o cat
EOF

cat > "$T/stop.sh" <<'EOF'
#!/bin/bash
sudo systemctl stop hb-test hb-test-ui 2>/dev/null || true
sudo systemctl reset-failed hb-test hb-test-ui 2>/dev/null || true
echo "Stopped."
EOF

cat > "$T/compare.sh" <<EOF
#!/bin/bash
# Live Tuya child bridge cache vs. test instance cache.
MAC=\$(sudo $NODE -p "(require('$LIVE/config.json').platforms.find(p=>p.platform==='TuyaPlatform')._bridge||{}).username||''" | tr -d ':' | tr a-z A-Z)
LIVECACHE=$LIVE/accessories/cachedAccessories\${MAC:+.\$MAC}
TMP=\$(mktemp); sudo cat "\$LIVECACHE" > "\$TMP"
HAP_SEARCH=$T/plugins/node_modules $NODE $T/tuya-compare.js "\$TMP" $T/storage/accessories/cachedAccessories live test
rm -f "\$TMP"
EOF

chmod +x "$T"/*.sh
echo
echo "Pairing code for the Home app: $("$NODE" -p "require('$T/storage/config.json').bridge.pin")"
echo "Setup complete"
