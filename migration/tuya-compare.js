#!/usr/bin/env node
// Compares two Homebridge accessory caches (cachedAccessories files) by accessory UUID.
// Usage: node tuya-compare.js <before-or-live-cache> <after-or-test-cache> [labelA] [labelB]
// Exit code: 0 = no accessory missing from B, 1 = some missing, 2 = usage/read error.
'use strict';
const fs = require('fs');
const path = require('path');

const [fileA, fileB, labelA = 'live', labelB = 'test'] = process.argv.slice(2);
if (!fileA || !fileB) {
  console.error('usage: tuya-compare.js <cacheA> <cacheB> [labelA] [labelB]');
  process.exit(2);
}

function load(file) {
  try {
    const list = JSON.parse(fs.readFileSync(file, 'utf8'));
    // Only Tuya accessories, from either plugin name.
    return list.filter(a => a.platform === 'TuyaPlatform');
  } catch (e) {
    console.error(`Cannot read ${file}: ${e.message}`);
    process.exit(2);
  }
}

// Map service UUIDs to names using the HAP library shipped with Homebridge, when available.
const serviceNames = new Map();
for (const base of [process.env.HAP_SEARCH, '/var/lib/homebridge/node_modules', path.join(process.env.HOME || '', 'hb-test/plugins/node_modules')]) {
  if (!base) continue;
  for (const p of ['@homebridge/hap-nodejs', 'homebridge/node_modules/@homebridge/hap-nodejs', 'hap-nodejs', 'homebridge/node_modules/hap-nodejs']) {
    try {
      const { Service } = require(path.join(base, p));
      for (const name of Object.getOwnPropertyNames(Service)) {
        const cls = Service[name];
        if (cls && typeof cls === 'function' && cls.UUID) serviceNames.set(cls.UUID, name);
      }
    } catch (e) { /* try next */ }
    if (serviceNames.size) break;
  }
  if (serviceNames.size) break;
}

const IGNORED_SERVICES = new Set(['AccessoryInformation', 'ProtocolInformation']);
const services = acc => (acc.services || [])
  .map(s => serviceNames.get(s.UUID) || s.UUID)
  .filter(n => !IGNORED_SERVICES.has(n))
  .sort();

const a = new Map(load(fileA).map(x => [x.UUID, x]));
const b = new Map(load(fileB).map(x => [x.UUID, x]));

const missing = [...a.keys()].filter(u => !b.has(u));
const extra = [...b.keys()].filter(u => !a.has(u));
const renamed = [];
const changed = [];
for (const [u, x] of a) {
  const y = b.get(u);
  if (!y) continue;
  if (x.displayName !== y.displayName) renamed.push(`${x.displayName}  ->  ${y.displayName}`);
  const sx = services(x).join(', ');
  const sy = services(y).join(', ');
  if (sx !== sy) changed.push(`${x.displayName}: [${sx}]  ->  [${sy}]`);
}

console.log(`Tuya accessories: ${labelA} ${a.size}, ${labelB} ${b.size}`);
const section = (title, rows) => {
  console.log(`\n${title}: ${rows.length}`);
  rows.forEach(r => console.log(`  - ${r}`));
};
section(`Missing in ${labelB}`, missing.map(u => a.get(u).displayName));
section(`Extra in ${labelB}`, extra.map(u => b.get(u).displayName));
section('Names changed', renamed);
section('Services changed', changed);
console.log(`\n${missing.length} accessories missing`);
process.exit(missing.length ? 1 : 0);
