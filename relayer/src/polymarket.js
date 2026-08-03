import { config } from "./config.js";

const UA = { "User-Agent": "alpha-market-relayer/0.1" };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function get(url, { timeout = 20000 } = {}) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeout);
  try {
    const res = await fetch(url, { headers: UA, signal: ctl.signal });
    if (!res.ok) return { ok: false, status: res.status, body: null };
    return { ok: true, status: res.status, body: await res.json() };
  } catch (e) {
    return { ok: false, status: 0, body: null, error: String(e).slice(0, 120) };
  } finally {
    clearTimeout(t);
  }
}

/** Gamma encodes several array fields as JSON strings. */
function jparse(v) {
  if (typeof v !== "string") return v;
  try { return JSON.parse(v); } catch { return null; }
}

/**
 * Fetch active markets ordered by volume.
 *
 * WARNING learned the hard way: Gamma silently ignores unknown query params and
 * returns an unfiltered page instead of an error. Never assume a filter applied
 * without checking the returned rows.
 */
export async function fetchActiveMarkets(limit = config.scanLimit) {
  const out = [];
  let offset = 0;
  while (out.length < limit) {
    const page = Math.min(100, limit - out.length);
    const url = `${config.gamma}/markets?active=true&closed=false&archived=false` +
                `&limit=${page}&offset=${offset}&order=volumeNum&ascending=false`;
    const { ok, body } = await get(url);
    if (!ok || !Array.isArray(body) || body.length === 0) break;
    out.push(...body);
    if (body.length < page) break;
    offset += page;
    await sleep(config.apiDelayMs);
  }
  return out.slice(0, limit);
}

/**
 * Look up one market by conditionId.
 *
 * Gamma excludes closed markets by default and returns [] with no error, so a
 * resolved market must be requested explicitly with closed=true.
 */
export async function fetchMarket(conditionId) {
  let r = await get(`${config.gamma}/markets?condition_ids=${conditionId}`);
  if (r.ok && Array.isArray(r.body) && r.body.length) return r.body[0];
  await sleep(config.apiDelayMs);
  r = await get(`${config.gamma}/markets?condition_ids=${conditionId}&closed=true`);
  if (r.ok && Array.isArray(r.body) && r.body.length) return r.body[0];
  return null;
}

/**
 * Measure resting notional near the mid.
 *
 * Volume is NOT depth. Measured on 2026-07-28: a market with $56M lifetime
 * volume held $282 within five probability points of the mid. Order arrays are
 * sorted explicitly rather than trusting the API's ordering.
 */
export function computeDepth(book, band = config.depthBand) {
  const num = (arr) => (arr || []).map((x) => [parseFloat(x.price), parseFloat(x.size)])
    .filter(([p, q]) => Number.isFinite(p) && Number.isFinite(q));
  const bids = num(book?.bids);
  const asks = num(book?.asks);
  if (!bids.length || !asks.length) return null;

  bids.sort((a, b) => a[0] - b[0]);
  asks.sort((a, b) => a[0] - b[0]);

  const bestBid = bids[bids.length - 1][0];
  const bestAsk = asks[0][0];
  if (!(bestAsk > bestBid)) return null;

  const mid = (bestBid + bestAsk) / 2;
  let depth = 0;
  for (const [p, q] of bids) if (p >= mid - band) depth += p * q;
  for (const [p, q] of asks) if (p <= mid + band) depth += p * q;

  return { bestBid, bestAsk, mid, spread: bestAsk - bestBid, depthUsd: depth };
}

export async function fetchDepth(market) {
  const toks = jparse(market.clobTokenIds);
  if (!Array.isArray(toks) || !toks.length) return null;
  const { ok, body } = await get(`${config.clob}/book?token_id=${toks[0]}`);
  if (!ok || !body) return null;
  const d = computeDepth(body);
  if (!d) return null;
  return { ...d, tokenId: toks[0], negRisk: body.neg_risk, tickSize: body.tick_size };
}

/**
 * Map a Gamma market onto our on-chain lifecycle.
 *
 * Signals available on Gamma, in the order we trust them:
 *   outcomePrices settled at 1/0 or 0/1  -> determinate outcome
 *   outcomePrices at 0.5/0.5 with closed -> Invalid, matching UMA's 50/50
 *   closed === true, prices not settled  -> upstream is resolving; HALT here
 *
 * Halting on the first sign of upstream resolution, rather than waiting for a
 * final answer, is deliberate. The interval between a proposal appearing on
 * Polygon and the result being knowable here is the largest information leak in
 * a mirror architecture.
 */
export function readResolution(market) {
  const prices = jparse(market.outcomePrices);
  const outcomes = jparse(market.outcomes) || ["Yes", "No"];
  const closed = market.closed === true || market.closed === "true";

  if (Array.isArray(prices) && prices.length >= 2) {
    const a = parseFloat(prices[0]);
    const b = parseFloat(prices[1]);
    const yesIdx = outcomes.findIndex((o) => String(o).toLowerCase() === "yes");
    const yesFirst = yesIdx === -1 ? true : yesIdx === 0;

    const settled = (x) => x >= 0.999 || x <= 0.001;
    if (closed && settled(a) && settled(b)) {
      const yesWon = yesFirst ? a >= 0.999 : b >= 0.999;
      return { state: "resolved", outcome: yesWon ? 1 : 2, prices: [a, b] };
    }
    if (closed && Math.abs(a - 0.5) < 0.01 && Math.abs(b - 0.5) < 0.01) {
      return { state: "resolved", outcome: 3, prices: [a, b] };
    }
  }
  if (closed) return { state: "resolving", outcome: 0 };
  return { state: "open", outcome: 0 };
}

/**
 * Run an async mapper over items with bounded concurrency.
 *
 * Sequential per-market lookups made cycle time grow linearly with the number
 * of mirrored markets (5s at 3 markets, 50s at 30). At the 300s interval that
 * would eventually overlap with the next cycle. Concurrency is capped so we do
 * not hammer the public API.
 */
export async function mapLimit(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (true) {
      const i = next++;
      if (i >= items.length) return;
      try {
        out[i] = await fn(items[i], i);
      } catch (e) {
        out[i] = { __error__: String(e).slice(0, 120) };
      }
    }
  });
  await Promise.all(workers);
  return out;
}

export { jparse };
