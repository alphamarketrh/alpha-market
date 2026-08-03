import { config } from "./config.js";
import { send } from "./chain.js";
import { fetchMarket, jparse, mapLimit } from "./polymarket.js";

/**
 * Position price maintenance for DirectionalVault.
 *
 * A one-sided prediction position has no provable floor, so lending against it
 * needs a price. MirrorPositionOracle holds that price and refuses to serve one
 * older than maxAge, which freezes borrowing and liquidation together. Nothing
 * wrote those prices, so the vault would have frozen one hour after deployment.
 *
 * ONLY THE YES SIDE IS WRITTEN. NO is derived on chain as ONE - YES, so the two
 * sides can never disagree.
 */

const ONE = 1_000_000n;
const BPS = 10_000n;

/** Extract the YES price from a Gamma market, honouring outcome ordering. */
export function readYesPrice(m) {
  const prices = jparse(m.outcomePrices);
  const outcomes = jparse(m.outcomes) || ["Yes", "No"];
  if (!Array.isArray(prices) || prices.length < 2) return null;

  // Some markets list No first. Assuming index 0 is Yes would invert every
  // price and mark healthy positions as liquidatable.
  let idx = outcomes.findIndex((o) => String(o).toLowerCase() === "yes");
  if (idx === -1) idx = 0;

  const v = parseFloat(prices[idx]);
  if (!Number.isFinite(v) || v <= 0 || v >= 1) return null;
  return BigInt(Math.round(v * 1e6));
}

/**
 * Move `from` toward `to` without exceeding the oracle's per-update cap.
 *
 * The cap stops a single bad write from zeroing every position at once. A
 * genuine gap still arrives, it just takes several cycles. Without this
 * stepping the relayer would simply revert on every large move and the price
 * would go stale, which freezes the vault exactly when it matters.
 */
export function stepToward(from, to, maxMoveBps) {
  if (from === null || from === undefined) return to;
  const maxDelta = (ONE * BigInt(maxMoveBps)) / BPS;
  const diff = to > from ? to - from : from - to;
  if (diff <= maxDelta) return to;
  const stepped = to > from ? from + maxDelta : from - maxDelta;
  if (stepped < 1n) return 1n;
  if (stepped > ONE - 1n) return ONE - 1n;
  return stepped;
}

export async function refreshPositionPrices(ctx, state, summary) {
  if (!ctx.positionOracle) return;

  const count = Number(await ctx.registry.marketCount());
  if (count === 0) return;

  const idx = Array.from({ length: count }, (_, i) => i);
  const ids = await mapLimit(idx, 8, (i) => ctx.registry.marketIds(i));
  const statuses = await mapLimit(ids, 8, (id) => ctx.registry.statusOf(id));

  // Resolved markets no longer need a price; orphans have no source.
  const live = ids.filter((id, i) => {
    if (Number(statuses[i]) === 5) return false;
    const rec = (state.markets ||= {})[id];
    return !(rec && rec.orphan);
  });
  if (live.length === 0) return;

  const maxMoveBps = Number(await ctx.positionOracle.maxMoveBps());
  const maxAge = Number(await ctx.positionOracle.maxAge());
  const nowS = Math.floor(Date.now() / 1000);

  const onchain = await mapLimit(live, 8, async (id) => {
    try {
      const p = await ctx.positionOracle.pointOf(id);
      return { seen: p.seen, price: BigInt(p.yesPrice), at: Number(p.updatedAt) };
    } catch {
      return { seen: false, price: null, at: 0 };
    }
  });

  const sources = await mapLimit(live, 6, (id) => fetchMarket(id));

  const ids2 = [];
  const prices = [];
  const notes = [];

  for (let i = 0; i < live.length; i++) {
    const src = sources[i];
    if (!src || src.__error__) continue;
    const target = readYesPrice(src);
    if (target === null) continue;

    const cur = onchain[i];
    const age = cur.seen ? nowS - cur.at : Infinity;
    const next = cur.seen ? stepToward(cur.price, target, maxMoveBps) : target;

    // Write when the stored price is getting old, or has drifted enough to
    // matter for a liquidation decision. Otherwise leave it alone and save gas.
    const drift = cur.seen && cur.price !== null
      ? (next > cur.price ? next - cur.price : cur.price - next)
      : ONE;
    const stale = age >= maxAge * 0.5;
    const moved = drift >= 5_000n;   // half a probability point
    if (!stale && !moved) continue;

    ids2.push(live[i]);
    prices.push(next);
    const label = String(src.question || "").slice(0, 34);
    notes.push(
      `${live[i].slice(0, 8)} ${cur.seen ? Number(cur.price) / 1e6 : "new"}` +
      `->${Number(next) / 1e6}${next !== target ? " (capped)" : ""} ${label}`,
    );
  }

  if (ids2.length === 0) return;

  console.log(`-- writing ${ids2.length} position price(s)`);
  for (const n of notes.slice(0, 6)) console.log(`   ${n}`);
  if (notes.length > 6) console.log(`   ... and ${notes.length - 6} more`);

  // Chunked so one oversized batch cannot exceed the block gas limit.
  const CHUNK = 25;
  let written = 0;
  for (let i = 0; i < ids2.length; i += CHUNK) {
    const a = ids2.slice(i, i + CHUNK);
    const b = prices.slice(i, i + CHUNK);
    const r = await send(
      `writePrices x${a.length}`, ctx.positionOracle.writePrices, a, b,
    );
    if (!r.error) written += a.length;
  }
  summary.positionPrices = written;
  state.lastPositionPriceWrite = new Date().toISOString();
}
