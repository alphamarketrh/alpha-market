#!/usr/bin/env bash
# ParlayFactory end-to-end.
# Part 1: build a parlay over two REAL mirrored Polymarket markets.
# Part 2: full lifecycle (create -> split -> resolve legs -> redeem) on two
#         dedicated test markets, so the demo does not falsify real mirror data.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

RPC="$RH_TESTNET_RPC"
D=contracts/deployments/46630.json
j(){ python3 -c "import json;print(json.load(open('$D'))['$1'])"; }
REG=$(j registry); COLL=$(j collateral); PF=$(j parlayFactory)
PK="$DEPLOYER_PRIVATE_KEY"; ME=$(cast wallet address --private-key "$PK")

say(){ printf "\n\033[1m== %s\033[0m\n" "$1"; }
send(){ cast send --rpc-url "$RPC" --private-key "$PK" "$@" >/dev/null; }
# The owner key no longer holds the relayer role; registerMarket must be sent
# by the dedicated relayer wallet.
RPK="${RELAYER_PRIVATE_KEY:-$PK}"
rsend(){ cast send --rpc-url "$RPC" --private-key "$RPK" "$@" >/dev/null; }
call(){ cast call --rpc-url "$RPC" "$@"; }
n(){ awk "{print \$1}"; }

say "0. context"
echo "  factory  $PF"
echo "  mirrored $(call "$REG" 'marketCount()(uint256)' | n)"
WIN=$(call "$REG" 'challengeWindow()(uint64)' | n)
echo "  window   ${WIN}s"

say "1. parlay over two REAL mirrored markets"
A=$(call "$REG" 'marketIds(uint256)(bytes32)' 2)
B=$(call "$REG" 'marketIds(uint256)(bytes32)' 3)
echo "  leg A $A  status=$(call "$REG" 'statusOf(bytes32)(uint8)' "$A" | n)"
echo "  leg B $B  status=$(call "$REG" 'statusOf(bytes32)(uint8)' "$B" | n)"

PID=$(call "$PF" 'parlayIdFor(bytes32[],uint8[])(bytes32)' "[$A,$B]" "[1,1]")
echo "  parlayId $PID"
EXIST=$(call "$PF" 'tokensOf(bytes32)(address,address)' "$PID" | head -1)
if [ "$EXIST" = "0x0000000000000000000000000000000000000000" ]; then
  send "$PF" "createParlay(bytes32[],uint8[])" "[$A,$B]" "[1,1]"
  echo "  created"
else
  echo "  already exists, reusing"
fi
TOK=$(call "$PF" 'tokensOf(bytes32)(address,address)' "$PID")
echo "  pYES $(echo "$TOK"|head -1)"
echo "  pNO  $(echo "$TOK"|tail -1)"

send "$COLL" "approve(address,uint256)" "$PF" 100000000000
send "$PF" "split(bytes32,uint256)" "$PID" 500000000
echo "  split 500 USDG -> pYES $(call "$(echo "$TOK"|head -1)" 'balanceOf(address)(uint256)' "$ME" | n)"
echo "  resolvable now? $(call "$PF" 'isResolvable(bytes32)(bool)' "$PID")  (false: legs open)"
send "$PF" "merge(bytes32,uint256)" "$PID" 500000000
echo "  merged back, pYES $(call "$(echo "$TOK"|head -1)" 'balanceOf(address)(uint256)' "$ME" | n)"

say "2. full lifecycle on dedicated test legs"
T1=0x$(openssl rand -hex 32); T2=0x$(openssl rand -hex 32)
END=$(( $(date +%s) + 7776000 ))
rsend "$REG" "registerMarket(bytes32,uint64,uint128)" "$T1" "$END" 50000
rsend "$REG" "registerMarket(bytes32,uint64,uint128)" "$T2" "$END" 50000
echo "  T1 $T1"
echo "  T2 $T2"

P2=$(call "$PF" 'parlayIdFor(bytes32[],uint8[])(bytes32)' "[$T1,$T2]" "[1,1]")
send "$PF" "createParlay(bytes32[],uint8[])" "[$T1,$T2]" "[1,1]"
TOK2=$(call "$PF" 'tokensOf(bytes32)(address,address)' "$P2")
PY2=$(echo "$TOK2"|head -1); PN2=$(echo "$TOK2"|tail -1)
echo "  parlay $P2"

send "$PF" "split(bytes32,uint256)" "$P2" 1000000000
echo "  split 1000 USDG"

say "3. resolve leg 1 = YES"
send "$COLL" "approve(address,uint256)" "$REG" 100000000000
send "$REG" "proposeOutcome(bytes32,uint8)" "$T1" 1
sleep $((WIN+5)); send "$REG" "finalize(bytes32)" "$T1"
echo "  T1 outcome $(call "$REG" 'outcomeOf(bytes32)(uint8)' "$T1" | n)  (1=Yes)"
echo "  parlay resolvable? $(call "$PF" 'isResolvable(bytes32)(bool)' "$P2")  (false: T2 pending)"

say "4. resolve leg 2 = NO  -> parlay must fail"
send "$REG" "proposeOutcome(bytes32,uint8)" "$T2" 2
sleep $((WIN+5)); send "$REG" "finalize(bytes32)" "$T2"
echo "  T2 outcome $(call "$REG" 'outcomeOf(bytes32)(uint8)' "$T2" | n)  (2=No)"

send "$PF" "resolve(bytes32)" "$P2"
echo "  parlay outcome $(call "$PF" 'getParlay(bytes32)(bytes32[],uint8[],address,address,uint8,bool)' "$P2" | tail -2 | head -1)  (2=No)"

say "5. redeem: YES side worthless, NO side pays all"
BAL=$(call "$COLL" 'balanceOf(address)(uint256)' "$ME" | n)
set +e
cast send --rpc-url "$RPC" --private-key "$PK" "$PF" \
  "redeem(bytes32,uint256,uint256)" "$P2" 1000000000 0 >/dev/null 2>&1
echo "  redeem YES-only exit=$?  (nonzero expected: NothingToRedeem)"
set -e
send "$PF" "redeem(bytes32,uint256,uint256)" "$P2" 0 1000000000
NEW=$(call "$COLL" 'balanceOf(address)(uint256)' "$ME" | n)
echo "  NO side received $((NEW-BAL))  (expect 1000000000)"
echo "  factory left     $(call "$COLL" 'balanceOf(address)(uint256)' "$PF" | n)  (expect 0)"

say "PARLAY SMOKE TEST COMPLETE"
echo "  one leg missed, so the parlay paid nothing."
echo "  holding both legs separately would still have paid on the winner."
echo "  resolution used zero new oracles: pure boolean over registry state."
