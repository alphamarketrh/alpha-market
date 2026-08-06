#!/usr/bin/env bash
# Richter end-to-end: open -> split -> settle -> redeem, in two currencies.
#
# Opens its own market with a window that has already closed and reopened, so it
# runs at any hour and waits for nothing. The window is searched for in the
# history the mirror already holds, because a mirror filled from mainnet
# inherits the real feed's gaps and a blindly chosen window lands in one.
#
# Proves the payout equals the settlement fraction to the base unit in both a
# 6-decimal and an 18-decimal collateral, and that a matched pair still returns
# one whole unit after settlement.
#
# NOTE ON PARSING
# cast annotates large numbers, so `262500 [2.625e5]` is one field to a reader
# and two to awk. Every value below is read by line, never by whitespace field,
# because doing it the other way silently shifts every later column.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

RPC="$RH_TESTNET_RPC"
D=contracts/deployments/richter-46630.json
E=contracts/deployments/46630.json
j() { python3 -c "import json;print(json.load(open('$1'))['$2'])"; }

ORACLE=$(j "$D" richterPositionOracle)
FACTORY=$(j "$D" richterMarketFactory)
FEED=$(j "$D" feedAMD)
CORE_USD=$(j "$D" richterCoreaUSD)
CORE_TSLA=$(j "$D" richterCoreTSLA)
AUSD=$(j "$E" collateral)
TSLA=$(python3 -c "import json;print(json.load(open('contracts/deployments/46630-pair-TSLA.json'))['collateral'])")

PK="$DEPLOYER_PRIVATE_KEY"; ME=$(cast wallet address --private-key "$PK")
say(){ printf "\n\033[1m== %s\033[0m\n" "$1"; }
send(){ cast send --rpc-url "$RPC" --private-key "$PK" "$@" >/dev/null; }
call(){ cast call --rpc-url "$RPC" "$@"; }
num(){ awk '{print $1}'; }          # strip the [1.23e4] annotation
die(){ echo "FAIL: $1"; exit 1; }

say "0. context"
echo "  oracle   $ORACLE"
echo "  factory  $FACTORY"
echo "  feed     $FEED  (AMD mirror)"
CAP=$(call "$FACTORY" 'tickers(address)(address,uint32,bool)' "$FEED" | sed -n 2p | num)
[ -n "$CAP" ] && [ "$CAP" != "0" ] || die "ticker not configured on the factory"
LAG=$(call "$ORACLE" 'maxOpenLagS()(uint256)' | num)
echo "  cap      ${CAP} bps,  maxOpenLag ${LAG}s"

say "1. find a settleable window that is not already open"
PHASE=$(call "$FEED" 'phase()(uint16)' | num)
N=$(call "$FEED" 'roundCount()(uint64)' | num)
rid(){ python3 -c "print(hex(($PHASE<<64)|$1))"; }
stamp(){ call "$FEED" 'getRoundData(uint80)(uint80,int256,uint256,uint256,uint80)' "$(rid $1)" | sed -n 4p | num; }
FIRST=$(stamp 1); LAST=$(stamp "$N")
echo "  history  $FIRST .. $LAST  ($(( (LAST-FIRST)/3600 ))h, $N rounds)"

STAMPS=$(for i in $(seq 1 "$N"); do stamp "$i"; done | tr '\n' ' ')
CANDIDATES=$(python3 - <<PY
ts = sorted(int(x) for x in "$STAMPS".split())
lag, now = $LAG, $(date +%s)
out = []
# A close just after ts[i] settles against ts[i]; an open just before ts[i+1]
# settles against ts[i+1], provided the gap fits inside the lag. Widest first,
# because a wider gap spans more price movement and makes a duller test less
# likely to settle at zero.
for i in range(len(ts) - 1):
    a, b = ts[i], ts[i + 1]
    if not (600 <= b - a <= lag):
        continue
    close, open_ = a + 60, b - 60
    if close < open_ < now:
        out.append((b - a, close, open_))
for _, c, o in sorted(out, reverse=True):
    print(c, o)
PY
)
[ -n "$CANDIDATES" ] || die "no window in this history fits inside maxOpenLag"
echo "  candidates $(echo "$CANDIDATES" | wc -l)"

