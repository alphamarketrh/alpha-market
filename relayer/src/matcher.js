import { config } from "./config.js";
import { send } from "./chain.js";
import { mapLimit } from "./polymarket.js";

/**
 * Order book matching.
 *
 * A resting buy of YES and a resting buy of NO whose limits sum to at least one
 * unit of collateral can be matched into a freshly minted pair. A resting sell
 * of each whose limits sum to at most one unit can be merged back into
 * collateral. Both are single atomic calls that need no capital from the
 * matcher, and the overlap between the two limits pays the gas.
 *
 * THE RELAYER NEVER TAKES A POSITION.
 * fill() is deliberately not used here. Filling requires the taker to deliver
 * the counter-asset, which would leave the relayer holding an outcome token and
 * therefore a directional bet. matchMint and matchMerge move tokens between two
 * makers without the matcher ever holding one.
 *
 * A buy and a sell on the SAME side are cleared by matchCross, which settles
 * both escrows against each other in one atomic call. That also needs no
 * capital, because both sides are already held by the book.
 */

const ONE = 1_000_000n;

const SIDE = { BUY_YES: 0, SELL_YES: 1, BUY_NO: 2, SELL_NO: 3 };

/**
 * The four ways two resting orders can clear.
 *
 *   crossYes  bid for YES against ask for YES, settled directly
 *   crossNo   the same on the NO side
 *   mint      bid for YES plus bid for NO, minted into a fresh pair
 *   merge     ask for YES plus ask for NO, merged back into collateral
 *
 * `paired` marks the two that use complementary sides, where crossing is judged
 * on the SUM of the limits against one whole unit. The cross kinds are ordinary
 * bid against ask, judged on the difference.
 */
const KINDS = {
  crossYes: { a: SIDE.BUY_YES, b: SIDE.SELL_YES, aDesc: true, bDesc: false, paired: false },
  crossNo: { a: SIDE.BUY_NO, b: SIDE.SELL_NO, aDesc: true, bDesc: false, paired: false },
  mint: { a: SIDE.BUY_YES, b: SIDE.BUY_NO, aDesc: true, bDesc: true, paired: true, atLeast: true },
  merge: { a: SIDE.SELL_YES, b: SIDE.SELL_NO, aDesc: false, bDesc: false, paired: true, atLeast: false },
};

function sortBy(list, desc) {
  return [...list].sort((x, y) => (desc ? Number(y.price - x.price) : Number(x.price - y.price)));
}

/**
 * Plan one kind of match, consuming from a shared remaining map.
 *
 * The map is shared across kinds on purpose. An order can be eligible for more
 * than one kind at once, and planning each kind against an untouched snapshot
 * would schedule the same size twice, so the second transaction would revert.
 */
function planKind(orders, kind, rem) {
  const k = KINDS[kind];
  const a = sortBy(orders.filter((o) => o.side === k.a), k.aDesc);
  const b = sortBy(orders.filter((o) => o.side === k.b), k.bDesc);

  const plan = [];
  for (let i = 0; i < a.length; i++) {
    const x = a[i];
    if ((rem.get(x.id) || 0n) === 0n) continue;

    for (let j = 0; j < b.length; j++) {
      const y = b[j];
      if ((rem.get(y.id) || 0n) === 0n) continue;

      // The book rejects a match between two orders from the same maker, so
      // step past it and try the next one. Advancing the outer pointer here
      // instead would silently discard every remaining counterparty.
      if (x.maker.toLowerCase() === y.maker.toLowerCase()) continue;

      let crosses;
      let surplus;
      if (k.paired) {
        const sum = x.price + y.price;
        crosses = k.atLeast ? sum >= ONE : sum <= ONE;
        surplus = k.atLeast ? sum - ONE : ONE - sum;
      } else {
        crosses = x.price >= y.price;      // bid at or above ask
        surplus = x.price - y.price;
      }
      // b is sorted best first, so once one fails to cross none of the rest can.
      if (!crosses) break;

      const ra = rem.get(x.id);
      const rb = rem.get(y.id);
      const amount = ra < rb ? ra : rb;
      plan.push({ kind, aId: x.id, bId: y.id, amount, surplus });
      rem.set(x.id, ra - amount);
      rem.set(y.id, rb - amount);

      if (rem.get(x.id) === 0n) break;   // this order is done, move to the next
    }
  }
  return plan;
}

