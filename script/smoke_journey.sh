#!/usr/bin/env bash
# The complete path a real user walks, on the live chain, end to end.
#
# Every earlier smoke test ran against contracts that have since been replaced.
# This one runs against whatever is deployed right now, and covers the whole
# journey rather than one contract at a time:
#
#   claim collateral -> place an order -> get matched -> market resolves
#   -> redeem the winnings -> and separately, exit while the system is paused
#
# Nothing is minted or granted by the operator. Both participants fund
# themselves from the public faucet, which is the point.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

RPC="$RH_TESTNET_RPC"
D=contracts/deployments/46630.json
j(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$D" "$1"; }
AUSD=$(j collateral); REG=$(j registry); CORE=$(j core); OB=$(j orderBook)
PK="$DEPLOYER_PRIVATE_KEY"; ME=$(cast wallet address --private-key "$PK")
RPK="$RELAYER_PRIVATE_KEY"
GPK="${GUARDIAN_PRIVATE_KEY:-$PK}"

say(){ echo; echo "== $1"; }
die(){ echo; echo "FAILED: $1"; exit 1; }
send(){ cast send --rpc-url "$RPC" --private-key "$PK" "$@" >/dev/null || die "tx reverted: $*"; }
xs(){ local k="$1"; shift; cast send --rpc-url "$RPC" --private-key "$k" "$@" >/dev/null || die "party tx reverted: $*"; }
call(){ cast call --rpc-url "$RPC" "$@"; }
n(){ awk "{print \$1}"; }
usd(){ awk -v v="$1" "BEGIN{printf \"%.2f\", v/1000000}"; }
mustfail(){ local k="$1"; shift; if cast send --rpc-url "$RPC" --private-key "$k" "$@" >/dev/null 2>&1; then die "expected a revert: $*"; else echo "  correctly refused"; fi; }

newkey(){ cast wallet new --json | python3 -c "import sys,json;print(json.load(sys.stdin)[0][\"private_key\"])"; }

MID=0x$(openssl rand -hex 32)
END=$(( $(date +%s) + 2592000 ))
EXPIRY=$(( $(date +%s) + 86400 ))

say "0. the deployment under test"
echo "  collateral $AUSD"
echo "  registry   $REG"
echo "  core       $CORE"
echo "  orderBook  $OB"
echo "  paused?    core=$(call "$CORE" 'entryPaused()(bool)') book=$(call "$OB" 'entryPaused()(bool)')"
[ "$(call "$CORE" 'entryPaused()(bool)')" = "true" ] && die "core is paused, cannot test the happy path"

say "1. two users appear with nothing but gas"
AK=$(newkey); A=$(cast wallet address --private-key "$AK")
BK=$(newkey); B=$(cast wallet address --private-key "$BK")
for pair in "$AK:$A" "$BK:$B"; do
  k="${pair%%:*}"; a="${pair##*:}"
  send --value 0.0004ether "$a"
done
echo "  user A $A"
echo "  user B $B"
echo "  A aUSD before claim: $(call "$AUSD" 'balanceOf(address)(uint256)' "$A" | n)"

say "2. each claims collateral from the public faucet, unaided"
for pair in "$AK:$A" "$BK:$B"; do
  k="${pair%%:*}"; a="${pair##*:}"
  [ "$(call "$AUSD" 'canClaim(address)(bool)' "$a")" = "true" ] || die "faucet refused a fresh address"
  xs "$k" "$AUSD" "claim()"
  xs "$k" "$AUSD" "approve(address,uint256)" "$OB" 10000000000
  xs "$k" "$AUSD" "approve(address,uint256)" "$CORE" 10000000000
done
echo "  A holds $(usd "$(call "$AUSD" 'balanceOf(address)(uint256)' "$A" | n)")"
echo "  B holds $(usd "$(call "$AUSD" 'balanceOf(address)(uint256)' "$B" | n)")"
echo "  claiming again is refused until the cooldown lapses:"
echo -n "    "
mustfail "$AK" "$AUSD" "claim()"

say "3. a market is mirrored and opened for trading"
xs "$RPK" "$REG" "registerMarket(bytes32,uint64,uint128)" "$MID" "$END" 0
send "$CORE" "initializeMarket(bytes32)" "$MID"
YN=$(call "$CORE" 'tokensOf(bytes32)(address,address)' "$MID")
YES=$(echo "$YN" | head -1); NO=$(echo "$YN" | tail -1)
echo "  market $MID"
echo "  YES $YES"
echo "  NO  $NO"
[ "$(call "$YES" 'totalSupply()(uint256)' | n)" = "0" ] || die "expected a market with no tokens yet"

say "4. both post buy orders. no tokens exist, so neither could sell"
xs "$AK" "$OB" "placeOrder(bytes32,uint8,uint64,uint128,uint64)" "$MID" 0 620000 2000000000 "$EXPIRY"
xs "$BK" "$OB" "placeOrder(bytes32,uint8,uint64,uint128,uint64)" "$MID" 2 430000 2000000000 "$EXPIRY"
CNT=$(call "$OB" 'marketOrderCount(bytes32)(uint256)' "$MID" | n)
echo "  orders on this market: $CNT"
[ "$CNT" = "2" ] || die "expected exactly two orders"
echo "  A escrowed $(usd $(( 10000000000 - $(call "$AUSD" 'balanceOf(address)(uint256)' "$A" | n) )))"
echo "  B escrowed $(usd $(( 10000000000 - $(call "$AUSD" 'balanceOf(address)(uint256)' "$B" | n) )))"

say "5. the API serves the book without anyone reading the chain directly"
curl -s --max-time 30 "http://127.0.0.1:8420/book?market=$MID" \
| python3 -c "
import sys, json
d = json.load(sys.stdin)
ms = [m for m in d['markets'] if m['id'].lower() == '$MID'.lower()]
if not ms:
    print('  MARKET NOT SERVED BY THE API'); raise SystemExit(1)
m = ms[0]
print(f\"  block {d['block']}  openOrders {m['openOrders']}\")
print(f\"  YES bid {m['yes']['bid']}   NO bid {m['no']['bid']}   mintable {m['mintable']}\")
" || die "the read API did not serve this market"

say "6. the relayer matches them into a minted pair, unprompted"
MB=$(call "$AUSD" 'balanceOf(address)(uint256)' "$(cast wallet address --private-key "$RPK")" | n)
( cd relayer && node src/index.js --live --once 2>&1 | grep -E "MATCH|sent\] mint|matched" | head -4 )
MA=$(call "$AUSD" 'balanceOf(address)(uint256)' "$(cast wallet address --private-key "$RPK")" | n)

AY=$(call "$YES" 'balanceOf(address)(uint256)' "$A" | n)
BN=$(call "$NO" 'balanceOf(address)(uint256)' "$B" | n)
echo "  A now holds $(usd "$AY") YES"
echo "  B now holds $(usd "$BN") NO"
echo "  core backing $(usd "$(call "$AUSD" 'balanceOf(address)(uint256)' "$CORE" | n)")"
echo "  matcher surplus $(usd $(( MA - MB )))  (0.62 + 0.43 - 1.00 = 0.05 per unit)"
[ "$AY" = "2000000000" ] || die "YES buyer did not receive the position"
[ "$BN" = "2000000000" ] || die "NO buyer did not receive the position"
[ "$(( MA - MB ))" -eq 100000000 ] || die "matcher surplus wrong: $(( MA - MB ))"

say "7. the market resolves through the bonded relay"
send "$AUSD" "approve(address,uint256)" "$REG" 1000000000
send "$REG" "proposeOutcome(bytes32,uint8)" "$MID" 1
W=$(call "$REG" 'challengeWindow()(uint64)' | n)
echo "  proposed YES, challenge window ${W}s"
sleep $(( W + 5 ))
send "$REG" "finalize(bytes32)" "$MID"
echo "  status  $(call "$REG" 'statusOf(bytes32)(uint8)' "$MID" | n)  (5 = Resolved)"
echo "  outcome $(call "$REG" 'outcomeOf(bytes32)(uint8)' "$MID" | n)  (1 = Yes)"
[ "$(call "$REG" 'outcomeOf(bytes32)(uint8)' "$MID" | n)" = "1" ] || die "wrong outcome"

say "8. the winner redeems, the loser gets nothing"
ABEF=$(call "$AUSD" 'balanceOf(address)(uint256)' "$A" | n)
xs "$AK" "$CORE" "redeem(bytes32,uint256,uint256)" "$MID" 2000000000 0
AAFT=$(call "$AUSD" 'balanceOf(address)(uint256)' "$A" | n)
echo "  A redeemed $(usd $(( AAFT - ABEF )))  for 2000 YES on a Yes outcome"
[ "$(( AAFT - ABEF ))" -eq 2000000000 ] || die "winner was underpaid"

# A losing redeem is refused rather than paid zero. Letting it through would
# burn the token and charge gas for nothing, so refusing protects the holder.
# Verified separately by RevertAtomicity.t.sol: the revert rolls the burn back.
BBEF=$(call "$AUSD" 'balanceOf(address)(uint256)' "$B" | n)
NBEF=$(call "$NO" 'balanceOf(address)(uint256)' "$B" | n)
echo -n "  B tries to redeem 2000 NO on a Yes outcome: "
mustfail "$BK" "$CORE" "redeem(bytes32,uint256,uint256)" "$MID" 0 2000000000
BAFT=$(call "$AUSD" 'balanceOf(address)(uint256)' "$B" | n)
NAFT=$(call "$NO" 'balanceOf(address)(uint256)' "$B" | n)
echo "  B cash unchanged: $(usd "$BBEF") -> $(usd "$BAFT")"
echo "  B still holds its worthless NO: $(usd "$NAFT")"
[ "$BAFT" = "$BBEF" ] || die "a losing token moved cash"
[ "$NAFT" = "$NBEF" ] || die "the failed redeem burned tokens anyway"

echo "  core left holding $(usd "$(call "$AUSD" 'balanceOf(address)(uint256)' "$CORE" | n)")  (backing other markets only)"

say "9. a user can still exit while the system is paused"
MID2=0x$(openssl rand -hex 32)
xs "$RPK" "$REG" "registerMarket(bytes32,uint64,uint128)" "$MID2" "$END" 0
send "$CORE" "initializeMarket(bytes32)" "$MID2"
xs "$AK" "$OB" "placeOrder(bytes32,uint8,uint64,uint128,uint64)" "$MID2" 0 500000 1000000000 "$EXPIRY"
IDS2=$(call "$OB" 'marketOrderIds(bytes32)(uint256[])' "$MID2" | tr -d "[]" | tr "," " ")
OID=$(echo "$IDS2" | awk "{print \$1}")
echo "  A placed order $OID, escrow $(usd "$(call "$OB" 'costOf(uint256,uint128)(uint256)' "$OID" 1000000000 | n)")"

echo "  guardian trips the pause"
xs "$GPK" "$OB" "pauseEntry()"
echo "  book entryPaused: $(call "$OB" 'entryPaused()(bool)')"

echo -n "  placing a new order while paused: "
mustfail "$AK" "$OB" "placeOrder(bytes32,uint8,uint64,uint128,uint64)" "$MID2" 0 500000 1000000 "$EXPIRY"

BEF=$(call "$AUSD" 'balanceOf(address)(uint256)' "$A" | n)
xs "$AK" "$OB" "cancelOrder(uint256)" "$OID"
AFT=$(call "$AUSD" 'balanceOf(address)(uint256)' "$A" | n)
echo "  cancelling while paused returned $(usd $(( AFT - BEF )))"
[ "$(( AFT - BEF ))" -eq 500000000 ] || die "escrow was trapped by the pause"

send "$OB" "unpauseEntry()"
echo "  owner resumed: entryPaused=$(call "$OB" 'entryPaused()(bool)')"

say "FULL USER JOURNEY PASSED"
echo "  Two strangers funded themselves, traded a market that held no tokens,"
echo "  were matched without asking anyone, and were paid exactly what they won."
echo "  A pause stopped new exposure and never once trapped their money."