CLOSE=""; OPEN=""; ID=""
while read -r c o; do
  [ -n "$c" ] || continue
  cid=$(call "$FACTORY" 'marketId(address,uint32,uint64)(bytes32)' "$FEED" "$CAP" "$c")
  if [ "$(call "$FACTORY" 'opened(bytes32)(bool)' "$cid")" = "false" ]; then
    CLOSE=$c; OPEN=$o; ID=$cid; break
  fi
done <<< "$CANDIDATES"
[ -n "$CLOSE" ] || die "every candidate window has already been opened"
echo "  close    $CLOSE"
echo "  open     $OPEN   (gap $(( OPEN-CLOSE ))s, both in the past)"
echo "  id       $ID"

say "2. open the market in every settlement currency"
# The node sometimes returns a null response for a transaction it did in fact
# mine, seen on 6 August 2026 with a five million gas open. Treating that as a
# failure would abandon a market that exists, so the state is checked rather
# than the return value.
if ! send "$FACTORY" 'open(address,uint64,uint64)' "$FEED" "$CLOSE" "$OPEN" --gas-limit 9000000 2>/dev/null; then
  sleep 4
  [ "$(call "$FACTORY" 'opened(bytes32)(bool)' "$ID")" = "true" ] \
    || die "open failed and the market does not exist"
  echo "  the send returned no response, but the market is on chain"
fi
CORES=$(call "$FACTORY" 'coreCount()(uint256)' | num)
for i in $(seq 0 $((CORES-1))); do
  C=$(call "$FACTORY" 'cores(uint256)(address)' "$i")
  T=$(call "$C" 'tokensOf(bytes32)(address,address)' "$ID" | sed -n 1p)
  [ "$T" != "0x0000000000000000000000000000000000000000" ] || die "core $i has no pair"
done
echo "  $CORES cores, every one holds a pair"

say "3. what the oracle says"
RAW=$(call "$ORACLE" 'preview(bytes32)(bool,uint256,bool)' "$ID")
echo "$RAW" | sed 's/^/    /'
READY=$(echo "$RAW" | sed -n 1p)
S=$(echo "$RAW" | sed -n 2p | num)
VOID=$(echo "$RAW" | sed -n 3p)
[ "$READY" = "true" ] || die "window is not settleable, ready=$READY"
[ "$VOID" = "false" ] || die "settled as void, not the path under test"
python3 - <<PY
s, cap = $S, $CAP
print(f"  fraction {s} of 1e6, implying a {s*cap/1e6/100:.3f}% move against a {cap/100:.2f}% cap")
if s == 0: raise SystemExit("settled at zero, the payout path would be untested")
PY

say "4. split, 6-decimal and 18-decimal collateral"
# Sized from what the wallet actually holds. A fixed amount fails whenever the
# faucet has not been drawn recently, and a smoke test that depends on a balance
# nobody topped up is a test that reports the wrong thing.
BAL6=$(call "$AUSD" 'balanceOf(address)(uint256)' "$ME" | num)
BAL18=$(call "$TSLA" 'balanceOf(address)(uint256)' "$ME" | num)
AMT6=$(python3 -c "print(min(1000000000, $BAL6 // 2))")
AMT18=$(python3 -c "print(min(10000000000000000000, $BAL18 // 2))")
python3 - <<PY || die "not enough collateral to run the test"
a6, a18 = $AMT6, $AMT18
print(f"  aUSD balance {$BAL6/1e6:.2f}, using {a6/1e6:.2f}")
print(f"  TSLA balance {$BAL18/1e18:.4f}, using {a18/1e18:.4f}")
# Below these the floor division in the payout check swallows the fraction and
# the assertion stops meaning anything.
if a6 < 1000000: raise SystemExit("aUSD balance too low, claim from the faucet")
if a18 < 1000000000000000: raise SystemExit("TSLA balance too low, claim from the faucet")
PY
send "$AUSD" 'approve(address,uint256)' "$CORE_USD" "$AMT6"
send "$CORE_USD" 'split(bytes32,uint256)' "$ID" "$AMT6"
send "$TSLA" 'approve(address,uint256)' "$CORE_TSLA" "$AMT18"
send "$CORE_TSLA" 'split(bytes32,uint256)' "$ID" "$AMT18"
echo "  locked"

