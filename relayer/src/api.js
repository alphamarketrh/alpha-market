import { config } from "./config.js";
import { mapLimit } from "./polymarket.js";
import { loadPairs, connectPairs, pairContext } from "./pairs.js";

/**
 * Read API for the order book.
 *
 * The book is fully on chain and anyone can read it, but reading it directly
 * costs one RPC call per order plus one per market. With dozens of markets that
 * is thousands of calls before a person can see a single price, which makes a
 * public book unusable in practice. The relayer already loads every order each
 * cycle for matching, so it serves that same data over HTTP.
 *
 * This is a convenience layer, not a source of truth. Every value here is
 * readable from the chain, and the response says which block it came from so a
 * caller can verify it independently.
 */

const ONE = 1_000_000n;
const SIDE_NAMES = ["BuyYes", "SellYes", "BuyNo", "SellNo"];
const STATUS_NAMES = ["None", "Active", "Halted", "Proposed", "Disputed", "Resolved"];
const OUTCOME_NAMES = ["Unresolved", "Yes", "No", "Invalid"];

/** Prices are millionths of one collateral unit; present them as 0..1. */
const asPrice = (v) => Number(v) / 1e6;
const asUnits = (v) => Number(v) / 1e6;

async function readMarket(ctx, id) {
  const [m, status] = await Promise.all([
    ctx.registry.getMarket(id),
    ctx.registry.statusOf(id),
  ]);
  let yes = null;
  let no = null;
  try {
    const t = await ctx.core.tokensOf(id);
    yes = t[0];
    no = t[1];
  } catch { /* not initialised */ }
  return {
    id,
    status: STATUS_NAMES[Number(status)] || String(status),
    outcome: OUTCOME_NAMES[Number(m.outcome)] || String(m.outcome),
    endTime: Number(m.endTime),
    yesToken: yes,
    noToken: no,
  };
}

