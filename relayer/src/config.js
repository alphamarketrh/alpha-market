import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.resolve(HERE, "..", "..");

/** Minimal .env reader. No dependency, no surprises. */
function loadEnv(file) {
  const out = {};
  if (!fs.existsSync(file)) return out;
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
  return out;
}

const env = { ...loadEnv(path.join(ROOT, ".env")), ...process.env };

function need(key) {
  const v = env[key];
  if (!v) throw new Error(`missing required env: ${key}`);
  return v;
}

const chainId = Number(env.RELAYER_CHAIN_ID || 46630);
const deployFile = path.join(ROOT, "contracts", "deployments", `${chainId}.json`);
if (!fs.existsSync(deployFile)) {
  throw new Error(`no deployment file at ${deployFile}`);
}
const deployed = JSON.parse(fs.readFileSync(deployFile, "utf8"));

for (const k of ["registry", "core", "collateral"]) {
  if (!deployed[k]) throw new Error(`deployment file missing ${k}`);
}

export const config = {
  chainId,
  rpc: chainId === 46630 ? need("RH_TESTNET_RPC") : need("RH_MAINNET_RPC"),
  // The relayer must never hold the owner key. It runs continuously on a
  // server and only needs the relayer role; the owner key can change params
  // and arbitrate disputes. Falls back only if no dedicated key is configured.
  privateKey: env.RELAYER_PRIVATE_KEY || need("DEPLOYER_PRIVATE_KEY"),

  registry: deployed.registry,
  parlayFactory: deployed.parlayFactory || null,
  marginVault: deployed.marginVault || null,
  priceOracle: deployed.priceOracle || null,
  // Equity feeds live on mainnet, not on this testnet.
  mainnetRpc: env.RH_MAINNET_RPC || null,
  // Equity feeds publish 24/5, so a price sits untouched across a weekend.
  // Measured on a Sunday, every feed was about 1.6 days old against a 24 hour
  // heartbeat. Three days accepts that without accepting a genuinely dead feed.
  equityMaxAgeS: Number(env.EQUITY_MAX_AGE_S || 259200),
  // How often to rewrite an equity price. The feed heartbeat is 24 hours, so
  // hourly is already far more often than the data changes.
  equityRefreshS: Number(env.EQUITY_REFRESH_S || 3600),
  positionOracle: deployed.positionOracle || null,
  orderBook: deployed.orderBook || null,
  // Directory holding the primary deployment and any per-currency pair files.
  deploymentsDir: path.dirname(deployFile),
  directionalVault: deployed.directionalVault || null,
  equityVault: deployed.equityVault || null,
  // Refresh well inside the oracle maxAge so a couple of failed cycles cannot
  // freeze the vaults that depend on it.
  priceRefreshS: Number(env.RELAYER_PRICE_REFRESH_S || 3600),
  core: deployed.core,
  collateral: deployed.collateral,

  gamma: env.POLYMARKET_GAMMA_API || "https://gamma-api.polymarket.com",
  clob: env.POLYMARKET_CLOB_API || "https://clob.polymarket.com",

  port: Number(env.RELAYER_PORT || 8420),
  statePath: path.join(ROOT, "relayer", "state.json"),

  // how many top-volume markets to consider each scan
  scanLimit: Number(env.RELAYER_SCAN_LIMIT || 100),
  // minimum measured depth (whole USD) before we will mirror a market
  // The depth gate was justified by market makers hedging back to Polymarket.
  // Odds now form in Alpha Market's own order flow, so that rationale is gone
  // and the filter would only reject markets that might trade well here.
  // Depth is still measured and reported, just no longer used to exclude.
  minDepthUsd: Number(env.RELAYER_MIN_DEPTH_USD || 0),
  // maximum markets to register per cycle, so a bad scan cannot flood the chain
  maxRegisterPerCycle: Number(env.RELAYER_MAX_REGISTER || 3),
  // depth is measured within +/- this many probability points of the mid
  depthBand: Number(env.RELAYER_DEPTH_BAND || 0.05),
  // seconds between cycles
  interval: Number(env.RELAYER_INTERVAL_S || 300),
  // polite delay between Polymarket API calls, ms
  apiDelayMs: Number(env.RELAYER_API_DELAY_MS || 120),

  live: process.argv.includes("--live"),
  once: process.argv.includes("--once"),
};

export function loadState() {
  try {
    return JSON.parse(fs.readFileSync(config.statePath, "utf8"));
  } catch {
    return { markets: {}, cycles: 0, lastCycleAt: null, errors: [] };
  }
}

export function saveState(s) {
  fs.writeFileSync(config.statePath, JSON.stringify(s, null, 2));
}
