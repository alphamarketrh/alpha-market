#!/usr/bin/env bash
# Dispute-path end-to-end on the live chain.
#
# Exercises the four protections that fence the arbiter role:
#   1. owner cannot rule, arbiter cannot touch funds
#   2. a ruling is announced first and only executes after rulingDelay
#   3. anyone may execute an announced ruling
#   4. a stalled dispute can be settled Invalid by anyone after disputeTimeout
# and the strongest one, which needs no arbiter at all:
#   5. merge stays open right through a dispute
#
# Ruling delay and dispute timeout are shortened for the run and restored at
# the end. Two fresh markets are used so mirrored data is never touched.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

RPC="$RH_TESTNET_RPC"
D=contracts/deployments/46630.json
j(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$D" "$1"; }
REG=$(j registry); CORE=$(j core); COLL=$(j collateral)
PK="$DEPLOYER_PRIVATE_KEY"; ME=$(cast wallet address --private-key "$PK")
RPK="$RELAYER_PRIVATE_KEY"
APK="$ARBITER_PRIVATE_KEY"; ARB=$(cast wallet address --private-key "$APK")

say(){ echo; echo "== $1"; }
die(){ echo; echo "FAILED: $1"; exit 1; }
send(){ cast send --rpc-url "$RPC" --private-key "$PK" "$@" >/dev/null || die "tx reverted: $*"; }
rsend(){ cast send --rpc-url "$RPC" --private-key "$RPK" "$@" >/dev/null || die "relayer tx reverted: $*"; }
asend(){ cast send --rpc-url "$RPC" --private-key "$APK" "$@" >/dev/null || die "arbiter tx reverted: $*"; }
call(){ cast call --rpc-url "$RPC" "$@"; }
n(){ awk "{print \$1}"; }
usd(){ awk -v v="$1" "BEGIN{printf \"%.2f\", v/1000000}"; }
mustfail(){ if cast send --rpc-url "$RPC" --private-key "$1" "${@:2}" >/dev/null 2>&1; then die "expected a revert: ${*:2}"; else echo "  correctly refused"; fi; }

DELAY=60
TIMEOUT=180
AMT=1000000000
BOND=$(call "$REG" "bondAmount()(uint256)" | n)
END=$(( $(date +%s) + 2592000 ))
A=0x$(openssl rand -hex 32)
B=0x$(openssl rand -hex 32)

say "0. roles on chain"
echo "  owner    $ME"
echo "  arbiter  $(call "$REG" "arbiter()(address)")"
echo "  bond     $(usd "$BOND")"
[ "$(call "$REG" "arbiter()(address)")" = "$ARB" ] || die "arbiter mismatch"
[ "$ME" = "$ARB" ] && die "owner equals arbiter, separation defeated"
echo "  owner is not the arbiter: separation holds"

say "1. shorten ruling delay to ${DELAY}s and timeout to ${TIMEOUT}s"
send "$REG" "setDisputeParams(uint64,uint64)" "$DELAY" "$TIMEOUT"
echo "  rulingDelay    $(call "$REG" "rulingDelay()(uint64)" | n)s"
echo "  disputeTimeout $(call "$REG" "disputeTimeout()(uint64)" | n)s"

say "2. two fresh markets, split into both"
for M in "$A" "$B"; do
  rsend "$REG" "registerMarket(bytes32,uint64,uint128)" "$M" "$END" 50000
  send "$CORE" "initializeMarket(bytes32)" "$M"
done
send "$COLL" "approve(address,uint256)" "$CORE" $(( AMT * 4 ))
send "$CORE" "split(bytes32,uint256)" "$A" "$AMT"
send "$CORE" "split(bytes32,uint256)" "$B" "$AMT"
YNA=$(call "$CORE" "tokensOf(bytes32)(address,address)" "$A")
YA=$(echo "$YNA" | head -1); NA=$(echo "$YNA" | tail -1)
echo "  market A $A"
echo "  market B $B"

say "3. propose then dispute on both markets"
DPK=$(cast wallet new --json | python3 -c "import sys,json;print(json.load(sys.stdin)[0][\"private_key\"])")
DIS=$(cast wallet address --private-key "$DPK")
echo "  disputer $DIS"
send "$COLL" "mint(address,uint256)" "$DIS" $(( BOND * 4 ))
send --value 0.001ether "$DIS"
cast send --rpc-url "$RPC" --private-key "$DPK" "$COLL" "approve(address,uint256)" "$REG" $(( BOND * 4 )) >/dev/null || die "disputer approve failed"

send "$COLL" "approve(address,uint256)" "$REG" $(( BOND * 4 ))
for M in "$A" "$B"; do
  send "$REG" "proposeOutcome(bytes32,uint8)" "$M" 1
  cast send --rpc-url "$RPC" --private-key "$DPK" "$REG" "disputeOutcome(bytes32)" "$M" >/dev/null || die "dispute failed"
done
echo "  A status $(call "$REG" "statusOf(bytes32)(uint8)" "$A" | n)  (4 = Disputed)"
echo "  B status $(call "$REG" "statusOf(bytes32)(uint8)" "$B" | n)  (4 = Disputed)"
DIS_AFTER_BONDS=$(call "$COLL" "balanceOf(address)(uint256)" "$DIS" | n)

say "4. PROTECTION 5: merge still works during a dispute"
echo "  a matched pair is worth one unit whatever the arbiter decides"
BEFORE=$(call "$COLL" "balanceOf(address)(uint256)" "$ME" | n)
send "$CORE" "merge(bytes32,uint256)" "$A" 400000000
AFTER=$(call "$COLL" "balanceOf(address)(uint256)" "$ME" | n)
echo "  merged 400 YES + 400 NO, received $(usd $(( AFTER - BEFORE )))"
[ "$(( AFTER - BEFORE ))" -eq 400000000 ] || die "merge did not pay out in full"

say "5. PROTECTION 1: neither owner nor a stranger may rule"
echo -n "  owner proposeRuling:   "
mustfail "$PK" "$REG" "proposeRuling(bytes32,uint8)" "$A" 2
echo -n "  disputer proposeRuling:"
mustfail "$DPK" "$REG" "proposeRuling(bytes32,uint8)" "$A" 2

say "6. PROTECTION 2: arbiter announces, and it does not take effect yet"
asend "$REG" "proposeRuling(bytes32,uint8)" "$A" 2
READY=$(call "$REG" "rulingExecutableAt(bytes32)(uint64)" "$A" | n)
echo "  announced outcome 2 (No), executable at $READY"
echo "  now                                    $(date +%s)"
echo -n "  execute immediately:   "
mustfail "$PK" "$REG" "executeRuling(bytes32)" "$A"
echo "  A status still $(call "$REG" "statusOf(bytes32)(uint8)" "$A" | n)  (4 = Disputed, not resolved)"

say "7. waiting out the ruling delay"
WAIT=$(( READY - $(date +%s) + 5 ))
[ "$WAIT" -gt 0 ] && sleep "$WAIT"

say "8. PROTECTION 3: anyone may execute the announced ruling"
cast send --rpc-url "$RPC" --private-key "$DPK" "$REG" "executeRuling(bytes32)" "$A" >/dev/null || die "execute by third party failed"
echo "  executed by the disputer, not the arbiter"
echo "  A status  $(call "$REG" "statusOf(bytes32)(uint8)" "$A" | n)  (5 = Resolved)"
echo "  A outcome $(call "$REG" "outcomeOf(bytes32)(uint8)" "$A" | n)  (2 = No)"
[ "$(call "$REG" "outcomeOf(bytes32)(uint8)" "$A" | n)" = "2" ] || die "wrong outcome"
DIS_NOW=$(call "$COLL" "balanceOf(address)(uint256)" "$DIS" | n)
echo "  disputer won both bonds: $(usd $(( DIS_NOW - DIS_AFTER_BONDS )))"
[ "$(( DIS_NOW - DIS_AFTER_BONDS ))" -eq $(( BOND * 2 )) ] || die "bond payout wrong"

say "9. PROTECTION 4: a stalled dispute settles Invalid, no arbiter needed"
TOA=$(call "$REG" "timeoutAt(bytes32)(uint64)" "$B" | n)
echo "  market B timeout at $TOA, now $(date +%s)"
echo -n "  settle too early:      "
mustfail "$PK" "$REG" "resolveByTimeout(bytes32)" "$B"
WAIT=$(( TOA - $(date +%s) + 5 ))
echo "  waiting ${WAIT}s"
[ "$WAIT" -gt 0 ] && sleep "$WAIT"
cast send --rpc-url "$RPC" --private-key "$DPK" "$REG" "resolveByTimeout(bytes32)" "$B" >/dev/null || die "timeout settle failed"
echo "  settled by a third party, arbiter never acted"
echo "  B outcome $(call "$REG" "outcomeOf(bytes32)(uint8)" "$B" | n)  (3 = Invalid)"
[ "$(call "$REG" "outcomeOf(bytes32)(uint8)" "$B" | n)" = "3" ] || die "expected Invalid"

BEFORE=$(call "$COLL" "balanceOf(address)(uint256)" "$ME" | n)
send "$CORE" "redeem(bytes32,uint256,uint256)" "$B" "$AMT" 0
AFTER=$(call "$COLL" "balanceOf(address)(uint256)" "$ME" | n)
echo "  redeemed 1000 YES for $(usd $(( AFTER - BEFORE )))  (half, as Invalid pays 0.5 each)"
[ "$(( AFTER - BEFORE ))" -eq 500000000 ] || die "invalid payout wrong"

say "10. restore production dispute parameters"
send "$REG" "setDisputeParams(uint64,uint64)" 86400 604800
echo "  rulingDelay    $(call "$REG" "rulingDelay()(uint64)" | n)s"
echo "  disputeTimeout $(call "$REG" "disputeTimeout()(uint64)" | n)s"

say "DISPUTE SMOKE TEST PASSED"
echo "  The arbiter can still rule wrongly on a directional position."
echo "  It can no longer do so secretly, instantly, or by freezing funds forever."
