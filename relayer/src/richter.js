import fs from "fs";
import path from "path";
import { ethers } from "ethers";
import { config } from "./config.js";
import { send } from "./chain.js";
import { EQUITY_FEEDS } from "./equity.js";

/**
 * Richter markets: mirrored rounds, and opening on the exchange calendar.
 *
 * WHY A MIRROR EXISTS AT ALL
 * Testnet 46630 has no equity feeds. Settlement needs round history, not just a
 * latest price, so PriceOracle cannot serve: its Feed struct holds one pushPrice
 * and one pushedAt. MirrorAggregator holds history in the Chainlink round shape,
 * and is filled here with the real mainnet prices this relayer already reads.
 *
 * None of this exists on mainnet 4663. There the contracts read the Chainlink
 * aggregators directly and no relayer stands in the path. The deploy script
 * refuses to deploy a mirror anywhere but the testnet.
 *
 * WHY PUSHES FOLLOW THE SOURCE RATHER THAN THE CYCLE
 * A round is written only when mainnet has published one newer than the mirror's
 * last. So the mirror inherits the real feed's cadence: dense during market
 * hours, silent over a weekend. Pushing once per cycle instead would invent a
 * heartbeat the real feed does not have, and settlement would then be tested
 * against a shape that never occurs in production.
 *
 * WHY MARKETS OPEN FROM A CONTRACT, TRIGGERED HERE
 * factory.open is permissionless and every parameter is fixed by the ticker table
 * on chain, so this function chooses nothing. It only pays the gas at the right
 * moment. Anyone else calling it first is fine and costs us nothing.
 */

const MIRROR_ABI = [
  "function push(int256 answer, uint64 updatedAt)",
  "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
  "function roundCount() view returns (uint64)",
  "function phase() view returns (uint16)",
];

const AGG_ABI = [
  "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
];

const FACTORY_ABI = [
  "function open(address feed, uint64 closeAt, uint64 openAt) returns (bytes32)",
  "function marketId(address feed, uint32 capBps, uint64 closeAt) view returns (bytes32)",
  "function opened(bytes32) view returns (bool)",
  "function tickers(address) view returns (address token, uint32 capBps, bool enabled)",
  "function coreCount() view returns (uint256)",
];

// Regular session in UTC. Robinhood Chain mainnet launched in July 2026 and this
// runs through the autumn, so EDT at UTC-4 holds. A run past the November change
// must move these to 21:00 and 14:30.
const CLOSE_UTC_H = 20.0;   // 16:00 ET
const OPEN_UTC_H = 13.5;    // 09:30 ET

let cached = null;

/** Read the Richter deployment file, or null when Richter is not deployed here. */
function richterConfig() {
  if (cached !== null) return cached;
  const file = path.join(config.deploymentsDir, `richter-${config.chainId}.json`);
  if (!fs.existsSync(file)) {
    cached = false;
    return cached;
  }
  const d = JSON.parse(fs.readFileSync(file, "utf8"));
  const mirrors = {};
  for (const sym of Object.keys(EQUITY_FEEDS)) {
    if (d[`feed${sym}`]) mirrors[sym] = d[`feed${sym}`];
  }
  cached = {
    factory: d.richterMarketFactory || null,
    oracle: d.richterPositionOracle || null,
    mirrors,
  };
  return cached;
}

/**
 * Copy any round mainnet has published since the mirror's last one.
 *
 * A mirror that is behind by more than one round is caught up a few at a time
 * rather than all at once, so a long outage cannot produce a transaction that
 * runs past the block gas limit.
 */
