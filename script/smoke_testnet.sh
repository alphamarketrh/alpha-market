#!/usr/bin/env bash
# Alpha Market - end-to-end smoke test against a live deployment.
# Proves: register -> initialize -> split -> transfer -> propose -> finalize -> redeem
# Requires: .env with DEPLOYER_PRIVATE_KEY and RH_TESTNET_RPC, deployments/<chainid>.json
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; source .env; set +a

RPC="$RH_TESTNET_RPC"
D=contracts/deployments/46630.json
REG=$(python3 -c "import json;print(json.load(open('$D'))['registry'])")
CORE=$(python3 -c "import json;print(json.load(open('$D'))['core'])")
COLL=$(python3 -c "import json;print(json.load(open('$D'))['collateral'])")
PK="$DEPLOYER_PRIVATE_KEY"
ME=$(cast wallet address --private-key "$PK")

# real Polymarket conditionId, mirrored as-is
# A fresh id each run. Hardcoding one ties the script to a deployment that
# will be replaced, and it then fails for anyone else who runs it.
MID=0x$(openssl rand -hex 32)
END=$(date -u -d "2026-07-31T12:00:00Z" +%s)
DEPTH=50000
AMT=1000000000        # 1000 USDG at 6 decimals
XFER=250000000        # 250 YES

say() { printf "\n\033[1m== %s\033[0m\n" "$1"; }
send() { cast send --rpc-url "$RPC" --private-key "$PK" "$@" >/dev/null; }

say "0. context"
echo "  chain   $(cast chain-id --rpc-url "$RPC")"
echo "  wallet  $ME"
echo "  eth     $(cast balance "$ME" --rpc-url "$RPC" --ether)"
echo "  market  $MID"

say "1. shorten challenge window to 120s (testnet UX)"
send "$REG" "setParams(uint256,uint64,uint128)" 100000000 120 25000
echo "  window now $(cast call "$REG" "challengeWindow()(uint64)" --rpc-url "$RPC")s"

say "2. register mirrored market"
if [ "$(cast call "$REG" "statusOf(bytes32)(uint8)" "$MID" --rpc-url "$RPC")" = "0" ]; then
  send "$REG" "registerMarket(bytes32,uint64,uint128)" "$MID" "$END" "$DEPTH"
  echo "  registered"
else
  echo "  already registered, skipping"
fi
echo "  status    $(cast call "$REG" "statusOf(bytes32)(uint8)" "$MID" --rpc-url "$RPC")  (1=Active)"
echo "  tradeable $(cast call "$REG" "isTradeable(bytes32)(bool)" "$MID" --rpc-url "$RPC")"

say "3. initialize YES/NO pair"
YN=$(cast call "$CORE" "tokensOf(bytes32)(address,address)" "$MID" --rpc-url "$RPC")
YES=$(echo "$YN" | head -1)
if [ "$YES" = "0x0000000000000000000000000000000000000000" ]; then
  send "$CORE" "initializeMarket(bytes32)" "$MID"
  YN=$(cast call "$CORE" "tokensOf(bytes32)(address,address)" "$MID" --rpc-url "$RPC")
fi
YES=$(echo "$YN" | head -1)
NO=$(echo "$YN" | tail -1)
echo "  YES $YES"
echo "  NO  $NO"

say "4. split 1000 USDG"
send "$COLL" "approve(address,uint256)" "$CORE" "$AMT"
send "$CORE" "split(bytes32,uint256)" "$MID" "$AMT"
echo "  YES bal  $(cast call "$YES" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC")"
echo "  NO  bal  $(cast call "$NO"  "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC")"
echo "  core USDG $(cast call "$COLL" "balanceOf(address)(uint256)" "$CORE" --rpc-url "$RPC")"

say "5. transfer 250 YES to a second wallet (transferability)"
PK2=$(cast wallet new --json | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['private_key'])")
ME2=$(cast wallet address --private-key "$PK2")
echo "  holder2 $ME2"
send "$YES" "transfer(address,uint256)" "$ME2" "$XFER"
cast send --rpc-url "$RPC" --private-key "$PK" --value 0.0005ether "$ME2" >/dev/null
echo "  holder2 YES $(cast call "$YES" "balanceOf(address)(uint256)" "$ME2" --rpc-url "$RPC")"

say "6. propose outcome YES (bonded)"
send "$COLL" "approve(address,uint256)" "$REG" 100000000
send "$REG" "proposeOutcome(bytes32,uint8)" "$MID" 1
echo "  status $(cast call "$REG" "statusOf(bytes32)(uint8)" "$MID" --rpc-url "$RPC")  (3=Proposed)"

say "7. wait out challenge window (125s)"
sleep 125

say "8. finalize"
send "$REG" "finalize(bytes32)" "$MID"
echo "  status  $(cast call "$REG" "statusOf(bytes32)(uint8)" "$MID" --rpc-url "$RPC")  (5=Resolved)"
echo "  outcome $(cast call "$REG" "outcomeOf(bytes32)(uint8)" "$MID" --rpc-url "$RPC")  (1=Yes)"

say "9. redeem from BOTH holders"
B1=$(cast call "$COLL" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC")
send "$CORE" "redeem(bytes32,uint256,uint256)" "$MID" 750000000 1000000000
A1=$(cast call "$COLL" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC")
echo "  holder1 payout $(( ${A1%% *} - ${B1%% *} ))  (expect 750000000)"

cast send --rpc-url "$RPC" --private-key "$PK2" "$CORE" \
  "redeem(bytes32,uint256,uint256)" "$MID" "$XFER" 0 >/dev/null
echo "  holder2 USDG   $(cast call "$COLL" "balanceOf(address)(uint256)" "$ME2" --rpc-url "$RPC")  (expect 250000000)"

say "10. solvency check"
echo "  core USDG left  $(cast call "$COLL" "balanceOf(address)(uint256)" "$CORE" --rpc-url "$RPC")"
echo "  YES supply left $(cast call "$YES" "totalSupply()(uint256)" --rpc-url "$RPC")"

say "SMOKE TEST COMPLETE"
echo "  explorer: https://explorer.testnet.chain.robinhood.com/address/$CORE"
