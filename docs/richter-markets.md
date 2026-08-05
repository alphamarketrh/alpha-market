# Richter Markets

Design document. Proposed, not built. Written 5 August 2026.

Every claim below is either verified against the running system on that date or
marked open. Two earlier claims were wrong and are corrected in section 3.

## 1. Summary

Richter is a native market category for Alpha Market. A position takes a view on
how far a tokenized equity moves between one market close and the next market
open, with no view on direction.

It is the first market category Alpha Market originates rather than mirrors. Every
market today is copied from Polymarket, so the content belongs to someone else and
resolution depends on a cross-chain relayer. Richter resolves from Chainlink feeds
that already live on Robinhood Chain, with no relayer in the path.

The collateral layer is unchanged. LendingVault and CrossVault accept Richter
positions under existing rules. DirectionalVault is disabled for Richter markets,
decided 5 August 2026, for the reason in section 6.

## 2. Verification status

| Claim | Status | Evidence |
| --- | --- | --- |
| LendingVault floors at min(Y,N) with no oracle | verified | `floorOf` at LendingVault.sol:391 |
| IPositionOracle can be swapped | verified | `positionOracle` is its own field in 46630.json |
| DirectionalVault can be gated per market | verified | standalone at 0x26108683fea6956914362711818acfac1a56c718 |
| OrderBook handles the full price range | verified | smoke test filled at 0.40 through 0.70 |
| MarketRegistry needs no change at all | verified | registerMarket checks two things, neither Polymarket-specific |
| MarketRegistry is upgradeable | **no** | Ownable with a constructor and an immutable, EIP-1967 slots all zero |
| Chainlink equity feeds exist on mainnet | verified | four feeds live, read directly |
| Round history can be walked backwards | verified | 10 fork tests pass against the live aggregators |
| Testnet 46630 has equity feeds | **no** | stated in 46630.json and relayer/src/equity.js |
| Sequencer uptime feed available | **no** | address not in the Chainlink directory for this chain |

## 3. Corrections

**The multiplier does not need normalising.** An earlier draft claimed a dividend
would be misread as a price move and required dividing `uiMultiplier()` out at
both snapshots. That is wrong. Robinhood equity feeds already quote the price of
one token with the multiplier applied upstream, recorded in
`relayer/src/equity.js` lines 15 to 18. Applying it again would double count.

**Round lookup is a bounded walk, not a search.** A Chainlink proxy packs a phase
into the top sixteen bits of the round id and the aggregator counter into the
bottom sixty-four. Arithmetic on the whole id crosses phase boundaries and
produces ids belonging to no round at all.

## 4. Settlement

`RHTSLA / USD` at `0x4A1166a659A55625345e9515b32adECea5547C38`, read 5 August 2026:
latest roundId 18446744073709552359, phase 1, aggregator round 743, proxy
`phaseId()` 1, aggregator `0x7A6b81ba7FbCB90104d8C496158Cf383cD7233b1`.

Phase is still 1, so a backward walk is safe today. Settlement must read
`phaseId()` and refuse any window that spans a phase change.

`src/ChainlinkRounds.sol` implements this. Two readings:

    close = lastAtOrBefore(feed, closeTimestamp, maxSteps)
    open  = firstAtOrAfter(feed, openTimestamp, maxSteps)

Both are token prices with the multiplier already applied, so:

    move = abs(open.answer / close.answer - 1)
    s    = min(move, C) / C
    payout(BIG)  = s
    payout(CALM) = 1 - s

### Measured walk depth

From `test_measureWalkDepthForRealWindows`, run against mainnet 4663:

| Ticker | Rounds available | Steps for 24h | Steps for 72h |
| --- | --- | --- | --- |
| TSLA | 743 | 21 | 54 |
| AMD | 2047 | 111 | 218 |
| AMZN | 532 | 8 | 42 |
| PLTR | 1225 | 49 | 189 |

At roughly 6,500 gas per step, a daily market costs up to 720,000 gas on AMD and a
weekend market up to 1.4 million. For comparison, `initializeMarket` in the relayer
uses 1,158,573 gas.

AMD publishes fifteen times more densely than AMZN. The step budget must be per
ticker, never a shared constant. A `MAX_STEPS` of 512 covers the worst case
measured with more than double the margin.

Feed descriptions are not uniform: TSLA and AMD read `RHTSLA / USD` style while
AMZN and PLTR read `Robinhood AMZN / USD`. Never parse the description to identify
a ticker.

Measured round spacing on TSLA ranged from 210 seconds to 19,537 seconds within a
single walk. The wide gaps are closed exchange hours, which is the behaviour
Richter prices.

