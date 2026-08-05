// Richter calibration. Read only, no gas, no contract touched.
//
// Pulls every published round for each Robinhood equity feed on mainnet 4663,
// then replays what a Richter market would have settled at for every close to
// open window in the data.
//
// The public endpoint rate limits and the ceiling is not documented, so the batch
// size is discovered rather than assumed: halve on a 429, creep back up while
// calls succeed. Progress is checkpointed, so a run that stops can be restarted
// and will continue instead of starting over.
//
// Session times are EDT, UTC-4. Robinhood Chain mainnet launched 1 July 2026 and
// this data ends in August, so the whole set is inside EDT. A run extending past
// the November change must handle EST at UTC-5.

import { writeFileSync, readFileSync, existsSync, unlinkSync } from "node:fs";

const RPC = process.env.RH_MAINNET_RPC;
if (!RPC) { console.error("RH_MAINNET_RPC not set"); process.exit(1); }

const FEEDS = {
  TSLA: "0x4A1166a659A55625345e9515b32adECea5547C38",
  AMD:  "0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72",
  AMZN: "0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C",
  PLTR: "0x820ABedFF239034956B7A9d2F0a331f9F075eB4c",
};

const SEL_LATEST = "0xfeaf968c";
const SEL_GET    = "0x9a6fc8f5";
const CLOSE_UTC_H = 20.0;   // 16:00 ET
const OPEN_UTC_H  = 13.5;   // 09:30 ET
const CAPS = [0.01, 0.02, 0.03, 0.05, 0.08, 0.12];

let rpcCalls = 0, rateLimited = 0;
class RateLimit extends Error {}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function rpc(batch) {
  for (let attempt = 1; attempt <= 8; attempt++) {
    let res;
    try {
      res = await fetch(RPC, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(batch),
      });
    } catch (e) {
      if (attempt === 8) throw e;
      await sleep(500 * attempt);
      continue;
    }
    if (res.status === 429) { rateLimited++; throw new RateLimit("429"); }
    if (!res.ok) {
      if (attempt === 8) throw new Error(`http ${res.status}`);
      await sleep(500 * attempt);
      continue;
    }
    const j = await res.json();
    rpcCalls += batch.length;
    const arr = Array.isArray(j) ? j : [j];
    // A node that rejects a whole batch answers with one error object rather than
    // one per request. Surfacing it stops a silent zero being read as an empty feed.
    if (arr.length === 1 && batch.length > 1 && arr[0].error) {
      throw new Error(`batch rejected: ${JSON.stringify(arr[0].error).slice(0, 160)}`);
    }
    return arr;
  }
  throw new Error("unreachable");
}

function decodeRound(hex) {
  if (!hex || hex.length < 2 + 64 * 5) return null;
  const w = (i) => hex.slice(2 + i * 64, 2 + (i + 1) * 64);
  const answer = BigInt("0x" + w(1));
  const updatedAt = Number(BigInt("0x" + w(3)));
  if (updatedAt === 0 || answer <= 0n) return null;
  return { answer, updatedAt };
}

const encodeRoundId = (phase, n) => (BigInt(phase) << 64n) | BigInt(n);

