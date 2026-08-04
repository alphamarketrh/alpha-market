import { loadState, saveState } from '../src/config.js';
import { fetchMarket, fetchEventTags } from '../src/polymarket.js';

const st = loadState();
const ms = Object.values(st.markets || {});
const need = ms.filter((m) => !m.tags || m.tags.length === 0);
console.log(`  ${ms.length} tracked, ${need.length} without tags`);

const missing = need.filter((m) => !m.eventId);
console.log(`  ${missing.length} also need an event id`);
let n = 0;
for (const m of missing) {
  const src = await fetchMarket(m.id);
  const ev = (src?.events || [])[0]?.id;
  if (ev) m.eventId = String(ev);
  if (++n % 20 === 0) console.log(`    ${n}/${missing.length}`);
}

const ids = [...new Set(need.map((m) => m.eventId).filter(Boolean))];
console.log(`  fetching tags for ${ids.length} distinct events`);
const tags = await fetchEventTags(ids);

let filled = 0;
for (const m of need) {
  const t = tags[m.eventId];
  if (t && t.length) { m.tags = t; filled++; }
}
saveState(st);
console.log(`  filled ${filled}`);

const counts = {};
for (const m of Object.values(st.markets)) {
  for (const t of (m.tags || [])) counts[t] = (counts[t] || 0) + 1;
}
console.log('');
console.log('  tags across the registry:');
Object.entries(counts).sort((a, b) => b[1] - a[1]).slice(0, 30)
  .forEach(([k, v]) => console.log(`    ${k.padEnd(30)} ${v}`));
