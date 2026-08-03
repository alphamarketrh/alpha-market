#!/usr/bin/env python3
"""Stage 1 measurement C: is rotation happening in PLEDGEABLE markets?

Prior finding (measure_rotation.py): 57.5% of active humans rotate capital in a
size-consistent way within 60 min. But inspection of samples showed most pairs
are the SAME RECURRING SERIES one window later:
    "Bitcoin Up or Down - July 2, 5:00AM" -> "... July 2, 6:05AM"
Different eventSlug, same product. The eventSlug fix caught intra-event rotation
but not recurring-series re-entry.

DECISIVE QUESTION
  The collateral design requires loan maturity BEFORE resolution, with a buffer.
  An hourly market resolving in 60 minutes can never be pledged. So: does
  rotation occur in long-dated markets, or only in ultra-short ones?

METHOD
  - Collapse recurring series by stripping date/time tails from slug.
  - Fetch each market endDate, compute hours-to-resolution AT TRADE TIME.
  - Bucket rotations by that tenor. Report notional per bucket.
  - Also summarise SPLIT/MERGE, which is direct evidence of hedged positions
    (the portfolios the margin engine is actually for).
"""

import json
import re
import sys
import csv
import time
import pathlib
import urllib.request
from collections import defaultdict

DATA = "https://data-api.polymarket.com"
GAMMA = "https://gamma-api.polymarket.com"
UA = {"User-Agent": "alpha-market-research/0.1"}
SLEEP = 0.05
BOT_TRADES_PER_DAY = 100
FUND_MIN, FUND_MAX = 0.5, 1.5
MIN_NOTIONAL = 20.0
WINDOW = 3600

DATE_TAIL = re.compile(
    r"[-_](jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*[-_]?\d{0,2}.*$|"
    r"[-_]\d{4}[-_]\d{2}[-_]\d{2}.*$|"
    r"[-_]\d{1,2}(am|pm).*$|"
    r"[-_]game[-_]?\d+.*$", re.I)


def series_key(slug):
    if not slug:
        return ""
    return DATE_TAIL.sub("", slug.lower()).strip("-_")


