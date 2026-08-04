import { config, loadState, saveState } from "./config.js";
import { config as _cfg } from "./config.js";
import { connect, send, toId, STATUS, OUTCOME } from "./chain.js";
// Equity prices are relayed from the real Chainlink feeds on Robinhood Chain
// mainnet. An earlier version wrote synthetic placeholder numbers here, which
// looked like data and was not.
import { refreshEquityPrices } from "./equity.js";
import { refreshPositionPrices } from "./positions.js";
import { matchOrderBook } from "./matcher.js";
import { loadPairs, connectPairs, pairContext } from "./pairs.js";
import {
  fetchActiveMarkets, fetchMarket, fetchDepth, readResolution, mapLimit,
  fetchEvents,
} from "./polymarket.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * One relayer cycle.
 *
 * Order matters. Resolution work runs before discovery so that a market already
 * being resolved upstream is halted here as early as possible, even if the
 * discovery half of the cycle later fails.
 */
export async function runCycle(ctx) {
  const state = loadState();
  state.cycles = (state.cycles || 0) + 1;
  state.markets = state.markets || {};

  const started = Date.now();
  console.log(`\n=== cycle ${state.cycles} ${new Date().toISOString()} ` +
              `${config.live ? "[LIVE]" : "[dry-run]"} ===`);

  const summary = {
    tracked: 0, halted: 0, unhalted: 0, proposed: 0, disputed: 0,
    finalized: 0, registered: 0, depthUpdated: 0, parlaysResolved: 0,
    equityPrices: 0, positionPrices: 0, matched: 0,
  };

  await refreshEquityPrices(ctx, state, summary);
  await refreshPositionPrices(ctx, state, summary);
  await trackExisting(ctx, state, summary);
  await resolveParlays(ctx, state, summary);
  await matchOrderBook(ctx, state, summary);

  // Each additional settlement currency has its own core and book on the same
  // registry, so the same matcher runs against each in turn. A failure in one
  // currency must not stop the others, hence the per-pair try.
  for (const pair of connectPairs(ctx, loadPairs(config.deploymentsDir, config.chainId))) {
    if (!pair.bookContract) continue;
    try {
      const before = summary.matched || 0;
      await matchOrderBook(pairContext(ctx, pair), state, summary);
      const done = (summary.matched || 0) - before;
      if (done > 0) console.log(`  ${done} match(es) settled in ${pair.symbol}`);
    } catch (e) {
      console.log(`  pair ${pair.symbol} matching failed: ${String(e).slice(0, 90)}`);
    }
  }
  await discoverNew(ctx, state, summary);

  state.lastCycleAt = new Date().toISOString();
  state.lastSummary = summary;
  state.durationMs = Date.now() - started;
  saveState(state);

  console.log(`  summary: ${JSON.stringify(summary)}  ${state.durationMs}ms`);
  return summary;
}

