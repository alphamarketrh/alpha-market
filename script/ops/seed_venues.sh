#!/usr/bin/env bash
# Rest a two-sided quote on seven markets across all five settlement currencies.
#
# Prices are centred on each market's own mirrored odds rather than a single
# fixed number, so a card reading 8% for the Knicks reads 8% and not something
# invented. Every order comes from one address, and the book refuses to match
# two orders from the same maker, so the quotes stay put until somebody else
# trades against them.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
RPC="$RH_TESTNET_RPC"
PK="$DEPLOYER_PRIVATE_KEY"
EXP=$(( $(date +%s) + 2592000 ))

# name:marketId:oddsMillionths
MARKETS="
Knicks_2027:0x9627e2834d3334df13c14242f6ea442317d9981d3a5e62d0248d832551ca9345:85000
Liverpool_EPL:0x849be83aad0311ca155a2ad0c1a86bf5cdf0313672c1de414bfaa902f351030a:130000
BTC_45k:0x024b68f77bfc019341ee3db8f57c103334e4b9430bba4746d8c94aafd8b36fee:245000
Fed_hike:0x80b3af88cb991980e8da1ce86b9794a0957f96ec98c29319dd7ba65e9744d82b:625000
Apple_largest:0x55a5a4b50b7947482e95af8f638fa0b8d9a46740c5cd04c6799443e83565176a:190500
GameStop_eBay:0x32e869cb0f7316273417ec79aa94c8a139f8c390ebff8a24150a18753d257f8e:125000
Clarity_Act:0x9cb23d04b2ded06147482076688b69b487a8d982c63ebdda2ab3678cf27cf390:225000
"

# symbol:core:orderBook:collateral:decimals:qty (qty in whole units, x10^decimals)
VENUES="
aUSD:0xc2E980AB433D4Ef2AA3d6139e05b4e82e81fd102:0xe91EF60A8036F0D2d5d12E9507f92A0B7Cf12464:0x7Bb22D6F8B1b1d8799B21Baa94e6829a85F9ffA5:6:30
TSLA:0x7f6d15b0d9052579bd38463be1cdf6af75e8e2e6:0xd7e7c86d8ba4f0aaae96bfe29415da9f2e9311c2:0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E:18:0.35
PLTR:0xf201831b2042e27b2ac036eda78d6a314080dd91:0xd97b7b01817600915bc80de7335333c992c62293:0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0:18:0.5
AMD:0x5d67599a6065a490e8ef1c72e61a903169c2f95c:0x07fcf5406c8a2a6b312cdd07d7cce144a088b75e:0x71178BAc73cBeb415514eB542a8995b82669778d:18:0.65
AMZN:0xd76142857f2f933eac4ed4ae384e435683b1f3c6:0xbbf7dd862e363c681f88a500354425c9dc1105dd:0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02:18:0.65
"

ok=0; fail=0
for vp in $VENUES; do
  IFS=: read -r SYM CORE OB COLL DEC QTY <<<"$vp"
  Q=$(python3 -c "print(int($QTY * 10**$DEC))")
  SPLIT=$(python3 -c "print(int($QTY * 10**$DEC * 2))")
  BIG=$(python3 -c "print(int(10**$DEC * 100000))")
  echo
  echo "===== $SYM   qty $QTY per order"
  cast send --rpc-url "$RPC" --private-key "$PK" "$COLL" "approve(address,uint256)" "$OB"   "$BIG" >/dev/null 2>&1
  cast send --rpc-url "$RPC" --private-key "$PK" "$COLL" "approve(address,uint256)" "$CORE" "$BIG" >/dev/null 2>&1

  for mp in $MARKETS; do
    IFS=: read -r NAME MID ODDS <<<"$mp"
    W=$(python3 -c "print(max(10000, int($ODDS * 0.12)))")
    BY=$(( ODDS - W )); SY=$(( ODDS + W ))
    BN=$(( 1000000 - ODDS - W )); SN=$(( 1000000 - ODDS + W ))
    if [ $BY -le 0 ] || [ $SN -ge 1000000 ]; then echo "  $NAME skipped, price out of range"; continue; fi

    if ! cast send --rpc-url "$RPC" --private-key "$PK" "$CORE" "split(bytes32,uint256)" "$MID" "$SPLIT" >/dev/null 2>&1; then
      echo "  $NAME split failed"; fail=$((fail+1)); continue
    fi
    YN=$(cast call --rpc-url "$RPC" "$CORE" 'tokensOf(bytes32)(address,address)' "$MID")
    YES=$(echo "$YN" | head -1); NO=$(echo "$YN" | tail -1)
    cast send --rpc-url "$RPC" --private-key "$PK" "$YES" "approve(address,uint256)" "$OB" "$BIG" >/dev/null 2>&1
    cast send --rpc-url "$RPC" --private-key "$PK" "$NO"  "approve(address,uint256)" "$OB" "$BIG" >/dev/null 2>&1

    n=0
    for so in "0:$BY" "1:$SY" "2:$BN" "3:$SN"; do
      S="${so%%:*}"; PX="${so##*:}"
      cast send --rpc-url "$RPC" --private-key "$PK" "$OB" \
        "placeOrder(bytes32,uint8,uint64,uint128,uint64)" "$MID" "$S" "$PX" "$Q" "$EXP" >/dev/null 2>&1 && n=$((n+1))
    done
    CNT=$(cast call --rpc-url "$RPC" "$OB" 'marketOrderCount(bytes32)(uint256)' "$MID" | awk '{print $1}')
    printf "  %-15s yes %s/%s  no %s/%s   placed %d/4, book has %s\n" \
      "$NAME" "$(python3 -c "print($BY/1e6)")" "$(python3 -c "print($SY/1e6)")" \
      "$(python3 -c "print($BN/1e6)")" "$(python3 -c "print($SN/1e6)")" "$n" "$CNT"
    [ "$n" = "4" ] && ok=$((ok+1)) || fail=$((fail+1))
  done
done

echo
echo "===== fully seeded $ok market-venues, incomplete $fail"
echo "===== eth left $(cast balance --rpc-url "$RPC" 0xB162c126512B13eB947B5E4AB1b936607DC32427 | awk '{printf "%.6f", $1/1e18}')"
