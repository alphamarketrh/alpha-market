import { ethers } from "ethers";
import { config } from "./config.js";

export const REGISTRY_ABI = [
  "function registerMarket(bytes32 conditionId, uint64 endTime, uint128 depthUsd)",
  "function updateDepth(bytes32 id, uint128 depthUsd)",
  "function halt(bytes32 id, string reason)",
  "function unhalt(bytes32 id)",
  "function proposeOutcome(bytes32 id, uint8 outcome)",
  "function disputeOutcome(bytes32 id)",
  "function finalize(bytes32 id)",
  "function statusOf(bytes32 id) view returns (uint8)",
  "function outcomeOf(bytes32 id) view returns (uint8)",
  "function isTradeable(bytes32 id) view returns (bool)",
  "function isResolved(bytes32 id) view returns (bool)",
  "function marketCount() view returns (uint256)",
  "function marketIds(uint256) view returns (bytes32)",
  "function minDepthUsd() view returns (uint128)",
  "function bondAmount() view returns (uint256)",
  "function challengeWindow() view returns (uint64)",
  "function isRelayer(address) view returns (bool)",
  "function getMarket(bytes32 id) view returns (tuple(bytes32 conditionId,uint64 endTime,uint64 registeredAt,uint128 depthUsd,uint8 status,uint8 outcome,address proposer,uint64 proposedAt,uint8 proposedOutcome,address disputer,uint64 disputedAt,uint8 pendingRuling,uint64 rulingAt))",
  "function arbiter() view returns (address)",
  "function rulingDelay() view returns (uint64)",
  "function disputeTimeout() view returns (uint64)",
  "function timeoutAt(bytes32) view returns (uint64)",
  "function resolveByTimeout(bytes32)",
];

export const PARLAY_ABI = [
  "function parlayCount() view returns (uint256)",
  "function parlayIds(uint256) view returns (bytes32)",
  "function isResolvable(bytes32) view returns (bool)",
  "function resolve(bytes32)",
  "function getParlay(bytes32) view returns (bytes32[],uint8[],address,address,uint8,bool)",
];

export const ORACLE_ABI = [
  "function getPrice(address) view returns (uint256,uint256)",
  "function isSupported(address) view returns (bool)",
  "function pushPrice(address,uint256)",
  "function pushPrices(address[],uint256[])",
  "function isPusher(address) view returns (bool)",
  "function maxAge() view returns (uint256)",
];

export const POSITION_ORACLE_ABI = [
  "function priceOf(bytes32,bool) view returns (uint256,uint256)",
  "function isPriced(bytes32) view returns (bool)",
  "function pointOf(bytes32) view returns (tuple(uint256 yesPrice,uint64 updatedAt,bool seen))",
  "function writePrice(bytes32,uint256)",
  "function writePrices(bytes32[],uint256[])",
  "function isWriter(address) view returns (bool)",
  "function maxAge() view returns (uint256)",
  "function maxMoveBps() view returns (uint256)",
];

export const BOOK_ABI = [
  "function marketOrderCount(bytes32) view returns (uint256)",
  "function marketOrderIds(bytes32) view returns (uint256[])",
  "function getOrder(uint256) view returns (tuple(address maker,bytes32 marketId,uint8 side,uint64 price,uint64 expiry,uint128 amount,uint128 filled,uint128 escrow,bool cancelled))",
  "function isOpen(uint256) view returns (bool)",
  "function remainingOf(uint256) view returns (uint128)",
  "function matchMint(uint256,uint256,uint128)",
  "function matchMerge(uint256,uint256,uint128)",
  "function matchCross(uint256,uint256,uint128)",
  "function feeBps() view returns (uint16)",
  "function feesAccrued() view returns (uint256)",
];

