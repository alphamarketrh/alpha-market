import { ethers } from "ethers";
import { config } from "./config.js";
import { send } from "./chain.js";
import { mapLimit } from "./polymarket.js";

/**
 * Equity prices, read from Chainlink on Robinhood Chain mainnet.
 *
 * Testnet 46630 has no equity feeds. Verified 2026-08-02: oraclePaused() is
 * present on the mainnet stock token and reverts on the testnet one, and no
 * aggregator on 46630 answers the AggregatorV3 interface. So the price is read
 * from mainnet, where the feeds are real, and relayed here.
 *
 * WHAT THE FEED ALREADY DOES FOR US
 * Robinhood equity feeds quote the price of one TOKEN, not one share: the
 * underlying price is already multiplied by uiMultiplier(). Dividends and
 * splits are therefore handled upstream and the multiplier must NOT be applied
 * again. Robinhood documents this explicitly.
 *
 * WHY THE STALENESS BUDGET IS DAYS, NOT HOURS
 * Equity feeds publish 24/5 and follow market hours, so a price is expected to
 * sit untouched across a weekend. Measured on a Sunday, every feed was roughly
 * 1.5 days old with a 24 hour heartbeat, which is normal rather than broken. A
 * one hour freshness rule would reject every price from Friday close to Monday
 * open and freeze anything depending on it.
 *
 * WHAT IS NOT DONE, STATED RATHER THAN GLOSSED
 * Robinhood documents an L2 sequencer uptime feed that should be consulted
 * before trusting any price. Its address is not in the Chainlink feed
 * directory for this chain and has not been located, so that check is absent.
 * During a sequencer outage a price could be stale beyond what updatedAt
 * reveals.
 */

const AGGREGATOR_ABI = [
  "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
  "function decimals() view returns (uint8)",
  "function description() view returns (string)",
];

const STOCK_ABI = ["function oraclePaused() view returns (bool)"];

/**
 * Chainlink proxies on Robinhood Chain mainnet, paired with the testnet token
 * they price. Read from the Chainlink feed directory and each confirmed live on
 * chain before being written here.
 *
 * NFLX is deliberately absent: the faucet issues it on testnet but no
 * Robinhood NFLX feed exists, so it has no price and no equity-backed lending.
 */
export const EQUITY_FEEDS = {
  TSLA: {
    feed: "0x4A1166a659A55625345e9515b32adECea5547C38",
    testnetToken: "0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E",
    mainnetToken: "0x322F0929c4625eD5bAd873c95208D54E1c003b2d",
  },
  AMD: {
    feed: "0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72",
    testnetToken: "0x71178BAc73cBeb415514eB542a8995b82669778d",
    mainnetToken: null,
  },
  AMZN: {
    feed: "0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C",
    testnetToken: "0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02",
    mainnetToken: null,
  },
  PLTR: {
    feed: "0x820ABedFF239034956B7A9d2F0a331f9F075eB4c",
    testnetToken: "0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0",
    mainnetToken: null,
  },
};

/** Feeds publish with 8 decimals; the oracle here stores 8 as well. */
export const PRICE_DECIMALS = 8;

/**
 * Decide whether a reading may be written on chain.
 *
 * Returns the reason for rejection, or null when the price is usable. Kept
 * separate from any network call so the rules can be tested directly.
 */
export function judgeReading(r, nowS, maxAgeS) {
  if (r == null) return "unreadable";
  if (r.paused === true) return "oracle paused for a corporate action";
  if (r.price == null || r.price <= 0n) return "non-positive answer";
  if (r.updatedAt == null || r.updatedAt <= 0) return "round not complete";
  const age = nowS - r.updatedAt;
  if (age < 0) return "timestamp in the future";
  if (age > maxAgeS) return `stale by ${age - maxAgeS}s`;
  return null;
}

/** Read one feed, plus the pause flag on the token it prices. */
async function readFeed(mainnetProvider, symbol, spec) {
  const agg = new ethers.Contract(spec.feed, AGGREGATOR_ABI, mainnetProvider);
  try {
    const [, answer, , updatedAt] = await agg.latestRoundData();
    let paused = null;
    if (spec.mainnetToken) {
      try {
        const t = new ethers.Contract(spec.mainnetToken, STOCK_ABI, mainnetProvider);
        paused = await t.oraclePaused();
      } catch {
        paused = null;   // advisory flag only; absence is not fatal
      }
    }
    return { symbol, price: BigInt(answer), updatedAt: Number(updatedAt), paused };
  } catch (e) {
    console.log(`  feed ${symbol}: ${String(e).slice(0, 70)}`);
    return null;
  }
}

/**
 * Relay mainnet equity prices into the testnet price oracle.
 *
 * Nothing is invented: a symbol with no usable reading is skipped and the
 * reason is printed, rather than a placeholder being written.
 */
/**
 * Read what is already stored for a token, or null if nothing is.
 *
 * A revert here means the token has no price yet or the stored one has aged
 * past the oracle's own limit. Either way it needs writing, so the failure is
 * treated as "absent" rather than propagated.
 */
async function storedAge(ctx, token, nowS) {
  try {
    const [, updatedAt] = await ctx.oracle.getPrice(token);
    return nowS - Number(updatedAt);
  } catch {
    return null;
  }
}

export async function refreshEquityPrices(ctx, state, summary) {
  // chain.js exposes the equity price oracle as ctx.oracle.
  if (!ctx.oracle || !config.mainnetRpc) return;

  // Equity feeds have a 24 hour heartbeat and stop entirely at the weekend, so
  // pushing every cycle rewrites an identical number and burns gas for nothing.
  // Only write when what is on chain has aged past the refresh interval.
  const nowCheck = Math.floor(Date.now() / 1000);
  const ages = await mapLimit(Object.keys(EQUITY_FEEDS), 4,
    (s) => storedAge(ctx, EQUITY_FEEDS[s].testnetToken, nowCheck));
  const anyDue = ages.some((a) => a === null || a === undefined || a.__error__ || a >= config.equityRefreshS);
  if (!anyDue) return;

  const provider = new ethers.JsonRpcProvider(config.mainnetRpc);
  const symbols = Object.keys(EQUITY_FEEDS);
  const readings = await mapLimit(symbols, 4, (s) => readFeed(provider, s, EQUITY_FEEDS[s]));

  const nowS = Math.floor(Date.now() / 1000);
  const maxAge = config.equityMaxAgeS;

  const tokens = [];
  const prices = [];
  const notes = [];

  for (let i = 0; i < symbols.length; i++) {
    const r = readings[i] && !readings[i].__error__ ? readings[i] : null;
    const reject = judgeReading(r, nowS, maxAge);
    if (reject) {
      notes.push(`${symbols[i]} skipped: ${reject}`);
      continue;
    }
    tokens.push(EQUITY_FEEDS[symbols[i]].testnetToken);
    prices.push(r.price);
    notes.push(`${symbols[i]} ${Number(r.price) / 1e8} age ${nowS - r.updatedAt}s`);
  }

  for (const n of notes) console.log(`   ${n}`);
  if (tokens.length === 0) return;

  console.log(`-- relaying ${tokens.length} equity price(s) from mainnet Chainlink`);
  const res = await send("pushPrices", ctx.oracle.pushPrices, tokens, prices);
  if (!res.error) {
    summary.equityPrices = tokens.length;
    state.lastEquityPush = new Date().toISOString();
  }
}
