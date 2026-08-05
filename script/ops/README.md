# Testnet operations

These write to the live testnet. They are not tests, and nothing here runs in
CI. The smoke scripts one level up assert and exit non-zero; these change state
and are meant to be read before they are run.

- `init_markets.sh` initialises a chosen set of markets on every equity core.
  A market registered upstream is only tradeable in an asset once that asset's
  core has minted its YES and NO pair.
- `seed_venues.sh` rests a two-sided quote on those markets in every currency,
  centred on each market's own mirrored odds so a card shows the real number.
  Every order comes from one address, and the book refuses to match two orders
  from the same maker, so the quotes stay until somebody else trades.

Both need `DEPLOYER_PRIVATE_KEY` and enough collateral in that account.
