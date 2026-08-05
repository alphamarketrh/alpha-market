#!/usr/bin/env bash
# Initialise a spread of markets on every equity core.
#
# A market registered upstream exists on the registry, but each settlement
# currency mints its own YES and NO pair, so a market is only tradeable in an
# asset once that asset's core has initialised it. Eight subjects were chosen
# to differ from one another: basketball, two football leagues, bitcoin, a Fed
# decision, a market cap race, an acquisition and a bill.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
RPC="$RH_TESTNET_RPC"
PK="$DEPLOYER_PRIVATE_KEY"

CORES="
0xf201831b2042e27b2ac036eda78d6a314080dd91:PLTR
0x7f6d15b0d9052579bd38463be1cdf6af75e8e2e6:TSLA
0x5d67599a6065a490e8ef1c72e61a903169c2f95c:AMD
0xd76142857f2f933eac4ed4ae384e435683b1f3c6:AMZN
"

MARKETS="
0x9627e2834d3334df13c14242f6ea442317d9981d3a5e62d0248d832551ca9345:Knicks_2027
0x849be83aad0311ca155a2ad0c1a86bf5cdf0313672c1de414bfaa902f351030a:Liverpool_EPL
0xefa17dee3af09f69f9ddf245b969aa4efbe7c71cdf06ee49d694408bc33e2ed2:Shakhtar_UCL
0x024b68f77bfc019341ee3db8f57c103334e4b9430bba4746d8c94aafd8b36fee:BTC_45k
0x80b3af88cb991980e8da1ce86b9794a0957f96ec98c29319dd7ba65e9744d82b:Fed_hike
0x55a5a4b50b7947482e95af8f638fa0b8d9a46740c5cd04c6799443e83565176a:Apple_largest
0x32e869cb0f7316273417ec79aa94c8a139f8c390ebff8a24150a18753d257f8e:GameStop_eBay
0x9cb23d04b2ded06147482076688b69b487a8d982c63ebdda2ab3678cf27cf390:Clarity_Act
"

Z=0x0000000000000000000000000000000000000000
done_n=0; skip_n=0; fail_n=0

for pair in $MARKETS; do
  MID="${pair%%:*}"; NAME="${pair##*:}"
  echo
  echo "== $NAME"
  for cp in $CORES; do
    CORE="${cp%%:*}"; SYM="${cp##*:}"
    Y=$(cast call --rpc-url "$RPC" "$CORE" 'tokensOf(bytes32)(address,address)' "$MID" 2>/dev/null | head -1)
    if [ "$Y" != "$Z" ] && [ -n "$Y" ]; then
      echo "   $SYM already"; skip_n=$((skip_n+1)); continue
    fi
    if cast send --rpc-url "$RPC" --private-key "$PK" \
         "$CORE" "initializeMarket(bytes32)" "$MID" >/dev/null 2>&1; then
      echo "   $SYM initialised"; done_n=$((done_n+1))
    else
      echo "   $SYM FAILED"; fail_n=$((fail_n+1))
    fi
  done
done

echo
echo "== initialised $done_n, already there $skip_n, failed $fail_n"
echo "== deployer eth left $(cast balance --rpc-url "$RPC" \
  0xB162c126512B13eB947B5E4AB1b936607DC32427 | awk '{printf "%.6f", $1/1e18}')"