async function readOrders(ctx, id) {
  if (!ctx.book) return [];
  const count = Number(await ctx.book.marketOrderCount(id));
  if (count === 0) return [];
  const ids = await ctx.book.marketOrderIds(id);
  const raw = await mapLimit(Array.from(ids), 8, async (oid) => {
    try {
      return { oid, o: await ctx.book.getOrder(oid) };
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
    const open = !o.cancelled && remaining > 0n && BigInt(o.expiry) >= nowS;
    out.push({
      id: String(r.oid),
      maker: o.maker,
      side: SIDE_NAMES[Number(o.side)],
      price: asPrice(o.price),
      amount: asUnits(o.amount),
      remaining: asUnits(remaining),
      expiry: Number(o.expiry),
      open,
    });
  }
  return out;
}

/** Best bid and ask per outcome, plus the implied mid. */
function summarise(orders) {
  const open = orders.filter((o) => o.open);
  const best = (side, pick) => {
    const xs = open.filter((o) => o.side === side).map((o) => o.price);
    return xs.length ? pick(...xs) : null;
  };
  const bidYes = best("BuyYes", Math.max);
  const askYes = best("SellYes", Math.min);
  const bidNo = best("BuyNo", Math.max);
  const askNo = best("SellNo", Math.min);
  const mid = (b, a) => (b !== null && a !== null ? (b + a) / 2 : (b ?? a));
  return {
    openOrders: open.length,
    yes: { bid: bidYes, ask: askYes, mid: mid(bidYes, askYes) },
    no: { bid: bidNo, ask: askNo, mid: mid(bidNo, askNo) },
    // A buy of YES and a buy of NO whose limits sum to at least one unit can be
    // minted into a fresh pair, which is how a market with no tokens starts.
    mintable: bidYes !== null && bidNo !== null && bidYes + bidNo >= 1,
  };
}

export async function bookSnapshot(ctx, { marketId = null, onlyActive = true } = {}) {
  const block = await ctx.provider.getBlockNumber();
  let ids;
  if (marketId) {
    ids = [marketId];
  } else {
    const count = Number(await ctx.registry.marketCount());
    const idx = Array.from({ length: count }, (_, i) => i);
    ids = await mapLimit(idx, 8, (i) => ctx.registry.marketIds(i));
  }

  const markets = await mapLimit(ids, 6, (id) => readMarket(ctx, id));
  const live = onlyActive ? markets.filter((m) => m.status === "Active") : markets;
  const orders = await mapLimit(live, 4, (m) => readOrders(ctx, m.id));

  const rows = live.map((m, i) => ({
    ...m,
    ...summarise(orders[i] || []),
    orders: (orders[i] || []).filter((o) => o.open),
  }));

  // Markets with resting orders first: those are the ones worth looking at.
  rows.sort((a, b) => b.openOrders - a.openOrders);

  // The same markets, quoted in every settlement currency that exists.
  const pairs = [];
  for (const pair of connectPairs(ctx, loadPairs(config.deploymentsDir, config.chainId))) {
    if (!pair.bookContract) continue;
    try {
      const pctx = pairContext(ctx, pair);
      const pmarkets = await mapLimit(live, 6, (m) => readMarket(pctx, m.id));
      const porders = await mapLimit(pmarkets, 4, (m) => readOrders(pctx, m.id));
      const prows = pmarkets
        .map((m, i) => ({ ...m, ...summarise(porders[i] || []), orders: (porders[i] || []).filter((o) => o.open) }))
        .sort((a, b) => b.openOrders - a.openOrders);
      pairs.push({
        symbol: pair.symbol,
        decimals: pair.decimals,
        collateral: pair.collateral,
        core: pair.core,
        orderBook: pair.orderBook,
        markets: prows,
      });
    } catch (e) {
      pairs.push({ symbol: pair.symbol, error: String(e).slice(0, 120) });
    }
  }

  return {
    chainId: config.chainId,
    block,
    orderBook: config.orderBook,
    collateral: config.collateral,
    marketCount: markets.length,
    markets: rows,
    pairs,
    note: "convenience read layer; every value is verifiable on chain at the stated block",
  };
}

/**
 * Every address a caller needs, read from the deployment record.
 *
 * Addresses change whenever a contract with an immutable dependency is
 * replaced, and a stale address fails silently rather than loudly: a call to a
 * dead registry simply returns nothing. Serving them from the running relayer
 * means the answer is always the deployment the relayer itself is using, and
 * anything written down elsewhere can be checked against it.
 */
export async function configSnapshot(ctx) {
  const block = await ctx.provider.getBlockNumber();
  const [collSymbol, collDecimals, claimAmount, cooldown] = await Promise.all([
    ctx.collateral.symbol().catch(() => null),
    ctx.collateral.decimals().catch(() => null),
    ctx.collateral.claimAmount ? ctx.collateral.claimAmount().catch(() => null) : null,
    ctx.collateral.cooldown ? ctx.collateral.cooldown().catch(() => null) : null,
  ]);

  return {
    chainId: config.chainId,
    block,
    rpc: "https://rpc.testnet.chain.robinhood.com",
    explorer: "https://explorer.testnet.chain.robinhood.com",
    contracts: {
      collateral: config.collateral,
      registry: config.registry,
      core: config.core,
      orderBook: config.orderBook,
      marginVault: config.marginVault,
      directionalVault: config.directionalVault,
      parlayFactory: config.parlayFactory,
      positionOracle: config.positionOracle,
    },
    collateralInfo: {
      symbol: collSymbol,
      decimals: collDecimals === null ? null : Number(collDecimals),
      claimAmount: claimAmount === null ? null : String(claimAmount),
      cooldownSeconds: cooldown === null ? null : Number(cooldown),
      howToGet: "call claim() on the collateral contract; no permission needed",
    },
    pairs: loadPairs(config.deploymentsDir, config.chainId).map((p) => ({
      symbol: p.symbol,
      decimals: p.decimals,
      collateral: p.collateral,
      core: p.core,
      orderBook: p.orderBook,
      marginVault: p.marginVault,
    })),
    notes: [
      "prices are millionths of one collateral unit, so 600000 means 0.60",
      "a question resolves once; each pair settles that answer in its own currency",
      "YES-aUSD and YES-TSLA are different tokens with different books and prices",
      "equity lending is not deployed here: chain 46630 has no Chainlink equity feed",
    ],
  };
}

export async function marketList(ctx) {
  const count = Number(await ctx.registry.marketCount());
  const idx = Array.from({ length: count }, (_, i) => i);
  const ids = await mapLimit(idx, 8, (i) => ctx.registry.marketIds(i));
  const markets = await mapLimit(ids, 8, (id) => readMarket(ctx, id));
  return { chainId: config.chainId, count, markets };
}
