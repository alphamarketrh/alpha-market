import { config, loadState } from "./config.js";
import { fetchMarket } from "./polymarket.js";
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

/**
 * What the relayer knows about a market that the chain does not.
 *
 * The registry stores a bytes32 and an end time. The question, the image and
 * the upstream volume live in the relayer state, refreshed from Polymarket
 * every cycle. Without them a market is a hash, which is unreadable to anyone
 * who did not register it.
 */
function upstreamMeta() {
  try {
    const st = loadState();
    const out = {};
    for (const [id, m] of Object.entries(st.markets || {})) {
      out[id.toLowerCase()] = {
        question: m.question || null,
        image: m.image || null,
        slug: m.slug || null,
        volumeUsd: m.volumeUsd || 0,
        tags: m.tags || [],
        // An event groups markets that are one question with different
        // answers: nine candidates for a nomination, six strike prices on one
        // day. Carrying the grouping lets an interface show them as one card
        // with rows rather than nine cards repeating the same sentence.
        eventId: m.eventId || null,
        eventTitle: m.eventTitle || null,
        eventImage: m.eventImage || null,
        // The short label for this row, e.g. "62,000" or "Oprah Winfrey".
        // Null on a market that stands alone.
        rowLabel: m.groupItemTitle || null,
      };
    }
    return out;
  } catch {
    // A missing or half-written state file must not take the API down.
    return {};
  }
}

/**
 * Market metadata, cached for a few seconds.
 *
 * A /book call reads the status and token pair of every market in every
 * settlement currency. With five currencies and ninety-six markets that is
 * close to two thousand chain reads, measured at seventy-two seconds, and the
 * frontend polls every twenty. Requests were piling up faster than they
 * finished.
 *
 * Almost none of it changes between calls: token addresses never change once a
 * market is initialised, and a status changes at most a few times in a market
 * lifetime. Ten seconds of cache turns the common case into one read per
 * market and leaves the numbers that actually move, the orders, uncached.
 */
const META_TTL_MS = 10_000;
const metaCache = new Map();

