import { ethers } from "ethers";
import { config } from "./config.js";
import { mapLimit } from "./polymarket.js";
import { loadRichter } from "./richter.js";

/**
 * Read API for Richter markets.
 *
 * Separate from the mirrored book for two reasons, both structural. The market
 * list there comes from Polymarket metadata and drops anything without a
 * question, which every Richter market is. And it reads OrderBook, which holds
 * its core as an immutable and can never see a pair minted by RichterCore.
 *
 * WHY MARKETS COME FROM EVENTS
 * RichterMarketFactory keeps `mapping(bytes32 => bool) opened` and no list, so
 * there is nothing to enumerate on chain. MarketOpened carries every parameter,
 * so the log is the index. Scanned once and cached, then extended from the last
 * block seen, because the log only grows.
 *
 * WHY THE SNAPSHOT IS REBUILT ON A TIMER
 * Reading eleven markets across five currencies is dozens of calls. Doing that
 * per request would make the endpoint slower than reading the chain directly,
 * which would defeat the point of having it.
 */

const FACTORY_ABI = [
  "event MarketOpened(bytes32 indexed id, address indexed feed, uint32 capBps, uint64 closeAt, uint64 openAt, uint256 coreCount)",
  "function coreCount() view returns (uint256)",
  "function cores(uint256) view returns (address)",
];

const ORACLE_ABI = [
  "function windowOf(bytes32) view returns (tuple(address feed, address token, uint32 capBps, uint64 closeAt, uint64 openAt, uint16 phase, bool exists))",
  "function preview(bytes32) view returns (bool ready, uint256 fraction, bool voided)",
];

const CORE_ABI = [
  "function tokensOf(bytes32) view returns (address big, address calm)",
  "function isSettled(bytes32) view returns (bool)",
  "function settlementOf(bytes32) view returns (uint256 s, uint256 at)",
  "function collateral() view returns (address)",
  "function collateralDecimals() view returns (uint8)",
];

const BOOK_ABI = [
  "function marketOrderCount(bytes32) view returns (uint256)",
  "function marketOrderIds(bytes32) view returns (uint256[])",
  // Copied from chain.js rather than written out again. Field order matters and
  // getting it wrong fails as "deferred error during ABI decoding", which points
  // at nothing in particular. The struct that shipped has maker first and an
  // expiry the earlier hand-written version left out entirely.
  "function getOrder(uint256) view returns (tuple(address maker,bytes32 marketId,uint8 side,uint64 price,uint64 expiry,uint128 amount,uint128 filled,uint128 escrow,bool cancelled))",
  "function isOpen(uint256) view returns (bool)",
  "function feeBps() view returns (uint16)",
];

// The book calls them BuyYes and BuyNo because the arithmetic is the same. Here
// they are named for what they actually buy.
const SIDE_NAMES = ["BuyBig", "SellBig", "BuyCalm", "SellCalm"];
const ONE = 1_000_000n;

let cache = null;
let building = false;
let lastScannedBlock = 0;
let knownMarkets = [];

function asPrice(v) {
  return Number(BigInt(v)) / 1e6;
}

/** Scan MarketOpened from where the last scan stopped. The log only grows. */
async function scanMarkets(provider, factoryAddr) {
  const factory = new ethers.Contract(factoryAddr, FACTORY_ABI, provider);
  const head = await provider.getBlockNumber();
  if (lastScannedBlock >= head) return knownMarkets;

  // The node answers the whole range in a fraction of a second, measured at
  // 0.24s across ninety-seven million blocks, so the log is fetched in one call.
  // Walking it in chunks was nine hundred sequential requests and timed out.
  const from = lastScannedBlock === 0 ? 0 : lastScannedBlock + 1;
  const found = [];
  try {
    const logs = await factory.queryFilter(factory.filters.MarketOpened(), from, head);
    for (const l of logs) {
      found.push({
        id: l.args.id,
        feed: l.args.feed,
        capBps: Number(l.args.capBps),
        closeAt: Number(l.args.closeAt),
        openAt: Number(l.args.openAt),
        block: l.blockNumber,
      });
    }
  } catch (e) {
    console.log(`  richter scan ${from}-${head}: ${String(e).slice(0, 70)}`);
    return knownMarkets;   // keep what is already known rather than losing it
  }

  lastScannedBlock = head;
  if (found.length) {
    const seen = new Set(knownMarkets.map((m) => m.id));
    for (const m of found) if (!seen.has(m.id)) knownMarkets.push(m);
    knownMarkets.sort((a, b) => b.closeAt - a.closeAt);
  }
  return knownMarkets;
}

async function readOrders(book, id, decimals) {
  const count = Number(await book.marketOrderCount(id));
  if (count === 0) return [];
  const ids = await book.marketOrderIds(id);
  const raw = await mapLimit(Array.from(ids), 8, async (oid) => {
    try {
      return { oid, o: await book.getOrder(oid) };
    } catch {
      return null;
    }
  });

  const nowS = BigInt(Math.floor(Date.now() / 1000));
  const unit = 10n ** BigInt(decimals);
  const out = [];
  for (const r of raw) {
    if (!r || r.__error__ || !r.o) continue;
    const o = r.o;
    const remaining = BigInt(o.amount) - BigInt(o.filled);
    out.push({
      id: String(r.oid),
      maker: o.maker,
      side: SIDE_NAMES[Number(o.side)],
      price: asPrice(o.price),
      amount: Number((BigInt(o.amount) * 10000n) / unit) / 10000,
      remaining: Number((remaining * 10000n) / unit) / 10000,
      expiry: Number(o.expiry ?? 0),
      open: !o.cancelled && remaining > 0n,
    });
  }
  return out;
}

