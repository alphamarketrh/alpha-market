import test from "node:test";
import assert from "node:assert/strict";
import { computeDepth, readResolution, mapLimit, jparse } from "../src/polymarket.js";
import { toId } from "../src/chain.js";

/**
 * Unit tests for the relayer's pure logic.
 *
 * These cover the places where a bug is silent rather than loud: order-book
 * orientation, Gamma's string-encoded fields, and its habit of returning an
 * unfiltered page instead of an error. Each case below corresponds to a real
 * mistake made while building this.
 */

test("computeDepth: best bid is the highest, best ask the lowest", () => {
  // Polymarket returns bids ascending and asks descending, i.e. both run from
  // the extreme toward the mid. Reading index 0 as "best" was the first bug.
  const book = {
    bids: [{ price: "0.001", size: "1000" }, { price: "0.40", size: "100" }],
    asks: [{ price: "0.999", size: "1000" }, { price: "0.42", size: "100" }],
  };
  const d = computeDepth(book);
  assert.equal(d.bestBid, 0.40);
  assert.equal(d.bestAsk, 0.42);
  assert.ok(Math.abs(d.mid - 0.41) < 1e-9);
});

test("computeDepth: survives reversed input ordering", () => {
  const a = computeDepth({
    bids: [{ price: "0.40", size: "100" }, { price: "0.001", size: "1000" }],
    asks: [{ price: "0.42", size: "100" }, { price: "0.999", size: "1000" }],
  });
  assert.equal(a.bestBid, 0.40);
  assert.equal(a.bestAsk, 0.42);
});

test("computeDepth: only counts size near the mid", () => {
  // A market can show huge volume while holding almost nothing near the mid.
  // Measured 2026-07-28: one market with 56M lifetime volume held 282 dollars.
  const d = computeDepth({
    bids: [{ price: "0.001", size: "10000000" }, { price: "0.50", size: "100" }],
    asks: [{ price: "0.999", size: "10000000" }, { price: "0.52", size: "100" }],
  }, 0.05);
  assert.ok(d.depthUsd < 200, `expected shallow, got ${d.depthUsd}`);
});

test("computeDepth: rejects crossed or empty books", () => {
  assert.equal(computeDepth({ bids: [], asks: [] }), null);
  assert.equal(computeDepth({
    bids: [{ price: "0.60", size: "10" }],
    asks: [{ price: "0.40", size: "10" }],
  }), null);
});

test("readResolution: open market is not resolving", () => {
  const r = readResolution({ closed: false, outcomePrices: JSON.stringify(["0.6", "0.4"]) });
  assert.equal(r.state, "open");
});

test("readResolution: closed but unsettled means halt, not resolve", () => {
  // The gap between upstream starting to resolve and the answer being knowable
  // is the largest information leak in a mirror architecture.
  const r = readResolution({ closed: true, outcomePrices: JSON.stringify(["0.6", "0.4"]) });
  assert.equal(r.state, "resolving");
  assert.equal(r.outcome, 0);
});

test("readResolution: settled Yes and No", () => {
  const yes = readResolution({
    closed: true,
    outcomes: JSON.stringify(["Yes", "No"]),
    outcomePrices: JSON.stringify(["1", "0"]),
  });
  assert.equal(yes.state, "resolved");
  assert.equal(yes.outcome, 1);

  const no = readResolution({
    closed: true,
    outcomes: JSON.stringify(["Yes", "No"]),
    outcomePrices: JSON.stringify(["0", "1"]),
  });
  assert.equal(no.outcome, 2);
});

test("readResolution: honours outcome ordering, not array position", () => {
  // Some markets list No first. Assuming index 0 is always Yes would invert
  // the answer and post a wrong bonded proposal on chain.
  const r = readResolution({
    closed: true,
    outcomes: JSON.stringify(["No", "Yes"]),
    outcomePrices: JSON.stringify(["0", "1"]),
  });
  assert.equal(r.outcome, 1, "Yes is second here, and Yes won");
});

test("readResolution: 50/50 maps to Invalid", () => {
  const r = readResolution({
    closed: true,
    outcomes: JSON.stringify(["Yes", "No"]),
    outcomePrices: JSON.stringify(["0.5", "0.5"]),
  });
  assert.equal(r.outcome, 3);
});

test("jparse: Gamma encodes arrays as strings", () => {
  assert.deepEqual(jparse('["Yes","No"]'), ["Yes", "No"]);
  assert.equal(jparse("not json"), null);
  assert.deepEqual(jparse(["already", "array"]), ["already", "array"]);
});

test("toId: only accepts a 32-byte hex conditionId", () => {
  const good = "0x" + "ab".repeat(32);
  assert.equal(toId(good), good);
  assert.equal(toId("0xdeadbeef"), null);
  assert.equal(toId(undefined), null);
  assert.equal(toId(""), null);
});

test("mapLimit: preserves order and bounds concurrency", async () => {
  let active = 0;
  let peak = 0;
  const out = await mapLimit([1, 2, 3, 4, 5, 6, 7, 8], 3, async (x) => {
    active++;
    peak = Math.max(peak, active);
    await new Promise((r) => setTimeout(r, 5));
    active--;
    return x * 10;
  });
  assert.deepEqual(out, [10, 20, 30, 40, 50, 60, 70, 80]);
  assert.ok(peak <= 3, `concurrency exceeded: ${peak}`);
});

test("mapLimit: one failure does not sink the batch", async () => {
  // A single unreachable market must not abort a whole cycle.
  const out = await mapLimit([1, 2, 3], 2, async (x) => {
    if (x === 2) throw new Error("boom");
    return x;
  });
  assert.equal(out[0], 1);
  assert.ok(out[1].__error__, "failure is captured, not thrown");
  assert.equal(out[2], 3);
});