### Guards

| Condition | Behaviour |
| --- | --- |
| `oraclePaused()` true on the stock token | defer |
| Answer zero or negative | revert, `BadAnswer` |
| Round id resolves to no data | revert, `EmptyRound` |
| Walk reaches round one of a phase | revert, `PhaseBoundary` |
| Step budget exhausted | revert, `SearchExhausted` |
| No round published after the open | void the market, refund |
| Window spans a phase change | void the market, refund |

Refund pays 0.5 per unit to each side, which preserves `BIG + CALM = 1` and keeps
every collateral position solvent through the void.

`relayer/src/equity.js` already implements this logic in JavaScript as
`judgeReading()`. The Solidity version should mirror it rather than invent new
rules.

**Sequencer outage is not covered.** The uptime feed address is not in the
Chainlink directory for this chain. During an outage no round is published while
the real price moves, so a window spanning an outage resolves against the last
round before it. The mitigation is the refund path above, triggered by a maximum
age on the open reading.

## 5. Market mechanics

Each market issues a complementary pair, BIG and CALM, summing to 1.

| Tier | Cap | Opens | Settles | Per ticker per year |
| --- | --- | --- | --- | --- |
| Daily | 3% | after close | next open | 250 |
| Weekly | 5% | Friday close | Monday open | 52 |
| Event | 12% | before earnings | first open after | 4 |

Caps are placeholders until the calibration study in section 9.

Feeds exist for TSLA, AMD, AMZN and PLTR. NFLX has a testnet token but no
Robinhood feed, so it cannot be used.

Markets open on a schedule, not permissionlessly. Permissionless creation would
reproduce the dead-market problem already visible on this chain.

## 6. Vault compatibility

**LendingVault works unchanged.** Total payout under graded settlement is
`V(s) = Y*s + N*(1-s)`, linear in `s`, so its minimum over [0,1] is at an
endpoint: `V(0) = N`, `V(1) = Y`, giving `min(Y, N)`. Identical to the binary
case.

**CrossVault works unchanged.** It values equity collateral through `PriceOracle`
and never touches `IPositionOracle`. Note that CrossVault is deployed per pair,
not once, and LTV is 15% with liquidation at 35%.

**DirectionalVault is disabled for Richter.** A one-sided position has no floor,
so the vault needs an external mark. For mirrored markets that mark comes from
Polymarket, which is deep and expensive to push. For Richter the only mark is
Alpha Market own order book, which can be pushed, borrowed against at a self-made
price, and abandoned. Enforce the rejection in the contract, not the frontend.
Users keep leverage through LendingVault at 95% by holding both sides.

## 7. Market identity and registration

An earlier draft treated this section as a blocker and offered three ways to give
MarketRegistry a category field. All three were answers to a question that does
not need asking. **The registry is not changed.**

### Why nothing needs to change

registerMarket enforces exactly two conditions, and neither is specific to
Polymarket: the market must not already be registered, and depthUsd must be at or
above minDepthUsd. minDepthUsd is currently 0, so the second is not binding.
conditionId is a bytes32 used as a key; the name refers to Polymarket but nothing
constrains its contents.

More decisive: the core never reads the Polymarket-specific fields. Every call it
makes into the registry goes through a status or outcome accessor.

| Call site | What it asks |
| --- | --- |
| AlphaMarketCore.sol:63 | statusOf |
| AlphaMarketCore.sol:91 | isTradeable |
| AlphaMarketCore.sol:103, :118 | isResolved |
| AlphaMarketCore.sol:120 | outcomeOf |
| AlphaMarketCore.sol:145 | owner |

Across the whole of src/, the registry is called 42 times through six view
functions. conditionId and depthUsd are read by none of them.

### Redeploying was never an option anyway

MarketRegistry is Ownable with a constructor and an immutable bondToken, so it is
not upgradeable by construction. On chain, all three EIP-1967 slots read zero and
the bytecode is 8,890 bytes, so the deployed address is the contract itself and
not a proxy. implementation() and proxiableUUID() both revert.

Seven contracts hold the registry as an immutable: AlphaMarketCore, OrderBook,
LendingVault, MarginVault, DirectionalVault, CrossVault, MirrorPositionOracle, and
ParlayFactory. An immutable is baked into bytecode at deployment with no setter,
so replacing the registry would mean redeploying the entire system, multiplied by
five settlement currencies, and migrating the resolution state of every live
market.

### Market identity

Richter market ids are derived, not assigned:

    id = keccak256(abi.encode(feed, tier, closeTimestamp))