async function fetchAll(symbol, addr) {
  const cache = `research/data/richter_rounds_${symbol}.json`;
  const partial = cache + ".partial";

  if (existsSync(cache)) {
    const c = JSON.parse(readFileSync(cache, "utf8"));
    console.log(`  ${symbol.padEnd(5)} ${String(c.rounds.length).padStart(5)} rounds from cache`);
    return c.rounds.map((r) => ({ answer: BigInt(r.a), updatedAt: r.t }));
  }

  const [head] = await rpc([{ jsonrpc: "2.0", id: 1, method: "eth_call",
    params: [{ to: addr, data: SEL_LATEST }, "latest"] }]);
  if (head.error || !head.result) throw new Error(`${symbol}: latestRoundData failed`);
  const rid = BigInt("0x" + head.result.slice(2, 66));
  const phase = Number(rid >> 64n);
  const top = Number(rid & 0xffffffffffffffffn);

  const rounds = [];
  let missing = 0, errored = 0, empty = 0, firstError = null;
  let size = 20, ok = 0, start = 1;

  if (existsSync(partial)) {
    const c = JSON.parse(readFileSync(partial, "utf8"));
    if (c.top === top) {
      for (const r of c.rounds) rounds.push({ answer: BigInt(r.a), updatedAt: r.t });
      start = c.next;
      console.log(`  ${symbol.padEnd(5)} resuming at ${start} with ${rounds.length} kept`);
    }
  }

  while (start <= top) {
    const end = Math.min(start + size - 1, top);
    const batch = [];
    for (let n = start; n <= end; n++) {
      const id = encodeRoundId(phase, n).toString(16).padStart(64, "0");
      batch.push({ jsonrpc: "2.0", id: n, method: "eth_call",
        params: [{ to: addr, data: SEL_GET + id }, "latest"] });
    }

    let out;
    try {
      out = await rpc(batch);
    } catch (e) {
      if (e instanceof RateLimit) {
        size = Math.max(1, size >> 1);
        ok = 0;
        process.stdout.write(`\r  ${symbol.padEnd(5)} rate limited, batch -> ${size}, waiting        `);
        await sleep(2500);
        continue;
      }
      throw e;
    }

    // Match by request id, never by array position. A node may answer out of
    // order, and one dropped entry would shift every later round onto the wrong
    // timestamp without anything looking broken.
    const byId = new Map(out.map((o) => [o.id, o]));
    for (let n = start; n <= end; n++) {
      const o = byId.get(n);
      if (!o) { missing++; continue; }
      if (o.error) {
        errored++;
        if (firstError === null) firstError = JSON.stringify(o.error).slice(0, 160);
        continue;
      }
      const d = decodeRound(o.result);
      if (d) rounds.push(d); else empty++;
    }

    start = end + 1;
    ok++;
    if (ok >= 4 && size < 60) { size = Math.min(60, size * 2); ok = 0; }
    if (rounds.length && start % 400 < size) {
      writeFileSync(partial, JSON.stringify({ top, next: start,
        rounds: rounds.map((r) => ({ a: r.answer.toString(), t: r.updatedAt })) }));
    }
    await sleep(150);
    process.stdout.write(`\r  ${symbol.padEnd(5)} ${end}/${top}  kept ${rounds.length}  batch ${size}    `);
  }

  rounds.sort((a, b) => a.updatedAt - b.updatedAt);

  // Refuse to cache a pull that mostly failed. Caching it would make every later
  // run reuse bad data and look reproducible while being wrong.
  if (rounds.length < top * 0.5) {
    console.log(`\r  ${symbol.padEnd(5)} FAILED: kept ${rounds.length} of ${top}` +
      `  (missing ${missing}, errored ${errored}, empty ${empty})    `);
    if (firstError) console.log(`    first error: ${firstError}`);
    throw new Error(`${symbol}: refusing to cache an incomplete pull`);
  }

  if (existsSync(partial)) unlinkSync(partial);
  writeFileSync(cache, JSON.stringify({ symbol, address: addr, phase, top,
    rounds: rounds.map((r) => ({ a: r.answer.toString(), t: r.updatedAt })) }));
  console.log(`\r  ${symbol.padEnd(5)} ${String(rounds.length).padStart(5)} of ${top} rounds` +
    `  (missing ${missing}, errored ${errored}, never published ${empty})    `);
  return rounds;
}

function lastAtOrBefore(rs, t) {
  let lo = 0, hi = rs.length - 1, a = -1;
  while (lo <= hi) { const m = (lo + hi) >> 1;
    if (rs[m].updatedAt <= t) { a = m; lo = m + 1; } else hi = m - 1; }
  return a < 0 ? null : rs[a];
}
function firstAtOrAfter(rs, t) {
  let lo = 0, hi = rs.length - 1, a = -1;
  while (lo <= hi) { const m = (lo + hi) >> 1;
    if (rs[m].updatedAt >= t) { a = m; hi = m - 1; } else lo = m + 1; }
  return a < 0 ? null : rs[a];
}

