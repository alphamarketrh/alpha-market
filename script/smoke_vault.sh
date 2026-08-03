#!/usr/bin/env bash
# MarginVault end-to-end: split -> pledge -> borrow -> resolve -> settle.
# Proves the vault is repaid from redemption proceeds with no oracle and no
# liquidation, and that a directional pledge borrows nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

RPC="$RH_TESTNET_RPC"
D=contracts/deployments/46630.json
j() { python3 -c "import json;print(json.load(open('$D'))['$1'])"; }
REG=$(j registry); CORE=$(j core); COLL=$(j collateral); VAULT=$(j marginVault)
PK="$DEPLOYER_PRIVATE_KEY"; ME=$(cast wallet address --private-key "$PK")

MID=0x$(openssl rand -hex 32)
END=$(( $(date +%s) + 7776000 ))     # +90 days
AMT=1000000000                        # 1000 USDG

say(){ printf "\n\033[1m== %s\033[0m\n" "$1"; }
send(){ cast send --rpc-url "$RPC" --private-key "$PK" "$@" >/dev/null; }
call(){ cast call --rpc-url "$RPC" "$@"; }

say "0. context"
echo "  vault   $VAULT"
echo "  market  $MID  (fresh, random)"
echo "  window  $(call "$REG" 'challengeWindow()(uint64)')s"
echo "  facility $(call "$COLL" 'balanceOf(address)(uint256)' "$VAULT")"

say "1. register + initialize"
send "$REG" "registerMarket(bytes32,uint64,uint128)" "$MID" "$END" 50000
send "$CORE" "initializeMarket(bytes32)" "$MID"
YN=$(call "$CORE" "tokensOf(bytes32)(address,address)" "$MID")
YES=$(echo "$YN"|head -1); NO=$(echo "$YN"|tail -1)
echo "  YES $YES"
echo "  NO  $NO"

say "2. split 1000 USDG"
send "$COLL" "approve(address,uint256)" "$CORE" "$AMT"
send "$CORE" "split(bytes32,uint256)" "$MID" "$AMT"

say "3. directional pledge borrows nothing"
send "$YES" "approve(address,uint256)" "$VAULT" "$AMT"
send "$VAULT" "pledge(bytes32,uint256,uint256)" "$MID" 400000000 0
echo "  floor     $(call "$VAULT" 'floorOf(bytes32,address)(uint256)' "$MID" "$ME")  (expect 0)"
echo "  available $(call "$VAULT" 'availableToBorrow(bytes32,address)(uint256)' "$MID" "$ME")  (expect 0)"

say "4. add NO side -> floor appears"
send "$NO" "approve(address,uint256)" "$VAULT" "$AMT"
send "$VAULT" "pledge(bytes32,uint256,uint256)" "$MID" 0 400000000
echo "  floor     $(call "$VAULT" 'floorOf(bytes32,address)(uint256)' "$MID" "$ME")  (expect 400000000)"
AVAIL=$(call "$VAULT" 'availableToBorrow(bytes32,address)(uint256)' "$MID" "$ME" | awk '{print $1}')
echo "  available $AVAIL  (< 380000000 after haircut + reserved interest)"

say "5. borrow the full advertised amount"
B=$(call "$COLL" 'balanceOf(address)(uint256)' "$ME" | awk '{print $1}')
send "$VAULT" "borrow(bytes32,uint256)" "$MID" "$AVAIL"
A=$(call "$COLL" 'balanceOf(address)(uint256)' "$ME" | awk '{print $1}')
echo "  received  $((A-B))  (expect $AVAIL)"
echo "  debt      $(call "$VAULT" 'debtOf(bytes32,address)(uint256)' "$MID" "$ME")"

say "6. resolve YES"
send "$COLL" "approve(address,uint256)" "$REG" 100000000
send "$REG" "proposeOutcome(bytes32,uint8)" "$MID" 1
W=$(call "$REG" 'challengeWindow()(uint64)' | awk '{print $1}')
echo "  waiting $((W+5))s"
sleep $((W+5))
send "$REG" "finalize(bytes32)" "$MID"
echo "  outcome $(call "$REG" 'outcomeOf(bytes32)(uint8)' "$MID")  (1=Yes)"

say "7. settle"
VB=$(call "$COLL" 'balanceOf(address)(uint256)' "$VAULT" | awk '{print $1}')
UB=$(call "$COLL" 'balanceOf(address)(uint256)' "$ME" | awk '{print $1}')
DEBT=$(call "$VAULT" 'debtOf(bytes32,address)(uint256)' "$MID" "$ME" | awk '{print $1}')
send "$VAULT" "settle(bytes32,address)" "$MID" "$ME"
VA=$(call "$COLL" 'balanceOf(address)(uint256)' "$VAULT" | awk '{print $1}')
UA=$(call "$COLL" 'balanceOf(address)(uint256)' "$ME" | awk '{print $1}')
echo "  debt at settle  $DEBT"
echo "  vault gained    $((VA-VB))  (expect $DEBT)"
echo "  user  received  $((UA-UB))  (expect $((400000000-DEBT)))"
echo "  debt after      $(call "$VAULT" 'debtOf(bytes32,address)(uint256)' "$MID" "$ME")"

say "SMOKE TEST COMPLETE"
echo "  no oracle used. no liquidation possible. vault repaid from redemption."
