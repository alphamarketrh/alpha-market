#!/usr/bin/env python3
"""Stage 1 measurement B (corrected): does the borrower population exist?

Supersedes measure_borrowers.py, which was invalid: /trades has no usable
pagination and returned a snapshot spanning 0.0h, so all time windows produced
identical numbers.

This version uses /activity?user=<wallet>, confirmed to span DAYS and paginate.

CORRECTIONS APPLIED
  - Group by eventSlug, not conditionId. Rotating between legs of the same event
    ("Bitcoin Up or Down") is not portfolio rotation and must not count.
  - Use usdcSize for true notional.
  - Segment bots from humans by trades/day. A wallet doing 500 trades in 2.4h is
    a market maker, not a retail borrower.
  - Require the buy notional to be fundable by the sell proceeds, otherwise the
    two events are unrelated rather than a funding relationship.

KNOWN BIAS (do not omit from any writeup)
  Wallet list was sampled from a realtime /trades snapshot, so it over-represents
  currently-active high-frequency traders. Percentages here are NOT population
  estimates for all Polymarket users.
"""

import json
import time
import sys
import csv
import pathlib
import urllib.request
from collections import defaultdict

DATA = "https://data-api.polymarket.com"
UA = {"User-Agent": "alpha-market-research/0.1"}
SLEEP = 0.15
WINDOWS = (300, 900, 3600, 21600, 86400)
BOT_TRADES_PER_DAY = 100          # above this, treat as automated
FUND_RATIO_MIN = 0.5              # buy must be >= 50% of sell proceeds
FUND_RATIO_MAX = 1.5              # and <= 150%
MIN_NOTIONAL = 20.0               # ignore dust below $20


def get(url, timeout=25):
    req = urllib.request.Request(url, headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        print(f"    ! {type(e).__name__} {str(e)[:50]}", file=sys.stderr)
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


def main():
    n_wallets = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    wallets = open("research/data/wallets.txt").read().split()[:n_wallets]
    print(f"pulling history for {len(wallets)} wallets ...")

    stats, all_hits, type_counter = [], [], defaultdict(int)

    for i, w in enumerate(wallets, 1):
        rows = history(w)
        if not rows:
            continue
        for r in rows:
            type_counter[r.get("type")] += 1

        trades = [r for r in rows if r.get("type") == "TRADE" and r.get("timestamp")]
        if len(trades) < 2:
            continue
        trades.sort(key=lambda r: int(r["timestamp"]))
        ts = [int(r["timestamp"]) for r in trades]
        span_d = max((max(ts) - min(ts)) / 86400.0, 1e-6)
        rate = len(trades) / span_d
        is_bot = rate >= BOT_TRADES_PER_DAY

        events = {r.get("eventSlug") for r in trades if r.get("eventSlug")}

        hits = {win: 0 for win in WINDOWS}
        best = None
        for a_i, a in enumerate(trades):
            if (a.get("side") or "").upper() != "SELL":
                continue
            a_usd = float(a.get("usdcSize") or 0)
            if a_usd < MIN_NOTIONAL:
                continue
            a_ev, a_ts = a.get("eventSlug"), int(a["timestamp"])
            for b in trades[a_i + 1:]:
                if (b.get("side") or "").upper() != "BUY":
                    continue
                if b.get("eventSlug") == a_ev:
                    continue
                b_usd = float(b.get("usdcSize") or 0)
                if b_usd < MIN_NOTIONAL:
                    continue
                ratio = b_usd / a_usd
                if not (FUND_RATIO_MIN <= ratio <= FUND_RATIO_MAX):
                    continue
                gap = int(b["timestamp"]) - a_ts
                if gap < 0:
                    continue
                for win in WINDOWS:
                    if gap <= win:
                        hits[win] += 1
                if gap <= WINDOWS[-1] and best is None:
                    best = (gap, a_usd, b_usd, (a.get("title") or "")[:38],
                            (b.get("title") or "")[:38])
                break

        stats.append({
            "wallet": w, "trades": len(trades), "span_days": round(span_d, 2),
            "trades_per_day": round(rate, 1), "is_bot": is_bot,
            "n_events": len(events),
            **{f"hits_{win}": hits[win] for win in WINDOWS},
        })
        if best:
            all_hits.append((w, is_bot) + best)
        if i % 20 == 0:
            print(f"  {i}/{len(wallets)} ...")

    if not stats:
        print("FATAL: no usable wallets")
        return

    pathlib.Path("research/data").mkdir(parents=True, exist_ok=True)
    with open("research/data/rotation.csv", "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(stats[0].keys()))
        wr.writeheader()
        wr.writerows(stats)

    humans = [s for s in stats if not s["is_bot"]]
    bots = [s for s in stats if s["is_bot"]]

    print(f"\nwrote research/data/rotation.csv")
    print(f"\nactivity types seen: {dict(type_counter)}")
    print(f"\nwallets analysed: {len(stats)}  |  human {len(humans)}  bot {len(bots)}")
    if humans:
        md = sorted(s["span_days"] for s in humans)[len(humans) // 2]
        mt = sorted(s["trades"] for s in humans)[len(humans) // 2]
        print(f"human median: {mt} trades over {md} days")

    print("\n=== FUNDED ROTATION (sell A, buy different EVENT, size-consistent) ===")
    for label, grp in (("HUMAN", humans), ("BOT", bots)):
        if not grp:
            continue
        print(f"  -- {label} (n={len(grp)})")
        for win in WINDOWS:
            n = sum(1 for s in grp if s[f"hits_{win}"] > 0)
            print(f"     within {win // 60:>5} min: {n:>4} wallets ({100 * n / len(grp):5.1f}%)")

    multi = [s for s in humans if s["n_events"] > 1]
    if humans:
        print(f"\nhumans touching >1 event at all: {len(multi)} "
              f"({100 * len(multi) / len(humans):.1f}%)")

    print("\n=== sample funded rotations ===")
    for w, bot, gap, a_usd, b_usd, ta, tb in all_hits[:10]:
        tag = "BOT " if bot else "HUM "
        print(f"  {tag}{w[:10]}.. gap {gap:>6}s  sold ${a_usd:>8,.0f} [{ta}]")
        print(f"                    -> bought ${b_usd:>8,.0f} [{tb}]")

    print("\n=== INTERPRETATION ===")
    print("Read the HUMAN rows only. Bots rotate constantly and would never borrow.")
    print("If HUMAN within-60min is low single digits AND notionals are tiny,")
    print("the collateral feature has no addressable market -> cut before Solidity.")
    print("Caveat: wallet sample is biased toward currently-active traders.")


if __name__ == "__main__":
    main()
