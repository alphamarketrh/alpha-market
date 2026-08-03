#!/usr/bin/env python3
"""Probe Polymarket public APIs. Read-only. Prints response SHAPE, not full dumps.
Purpose: verify field names before writing the Stage 1 measurement script."""

import json
import urllib.request
import urllib.error

GAMMA = "https://gamma-api.polymarket.com"
CLOB = "https://clob.polymarket.com"
UA = {"User-Agent": "alpha-market-research/0.1"}


def get(url, timeout=20):
    req = urllib.request.Request(url, headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:300].decode(errors="replace")
    except Exception as e:
        return None, f"{type(e).__name__}: {e}"


def shape(obj, depth=0, max_depth=2):
    pad = "  " * depth
    if isinstance(obj, dict):
        out = []
        for k, v in list(obj.items())[:25]:
            if depth < max_depth and isinstance(v, (dict, list)):
                out.append(f"{pad}{k}:")
                out.append(shape(v, depth + 1, max_depth))
            else:
                s = repr(v)
                out.append(f"{pad}{k} = {s[:70]}")
        return "\n".join(out)
    if isinstance(obj, list):
        if not obj:
            return f"{pad}[] (empty)"
        return f"{pad}[{len(obj)} items] first:\n" + shape(obj[0], depth + 1, max_depth)
    return f"{pad}{repr(obj)[:70]}"


def section(title):
    print("\n" + "=" * 62)
    print(title)
    print("=" * 62)


section("1. GAMMA /markets  (active, sorted by volume)")
url = f"{GAMMA}/markets?active=true&closed=false&limit=2&order=volumeNum&ascending=false"
st, body = get(url)
print("status:", st)
if isinstance(body, (dict, list)):
    print(shape(body))
else:
    print(body)

token_id = None
condition_id = None
if isinstance(body, list) and body:
    m = body[0]
    condition_id = m.get("conditionId")
    raw = m.get("clobTokenIds")
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except Exception:
            raw = None
    if isinstance(raw, list) and raw:
        token_id = raw[0]
    print("\n--- extracted ---")
    print("question   :", str(m.get("question"))[:80])
    print("conditionId:", condition_id)
    print("token_id[0]:", token_id)
    print("liquidity  :", m.get("liquidityNum") or m.get("liquidity"))
    print("volume     :", m.get("volumeNum") or m.get("volume"))
    print("endDate    :", m.get("endDate"))

section("2. CLOB /book?token_id=  (order book depth)")
if token_id:
    st, body = get(f"{CLOB}/book?token_id={token_id}")
    print("status:", st)
    if isinstance(body, dict):
        print("top-level keys:", list(body.keys()))
        for side in ("bids", "asks"):
            lv = body.get(side)
            if isinstance(lv, list):
                print(f"{side}: {len(lv)} levels, first 3 -> {lv[:3]}")
    else:
        print(str(body)[:400])
else:
    print("SKIP: no token_id from step 1")

section("3. CLOB /prices-history  (for gap measurement)")
if token_id:
    st, body = get(f"{CLOB}/prices-history?market={token_id}&interval=1m&fidelity=60")
    print("status:", st)
    if isinstance(body, dict):
        print("keys:", list(body.keys()))
        h = body.get("history")
        if isinstance(h, list):
            print("points:", len(h), "| first:", h[:2], "| last:", h[-2:] if h else None)
    else:
        print(str(body)[:400])
else:
    print("SKIP: no token_id")

section("4. CLOB /midpoint")
if token_id:
    st, body = get(f"{CLOB}/midpoint?token_id={token_id}")
    print("status:", st, "| body:", str(body)[:200])

section("DONE")
print("Next: only after shapes above are confirmed do we write the measurement script.")