/** Advance every market we already mirror. */
async function trackExisting(ctx, state, summary) {
  const count = Number(await ctx.registry.marketCount());
  if (count === 0) return;
  console.log(`-- tracking ${count} mirrored market(s)`);

  // Read chain state and source data concurrently. Writes stay sequential
  // below, since they share one nonce.
  const idx = Array.from({ length: count }, (_, i) => i);
  const ids = await mapLimit(idx, 8, (i) => ctx.registry.marketIds(i));
  const statuses = await mapLimit(ids, 8, (id) => ctx.registry.statusOf(id));

  const pending = ids
    .map((id, i) => ({ id, status: Number(statuses[i]) }))
    .filter(({ id, status }) => {
      summary.tracked++;
      if (status === 5) return false;
      const rec = (state.markets[id] ||= { id });
      if (rec.orphan) { summary.orphans = (summary.orphans || 0) + 1; return false; }
      return true;
    });

  const sources = await mapLimit(pending, 6, ({ id }) => fetchMarket(id));

  // Depth is needed for status Active (refresh) and Halted (recovery check).
  // Fetching it inside the sequential loop was the remaining bottleneck.
  const depths = await mapLimit(pending, 6, ({ status }, i) => {
    if (status !== 1 && status !== 2) return null;
    const src = sources[i];
    if (!src || src.__error__) return null;
    return fetchDepth(src);
  });

  for (let k = 0; k < pending.length; k++) {
    const { id, status } = pending[k];
    const rec = state.markets[id];
    const src = sources[k] && !sources[k].__error__ ? sources[k] : null;

    if (!src) {
      // Markets registered by hand during testing use random ids that do not
      // exist upstream. Count the misses and stop polling after three, so a
      // test artifact does not burn two API calls every cycle forever.
      rec.missCount = (rec.missCount || 0) + 1;
      rec.lastError = `source lookup failed (${rec.missCount})`;
      if (rec.missCount >= 3) {
        rec.orphan = true;
        console.log(`  ORPHAN ${id.slice(0, 10)} not found upstream, halting`);
        if (status === 1) {
          await send(`halt ${id.slice(0, 10)}`, ctx.registry.halt, id, "not found upstream");
          summary.halted++;
        }
      }
      continue;
    }
    rec.missCount = 0;
    const res = readResolution(src);
    rec.sourceState = res.state;
    rec.question = String(src.question || "").slice(0, 90);
    // Backfills markets registered before the metadata was kept.
    if (src.image || src.icon) rec.image = String(src.image || src.icon).slice(0, 300);
    if (src.slug) rec.slug = String(src.slug).slice(0, 120);
    if (src.groupItemTitle) rec.groupItemTitle = String(src.groupItemTitle).slice(0, 60);
    if (src.volume != null) rec.volumeUsd = Number(src.volume) || 0;

    // 1. halt as soon as upstream starts resolving
    if (res.state !== "open" && status === 1) {
      console.log(`  HALT ${rec.question}`);
      await send(`halt ${id.slice(0, 10)}`, ctx.registry.halt, id, "source resolving");
      summary.halted++;
      continue;
    }

    // 1b. unhalt when the source is open again and depth has recovered.
    // Without this a market halted by a transient depth dip stays frozen
    // forever, which silently removes it from the venue.
    if (status === 2 && res.state === "open" && !rec.orphan) {
      const dd = depths[k] && !depths[k].__error__ ? depths[k] : null;
      const floor = Number(await ctx.registry.minDepthUsd());
      if (dd && Math.floor(dd.depthUsd) >= floor) {
        const usd = Math.floor(dd.depthUsd);
        if (usd !== rec.lastReportedDepth) {
          await send(`updateDepth ${id.slice(0, 10)} -> ${usd}`,
                     ctx.registry.updateDepth, id, usd);
          rec.lastReportedDepth = usd;
        }
        console.log(`  UNHALT depth recovered $${usd.toLocaleString()}  ${rec.question}`);
        const r = await send(`unhalt ${id.slice(0, 10)}`, ctx.registry.unhalt, id);
        if (!r.error) summary.unhalted++;
      }
      continue;
    }

    // 2. propose once upstream has a determinate answer
    if (res.state === "resolved" && (status === 1 || status === 2)) {
      console.log(`  PROPOSE ${OUTCOME[res.outcome]} for ${rec.question}`);
      const bond = await ctx.registry.bondAmount();
      const allowance = await ctx.collateral.allowance(ctx.address, config.registry);
      if (allowance < bond) {
        await send("approve bond", ctx.collateral.approve, config.registry, bond * 100n);
      }
      const r = await send(
        `proposeOutcome ${id.slice(0, 10)}`, ctx.registry.proposeOutcome, id, res.outcome,
      );
      if (!r.error) { rec.proposedOutcome = res.outcome; summary.proposed++; }
      continue;
    }

    // 3. police the proposal, then finalize once the window has elapsed
    if (status === 3) {
      const m = await ctx.registry.getMarket(id);
      const win = Number(await ctx.registry.challengeWindow());
      const now = Math.floor(Date.now() / 1000);
      const ready = now > Number(m.proposedAt) + win;

      // A bonded proposal is permissionless, so anyone may post a wrong answer.
      // The relayer is the party that can see the source, so it must challenge
      // inside the window; after the window closes the wrong answer is final.
      if (!ready && res.state === "resolved" &&
          Number(m.proposedOutcome) !== res.outcome) {
        console.log(`  DISPUTE proposed=${OUTCOME[Number(m.proposedOutcome)]} ` +
                    `source=${OUTCOME[res.outcome]}  ${rec.question}`);
        const bond = await ctx.registry.bondAmount();
        const allowance = await ctx.collateral.allowance(ctx.address, config.registry);
        if (allowance < bond) {
          await send("approve bond", ctx.collateral.approve, config.registry, bond * 100n);
        }
        const r = await send(`disputeOutcome ${id.slice(0, 10)}`,
                             ctx.registry.disputeOutcome, id);
        if (!r.error) { rec.disputed = true; summary.disputed++; }
        continue;
      }

      if (ready) {
        console.log(`  FINALIZE ${rec.question}`);
        const r = await send(`finalize ${id.slice(0, 10)}`, ctx.registry.finalize, id);
        if (!r.error) summary.finalized++;
      } else {
        const left = Number(m.proposedAt) + win - now;
        console.log(`  window open ${left}s  ${rec.question}`);
      }
      continue;
    }

    // 4. refresh depth on markets still trading
    if (status === 1) {
      const d = depths[k] && !depths[k].__error__ ? depths[k] : null;
      if (d) {
        const usd = Math.floor(d.depthUsd);
        rec.depthUsd = usd;
        if (rec.lastReportedDepth === undefined ||
            Math.abs(usd - rec.lastReportedDepth) > rec.lastReportedDepth * 0.2) {
          await send(`updateDepth ${id.slice(0, 10)} -> ${usd}`,
                     ctx.registry.updateDepth, id, usd);
          rec.lastReportedDepth = usd;
          summary.depthUpdated++;
        }
      }
    }
  }
}

