#!/usr/bin/env python3
"""Stage 1 measurement A: order book depth across active Polymarket markets.

Question: how many markets would pass a depth floor, i.e. are mirrorable at all?
Volume is NOT depth. This measures notional resting near the mid.

CONFIRMED API SHAPES (probe 2026-07-28):
  - bids ascend from worst; asks descend from worst. Best = last element.
    We sort explicitly rather than trust order.
  - outcomes/outcomePrices/clobTokenIds are JSON-encoded STRINGS.
"""

import json
import time
import urllib.request
import urllib.error
import csv
import sys

GAMMA = "https://gamma-api.polymarket.com"
CLOB = "https://clob.polymarket.com"
UA = {"User-Agent": "alpha-market-research/0.1"}
SLEEP = 0.25
ABS_BAND = 0.05          # +/- 5 probability points
REL_BAND = 0.10          # +/- 10 percent of mid


def get(url, timeout=20):
    req = urllib.request.Request(url, headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        print(f"  ! {type(e).__name__} on {url[:70]}", file=sys.stderr)
        return None


def jparse(v):
    if isinstance(v, str):
        try:
            return json.loads(v)
        except Exception:
            return None
    return v


def depth(book):
    """Return (best_bid, best_ask, mid, depth_abs, depth_rel) in USDC notional."""
    bids = [(float(x["price"]), float(x["size"])) for x in book.get("bids") or []]
    asks = [(float(x["price"]), float(x["size"])) for x in book.get("asks") or []]
    if not bids or not asks:
        return None
    bids.sort(key=lambda t: t[0])          # ascending
    asks.sort(key=lambda t: t[0])          # ascending
    best_bid = bids[-1][0]                 # highest bid
    best_ask = asks[0][0]                  # lowest ask
    if best_ask <= best_bid:
        return None
    mid = (best_bid + best_ask) / 2

    def band_sum(lo, hi):
        s = 0.0
        for p, q in bids:
            if p >= lo:
                s += p * q
        for p, q in asks:
            if p <= hi:
                s += p * q
        return s

    d_abs = band_sum(mid - ABS_BAND, mid + ABS_BAND)
    d_rel = band_sum(mid * (1 - REL_BAND), mid * (1 + REL_BAND))
    return best_bid, best_ask, mid, d_abs, d_rel


def fetch_markets(target):
    out, offset = [], 0
    while len(out) < target:
        url = (f"{GAMMA}/markets?active=true&closed=false&archived=false"
               f"&limit=100&offset={offset}&order=volumeNum&ascending=false")
        batch = get(url)
        if not batch:
            break
        out.extend(batch)
        if len(batch) < 100:
            break
        offset += 100
        time.sleep(SLEEP)
    return out[:target]


def main():
    target = int(sys.argv[1]) if len(sys.argv) > 1 else 50
    print(f"fetching {target} active markets by volume ...")
    markets = fetch_markets(target)
    print(f"got {len(markets)}")

    rows = []
    for i, m in enumerate(markets, 1):
        toks = jparse(m.get("clobTokenIds")) or []
        if not toks:
            continue
        book = get(f"{CLOB}/book?token_id={toks[0]}")
        time.sleep(SLEEP)
        if not book:
            continue
        d = depth(book)
        if not d:
            continue
        bb, ba, mid, d_abs, d_rel = d
        rows.append({
            "question": (m.get("question") or "")[:70],
            "conditionId": m.get("conditionId"),
            "volume": round(float(m.get("volume") or 0), 2),
            "liquidity": round(float(m.get("liquidity") or 0), 2),
            "endDate": m.get("endDate"),
            "neg_risk": book.get("neg_risk"),
            "tick_size": book.get("tick_size"),
            "best_bid": bb,
            "best_ask": ba,
            "spread": round(ba - bb, 4),
            "mid": round(mid, 4),
            "depth_abs_5pt": round(d_abs, 2),
            "depth_rel_10pct": round(d_rel, 2),
        })
        if i % 10 == 0:
            print(f"  {i}/{len(markets)} ...")

    pathlib.Path("research/data").mkdir(parents=True, exist_ok=True)
    out = "research/data/depth.csv"
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    print(f"\nwrote {out}  ({len(rows)} markets)")
    print("\n=== depth floor survival ===")
    for floor in (1000, 5000, 10000, 25000, 50000, 100000):
        n = sum(1 for r in rows if r["depth_abs_5pt"] >= floor)
        pct = 100 * n / len(rows) if rows else 0
        print(f"  depth(+/-5pt) >= ${floor:>7,}: {n:>4} markets ({pct:5.1f}%)")
    print("\n=== spread distribution ===")
    sp = sorted(r["spread"] for r in rows)
    for label, idx in (("p10", 0.10), ("median", 0.50), ("p90", 0.90)):
        print(f"  {label:>6}: {sp[int(len(sp) * idx)]:.4f}")
    print("\n=== volume vs depth sanity (top 5 by volume) ===")
    for r in sorted(rows, key=lambda x: -x["volume"])[:5]:
        print(f"  vol ${r['volume']:>14,.0f} | depth ${r['depth_abs_5pt']:>10,.0f} | {r['question'][:45]}")


import pathlib  # noqa: E402
if __name__ == "__main__":
    main()