function buildWindows(rounds) {
  const first = rounds[0].updatedAt, last = rounds[rounds.length - 1].updatedAt;
  const dayOf = (t) => Math.floor(t / 86400) * 86400;
  const out = [];
  for (let d = dayOf(first); d <= dayOf(last); d += 86400) {
    const dow = new Date(d * 1000).getUTCDay();
    if (dow === 0 || dow === 6) continue;
    const close = d + Math.round(CLOSE_UTC_H * 3600);
    const nextOpenDay = dow === 5 ? d + 3 * 86400 : d + 86400;
    const open = nextOpenDay + Math.round(OPEN_UTC_H * 3600);
    if (open > last || close < first) continue;
    out.push({ kind: dow === 5 ? "weekend" : "daily", close, open });
  }
  return out;
}

const pct = (xs, p) => {
  if (!xs.length) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(p * s.length))];
};
const f2 = (x) => (Number.isFinite(x) ? (x * 100).toFixed(2) : "n/a");

console.log("=== fetching rounds from mainnet 4663 ===");
const results = {};
for (const [sym, addr] of Object.entries(FEEDS)) results[sym] = await fetchAll(sym, addr);
console.log(`  rpc calls: ${rpcCalls}, rate limited ${rateLimited} times`);

console.log("\n=== close to open windows ===");
const all = { daily: [], weekend: [] };
for (const [sym, rounds] of Object.entries(results)) {
  if (rounds.length < 2) { console.log(`  ${sym}: too few rounds`); continue; }
  const moves = { daily: [], weekend: [] };
  for (const w of buildWindows(rounds)) {
    const a = lastAtOrBefore(rounds, w.close);
    const b = firstAtOrAfter(rounds, w.open);
    if (!a || !b || a.updatedAt >= b.updatedAt) continue;
    const move = Math.abs(Number(b.answer) / Number(a.answer) - 1);
    moves[w.kind].push(move);
    all[w.kind].push(move);
  }
  console.log(`  ${sym.padEnd(5)} daily n=${String(moves.daily.length).padStart(3)}` +
    `  median ${f2(pct(moves.daily, 0.5))}%  p90 ${f2(pct(moves.daily, 0.9))}%` +
    `  max ${f2(moves.daily.length ? Math.max(...moves.daily) : NaN)}%` +
    `   |   weekend n=${String(moves.weekend.length).padStart(2)}` +
    `  median ${f2(pct(moves.weekend, 0.5))}%` +
    `  max ${f2(moves.weekend.length ? Math.max(...moves.weekend) : NaN)}%`);
}

console.log("\n=== what BIG is worth, pooled across tickers ===");
console.log("  Fair price of BIG is the mean of s. A minter selling BIG above that");
console.log("  price profits on average.\n");
for (const kind of ["daily", "weekend"]) {
  const xs = all[kind];
  if (!xs.length) { console.log(`  ${kind}: no windows\n`); continue; }
  console.log(`  ${kind}  n=${xs.length}`);
  console.log("    cap    fair BIG    p50 s    p90 s   pays full");
  for (const c of CAPS) {
    const ss = xs.map((m) => Math.min(m, c) / c);
    const mean = ss.reduce((a, b) => a + b, 0) / ss.length;
    const full = ss.filter((x) => x >= 0.999).length / ss.length;
    console.log(`    ${(c * 100).toFixed(0).padStart(3)}%    ${mean.toFixed(3).padStart(7)}   ` +
      `${pct(ss, 0.5).toFixed(3)}   ${pct(ss, 0.9).toFixed(3)}   ${(full * 100).toFixed(0).padStart(4)}%`);
  }
  console.log("");
}

console.log("=== caveat ===");
console.log("  Mainnet launched 1 July 2026, so this is about five weeks of data.");
console.log("  The weekend sample is single digit and contains no earnings window.");
console.log("  A first read, not a conclusion.");