export async function refreshRichterRounds(ctx, state, summary) {
  const rc = richterConfig();
  if (!rc || !config.mainnetRpc) return;
  if (Object.keys(rc.mirrors).length === 0) return;

  const wallet = ctx.wallet;
  const mainnet = new ethers.JsonRpcProvider(config.mainnetRpc);
  let written = 0;

  for (const [sym, mirrorAddr] of Object.entries(rc.mirrors)) {
    const spec = EQUITY_FEEDS[sym];
    if (!spec) continue;

    const mirror = new ethers.Contract(mirrorAddr, MIRROR_ABI, wallet);
    const source = new ethers.Contract(spec.feed, AGG_ABI, mainnet);

    let lastStamp = 0;
    try {
      const [, , , updatedAt] = await mirror.latestRoundData();
      lastStamp = Number(updatedAt);
    } catch {
      lastStamp = 0;   // an empty mirror, every round is new
    }

    let answer, stamp;
    try {
      const [, a, , t] = await source.latestRoundData();
      answer = BigInt(a);
      stamp = Number(t);
    } catch (e) {
      console.log(`   richter ${sym}: source unreadable, ${String(e).slice(0, 60)}`);
      continue;
    }

    if (answer <= 0n || stamp <= 0) continue;
    // The mirror refuses a stamp that does not increase, so a round already
    // written is skipped here rather than sent and reverted. Seeding history by
    // hand can leave the mirror ahead of what latestRoundData reports for a
    // while, and paying gas to learn that is waste.
    if (stamp <= lastStamp) continue;

    const r = await send(
      `richter push ${sym} ${Number(answer) / 1e8} at ${stamp}`,
      mirror.push, answer, stamp
    );
    if (!r.error) written++;
  }

  if (written) summary.richterRounds = written;
}

/**
 * The most recent close that has already happened, and the open that follows it.
 *
 * A close lands on a weekday. The open is the next weekday morning, so a Friday
 * close pairs with a Monday open. Holidays are not modelled: on a holiday the
 * feed simply publishes nothing, and the market voids through the staleness rule
 * rather than settling against a price nobody could trade at.
 */
export function currentWindow(nowS) {
  const DAY = 86400;
  const dayStart = Math.floor(nowS / DAY) * DAY;
  const dow = (d) => new Date(d * 1000).getUTCDay();   // 0 Sun .. 6 Sat

  let close = dayStart + Math.round(CLOSE_UTC_H * 3600);
  // Walk back to the most recent weekday close that is already in the past.
  while (close > nowS || dow(close) === 0 || dow(close) === 6) {
    close -= DAY;
  }

  let openDay = close + DAY;
  while (dow(openDay) === 0 || dow(openDay) === 6) openDay += DAY;
  const open = Math.floor(openDay / DAY) * DAY + Math.round(OPEN_UTC_H * 3600);

  return { close, open };
}

/**
 * Open the current window for every enabled ticker, once.
 *
 * Nothing is opened after its own open has passed: such a market would be
 * settleable the moment it existed and would never have a trading window.
 */
export async function openRichterMarkets(ctx, state, summary) {
  const rc = richterConfig();
  if (!rc || !rc.factory) return;

  const wallet = ctx.wallet;
  const factory = new ethers.Contract(rc.factory, FACTORY_ABI, wallet);

  const cores = Number(await factory.coreCount());
  if (cores === 0) return;

  const nowS = Math.floor(Date.now() / 1000);
  const { close, open } = currentWindow(nowS);
  if (nowS >= open) return;   // the window has already run out

  let opened = 0;
  for (const [sym, mirrorAddr] of Object.entries(rc.mirrors)) {
    let capBps, enabled;
    try {
      const t = await factory.tickers(mirrorAddr);
      capBps = Number(t.capBps);
      enabled = t.enabled;
    } catch {
      continue;
    }
    if (!enabled || capBps === 0) continue;

    const id = await factory.marketId(mirrorAddr, capBps, close);
    if (await factory.opened(id)) continue;

    // Without a round at or before the close there is nothing to settle
    // against, so the market is left for a later cycle.
    const mirror = new ethers.Contract(mirrorAddr, MIRROR_ABI, wallet);
    try {
      const [, , , updatedAt] = await mirror.latestRoundData();
      if (Number(updatedAt) < close) {
        console.log(`   richter ${sym}: mirror has nothing before the close yet`);
        continue;
      }
    } catch {
      continue;
    }

    const r = await send(
      `richter open ${sym} cap=${capBps}bps close=${close} open=${open}`,
      factory.open, mirrorAddr, close, open
    );
    if (!r.error) opened++;
  }

  if (opened) summary.richterMarkets = opened;
}
