#!/usr/bin/env node
/**
 * Alpha Market relayer.
 *
 *   node src/index.js            single dry-run cycle, no writes
 *   node src/index.js --once     alias for the above
 *   node src/index.js --live     broadcast, loop forever
 *
 * Dry-run is the default on purpose. Every write goes through chain.js send(),
 * which refuses to broadcast unless --live is present, so there is exactly one
 * place where that guarantee has to hold.
 */
import http from "node:http";
import { config, loadState } from "./config.js";
import { connect } from "./chain.js";
import { runCycle, preflight } from "./relayer.js";
import { bookSnapshot, marketList, configSnapshot } from "./api.js";

let health = { status: "starting", startedAt: new Date().toISOString() };

function serve(ctx) {
  const json = (res, code, body) => {
    res.writeHead(code, {
      "content-type": "application/json",
      // The book is public data; a browser-based UI must be able to read it.
      "access-control-allow-origin": "*",
    });
    res.end(JSON.stringify(body, null, 2));
  };

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, "http://localhost");

    if (url.pathname === "/book") {
      try {
        const snap = await bookSnapshot(ctx, {
          marketId: url.searchParams.get("market"),
          onlyActive: url.searchParams.get("all") !== "1",
        });
        return json(res, 200, snap);
      } catch (e) {
        return json(res, 500, { error: String(e).slice(0, 200) });
      }
    }

    if (url.pathname === "/config") {
      try {
        return json(res, 200, await configSnapshot(ctx));
      } catch (e) {
        return json(res, 500, { error: String(e).slice(0, 200) });
      }
    }

    if (url.pathname === "/markets") {
      try {
        return json(res, 200, await marketList(ctx));
      } catch (e) {
        return json(res, 500, { error: String(e).slice(0, 200) });
      }
    }

    if (req.url === "/health" || req.url === "/") {
      const s = loadState();
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({
        ...health,
        mode: config.live ? "live" : "dry-run",
        chainId: config.chainId,
        registry: config.registry,
        cycles: s.cycles || 0,
        lastCycleAt: s.lastCycleAt,
        lastSummary: s.lastSummary,
        trackedMarkets: Object.keys(s.markets || {}).length,
      }, null, 2));
      return;
    }
    if (req.url === "/markets") {
      const s = loadState();
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(s.markets || {}, null, 2));
      return;
    }
    res.writeHead(404).end();
  });
  server.listen(config.port, () => console.log(`health on :${config.port}/health`));
  return server;
}

async function main() {
  const ctx = connect();
  await preflight(ctx);

  if (config.once || !config.live) {
    health.status = "single-cycle";
    await runCycle(ctx);
    console.log("\nsingle cycle complete. use --live to broadcast and loop.");
    return;
  }

  const server = serve(ctx);
  health.status = "running";

  let stopping = false;
  const stop = () => {
    if (stopping) process.exit(1);
    stopping = true;
    console.log("\nshutting down after current cycle ...");
    server.close();
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);

  while (!stopping) {
    try {
      await runCycle(ctx);
      health.lastError = null;
    } catch (e) {
      health.lastError = String(e).slice(0, 200);
      console.error("cycle failed:", health.lastError);
    }
    for (let i = 0; i < config.interval && !stopping; i++) {
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
  process.exit(0);
}

main().catch((e) => {
  console.error("fatal:", e.message || e);
  process.exit(1);
});