// Read-only. The relayer never borrows, supplies or settles: it reports.
export const LENDING_ABI = [
  "function totalSupplied() view returns (uint256)",
  "function totalPrincipal() view returns (uint256)",
  "function reserveBalance() view returns (uint256)",
  "function availableLiquidity() view returns (uint256)",
  "function utilisation() view returns (uint256)",
  "function borrowRate() view returns (uint256)",
  "function supplyRate() view returns (uint256)",
  "function rateCeilingBps() view returns (uint256)",
  "function haircutBps() view returns (uint256)",
  "function reserveBps() view returns (uint256)",
  "function deadlineBuffer() view returns (uint64)",
  "function maxDebtPerMarket() view returns (uint256)",
  "function entryPaused() view returns (bool)",
];

export const CORE_ABI = [
  "function initializeMarket(bytes32 id) returns (address,address)",
  "function tokensOf(bytes32 id) view returns (address,address)",
];

// The testnet collateral carries a public faucet on top of ERC20. Reading
// those fields is what lets /config tell a newcomer how to obtain a balance.
export const COLLATERAL_ABI = [
  // ERC20. approve and allowance are what let the relayer post a resolution
  // bond, so dropping them silently disables proposing and disputing.
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
  // The testnet collateral adds a public faucet on top, which is what /config
  // reads to tell a newcomer how to obtain a balance.
  "function claimAmount() view returns (uint256)",
  "function cooldown() view returns (uint256)",
  "function supplyCap() view returns (uint256)",
  "function canClaim(address) view returns (bool)",
];

export const ERC20_ABI = [
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
];

export const STATUS = ["None", "Active", "Halted", "Proposed", "Disputed", "Resolved"];
export const OUTCOME = ["Unresolved", "Yes", "No", "Invalid"];

export function connect() {
  // staticNetwork avoids a chain-id round trip on every call. Robinhood Chain
  // produces ~13 blocks/second, so minimising RPC chatter matters.
  const provider = new ethers.JsonRpcProvider(config.rpc, config.chainId, {
    staticNetwork: ethers.Network.from(config.chainId),
  });
  const wallet = new ethers.Wallet(config.privateKey, provider);
  return {
    provider,
    wallet,
    address: wallet.address,
    registry: new ethers.Contract(config.registry, REGISTRY_ABI, wallet),
    core: new ethers.Contract(config.core, CORE_ABI, wallet),
    collateral: new ethers.Contract(config.collateral, COLLATERAL_ABI, wallet),
    parlay: config.parlayFactory
      ? new ethers.Contract(config.parlayFactory, PARLAY_ABI, wallet)
      : null,
    oracle: config.priceOracle
      ? new ethers.Contract(config.priceOracle, ORACLE_ABI, wallet)
      : null,
    positionOracle: config.positionOracle
      ? new ethers.Contract(config.positionOracle, POSITION_ORACLE_ABI, wallet)
      : null,
    lending: config.lendingVault
      ? new ethers.Contract(config.lendingVault, LENDING_ABI, wallet)
      : null,
    book: config.orderBook
      ? new ethers.Contract(config.orderBook, BOOK_ABI, wallet)
      : null,
  };
}

/**
 * Send a transaction and wait for one confirmation.
 *
 * Every write goes through here so that dry-run is enforced in exactly one
 * place. Default is dry-run; --live is required to broadcast.
 */
export async function send(label, fn, ...args) {
  if (!config.live) {
    console.log(`  [dry-run] ${label}`);
    return { dryRun: true };
  }
  try {
    const tx = await fn(...args);
    const rc = await tx.wait(1);
    console.log(`  [sent] ${label}  tx=${rc.hash} gas=${rc.gasUsed}`);
    return { hash: rc.hash, gasUsed: rc.gasUsed?.toString() };
  } catch (e) {
    const reason = e.shortMessage || e.reason || String(e).slice(0, 160);
    console.log(`  [FAIL] ${label}  ${reason}`);
    return { error: reason };
  }
}

/** Polymarket conditionIds are already 32-byte hex, used verbatim as our id. */
export function toId(conditionId) {
  const s = String(conditionId || "").toLowerCase();
  if (!/^0x[0-9a-f]{64}$/.test(s)) return null;
  return s;
}