say "5. settle, permissionless"
send "$CORE_USD" 'settle(bytes32)' "$ID"
send "$CORE_TSLA" 'settle(bytes32)' "$ID"
SU=$(call "$CORE_USD" 'settlementOf(bytes32)(uint256,uint256)' "$ID" | sed -n 1p | num)
ST=$(call "$CORE_TSLA" 'settlementOf(bytes32)(uint256,uint256)' "$ID" | sed -n 1p | num)
[ "$SU" = "$S" ] || die "aUSD core froze $SU, oracle said $S"
[ "$ST" = "$S" ] || die "TSLA core froze $ST, oracle said $S"
echo "  both cores froze $S, matching the oracle"

say "6. redeem BIG, payout must equal amount times the fraction"
B0=$(call "$AUSD" 'balanceOf(address)(uint256)' "$ME" | num)
T0=$(call "$TSLA" 'balanceOf(address)(uint256)' "$ME" | num)
send "$CORE_USD" 'redeem(bytes32,uint256,uint256)' "$ID" "$AMT6" 0
send "$CORE_TSLA" 'redeem(bytes32,uint256,uint256)' "$ID" "$AMT18" 0
B1=$(call "$AUSD" 'balanceOf(address)(uint256)' "$ME" | num)
T1=$(call "$TSLA" 'balanceOf(address)(uint256)' "$ME" | num)
python3 - <<PY || die "payout did not match the fraction"
s = $S
for label, amt, got in [("aUSD", $AMT6, $B1 - $B0), ("TSLA", $AMT18, $T1 - $T0)]:
    want = amt * s // 1000000
    print(f"  {label}  paid {got}  expected {want}  {'OK' if got == want else 'MISMATCH'}")
    if got != want: raise SystemExit(1)
PY

say "7. split is closed, and the pair is still one whole unit"
if send "$CORE_USD" 'split(bytes32,uint256)' "$ID" 1 2>/dev/null; then
  die "split must be refused after settlement"
fi
echo "  split correctly refused"
CALMU=$(call "$CORE_USD" 'tokensOf(bytes32)(address,address)' "$ID" | sed -n 2p)
CB=$(call "$CALMU" 'balanceOf(address)(uint256)' "$ME" | num)
B2=$(call "$AUSD" 'balanceOf(address)(uint256)' "$ME" | num)
send "$CORE_USD" 'redeem(bytes32,uint256,uint256)' "$ID" 0 "$CB"
B3=$(call "$AUSD" 'balanceOf(address)(uint256)' "$ME" | num)
python3 - <<PY || die "the pair did not return one whole unit"
amt, big, calm = $AMT6, $B1 - $B0, $B3 - $B2
print(f"  BIG {big} + CALM {calm} = {big+calm}, locked {amt}")
if not (amt - 2 <= big + calm <= amt): raise SystemExit(1)
print("  the pair invariant holds through graded settlement")
PY

say "8. the book: two wallets with cash and no tokens"
# The cold start. Nobody holds BIG or CALM, so nobody can sell, so ordinarily
# nobody can buy. A mint-match takes two buyers on opposite sides whose limits
# cover one whole unit between them and creates the pair out of the cash they
# both brought.
BOOK=$(j "$D" richterBookaUSD)
echo "  book     $BOOK"
[ "$(call "$BOOK" 'core()(address)')" = "$CORE_USD" ] || die "book is bound to another core"

# A second market, still unsettled, because the book refuses a settled one.
CLOSE2=""; OPEN2=""; ID2=""
while read -r c o; do
  [ -n "$c" ] || continue
  cid=$(call "$FACTORY" 'marketId(address,uint32,uint64)(bytes32)' "$FEED" "$CAP" "$c")
  if [ "$(call "$FACTORY" 'opened(bytes32)(bool)' "$cid")" = "false" ]; then
    CLOSE2=$c; OPEN2=$o; ID2=$cid; break
  fi