/**
 * Plan every match available on one market.
 *
 * Direct crosses are planned first. They move existing tokens between two
 * makers, whereas a mint creates new supply and a merge destroys it, so
 * clearing the direct trades first keeps outstanding supply closer to what the
 * market actually needs.
 */
export function planMatches(orders) {
  const rem = new Map();
  for (const o of orders) rem.set(o.id, o.remaining);
  const plan = [];
  for (const kind of ["crossYes", "crossNo", "mint", "merge"]) {
    plan.push(...planKind(orders, kind, rem));
  }
  return plan;
}

/** Read every open order on one market and shape it for the planner. */
async function openOrders(ctx, marketId) {
  const count = Number(await ctx.book.marketOrderCount(marketId));
  if (count === 0) return [];
  const ids = await ctx.book.marketOrderIds(marketId);

  const raw = await mapLimit(Array.from(ids), 8, async (id) => {
    try {
      const o = await ctx.book.getOrder(id);
      return { id, o };
    } catch {
      return null;
    }
  });

  const nowS = BigInt(Math.floor(Date.now() / 1000));
  const out = [];
  for (const r of raw) {
    if (!r || r.__error__ || !r.o) continue;
    const o = r.o;
    const remaining = BigInt(o.amount) - BigInt(o.filled);
    if (o.cancelled) continue;
    if (remaining <= 0n) continue;
    if (BigInt(o.expiry) < nowS) continue;
    out.push({
      id: r.id,
      maker: o.maker,
      side: Number(o.side),
      price: BigInt(o.price),
      remaining,
    });
  }
  return out;
}

export async function matchOrderBook(ctx, state, summary) {
  if (!ctx.book) return;

  const count = Number(await ctx.registry.marketCount());
  if (count === 0) return;

  const idx = Array.from({ length: count }, (_, i) => i);
  const ids = await mapLimit(idx, 8, (i) => ctx.registry.marketIds(i));
  const statuses = await mapLimit(ids, 8, (id) => ctx.registry.statusOf(id));

  // Only Active markets can trade. Halted means upstream has begun resolving,
  // and the book itself refuses a match there, so do not waste the call.
  const active = ids.filter((_, i) => Number(statuses[i]) === 1);
  if (active.length === 0) return;

  // marketOrderCount is a single cheap read, so use it to skip the many
  // markets that have never had an order before fetching any order bodies.
  const counts = await mapLimit(active, 8, (id) => ctx.book.marketOrderCount(id));
  const withOrders = active.filter((_, i) => Number(counts[i]) > 0);
  if (withOrders.length === 0) return;

  let matched = 0;
  let totalSurplus = 0n;

  for (const marketId of withOrders) {
    const orders = await openOrders(ctx, marketId);
    if (orders.length < 2) continue;

    for (const p of planMatches(orders)) {
      const fn = p.kind === "mint"
        ? ctx.book.matchMint
        : p.kind === "merge"
          ? ctx.book.matchMerge
          : ctx.book.matchCross;
      console.log(
        `  MATCH ${p.kind} on ${marketId.slice(0, 10)} ` +
        `orders ${p.aId}/${p.bId} amount ${Number(p.amount) / 1e6} ` +
        `surplus ${Number(p.surplus) / 1e6} per unit`,
      );
      const r = await send(`${p.kind} ${p.aId}+${p.bId}`, fn, p.aId, p.bId, p.amount);
      if (!r.error) {
        matched++;
        totalSurplus += (p.surplus * p.amount) / ONE;
      }
    }
  }

  if (matched > 0) {
    console.log(`-- matched ${matched} pair(s), surplus ${Number(totalSurplus) / 1e6}`);
    summary.matched = matched;
    state.lastMatchAt = new Date().toISOString();
  }
}
