#!/usr/bin/env python3
"""Stage 1 measurement B: does the borrower population exist?

Hypothesis under test: users exit position A only in order to fund position B.
If true, they would prefer pledging A over selling A. If the pattern is rare,
the collateral feature has no addressable market and should not be built.

CONFIRMED (probe 2026-07-28): data-api /trades is open, no auth.
Fields: proxyWallet, side, asset, conditionId, size, price, timestamp, title.
"""

import json
import time
import csv
import sys
import pathlib
import urllib.request
from collections import defaultdict

DATA = "https://data-api.polymarket.com"
UA = {"User-Agent": "alpha-market-research/0.1"}
SLEEP = 0.2
WINDOWS = (300, 900, 3600, 21600)   # 5m, 15m, 1h, 6h


def get(url, timeout=25):
    req = urllib.request.Request(url, headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        print(f"  ! {type(e).__name__} {str(e)[:60]}", file=sys.stderr)
        return None


def fetch_trades(pages, per_page):
    seen, out = set(), []
    for i in range(pages):
        batch = get(f"{DATA}/trades?limit={per_page}&offset={i * per_page}")
        if not batch:
            break
        fresh = 0
        for t in batch:
            key = (t.get("transactionHash") or "", t.get("proxyWallet"),
                   t.get("timestamp"), t.get("asset"), t.get("size"))
            if key in seen:
                continue
            seen.add(key)
            out.append(t)
            fresh += 1
        print(f"  page {i + 1}/{pages}: +{fresh} (total {len(out)})")
        if fresh == 0:
            print("  no new rows, pagination exhausted")
            break
        time.sleep(SLEEP)
    return out


def main():
    pages = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    per_page = int(sys.argv[2]) if len(sys.argv) > 2 else 500

    print(f"fetching up to {pages * per_page} recent trades ...")
    trades = fetch_trades(pages, per_page)
    if not trades:
        print("FATAL: no trades")
        return
    ts = [int(t["timestamp"]) for t in trades if t.get("timestamp")]
    span_h = (max(ts) - min(ts)) / 3600 if ts else 0
    print(f"\n{len(trades)} trades spanning {span_h:.1f}h")

    by_wallet = defaultdict(list)
    for t in trades:
        w = t.get("proxyWallet")
        if not w:
            continue
        by_wallet[w].append({
            "ts": int(t.get("timestamp") or 0),
            "side": (t.get("side") or "").upper(),
            "cond": t.get("conditionId"),
            "notional": float(t.get("size") or 0) * float(t.get("price") or 0),
            "title": (t.get("title") or "")[:50],
        })

    print(f"{len(by_wallet)} distinct wallets")

    hits = {w: 0 for w in WINDOWS}
    hit_wallets = {w: set() for w in WINDOWS}
    examples = []
    multi = 0

    for w, evs in by_wallet.items():
        evs.sort(key=lambda e: e["ts"])
        conds = {e["cond"] for e in evs}
        if len(conds) > 1:
            multi += 1
        for i, a in enumerate(evs):
            if a["side"] != "SELL":
                continue
            for b in evs[i + 1:]:
                if b["side"] != "BUY" or b["cond"] == a["cond"]:
                    continue
                gap = b["ts"] - a["ts"]
                if gap < 0:
                    continue
                for win in WINDOWS:
                    if gap <= win:
                        hits[win] += 1
                        hit_wallets[win].add(w)
                if gap <= WINDOWS[-1] and len(examples) < 8:
                    examples.append((w[:10], gap, round(a["notional"], 2),
                                     round(b["notional"], 2), a["title"], b["title"]))
                break

    print("\n=== SELL then BUY a DIFFERENT market (the borrower pattern) ===")
    nw = len(by_wallet)
    for win in WINDOWS:
        n = len(hit_wallets[win])
        print(f"  within {win // 60:>4} min: {n:>5} wallets "
              f"({100 * n / nw:5.2f}% of all) | {hits[win]} occurrences")

    print(f"\nwallets trading >1 market at all: {multi} ({100 * multi / nw:.1f}%)")

    print("\n=== sample sequences ===")
    for w, gap, na, nb, ta, tb in examples:
        print(f"  {w}.. gap {gap:>5}s  sold ${na:>9,.0f} [{ta[:28]}]")
        print(f"              -> bought ${nb:>9,.0f} [{tb[:28]}]")

    pathlib.Path("research/data").mkdir(parents=True, exist_ok=True)
    with open("research/data/trades_raw.csv", "w", newline="") as f:
        keys = ["proxyWallet", "side", "conditionId", "size", "price",
                "timestamp", "title", "slug"]
        wr = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        wr.writeheader()
        wr.writerows(trades)
    print(f"\nwrote research/data/trades_raw.csv ({len(trades)} rows)")

    print("\n=== READ THIS ===")
    print("If the 15-60 min number is low single-digit percent, the collateral")
    print("feature has no addressable market. That is a Stage 1 kill signal.")


if __name__ == "__main__":
    main()