done <<< "$CANDIDATES"
[ -n "$ID2" ] || die "no second window left to open"
send "$FACTORY" 'open(address,uint64,uint64)' "$FEED" "$CLOSE2" "$OPEN2" --gas-limit 9000000
echo "  market   $ID2"

A=$(cast wallet new | grep Address | awk '{print $2}')
AK=$(cast wallet new --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['private_key'])" 2>/dev/null)
# Deterministic throwaway keys, so the run is reproducible and nothing is left
# holding value: everything here is testnet and returns to the deployer anyway.
AK=0x$(openssl rand -hex 32); A=$(cast wallet address --private-key "$AK")
BK=0x$(openssl rand -hex 32); B=$(cast wallet address --private-key "$BK")
echo "  buyer of BIG  $A"
echo "  buyer of CALM $B"

FUND=30000000    # 30 aUSD each, enough for the order and the escrow rounding
send "$AUSD" 'transfer(address,uint256)' "$A" "$FUND"
send "$AUSD" 'transfer(address,uint256)' "$B" "$FUND"
cast send --rpc-url "$RPC" --private-key "$PK" --value 0.00005ether "$A" >/dev/null
cast send --rpc-url "$RPC" --private-key "$PK" --value 0.00005ether "$B" >/dev/null

BIG2=$(call "$CORE_USD" 'tokensOf(bytes32)(address,address)' "$ID2" | sed -n 1p)
CALM2=$(call "$CORE_USD" 'tokensOf(bytes32)(address,address)' "$ID2" | sed -n 2p)
echo "  BIG supply before: $(call "$BIG2" 'totalSupply()(uint256)' | num)"

EXP=$(( $(date +%s) + 86400 ))
sendas(){ local k=$1; shift; cast send --rpc-url "$RPC" --private-key "$k" "$@" >/dev/null; }
sendas "$AK" "$AUSD" 'approve(address,uint256)' "$BOOK" "$FUND"
sendas "$BK" "$AUSD" 'approve(address,uint256)' "$BOOK" "$FUND"
# 0.60 for BIG and 0.45 for CALM sum to 1.05, so the pair mints and the five
# hundredths of overlap pay whoever calls the match.
sendas "$AK" "$BOOK" 'placeOrder(bytes32,uint8,uint64,uint128,uint64)' "$ID2" 0 600000 20000000 "$EXP"
sendas "$BK" "$BOOK" 'placeOrder(bytes32,uint8,uint64,uint128,uint64)' "$ID2" 2 450000 20000000 "$EXP"
NEXT=$(call "$BOOK" 'nextOrderId()(uint256)' | num)
OA=$((NEXT-2)); OB=$((NEXT-1))
echo "  orders   $OA BuyBig at 0.60, $OB BuyCalm at 0.45"

MB0=$(call "$AUSD" 'balanceOf(address)(uint256)' "$ME" | num)
send "$BOOK" 'matchMint(uint256,uint256,uint128)' "$OA" "$OB" 20000000
MB1=$(call "$AUSD" 'balanceOf(address)(uint256)' "$ME" | num)

python3 - <<PY || die "the cold start did not create the pair"
big = $(call "$BIG2" 'balanceOf(address)(uint256)' "$A" | num)
calm = $(call "$CALM2" 'balanceOf(address)(uint256)' "$B" | num)
supply = $(call "$BIG2" 'totalSupply()(uint256)' | num)
surplus = $MB1 - $MB0
print(f"  A holds BIG   {big}")
print(f"  B holds CALM  {calm}")
print(f"  BIG supply    {supply}   created from cash alone")
print(f"  matcher took  {surplus}   the 0.05 overlap")
if big != 20000000 or calm != 20000000: raise SystemExit(1)
if supply != 20000000: raise SystemExit(1)
PY

say "RICHTER SMOKE TEST PASSED"
echo "  A market on the size of a move settled to a fraction, in two collaterals"
echo "  with different decimals, from two Chainlink rounds and no human."
echo "  And a second one traded from nothing: two wallets holding only cash"
echo "  became holders of opposite sides, because BIG and CALM sum to one unit."