/** Best bid and ask for one side, from the open orders. */
function quote(orders, buySide, sellSide) {
  const bids = orders.filter((o) => o.open && o.side === buySide).map((o) => o.price);
  const asks = orders.filter((o) => o.open && o.side === sellSide).map((o) => o.price);
  const bid = bids.length ? Math.max(...bids) : null;
  const ask = asks.length ? Math.min(...asks) : null;
  const mid = bid !== null && ask !== null ? (bid + ask) / 2 : bid ?? ask;
  return { bid, ask, mid };
}

/**
 * One market row for one settlement currency.
 *
 * Lifted out of the loop so a failed read can be retried by calling it again.
 * Dropping a row instead makes a market vanish from one currency and not
 * another, which reads as a contract fault and is not one.
 */
async function readRow(core, oracle, book, m, symbol, decimals, bookAddr) {
  const [tokens, settled, prev] = await Promise.all([
    core.tokensOf(m.id),
    core.isSettled(m.id),
    oracle.preview(m.id).catch(() => null),
  ]);
  if (tokens[0] === ethers.ZeroAddress) return null;

  const orders = book ? await readOrders(book, m.id, decimals) : [];
  const open = orders.filter((o) => o.open);

  let fraction = null;
  let voided = null;
  if (prev && prev.ready) {
    fraction = Number(prev.fraction) / 1e6;
    voided = prev.voided;
  }

  let frozen = null;
  if (settled) {
    const st = await core.settlementOf(m.id);
    frozen = Number(st[0]) / 1e6;
  }

  const nowS = Math.floor(Date.now() / 1000);
  return {
    id: m.id,
    symbol,
    feed: m.feed,
    capBps: m.capBps,
    capPct: m.capBps / 100,
    closeAt: m.closeAt,
    openAt: m.openAt,
    // Three states a reader can act on: the window is still running, it has
    // closed and can be settled, or it is settled and pays a known number.
    phase: settled ? "settled" : nowS >= m.openAt ? "settleable" : "open",
    settled,
    fraction,
    frozenFraction: frozen,
    voided,
    bigToken: tokens[0],
    calmToken: tokens[1],
    book: bookAddr,
    openOrders: open.length,
    big: quote(orders, "BuyBig", "SellBig"),
    calm: quote(orders, "BuyCalm", "SellCalm"),
    orders: open,
  };
}

async function build(provider) {
  const rc = loadRichter();
  if (!rc) return null;

  const markets = await scanMarkets(provider, rc.factory);
  const oracle = new ethers.Contract(rc.positionOracle, ORACLE_ABI, provider);

  // One venue per settlement currency, mirroring how the main book is shaped, so
  // the interface can reuse the same currency switch.
  const venues = [];
  for (const [symbol, coreAddr] of Object.entries(rc.cores)) {
    const core = new ethers.Contract(coreAddr, CORE_ABI, provider);
    const bookAddr = rc.books?.[symbol] ?? null;
    const book = bookAddr ? new ethers.Contract(bookAddr, BOOK_ABI, provider) : null;

    let decimals = 18;
    let collateral = null;
    try {
      decimals = Number(await core.collateralDecimals());
      collateral = await core.collateral();
    } catch { /* leave the defaults, the rows still read */ }

    const rows = await mapLimit(markets, 3, (m) =>
      readRow(core, oracle, book, m, symbol, decimals, bookAddr)
    );

    // mapLimit swallows a throw into { __error__ }, so a rate-limited read shows
    // up as a missing row rather than an error. Each one is retried once, and
    // only then given up on, with the reason printed.
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i];
      if (r && !r.__error__) continue;
      await new Promise((res) => setTimeout(res, 300));
      try {
        rows[i] = await readRow(core, oracle, book, markets[i], symbol, decimals, bookAddr);
      } catch (e) {
        console.log(`  richter ${symbol} ${markets[i].id.slice(0, 10)}: ${String(e).slice(0, 70)}`);
        rows[i] = null;
      }
    }

    venues.push({
      symbol,
      collateral,
      decimals,
      core: coreAddr,
      book: bookAddr,
      markets: rows.filter(Boolean),
    });
  }

  return {
    chainId: config.chainId,
    block: await provider.getBlockNumber(),
    factory: rc.factory,
    positionOracle: rc.positionOracle,
    feedsAreMirrors: rc.feedsAreMirrors,
    marketCount: markets.length,
    venues,
    note: "a richter market settles to a fraction of its cap: BIG pays s, CALM pays 1-s",
    builtAt: new Date().toISOString(),
  };
}

/** Rebuild in the background, never blocking a request. */
export function startRichterRefresh(ctx, everyMs = 60000) {
  const run = async () => {
    if (building) return;
    building = true;
    try {
      const next = await build(ctx.provider);
      if (next) cache = next;
    } catch (e) {
      console.log(`  richter snapshot failed: ${String(e).slice(0, 90)}`);
    } finally {
      building = false;
    }
  };
  run();
  setInterval(run, everyMs);
}

export async function richterSnapshot(ctx) {
  if (!cache) {
    const built = await build(ctx.provider);
    if (!built) return { error: "richter is not deployed on this chain" };
    cache = built;
  }
  return { ...cache, builtMsAgo: Date.now() - new Date(cache.builtAt).getTime() };
}
