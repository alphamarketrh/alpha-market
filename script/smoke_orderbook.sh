#!/usr/bin/env bash
# OrderBook end-to-end on the live chain.
#
# The headline claim: two wallets holding nothing but cash can trade with each
# other in a market where not one outcome token exists. That is what makes a
# freshly mirrored market tradeable instead of dead on arrival.
#
# Then the ordinary paths: a cash-against-token fill, a paired exit by merge,
# and a cancellation that returns the escrow untouched.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

RPC="$RH_TESTNET_RPC"
D=contracts/deployments/46630.json
j(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$D" "$1"; }
REG=$(j registry); CORE=$(j core); COLL=$(j collateral); OB=$(j orderBook)
PK="$DEPLOYER_PRIVATE_KEY"; ME=$(cast wallet address --private-key "$PK")
RPK="$RELAYER_PRIVATE_KEY"

say(){ echo; echo "== $1"; }
die(){ echo; echo "FAILED: $1"; exit 1; }
send(){ cast send --rpc-url "$RPC" --private-key "$PK" "$@" >/dev/null || die "tx reverted: $*"; }
rsend(){ cast send --rpc-url "$RPC" --private-key "$RPK" "$@" >/dev/null || die "relayer tx reverted: $*"; }
xsend(){ local k="$1"; shift; cast send --rpc-url "$RPC" --private-key "$k" "$@" >/dev/null || die "tx reverted for a party: $*"; }
call(){ cast call --rpc-url "$RPC" "$@"; }
n(){ awk "{print \$1}"; }
usd(){ awk -v v="$1" "BEGIN{printf \"%.2f\", v/1000000}"; }

newwallet(){ cast wallet new --json | python3 -c "import sys,json;print(json.load(sys.stdin)[0][\"private_key\"])"; }

MID=0x$(openssl rand -hex 32)
END=$(( $(date +%s) + 2592000 ))
EXP=$(( $(date +%s) + 86400 ))
AMT=1000000000

say "0. context"
echo "  orderBook $OB"
echo "  fee       $(call "$OB" 'feeBps()(uint16)' | n) bps"
echo "  market    $MID  (fresh)"

say "1. register and initialize a market that has never traded"
rsend "$REG" "registerMarket(bytes32,uint64,uint128)" "$MID" "$END" 0
send "$CORE" "initializeMarket(bytes32)" "$MID"
YN=$(call "$CORE" 'tokensOf(bytes32)(address,address)' "$MID")
YES=$(echo "$YN" | head -1); NO=$(echo "$YN" | tail -1)
echo "  YES $YES"
echo "  NO  $NO"
SUP=$(call "$YES" 'totalSupply()(uint256)' | n)
echo "  YES supply $SUP"
[ "$SUP" = "0" ] || die "expected an empty market, supply is $SUP"

say "2. two fresh wallets, cash only, zero tokens"
APK=$(newwallet); A=$(cast wallet address --private-key "$APK")
BPK=$(newwallet); B=$(cast wallet address --private-key "$BPK")
echo "  buyer of YES $A"
echo "  buyer of NO  $B"
for pair in "$APK:$A" "$BPK:$B"; do
  k="${pair%%:*}"; addr="${pair##*:}"
  send "$COLL" "mint(address,uint256)" "$addr" 2000000000
  send --value 0.0003ether "$addr"
  xsend "$k" "$COLL" "approve(address,uint256)" "$OB" 2000000000
done
echo "  A holds $(usd "$(call "$COLL" 'balanceOf(address)(uint256)' "$A" | n)") cash, $(call "$YES" 'balanceOf(address)(uint256)' "$A" | n) YES"
echo "  B holds $(usd "$(call "$COLL" 'balanceOf(address)(uint256)' "$B" | n)") cash, $(call "$NO" 'balanceOf(address)(uint256)' "$B" | n) NO"

say "3. both post buy orders. neither can sell, because neither owns anything"
xsend "$APK" "$OB" "placeOrder(bytes32,uint8,uint64,uint128,uint64)" "$MID" 0 600000 "$AMT" "$EXP"
xsend "$BPK" "$OB" "placeOrder(bytes32,uint8,uint64,uint128,uint64)" "$MID" 2 450000 "$AMT" "$EXP"
CNT=$(call "$OB" 'marketOrderCount(bytes32)(uint256)' "$MID" | n)
BUYYES=$((CNT - 1)); BUYNO=$CNT
IDY=$(call "$OB" 'marketOrderIds(bytes32)(uint256[])' "$MID" | tr -d "[]" | tr "," "\n" | sed -n "1p" | tr -d " ")
IDN=$(call "$OB" 'marketOrderIds(bytes32)(uint256[])' "$MID" | tr -d "[]" | tr "," "\n" | sed -n "2p" | tr -d " ")
echo "  order $IDY  BuyYes at 0.60 for $(usd "$AMT")"
echo "  order $IDN  BuyNo  at 0.45 for $(usd "$AMT")"
echo "  escrowed from A: $(usd $(( 2000000000 - $(call "$COLL" 'balanceOf(address)(uint256)' "$A" | n) )))"
echo "  escrowed from B: $(usd $(( 2000000000 - $(call "$COLL" 'balanceOf(address)(uint256)' "$B" | n) )))"

say "4. THE COLD START: anyone matches the two buys into a minted pair"
MB=$(call "$COLL" 'balanceOf(address)(uint256)' "$ME" | n)
send "$OB" "matchMint(uint256,uint256,uint128)" "$IDY" "$IDN" "$AMT"
MA=$(call "$COLL" 'balanceOf(address)(uint256)' "$ME" | n)

AY=$(call "$YES" 'balanceOf(address)(uint256)' "$A" | n)
BN=$(call "$NO" 'balanceOf(address)(uint256)' "$B" | n)
SUP=$(call "$YES" 'totalSupply()(uint256)' | n)
BACK=$(call "$COLL" 'balanceOf(address)(uint256)' "$CORE" | n)
echo "  A now holds $(usd "$AY") YES"
echo "  B now holds $(usd "$BN") NO"
echo "  YES supply  $(usd "$SUP")   created from cash alone"
echo "  core backing $(usd "$BACK")  one unit behind every pair"
echo "  matcher took $(usd $(( MA - MB )))  the 0.05 overlap between the two limits"
[ "$AY" = "$AMT" ] || die "YES buyer did not receive tokens"
[ "$BN" = "$AMT" ] || die "NO buyer did not receive tokens"
[ "$SUP" = "$AMT" ] || die "supply mismatch"
[ "$(( MA - MB ))" -eq 50000000 ] || die "surplus wrong: $(( MA - MB ))"

say "5. an ordinary fill: A sells YES, a third party pays cash"
xsend "$APK" "$YES" "approve(address,uint256)" "$OB" "$AMT"
xsend "$APK" "$OB" "placeOrder(bytes32,uint8,uint64,uint128,uint64)" "$MID" 1 700000 400000000 "$EXP"
IDS=$(call "$OB" 'marketOrderIds(bytes32)(uint256[])' "$MID" | tr -d "[]" | tr "," "\n" | sed -n "3p" | tr -d " ")
echo "  order $IDS  SellYes at 0.70 for 400.00"

CPK=$(newwallet); C=$(cast wallet address --private-key "$CPK")
send "$COLL" "mint(address,uint256)" "$C" 1000000000
send --value 0.0003ether "$C"
xsend "$CPK" "$COLL" "approve(address,uint256)" "$OB" 1000000000
AB=$(call "$COLL" 'balanceOf(address)(uint256)' "$A" | n)
xsend "$CPK" "$OB" "fill(uint256,uint128)" "$IDS" 400000000
AA=$(call "$COLL" 'balanceOf(address)(uint256)' "$A" | n)
echo "  taker $C received $(usd "$(call "$YES" 'balanceOf(address)(uint256)' "$C" | n)") YES"
echo "  maker A received $(usd $(( AA - AB )))  (400 at 0.70)"
echo "  fees accrued     $(usd "$(call "$OB" 'feesAccrued()(uint256)' | n)")"
[ "$(( AA - AB ))" -eq 280000000 ] || die "maker payout wrong"

say "6. paired exit: A and B both sell, the book merges them back to cash"
xsend "$BPK" "$NO" "approve(address,uint256)" "$OB" "$AMT"
xsend "$APK" "$OB" "placeOrder(bytes32,uint8,uint64,uint128,uint64)" "$MID" 1 550000 300000000 "$EXP"
xsend "$BPK" "$OB" "placeOrder(bytes32,uint8,uint64,uint128,uint64)" "$MID" 3 400000 300000000 "$EXP"
IDSY=$(call "$OB" 'marketOrderIds(bytes32)(uint256[])' "$MID" | tr -d "[]" | tr "," "\n" | sed -n "4p" | tr -d " ")
IDSN=$(call "$OB" 'marketOrderIds(bytes32)(uint256[])' "$MID" | tr -d "[]" | tr "," "\n" | sed -n "5p" | tr -d " ")
echo "  order $IDSY SellYes at 0.55, order $IDSN SellNo at 0.40"

AB=$(call "$COLL" 'balanceOf(address)(uint256)' "$A" | n)
BB=$(call "$COLL" 'balanceOf(address)(uint256)' "$B" | n)
MB=$(call "$COLL" 'balanceOf(address)(uint256)' "$ME" | n)
send "$OB" "matchMerge(uint256,uint256,uint128)" "$IDSY" "$IDSN" 300000000
echo "  A received $(usd $(( $(call "$COLL" 'balanceOf(address)(uint256)' "$A" | n) - AB )))  (300 at 0.55)"
echo "  B received $(usd $(( $(call "$COLL" 'balanceOf(address)(uint256)' "$B" | n) - BB )))  (300 at 0.40)"
echo "  matcher    $(usd $(( $(call "$COLL" 'balanceOf(address)(uint256)' "$ME" | n) - MB )))  (the 0.05 gap)"
echo "  YES supply now $(usd "$(call "$YES" 'totalSupply()(uint256)' | n)")  (the merged pair was burned)"

say "7. cancellation returns the escrow untouched"
BEF=$(call "$COLL" 'balanceOf(address)(uint256)' "$B" | n)
xsend "$BPK" "$OB" "placeOrder(bytes32,uint8,uint64,uint128,uint64)" "$MID" 2 300000 500000000 "$EXP"
IDC=$(call "$OB" 'marketOrderIds(bytes32)(uint256[])' "$MID" | tr -d "[]" | tr "," "\n" | sed -n "6p" | tr -d " ")
MID_BAL=$(call "$COLL" 'balanceOf(address)(uint256)' "$B" | n)
echo "  order $IDC placed, escrow $(usd $(( BEF - MID_BAL )))"
xsend "$BPK" "$OB" "cancelOrder(uint256)" "$IDC"
AFT=$(call "$COLL" 'balanceOf(address)(uint256)' "$B" | n)
echo "  after cancel, balance restored: $(usd "$AFT") vs $(usd "$BEF")"
[ "$AFT" = "$BEF" ] || die "cancellation did not refund in full"

say "8. book state is public and readable"
echo "  orders ever placed on this market: $(call "$OB" 'marketOrderCount(bytes32)(uint256)' "$MID" | n)"
echo "  order $IDY open? $(call "$OB" 'isOpen(uint256)(bool)' "$IDY")"
echo "  order $IDC open? $(call "$OB" 'isOpen(uint256)(bool)' "$IDC")  (cancelled)"
echo "  book collateral held: $(usd "$(call "$COLL" 'balanceOf(address)(uint256)' "$OB" | n)")"

say "ORDER BOOK SMOKE TEST PASSED"
echo "  A market with no tokens and no market maker became tradeable"
echo "  because YES and NO always sum to one unit of collateral."