def get(url, timeout=25):
    req = urllib.request.Request(url, headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except Exception:
        return None


def history(wallet, max_pages=6, limit=500):
    rows = []
    for p in range(max_pages):
        d = get(f"{DATA}/activity?user={wallet}&limit={limit}&offset={p * limit}")
        if not isinstance(d, list) or not d:
            break
        rows.extend(d)
        if len(d) < limit:
            break
        time.sleep(SLEEP)
    return rows


END_CACHE = {}


def end_ts(cond):
    if cond in END_CACHE:
        return END_CACHE[cond]
    d = get(f"{GAMMA}/markets?condition_ids={cond}", timeout=8)
    if not (isinstance(d, list) and d):
        # gamma excludes closed markets by default and returns [] with no error.
        # Historical rotations mostly point at resolved markets, so retry.
        d = get(f"{GAMMA}/markets?condition_ids={cond}&closed=true", timeout=8)
    val = None
    if isinstance(d, list) and d:
        ed = d[0].get("endDate")
        if ed:
            try:
                import datetime as dt
                val = int(dt.datetime.fromisoformat(
                    ed.replace("Z", "+00:00")).timestamp())
            except Exception:
                val = None
    END_CACHE[cond] = val
    time.sleep(SLEEP)
    return val


BUCKETS = [(0, 1, "under 1h"), (1, 6, "1-6h"), (6, 24, "6-24h"),
           (24, 168, "1-7d"), (168, 720, "7-30d"), (720, 10**9, "over 30d")]


def bucket(hours):
    for lo, hi, name in BUCKETS:
        if lo <= hours < hi:
            return name
    return "unknown"


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 60
    wallets = open("research/data/wallets.txt").read().split()[:n]
    print(f"analysing {len(wallets)} wallets (tenor-segmented) ...")

    pairs = []
    split_merge = defaultdict(int)
    sm_wallets = set()
    same_series = 0
    cross_series = 0

    for i, w in enumerate(wallets, 1):
        rows = history(w)
        if not rows:
            continue
        for r in rows:
            t = r.get("type")
            if t in ("SPLIT", "MERGE", "CONVERSION"):
                split_merge[t] += 1
                sm_wallets.add(w)

        trades = [r for r in rows if r.get("type") == "TRADE" and r.get("timestamp")]
        if len(trades) < 2:
            continue
        trades.sort(key=lambda r: int(r["timestamp"]))
        ts = [int(r["timestamp"]) for r in trades]
        span_d = max((max(ts) - min(ts)) / 86400.0, 1e-6)
        if len(trades) / span_d >= BOT_TRADES_PER_DAY:
            continue

        for a_i, a in enumerate(trades):
            if (a.get("side") or "").upper() != "SELL":
                continue
            a_usd = float(a.get("usdcSize") or 0)
            if a_usd < MIN_NOTIONAL:
                continue
            a_ts = int(a["timestamp"])
            a_series = series_key(a.get("eventSlug"))
            for b in trades[a_i + 1:]:
                if (b.get("side") or "").upper() != "BUY":
                    continue
                if b.get("eventSlug") == a.get("eventSlug"):
                    continue
                b_usd = float(b.get("usdcSize") or 0)
                if b_usd < MIN_NOTIONAL:
                    continue
                if not (FUND_MIN <= b_usd / a_usd <= FUND_MAX):
                    continue
                gap = int(b["timestamp"]) - a_ts
                if gap < 0 or gap > WINDOW:
                    break
                b_series = series_key(b.get("eventSlug"))
                if a_series and a_series == b_series:
                    same_series += 1
                    break
                cross_series += 1
                pairs.append({
                    "wallet": w, "gap_s": gap,
                    "sell_usd": round(a_usd, 2), "buy_usd": round(b_usd, 2),
                    "buy_cond": b.get("conditionId"),
                    "buy_ts": int(b["timestamp"]),
                    "buy_title": (b.get("title") or "")[:60],
                })
                break
        if i % 20 == 0:
            print(f"  {i}/{len(wallets)} ...")

    print(f"\nrecurring-series re-entry (EXCLUDED): {same_series}")
    print(f"genuine cross-series rotations:        {cross_series}")
    if not pairs:
        print("\nNo genuine cross-series rotation found. That is the answer.")
        return

    print(f"\nresolving endDate for {len(set(p['buy_cond'] for p in pairs))} markets ...")
    by_bucket = defaultdict(list)
    _uniq = len(set(p["buy_cond"] for p in pairs))
    for _i, p in enumerate(pairs, 1):
        if _i % 100 == 0:
            print(f"  {_i}/{len(pairs)} pairs | {len(END_CACHE)}/{_uniq} unique resolved",
                  flush=True)
        e = end_ts(p["buy_cond"])
        if not e:
            by_bucket["unknown"].append(p)
            continue
        hrs = (e - p["buy_ts"]) / 3600.0
        p["tenor_h"] = round(hrs, 1)
        by_bucket[bucket(hrs)].append(p)

    pathlib.Path("research/data").mkdir(parents=True, exist_ok=True)
    with open("research/data/tenor.csv", "w", newline="") as f:
        keys = sorted({k for p in pairs for k in p.keys()})
        wr = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        wr.writeheader()
        wr.writerows(pairs)
    print("wrote research/data/tenor.csv")

    print("\n=== ROTATION BY TIME-TO-RESOLUTION OF THE MARKET BOUGHT ===")
    print("  (pledgeable requires roughly >7d so a loan can mature first)")
    order = [b[2] for b in BUCKETS] + ["unknown"]
    tot = len(pairs)
    for name in order:
        grp = by_bucket.get(name) or []
        if not grp:
            continue
        med = sorted(p["buy_usd"] for p in grp)[len(grp) // 2]
        mx = max(p["buy_usd"] for p in grp)
        flag = "  <-- PLEDGEABLE" if name in ("7-30d", "over 30d") else ""
        print(f"  {name:>10}: {len(grp):>4} ({100*len(grp)/tot:5.1f}%) "
              f"| median ${med:>8,.0f} | max ${mx:>10,.0f}{flag}")

    pledge = [p for nm in ("7-30d", "over 30d") for p in (by_bucket.get(nm) or [])]
    print(f"\n=== PLEDGEABLE SUBSET (n={len(pledge)}) ===")
    if pledge:
        v = sorted(p["buy_usd"] for p in pledge)
        print(f"  notional  p50 ${v[len(v)//2]:,.0f} | p90 ${v[int(len(v)*0.9)]:,.0f} | max ${v[-1]:,.0f}")
        print(f"  wallets   {len(set(p['wallet'] for p in pledge))}")
        print(f"  loan at 35% LTV on p50: ${v[len(v)//2]*0.35:,.2f}")
        for p in sorted(pledge, key=lambda x: -x["buy_usd"])[:5]:
            print(f"    ${p['buy_usd']:>9,.0f} tenor {p.get('tenor_h',0)/24:>6.1f}d  {p['buy_title'][:44]}")
    else:
        print("  NONE. Rotation does not occur in pledgeable markets.")

    print(f"\n=== HEDGING PRIMITIVES (margin engine relevance) ===")
    print(f"  {dict(split_merge)}")
    print(f"  wallets using split/merge/conversion: {len(sm_wallets)}/{len(wallets)}")

    print("\n=== DECISION RULE ===")
    print("If PLEDGEABLE subset is near-empty or notionals are tens of dollars,")
    print("the collateral feature has no market. Ship mirror + parlay only.")


if __name__ == "__main__":
    main()