async function readMarket(ctx, id) {
  const key = `${ctx.core?.target ?? "x"}:${id}`;
  const hit = metaCache.get(key);
  if (hit && Date.now() - hit.at < META_TTL_MS) return hit.v;

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
  const out = {
    id,
    status: STATUS_NAMES[Number(status)] || String(status),
    outcome: OUTCOME_NAMES[Number(m.outcome)] || String(m.outcome),
    endTime: Number(m.endTime),
    yesToken: yes,
    noToken: no,
  };
  metaCache.set(key, { at: Date.now(), v: out });
  return out;
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

/**
 * The whole book, served from a background refresh.
 *
 * The public RPC rate limits: raising concurrency to speed this up produced
 * 429s and retry waits that made it slower, not faster. Reading it on demand
 * also meant every visitor paid for a full sweep, and the frontend polls every
 * twenty seconds.
 *
 * So one refresh runs in the background at a pace the RPC tolerates, and every
 * request is answered from what it last produced. A response therefore names
 * the block it was built at, which may be a little behind the head. Orders and
 * balances that matter for a transaction are read by the wallet directly from
 * chain, so nothing is decided on this snapshot.
 */
let bookCache = null;
let bookBuilding = false;

/**
 * Set while a cycle is broadcasting, so the sweep waits its turn.
 *
 * The relayer and this refresh share one rate limited RPC. Running both at once
 * is what produced "exceeded maximum retry limit": the cycle sends transactions
 * a few seconds apart while the sweep issues hundreds of reads, and together
 * they pass what the endpoint allows. Writes matter more than a fresh snapshot,
 * so the sweep yields.
 */
let cycleBusy = false;
export function setCycleBusy(v) { cycleBusy = v; }

async function refreshBook(ctx) {
  if (bookBuilding || cycleBusy) return;
  bookBuilding = true;
  const started = Date.now();
  try {
    bookCache = { at: Date.now(), v: await buildBook(ctx, {}) };
    console.log(`  book rebuilt in ${((Date.now() - started) / 1000).toFixed(1)}s`);
  } catch (e) {
    console.log(`  book refresh failed after ${((Date.now() - started) / 1000).toFixed(1)}s: ${String(e).slice(0, 80)}`);
  } finally {
    bookBuilding = false;
  }
}

export function startBookRefresh(ctx, everyMs = 180000) {
  // A full sweep measured 163 seconds across two hundred markets and five
  // currencies, so asking every thirty simply queued four calls that the guard
  // above threw away. Three minutes lets one finish before the next begins.

  refreshBook(ctx);
  setInterval(() => refreshBook(ctx), everyMs);
}

export async function bookSnapshot(ctx, { marketId = null, onlyActive = true } = {}) {
  // A single market is cheap enough to read live.
  if (marketId) return buildBook(ctx, { marketId, onlyActive });
  if (bookCache) return { ...bookCache.v, builtMsAgo: Date.now() - bookCache.at };

  // Never sweep the whole registry inside a request. Two hundred markets
  // across five currencies takes minutes when the relayer is also broadcasting,
  // and both share one rate limited RPC, so the caller would simply hang.
  // Answer honestly instead: nothing yet, and say why.
  return {
    chainId: config.chainId,
    block: 0,
    building: true,
    note: "the first sweep has not finished; try again shortly",
    markets: [],
    pairs: [],
  };
}

async function buildBook(ctx, { marketId = null, onlyActive = true } = {}) {
  const block = await ctx.provider.getBlockNumber();
  let ids;
  if (marketId) {
    ids = [marketId];
  } else {
    const count = Number(await ctx.registry.marketCount());
    const idx = Array.from({ length: count }, (_, i) => i);
    ids = await mapLimit(idx, 8, (i) => ctx.registry.marketIds(i));
  }

  const markets = await mapLimit(ids, 4, (id) => readMarket(ctx, id));
  const live = onlyActive ? markets.filter((m) => m.status === "Active") : markets;
  const orders = await mapLimit(live, 3, (m) => readOrders(ctx, m.id));

  const meta = upstreamMeta();
  const rows = live.map((m, i) => ({
    ...m,
    ...(meta[m.id.toLowerCase()] || {}),
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
      const pmarkets = await mapLimit(live, 4, (m) => readMarket(pctx, m.id));
      const porders = await mapLimit(pmarkets, 3, (m) => readOrders(pctx, m.id));
      const prows = pmarkets
        .map((m, i) => ({
          ...m,
          ...(meta[m.id.toLowerCase()] || {}),
          ...summarise(porders[i] || []),
          orders: (porders[i] || []).filter((o) => o.open),
        }))
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
/**
 * What the lending facility looks like right now.
 *
 * These move with every deposit, borrow and repayment, so an interface that
 * hardcoded them would be wrong within minutes. A vault that is absent or
 * unreadable returns null rather than taking the endpoint down.
 */
async function lendingSnapshot(vault) {
  if (!vault) return null;
  try {
    const [supplied, borrowed, idle, util, borrow, supply, ceiling, haircut, reserve] =
      await Promise.all([
        vault.totalSupplied(), vault.totalPrincipal(), vault.availableLiquidity(),
        vault.utilisation(), vault.borrowRate(), vault.supplyRate(),
        vault.rateCeilingBps(), vault.haircutBps(), vault.reserveBps(),
      ]);
    return {
      totalSupplied: String(supplied),
      totalBorrowed: String(borrowed),
      availableToLend: String(idle),
      utilisationBps: Number(util),
      borrowRateBps: Number(borrow),
      supplyRateBps: Number(supply),
      rateCeilingBps: Number(ceiling),
      haircutBps: Number(haircut),
      reserveBps: Number(reserve),
    };
  } catch {
    return null;
  }
}

/**
 * Addresses and parameters, cached.
 *
 * Contract addresses never change and parameters change rarely, but the
 * lending figures move with every deposit and repayment, so the whole thing is
 * rebuilt on a short cycle rather than on demand. Fourteen chain reads per
 * visitor against a rate limited public RPC is what made this slow.
 */
let cfgCache = null;
const CFG_TTL_MS = 15_000;

/**
 * The resolution rules for one market, fetched when somebody asks.
 *
 * Descriptions run to a thousand characters at the median and three thousand
 * at the top. Keeping one on every market would roughly double a state file
 * that is rewritten every cycle, to serve text that is only ever read when a
 * single market is opened. So it is fetched on demand and held briefly.
 *
 * What comes back describes how POLYMARKET resolves the question. This venue
 * mirrors that answer but reaches it through its own registry: the relayer
 * proposes an outcome with a bond, anyone may dispute it, and an arbiter rules
 * after a delay. An interface should say so rather than let a reader assume
 * Polymarket settles their position.
 */
const ruleCache = new Map();
const RULE_TTL_MS = 30 * 60 * 1000;

export async function marketRules(id) {
  const key = String(id).toLowerCase();
  const hit = ruleCache.get(key);
  if (hit && Date.now() - hit.at < RULE_TTL_MS) return hit.v;

  const src = await fetchMarket(id);
  const v = src
    ? {
        id,
        question: src.question || null,
        description: src.description || null,
        resolutionSource: src.resolutionSource || null,
        endDate: src.endDate || null,
        outcomes: (() => {
          try {
            return typeof src.outcomes === "string"
              ? JSON.parse(src.outcomes)
              : src.outcomes || null;
          } catch {
            return null;
          }
        })(),
      }
    : { id, description: null, note: "not found upstream" };

  ruleCache.set(key, { at: Date.now(), v });
  return v;
}

export async function configSnapshot(ctx) {
  if (cfgCache && Date.now() - cfgCache.at < CFG_TTL_MS) {
    return { ...cfgCache.v, builtMsAgo: Date.now() - cfgCache.at };
  }
  const v = await buildConfig(ctx);
  cfgCache = { at: Date.now(), v };
  return v;
}

async function buildConfig(ctx) {
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
      lendingVault: config.lendingVault,
      interestModel: config.interestModel,
      riskModel: config.riskModel,
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
      lendingVault: p.lendingVault,
      crossVaultToAUSD: p.crossVaultToAUSD,
      marginVault: p.marginVault,
    })),
    lending: await lendingSnapshot(ctx.lending),
    notes: [
      "prices are millionths of one collateral unit, so 600000 means 0.60",
      "the borrow rate follows utilisation and is capped by rateCeilingBps",
      "a hedged pair lends against a floor proven by arithmetic, so no oracle and no liquidation",
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
  const raw = await mapLimit(ids, 8, (id) => readMarket(ctx, id));
  const meta = upstreamMeta();
  const markets = raw.map((m) => ({ ...m, ...(meta[m.id.toLowerCase()] || {}) }));
  return { chainId: config.chainId, count, markets };
}