Deterministic, so anyone can recompute an id and verify it belongs to the market
it claims to. Collision with a Polymarket conditionId is not a practical concern
at 32 bytes.

### Where the category actually lives

Only two contracts need to know a market is Richter: RichterPositionOracle, which
reads Chainlink and computes s, and DirectionalVault, which must refuse Richter
positions per section 6. Both can hold that knowledge themselves. Neither requires
the registry to carry it.

### Registration is done by a contract, not a process

registerMarket is onlyRelayer, so something must hold that role. The existing
relayer is an EOA running a Node process, which is correct for mirrored markets
because reading Polymarket means reading another chain.

Richter needs none of that. Exchange hours are a fixed rule and Chainlink prices
are on the same chain, so RichterMarketFactory holds the relayer role instead,
granted with setRelayer(factory, true), which is already onlyOwner.

This is the stronger arrangement. With an EOA, users must trust that a private
server creates markets with the right parameters and have no way to check. With a
contract, the caps, the schedule and the permitted tickers are readable on an
explorer. It also removes a real operational failure: the existing relayer has run
out of gas twice, silently, and market creation should not depend on that.

The role is narrow by design. A relayer can call registerMarket, updateDepth,
halt and unhalt. It cannot touch funds, resolve a market, or change a parameter. A
faulty factory can at worst create junk markets, which can be halted, and the role
is revoked with setRelayer(factory, false) without affecting any market already
registered.

The factory must therefore be as narrow as it can be: it accepts only ids derived
by the formula above, only for tickers on a fixed list, and exposes nothing else.

## 8. Development strategy

Testnet 46630 has no equity feeds. Verified 2 August 2026: `oraclePaused()`
reverts on the testnet token and no aggregator on 46630 answers the AggregatorV3
interface.

Two layers, both in the repo. Unit tests replay twelve real TSLA rounds through a
phase-encoded mock and prove every branch including the failure paths a live feed
will not perform on demand. Fork tests read the real aggregators over a fork of
chain 4663, spending no gas. See the Testing section of the README for how to run
them and why the `fork` profile exists.

Richter cannot launch on testnet. Testnet proves the logic only. Production is
mainnet 4663.

## 9. Calibration study, outstanding

No settlement contract until this is done.

Pull the full round history for all four feeds from mainnet 4663. For each
close-to-open pair compute the move, then produce the distribution of the move per
ticker split by daily, weekend and earnings; the `s` each historical market would
have settled at; the break-even price for BIG at each candidate cap; and the
realised profit and loss of the minting side across the period.

Decision rule: if the minting side is profitable across the period, the vault
capacity queue has real value and the token has a foundation. If not, either the
caps are wrong or the product does not work.

`ChainlinkRounds.lastAtOrBefore` is the primitive this study needs.

## 10. Token

One token, Alpha Market own. Richter introduces none. BIG and CALM are positions
minted per market and extinguished at settlement, the same shape as existing
outcome tokens.

Two functions, both spanning mirrored and Richter markets. First, a vault capacity
queue: LendingVault accepts public deposits and capacity is finite, and yield per
depositor falls as deposits rise, so priority is a real economic right rather than
an invented one. Second, burn to claim protocol revenue: fees accumulate as aUSD
and claiming requires burning tokens of equivalent value, a redemption rather than
a distribution.

The token is never collateral for protocol losses. Launch after mainnet, after
both categories show measurable volume.

## 11. Rollout

| Stage | Content | Exit condition |
| --- | --- | --- |
| 0 | Ship the current build | demo recorded, testnet stable |
| 1 | Calibration study | caps chosen from data, or design dropped |
| 2 | Write RichterMarketFactory, narrow scope, grant the relayer role | factory registers one market on testnet |
| 3 | Build RichterPositionOracle, factory, graded settlement | full suite green |
| 4 | Mainnet 4663, weekly tier, one ticker, small cap | one month, no incident |
| 5 | Richter becomes the front page, mirror runs underneath | Richter books hold their own prices |
| 6 | Retire the mirror and the relayer | Richter volume exceeds mirror volume |

The mirror is the liquidity scaffold that holds the book up while Richter has no
price history. Do not remove it before the structure stands.

## 12. Open questions

1. Whether Richter is built before or after the current release. A business
   decision, not a technical one. The technical recommendation is after.
2. Cold start pricing. Richter markets open with no price history.
3. Gas versus stake size on the daily tier. Overnight moves are often under 1%.
4. Tier caps. Placeholders until section 9.
5. Sequencer uptime feed. Still not located.
6. Jurisdiction. These are economically derivatives on US equities. Robinhood
   restricts Stock Tokens to non-US persons. Match that at minimum.
