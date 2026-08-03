#!/usr/bin/env bash
# DirectionalVault end-to-end on the live chain.
#
# Proves the retail feature: pledge ONE side of a prediction position, borrow
# against it, get liquidated when the price falls, repay and recover the rest.
# MarginVault lends nothing here, which is exactly why this vault exists.
#
# Uses a dedicated test market with a random id. The relayer cannot find it
# upstream, marks it an orphan after three misses and leaves its price alone,
# so this script controls the price without fighting the service.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

RPC="$RH_TESTNET_RPC"
D=contracts/deployments/46630.json
j(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$D" "$1"; }
REG=$(j registry); CORE=$(j core); COLL=$(j collateral)
PO=$(j positionOracle); DV=$(j directionalVault)
PK="$DEPLOYER_PRIVATE_KEY"; ME=$(cast wallet address --private-key "$PK")
RPK="${RELAYER_PRIVATE_KEY:-$PK}"
UMAX=115792089237316195423570985008687907853269984665640564039457584007913129639935

say(){ echo; echo "== $1"; }
die(){ echo; echo "FAILED: $1"; exit 1; }
send(){ cast send --rpc-url "$RPC" --private-key "$PK" "$@" >/dev/null || die "tx reverted: $*"; }
rsend(){ cast send --rpc-url "$RPC" --private-key "$RPK" "$@" >/dev/null || die "relayer tx reverted: $*"; }
call(){ cast call --rpc-url "$RPC" "$@"; }
n(){ awk "{print \$1}"; }
usd(){ awk -v v="$1" "BEGIN{printf \"%.2f\", v/1000000}"; }
px(){ awk -v v="$1" "BEGIN{printf \"%.4f\", v/1000000}"; }

MID=0x$(openssl rand -hex 32)
END=$(( $(date +%s) + 2592000 ))   # 30 days out
AMT=1000000000                      # 1000 USDG

say "0. context"
echo "  vault    $DV"
echo "  oracle   $PO"
echo "  market   $MID  (fresh, not mirrored)"
echo "  ltv      $(call "$DV" 'ltvBps()(uint16)' | n) bps"
echo "  liqThr   $(call "$DV" 'liqThresholdBps()(uint16)' | n) bps"
echo "  liquid   $(usd "$(call "$COLL" 'balanceOf(address)(uint256)' "$DV" | n)")"

say "1. register market and seed a 0.60 price"
rsend "$REG" "registerMarket(bytes32,uint64,uint128)" "$MID" "$END" 50000
send "$CORE" "initializeMarket(bytes32)" "$MID"
send "$PO" "writePrice(bytes32,uint256)" "$MID" 600000
YN=$(call "$CORE" 'tokensOf(bytes32)(address,address)' "$MID")
YES=$(echo "$YN" | head -1)
echo "  YES token $YES"
echo "  price     $(px "$(call "$PO" 'priceOf(bytes32,bool)(uint256,uint256)' "$MID" true | head -1 | n)")"

say "2. split 1000 USDG, pledge ONLY the YES side"
send "$COLL" "approve(address,uint256)" "$CORE" "$AMT"
send "$CORE" "split(bytes32,uint256)" "$MID" "$AMT"
send "$YES" "approve(address,uint256)" "$DV" "$AMT"
send "$DV" "pledge(bytes32,uint256,uint256)" "$MID" "$AMT" 0
VAL=$(call "$DV" 'positionValue(bytes32,address)(uint256)' "$MID" "$ME" | n)
LIM=$(call "$DV" 'borrowLimit(bytes32,address)(uint256)' "$MID" "$ME" | n)
LIQ=$(call "$DV" 'liquidationLimit(bytes32,address)(uint256)' "$MID" "$ME" | n)
echo "  position value   $(usd "$VAL")   (1000 YES at 0.60)"
echo "  borrow limit     $(usd "$LIM")   30 percent LTV"
echo "  liquidation at   $(usd "$LIQ")   50 percent"
[ "$VAL" = "600000000" ] || die "expected 600.00 value, got $(usd "$VAL")"
echo "  >>> a one-sided pledge has borrow power here. MarginVault would lend 0."

AVAIL=$(call "$DV" 'availableToBorrow(bytes32,address)(uint256)' "$MID" "$ME" | n)
BORROW=$(( AVAIL * 93 / 100 ))
say "3. borrow $(usd "$BORROW")"
B4=$(call "$COLL" 'balanceOf(address)(uint256)' "$ME" | n)
send "$DV" "borrow(bytes32,uint256)" "$MID" "$BORROW"
AF=$(call "$COLL" 'balanceOf(address)(uint256)' "$ME" | n)
echo "  received  $(usd $(( AF - B4 )))"
echo "  debt      $(usd "$(call "$DV" 'debtOf(bytes32,address)(uint256)' "$MID" "$ME" | n)")"
echo "  health    $(call "$DV" 'healthBps(bytes32,address)(uint256)' "$MID" "$ME" | n) bps"
[ "$(( AF - B4 ))" -eq "$BORROW" ] || die "borrow mismatch"

say "4. price falls 0.60 -> 0.40 -> 0.30, stepped by the oracle move cap"
send "$PO" "writePrice(bytes32,uint256)" "$MID" 400000
echo "  at 0.40 health $(call "$DV" 'healthBps(bytes32,address)(uint256)' "$MID" "$ME" | n) bps"
send "$PO" "writePrice(bytes32,uint256)" "$MID" 300000
HB=$(call "$DV" 'healthBps(bytes32,address)(uint256)' "$MID" "$ME" | n)
echo "  position value $(usd "$(call "$DV" 'positionValue(bytes32,address)(uint256)' "$MID" "$ME" | n)")"
echo "  liquidation at $(usd "$(call "$DV" 'liquidationLimit(bytes32,address)(uint256)' "$MID" "$ME" | n)")"
echo "  debt           $(usd "$(call "$DV" 'debtOf(bytes32,address)(uint256)' "$MID" "$ME" | n)")"
echo "  health         $HB bps, below 10000 = seizable"
[ "$HB" -lt 10000 ] || die "expected an unhealthy position, got $HB"

say "5. an independent keeper liquidates"
KPK=$(cast wallet new --json | python3 -c "import sys,json;print(json.load(sys.stdin)[0][\"private_key\"])")
KEEP=$(cast wallet address --private-key "$KPK")
echo "  keeper $KEEP"
DEBT=$(call "$DV" 'debtOf(bytes32,address)(uint256)' "$MID" "$ME" | n)
HALF=$(( DEBT / 2 ))
send "$COLL" "mint(address,uint256)" "$KEEP" $(( DEBT * 2 ))
send --value 0.0006ether "$KEEP"
cast send --rpc-url "$RPC" --private-key "$KPK" "$COLL" "approve(address,uint256)" "$DV" $(( DEBT * 2 )) >/dev/null || die "keeper approve failed"
K0=$(call "$YES" 'balanceOf(address)(uint256)' "$KEEP" | n)
cast send --rpc-url "$RPC" --private-key "$KPK" "$DV" "liquidate(bytes32,address,uint256)" "$MID" "$ME" "$HALF" >/dev/null || die "liquidation reverted"
K1=$(call "$YES" 'balanceOf(address)(uint256)' "$KEEP" | n)
SEIZED=$(( K1 - K0 ))
echo "  keeper repaid $(usd "$HALF") and seized $(usd "$SEIZED") YES"
echo "  expected      $(usd $(( HALF * 108 / 100 * 1000000 / 300000 ))) YES at 0.30 plus 8 percent"
echo "  debt now      $(usd "$(call "$DV" 'debtOf(bytes32,address)(uint256)' "$MID" "$ME" | n)")"
echo "  health now    $(call "$DV" 'healthBps(bytes32,address)(uint256)' "$MID" "$ME" | n) bps"
[ "$SEIZED" -gt 0 ] || die "keeper seized nothing"
[ "$(call "$DV" 'healthBps(bytes32,address)(uint256)' "$MID" "$ME" | n)" -gt 10000 ] || die "still unhealthy after liquidation"

say "6. repay in full and recover the remaining position"
Q=$(call "$DV" 'debtOf(bytes32,address)(uint256)' "$MID" "$ME" | n)
echo "  quoted debt $(usd "$Q")"
send "$COLL" "approve(address,uint256)" "$DV" $(( Q * 2 ))
send "$DV" "repay(bytes32,uint256)" "$MID" "$UMAX"
FD=$(call "$DV" 'debtOf(bytes32,address)(uint256)' "$MID" "$ME" | n)
echo "  debt after repay $(usd "$FD")"
[ "$FD" = "0" ] || die "debt not cleared: $FD"

# Parsing a struct out of cast output is fragile; the remaining pledge is
# simply what was put in minus what the keeper took.
LEFT=$(( AMT - SEIZED ))
echo "  still pledged $(usd "$LEFT") YES"
send "$DV" "unpledge(bytes32,uint256,uint256)" "$MID" "$LEFT" 0
echo "  YES returned  $(usd "$(call "$YES" 'balanceOf(address)(uint256)' "$ME" | n)")"

say "DIRECTIONAL SMOKE TEST PASSED"
echo "  A one-sided position was collateral, which MarginVault cannot do."
echo "  Cost: a price oracle and a liquidation engine, both exercised above."
