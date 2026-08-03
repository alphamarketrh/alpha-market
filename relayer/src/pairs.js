import fs from "node:fs";
import path from "node:path";
import { ethers } from "ethers";
import { config } from "./config.js";
import { BOOK_ABI, CORE_ABI, ERC20_ABI } from "./chain.js";

/**
 * Additional settlement currencies.
 *
 * A question resolves once, but the answer can be settled in whatever asset the
 * holder already owns. The registry is therefore shared and a separate core,
 * order book and margin vault exist per collateral. YES-aUSD and YES-TSLA on
 * the same question are different tokens with different books and different
 * prices, which is correct: they are quoted in different units.
 *
 * DELIBERATELY OPTIONAL
 * Each pair lives in its own deployment file. If none exist, or one is
 * malformed, the relayer runs exactly as it did before this module was added.
 * A second currency must never be able to break the first.
 */

const PAIR_FILE = /^(\d+)-pair-(.+)\.json$/;

/** Load every pair deployment recorded for this chain. */
export function loadPairs(deploymentsDir, chainId) {
  let names;
  try {
    names = fs.readdirSync(deploymentsDir);
  } catch {
    return [];
  }

  const out = [];
  for (const name of names) {
    const m = PAIR_FILE.exec(name);
    if (!m || Number(m[1]) !== Number(chainId)) continue;
    try {
      const d = JSON.parse(fs.readFileSync(path.join(deploymentsDir, name), "utf8"));
      if (!d.core || !d.collateral) {
        console.log(`  pair ${name}: missing core or collateral, skipping`);
        continue;
      }
      out.push({
        symbol: d.symbol || m[2],
        decimals: Number(d.decimals ?? 18),
        collateral: d.collateral,
        core: d.core,
        orderBook: d.orderBook || null,
        marginVault: d.marginVault || null,
        file: name,
      });
    } catch (e) {
      // A broken file is reported and ignored rather than fatal.
      console.log(`  pair ${name}: unreadable (${String(e).slice(0, 60)}), skipping`);
    }
  }
  return out;
}

/** Attach contract handles for each pair to the shared context. */
export function connectPairs(ctx, pairs) {
  const wallet = ctx.wallet;
  return pairs.map((p) => ({
    ...p,
    coreContract: new ethers.Contract(p.core, CORE_ABI, wallet),
    bookContract: p.orderBook ? new ethers.Contract(p.orderBook, BOOK_ABI, wallet) : null,
    collateralContract: new ethers.Contract(p.collateral, ERC20_ABI, wallet),
  }));
}

/**
 * A view of one pair shaped like the primary deployment.
 *
 * Matching and the read API both take a context and reach for ctx.book and
 * ctx.core. Handing them a shallow copy with those two swapped lets the same
 * code serve every currency without a second implementation to keep in step.
 */
export function pairContext(ctx, pair) {
  return {
    ...ctx,
    core: pair.coreContract,
    book: pair.bookContract,
    collateral: pair.collateralContract,
    pairSymbol: pair.symbol,
    pairDecimals: pair.decimals,
  };
}