/**
 * Resolve parlays whose legs are all final.
 *
 * ParlayFactory.resolve is permissionless and deterministic, but somebody has
 * to call it. Without this pass a parlay stays unresolved forever even though
 * every leg has settled, and holders cannot redeem.
 */
async function resolveParlays(ctx, state, summary) {
  if (!ctx.parlay) return;
  const count = Number(await ctx.parlay.parlayCount());
  if (count === 0) return;
  console.log(`-- checking ${count} parlay(s)`);

  for (let i = 0; i < count; i++) {
    const pid = await ctx.parlay.parlayIds(i);
    let resolvable;
    try {
      resolvable = await ctx.parlay.isResolvable(pid);
    } catch {
      continue;
    }
    if (!resolvable) continue;
    console.log(`  RESOLVE PARLAY ${pid.slice(0, 12)}`);
    const r = await send(`resolve parlay ${pid.slice(0, 10)}`, ctx.parlay.resolve, pid);
    if (!r.error) {
      summary.parlaysResolved++;
      (state.parlays ||= {})[pid] = { resolvedAt: new Date().toISOString() };
    }
  }
}

/** Find new markets that clear the depth gate and mirror them. */
async function discoverNew(ctx, state, summary) {
  const markets = await fetchActiveMarkets(config.scanLimit);
  console.log(`-- scanned ${markets.length} candidate(s)`);

  let registered = 0;
  const rejected = { alreadyMirrored: 0, badId: 0, noEnd: 0, noBook: 0, thin: 0, tooSoon: 0 };

  // Cheap filters first: no network needed.
  const nowS = Math.floor(Date.now() / 1000);
  const cheap = [];
  for (const m of markets) {
    const id = toId(m.conditionId);
    if (!id) { rejected.badId++; continue; }
    const endMs = Date.parse(m.endDate || "");
    if (!Number.isFinite(endMs)) { rejected.noEnd++; continue; }
    const endTime = Math.floor(endMs / 1000);
    // A loan must mature before resolution, and the vaults set that deadline
    // one hour ahead. Six hours leaves room for that plus several relayer
    // cycles to react to an upstream change. Twenty four hours was arbitrary
    // and rejected almost every sports market, which is where the day to day
    // volume actually is.
    if (endTime - nowS < 21600) { rejected.tooSoon++; continue; }
    cheap.push({ m, id, endTime });
  }

  // Then batch the chain reads.
  const known = await mapLimit(cheap, 8, ({ id }) => ctx.registry.statusOf(id));
  const fresh = cheap.filter((c, i) => {
    if (Number(known[i]) !== 0) { rejected.alreadyMirrored++; return false; }
    return true;
  });

  // Then batch the book fetches, capped so a large scan does not fetch
  // hundreds of books just to register a handful.
  const probeCap = Math.min(fresh.length, config.maxRegisterPerCycle * 15);
  const probe = fresh.slice(0, probeCap);
  const books = await mapLimit(probe, 6, ({ m }) => fetchDepth(m));
  const examined = probe.length;

  for (let i = 0; i < probe.length; i++) {
    if (registered >= config.maxRegisterPerCycle) break;
    const { m, id, endTime } = probe[i];
    const d = books[i] && !books[i].__error__ ? books[i] : null;
    if (!d) { rejected.noBook++; continue; }

    const usd = Math.floor(d.depthUsd);
    if (usd < config.minDepthUsd) { rejected.thin++; continue; }

    console.log(`  REGISTER depth=$${usd.toLocaleString()} spread=${d.spread.toFixed(4)} ` +
                `${String(m.question).slice(0, 60)}`);
    const r = await send(`registerMarket ${id.slice(0, 10)}`,
                         ctx.registry.registerMarket, id, endTime, usd);
    if (r.error) continue;

    if (config.live) {
      await send(`initializeMarket ${id.slice(0, 10)}`, ctx.core.initializeMarket, id);
    }
    // Tags belong to the event, and the event id arrives with the market, so
    // the category costs one batched call rather than one call per market.
    // An event groups several markets that are really one question with
    // different answers: nine candidates for a nomination, six strike prices
    // on the same day. Keeping the event title and image lets those be shown
    // as one card with rows, which is what they are, instead of nine cards
    // repeating the same sentence.
    const evId = (m.events || [])[0]?.id;
    let tags = [];
    let eventTitle = null;
    let eventImage = null;
    if (evId) {
      try {
        const ev = (await fetchEvents([String(evId)]))[String(evId)];
        if (ev) {
          tags = ev.tags || [];
          eventTitle = ev.title;
          eventImage = ev.image;
        }
      } catch { /* missing grouping must not block registration */ }
    }

    state.markets[id] = {
      id, question: String(m.question || "").slice(0, 90),
      eventId: evId ? String(evId) : null,
      eventTitle,
      eventImage,
      // The short label for this market's row, e.g. "62,000" under
      // "Bitcoin above ___ on August 4?". Absent on standalone markets.
      groupItemTitle: String(m.groupItemTitle || "").slice(0, 60) || null,
      tags,
      // Polymarket returns an image, a slug and a volume alongside the
      // question. The relayer already fetches all of it every cycle to decide
      // what to register, so keeping it costs nothing and is what lets a
      // market appear as something a person recognises rather than a hash.
      image: String(m.image || m.icon || "").slice(0, 300) || null,
      slug: String(m.slug || "").slice(0, 120) || null,
      volumeUsd: Number(m.volume || 0) || 0,
      endTime, depthUsd: usd, lastReportedDepth: usd,
      registeredAt: new Date().toISOString(),
    };
    registered++;
    summary.registered++;
  }

  console.log(`  examined ${examined} book(s); rejected ${JSON.stringify(rejected)}`);
}

export async function preflight(ctx) {
  const net = await ctx.provider.getNetwork();
  const bal = await ctx.provider.getBalance(ctx.address);
  const isRelayer = await ctx.registry.isRelayer(ctx.address);
  const floor = await ctx.registry.minDepthUsd();
  const count = await ctx.registry.marketCount();

  console.log("relayer preflight");
  console.log(`  chain        ${net.chainId}`);
  console.log(`  wallet       ${ctx.address}`);
  console.log(`  eth          ${(Number(bal) / 1e18).toFixed(6)}`);
  console.log(`  registry     ${config.registry}`);
  console.log(`  isRelayer    ${isRelayer}`);
  console.log(`  minDepthUsd  ${floor}`);
  console.log(`  mirrored     ${count}`);
  console.log(`  mode         ${config.live ? "LIVE" : "dry-run"}`);

  if (!isRelayer) throw new Error("wallet is not authorised as relayer");
  if (bal === 0n && config.live) throw new Error("wallet has no ETH for gas");
  return { chainId: Number(net.chainId), isRelayer, marketCount: Number(count) };
}
