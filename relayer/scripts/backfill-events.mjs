import { loadState, saveState } from '../src/config.js';
import { fetchMarket, fetchEvents } from '../src/polymarket.js';

const st = loadState();
const ms = Object.values(st.markets || {});
const need = ms.filter((m) => !m.eventTitle);
console.log(`  ${ms.length} tracked, ${need.length} without an event title`);

// Some markets never got an event id, and the row label lives on the market
// rather than the event, so both come from one lookup per market.
const noId = need.filter((m) => !m.eventId);
const noLabel = need.filter((m) => m.groupItemTitle === undefined);
const fetchThese = [...new Set([...noId, ...noLabel])];
console.log(`  ${fetchThese.length} need a market lookup`);

let n = 0;
for (const m of fetchThese) {
  const src = await fetchMarket(m.id);
  if (src) {
    const ev = (src.events || [])[0]?.id;
    if (ev) m.eventId = String(ev);
    m.groupItemTitle = String(src.groupItemTitle || '').slice(0, 60) || null;
  }
  if (++n % 25 === 0) console.log(`    ${n}/${fetchThese.length}`);
}

const ids = [...new Set(need.map((m) => m.eventId).filter(Boolean))];
console.log(`  fetching ${ids.length} distinct events`);
const evs = await fetchEvents(ids);

let filled = 0;
for (const m of need) {
  const e = evs[m.eventId];
  if (!e) continue;
  m.eventTitle = e.title;
  m.eventImage = e.image;
  if (e.tags?.length) m.tags = e.tags;
  filled++;
}
saveState(st);
console.log(`  filled ${filled}`);

const g = {};
for (const m of Object.values(st.markets)) {
  const k = m.eventId || m.id;
  (g[k] ||= []).push(m);
}
const multi = Object.values(g).filter((v) => v.length > 1);
console.log('');
console.log(`  ${Object.keys(g).length} cards instead of ${ms.length} markets`);
console.log(`  ${multi.length} of them group more than one row`);
console.log('');
for (const grp of multi.sort((a, b) => b.length - a.length).slice(0, 5)) {
  console.log(`  ${grp[0].eventTitle || grp[0].question} (${grp.length} rows)`);
  for (const m of grp.slice(0, 3)) {
    console.log(`     ${m.groupItemTitle || m.question?.slice(0, 50)}`);
  }
}
