<div align="center">

# Alpha Market

<img src="assets/banner.png" alt="One asset. Four jobs." width="820">

[![license](https://img.shields.io/badge/license-MIT-E8E8E8?style=flat-square&labelColor=111111)](LICENSE)
[![solidity](https://img.shields.io/badge/solidity-0.8.28-E8E8E8?style=flat-square&labelColor=111111)](contracts/foundry.toml)
[![tests](https://img.shields.io/badge/tests-332%20passing-E8E8E8?style=flat-square&labelColor=111111)](#testing)
[![fuzz](https://img.shields.io/badge/fuzz-18%20invariants%20%C3%97%2050k-E8E8E8?style=flat-square&labelColor=111111)](#testing)
[![chain](https://img.shields.io/badge/chain-Robinhood%20Chain-E8E8E8?style=flat-square&labelColor=111111)](https://explorer.testnet.chain.robinhood.com)
[![settlement](https://img.shields.io/badge/settles%20in-5%20currencies-E8E8E8?style=flat-square&labelColor=111111)](#deployed-on-robinhood-chain-testnet-chainid-46630)

[Website](https://alphamarket.network) ·
[Docs](https://alphamarket.network/docs) ·
[API](https://api.alphamarket.network/config) ·
[X](https://x.com/alphamarketnet) ·
[Explorer](https://explorer.testnet.chain.robinhood.com)

</div>

---

A prediction market on **Robinhood Chain** where the question comes from
Polymarket and the price does not.

Markets and their resolved outcomes are mirrored from Polymarket, because
re-litigating whether an event happened is not where the value is. Everything
downstream is native: an on-chain order book forms the odds, and the same
position can be settled in whichever asset the holder already owns. A user
whose wealth is in tokenized equities bets in equities and is paid in equities,
without selling anything first.

On top sits the part that has no equivalent elsewhere: **three ways to borrow
against a position, each priced by how much can actually be proven about what
the collateral is worth.**

**Status:** live at **[alphamarket.network](https://alphamarket.network)** on
testnet 46630, settling in five currencies. 332 contract tests, 13 relayer
tests, 23 fuzzed invariants at 50,000 runs each, and 8 end-to-end smoke scripts
that run against the deployed contracts rather than a local simulator.

---

## Quick start

Everything below works against the live testnet. Nothing is granted by the
team; both assets are obtained by the user.

```bash
export RPC=https://rpc.testnet.chain.robinhood.com
export AUSD=0x7Bb22D6F8B1b1d8799B21Baa94e6829a85F9ffA5
export CORE=0xc2E980AB433D4Ef2AA3d6139e05b4e82e81fd102
export BOOK=0xe91EF60A8036F0D2d5d12E9507f92A0B7Cf12464
export REG=0x5ee116f6145158C395106AE6806b9FDa2bB94c9e

# 1. collateral, self-service, no permission needed
cast send $AUSD "claim()" --rpc-url $RPC --private-key $PK

# 2. see what is trading, in one call instead of thousands
curl -s https://api.alphamarket.network/book | jq '.markets[0]'

# 3. buy YES at 0.62 for 1000 units, expiring in a day
cast send $AUSD "approve(address,uint256)" $BOOK 1000000000 --rpc-url $RPC --private-key $PK
cast send $BOOK "placeOrder(bytes32,uint8,uint64,uint128,uint64)" \
  $MARKET_ID 0 620000 1000000000 $(($(date +%s) + 86400)) \
  --rpc-url $RPC --private-key $PK
```

A price of `620000` means 0.62. Prices are millionths of one whole unit of
collateral, independent of that asset's own decimals.

For ETH gas and stock tokens, use the official
[Robinhood testnet faucet](https://faucet.testnet.chain.robinhood.com).

---

## The central idea

Everything follows from one question: **how much can be proven about what the
collateral is worth?**

| | `LendingVault` | `DirectionalVault` | `CrossVault` |
|---|---|---|---|
| Pledge | 1,000 YES **and** 1,000 NO | 1,000 YES **only** | 1,000 YES-TSLA |
| Debt asset | same as the pledge | same as the pledge | **a different asset** |
| Worst case | `min(Y, N)` = 1,000 | 0, YES can lose | 0, and two prices move |
| How that is known | **proven by enumeration** | one price | two prices multiplied |
| Price oracle | **none** | required | two required |
| Liquidation | **never** | yes | yes |
| Max LTV | 95% | 30% | 15% |
| Rate ceiling | 30% | 60% | 60% |
| Funded by | **anyone** | owner | owner |
| Bad debt | **impossible** | possible | possible |

A binary market has exactly three terminal states, so a hedged position can be
valued by listing them:

| Outcome | 1,000 YES redeems | 1,000 NO redeems |
|---|---|---|
| Yes | 1,000 | 0 |
| No | 0 | 1,000 |
| Invalid | 500 | 500 |

Every row totals at least `min(Y, N)`. Cap the debt below that and the vault
repays itself out of redemption proceeds. Nothing to manipulate, nothing to
liquidate, and bad debt is arithmetically impossible rather than unlikely.

The honest cost: a purely directional holder has a worst case of zero and
borrows nothing there. That is most retail users, so `DirectionalVault` serves
them with a price feed, a 30% LTV and a liquidation engine, and pays for it with
every failure mode `LendingVault` avoids.

`CrossVault` goes further and is priced accordingly. Collateral value is the
**product** of two independent prices, so a 30% fall in each leaves 49% of the
value. LTV is 15% against a 35% threshold: a fully drawn loan survives a 57%
fall in combined value, roughly 35% on each price at once.

### The deadline is what makes the risky vaults safe at all

At resolution an outcome token jumps to 0 or 1 in a single block, and no
liquidator can act inside that move. Both price-based vaults therefore carry a
hard deadline one hour before resolution: past it, liquidation opens whatever
the health reads, and interest stops accruing. Exposure is bounded by the clock.

And when the oracle itself is dead at that moment, `absorb()` is the exit that
needs no price at all: the vault takes the position, writes the debt off, and
recovers it by redemption once the market resolves.

---

## One question, many currencies

A question resolves once. The registry is shared, and a separate core, order
book and vault exist per settlement asset.

```
                        MarketRegistry        one registry, one resolution
             /-------------+-------------\
    AlphaMarketCore   AlphaMarketCore   AlphaMarketCore   ... AMZN, PLTR
      (aUSD, 6dp)       (TSLA, 18dp)      (AMD, 18dp)
          |                  |                 |
     OrderBook          OrderBook         OrderBook    separate books, prices
     LendingVault       LendingVault      LendingVault none needs an oracle
     DirectionalVault   CrossVault -----> borrows aUSD against a TSLA position
     ParlayFactory
```

Five settlement currencies are live: aUSD, and the TSLA, AMD, AMZN and PLTR
stock tokens the official faucet hands out. NFLX is issued by that faucet too
and has no pair, because no Chainlink feed prices it.

YES-aUSD and YES-TSLA on the same question are **different tokens with
different books and different prices**, and that is correct: they are quoted in
different units, exactly as BTC/USD and BTC/EUR differ. Mixing them into one
book would make the contract insolvent.

The aUSD book is the one whose price reads as a probability. A TSLA-denominated
price moves with Tesla as well as with the event, so it is a price, not a
forecast.

---

## Richter, trading how far rather than which way

Every other market here asks which way. Richter asks how far, and throws direction
away.

A market names one equity, one closing bell, one opening bell, and a cap set for
that ticker. It issues BIG and CALM, which always sum to one unit of collateral.
Settlement measures how far the price moved between the two bells as a fraction of
the cap, so a 3% fall settles identically to a 3% rise.

| Overnight move, 5% cap | BIG | CALM |
|---|---|---|
| 0.0% | 0.00 | 1.00 |
| 2.0% | 0.40 | 0.60 |
| 3.5% | 0.70 | 0.30 |
| 6.0% or more | 1.00 | 0.00 |

The worst case is what was paid. There is no margin and no liquidation, because
every position is backed by collateral locked when it was minted.

### The caps were measured, not chosen

Every round ever published by the four live mainnet feeds was pulled and replayed
on 5 August 2026: 4,548 rounds, none missing, none errored.
`research/richter_calibration.mjs` reproduces it.

| Ticker | Daily median | p90 | Cap |
|---|---|---|---|
| AMZN | 0.75% | 2.58% | 3% |
| TSLA | 0.93% | 3.08% | 4% |
| PLTR | 1.66% | 4.28% | 5% |
| AMD | 3.64% | 6.74% | 8% |

Two assumptions died in that table. A shared cap is indefensible, because the
medians span five times over and any cap that leaves AMZN interesting leaves AMD
at the ceiling half the time, where a graded payout is a coin flip with extra
steps. And weekends turn out calmer than weeknights on three of four tickers, TSLA
by a factor of four, which is the opposite of what a 65-hour window suggests. No
company files on a Saturday.

### Settlement has no human in it

The last round published at or before the close, and the first published at or
after the open. `ChainlinkRounds` walks the history to find them.

That walk is not a subtraction. A Chainlink proxy packs a phase into the top
sixteen bits of a round id and the aggregator's own counter into the bottom
sixty-four, so arithmetic on the whole id lands in a phase that never held that
round and returns nothing rather than failing loudly. The walk decodes the id,
decrements only the counter, refuses to step below one, and takes a bounded budget
from its caller. Exhausting the budget is an error, never an approximation,
because a settlement that quietly used the wrong round is indistinguishable from
one that used the right one.

Depth was measured too: covering 24 hours takes 8 steps on AMZN and 111 on AMD. A
shared step budget would pass every test and run out of gas in production on one
ticker.

Three things make an honest settlement impossible. Chainlink can swap the
aggregator, which restarts the counter. The stock token carries a pause flag its
issuer raises during a corporate action. The sequencer can go down, during which
no round is published while the real price moves. In every one of those the market
voids at one half to each side, rather than reverting: a permanent revert would
lock the collateral and leave any loan taken against these positions unrepayable.

### It joins the collateral layer

Total payout on a hedged position is `Y*s + N*(1-s)`, linear in `s`, so its
minimum sits at an endpoint and the floor is `min(BIG, CALM)`, exactly as for a
binary market. Nothing about graded settlement disturbs it, so `LendingVault`
lends 95% against a Richter pair with no oracle and no liquidation engine, using
the same enumeration proof it already uses.

`DirectionalVault` refuses them, and that is a decision rather than an oversight.
Lending against one side alone needs an external mark, and the only one available
would be Alpha Market's own book, which can be pushed on thin liquidity, borrowed
against at a self-made price and abandoned. The refusal is structural rather than
a gate: that vault resolves tokens through `AlphaMarketCore`, and a Richter pair
is minted by `RichterCore`.

### Opened by a contract, not by a server

`RichterMarketFactory` holds the relayer role. The ticker list, the caps and the
schedule are all readable on an explorer, and a market id is `keccak256` of the
factory, the feed, the cap and the close, so anyone can recompute one and check
that a market is what it claims to be. `open` is permissionless and every
parameter comes from the on-chain ticker table, so a caller chooses nothing and
gains nothing by calling first.

### Its own book, because a book is bound to its core

`OrderBook` holds `AlphaMarketCore` as an immutable with no setter, so it can
never reach a pair minted by `RichterCore`. `RichterOrderBook` is the same book
with the same three ways to match and the same escrow rules, and one difference:
`OrderBook` asks the registry whether a market is tradeable, while a Richter
market is not resolved through the registry at all, so this one asks the core and
closes the moment a market settles.

There is one per settlement currency, for the same reason. Its 29 tests are the
ones that already guard `OrderBook`, because the arithmetic is identical: BIG
plus CALM is one unit in exactly the way YES plus NO is, which is what makes the
cold start work. A smoke test proves it on chain, from a total supply of zero.

---

## Deployed on Robinhood Chain Testnet (chainId 46630)

### aUSD, the settlement currency

| Contract | Address | Purpose |
|---|---|---|
| `MarketRegistry` | [`0x5ee116f6145158C395106AE6806b9FDa2bB94c9e`](https://explorer.testnet.chain.robinhood.com/address/0x5ee116f6145158C395106AE6806b9FDa2bB94c9e) | Mirrored markets, bonded resolution, fenced arbiter |
| `TestDollar` | [`0x7Bb22D6F8B1b1d8799B21Baa94e6829a85F9ffA5`](https://explorer.testnet.chain.robinhood.com/address/0x7Bb22D6F8B1b1d8799B21Baa94e6829a85F9ffA5) | Settlement collateral with a public faucet |
| `AlphaMarketCore` | [`0xc2E980AB433D4Ef2AA3d6139e05b4e82e81fd102`](https://explorer.testnet.chain.robinhood.com/address/0xc2E980AB433D4Ef2AA3d6139e05b4e82e81fd102) | Split / merge / redeem outcome tokens |
| `OrderBook` | [`0xe91EF60A8036F0D2d5d12E9507f92A0B7Cf12464`](https://explorer.testnet.chain.robinhood.com/address/0xe91EF60A8036F0D2d5d12E9507f92A0B7Cf12464) | On-chain limit book, four ways to match |
| `LendingVault` | [`0x030c3baf8df11802e93de203dabeb690dd6f4e1a`](https://explorer.testnet.chain.robinhood.com/address/0x030c3baf8df11802e93de203dabeb690dd6f4e1a) | Lends against a **proven** floor, funded by anyone |
| `InterestModel` | [`0x63290d3a5582c3657202487cfadabdc41e56fb9f`](https://explorer.testnet.chain.robinhood.com/address/0x63290d3a5582c3657202487cfadabdc41e56fb9f) | The rate curve, 30% ceiling |
| `InterestModel` (risk) | [`0x251f6e4e0f7a0f2ce737bf11c68001ec9683f220`](https://explorer.testnet.chain.robinhood.com/address/0x251f6e4e0f7a0f2ce737bf11c68001ec9683f220) | The steeper curve, 60% ceiling |
| `DirectionalVault` | [`0x26108683fea6956914362711818acfac1a56c718`](https://explorer.testnet.chain.robinhood.com/address/0x26108683fea6956914362711818acfac1a56c718) | Lends against one side, oracle priced |
| `ParlayFactory` | [`0xd6B758a8db803bA684B4953129d618f3a4d0D1A6`](https://explorer.testnet.chain.robinhood.com/address/0xd6B758a8db803bA684B4953129d618f3a4d0D1A6) | Boolean combinations of markets |
| `MirrorPositionOracle` | [`0x4f5a75964F128c0Cb709ea1B37C88be4E281C59e`](https://explorer.testnet.chain.robinhood.com/address/0x4f5a75964F128c0Cb709ea1B37C88be4E281C59e) | Outcome-token odds, swappable source |
| `PriceOracle` | [`0xe04062cbab194cc2ac65618ddb606d9bdeaabdcb`](https://explorer.testnet.chain.robinhood.com/address/0xe04062cbab194cc2ac65618ddb606d9bdeaabdcb) | Equity prices, relayed from mainnet Chainlink |

### TSLA

| Contract | Address |
|---|---|
| Stock token (faucet) | [`0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E`](https://explorer.testnet.chain.robinhood.com/address/0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E) |
| `AlphaMarketCore` | [`0x7f6d15b0d9052579bd38463be1cdf6af75e8e2e6`](https://explorer.testnet.chain.robinhood.com/address/0x7f6d15b0d9052579bd38463be1cdf6af75e8e2e6) |
| `OrderBook` | [`0xd7e7c86d8ba4f0aaae96bfe29415da9f2e9311c2`](https://explorer.testnet.chain.robinhood.com/address/0xd7e7c86d8ba4f0aaae96bfe29415da9f2e9311c2) |
| `LendingVault` | [`0x619ff428cf3eac697c8798bab45368a5dc40ab01`](https://explorer.testnet.chain.robinhood.com/address/0x619ff428cf3eac697c8798bab45368a5dc40ab01) |
| `CrossVault` (TSLA to aUSD) | [`0x481ad32ccee2e3762b7467933f03c1bc92326f7d`](https://explorer.testnet.chain.robinhood.com/address/0x481ad32ccee2e3762b7467933f03c1bc92326f7d) |

### AMD, AMZN and PLTR

Deployed from the same bytecode: one core, book, lending vault and cross vault
each. Every equity pair can secure an aUSD loan.

| Currency | `AlphaMarketCore` | `OrderBook` | `LendingVault` | `CrossVault` |
|---|---|---|---|---|
| AMD | `0x5d67599a6065a490e8ef1c72e61a903169c2f95c` | `0x07fcf5406c8a2a6b312cdd07d7cce144a088b75e` | `0x9d8028019729adba13a39938e6eb8fc140bdf30f` | `0x79eed4e04878c82df42a622fd84eb454677ae908` |
| AMZN | `0xd76142857f2f933eac4ed4ae384e435683b1f3c6` | `0xbbf7dd862e363c681f88a500354425c9dc1105dd` | `0xc7b70d0e672476514090356f09baaaed4e5be214` | `0xcaa23d695b2e99cde0362ddce1c993ed5215ab32` |
| PLTR | `0xf201831b2042e27b2ac036eda78d6a314080dd91` | `0xd97b7b01817600915bc80de7335333c992c62293` | `0x3d6d169bf7dfd7b41e3e6bb6ca699be7d23c31db` | `0x3f5283a1ba203b7d3fe79c4501e0cf0d1cfb852d` |

### Richter, markets on the size of a move

| Contract | Address | Purpose |
|---|---|---|
| `RichterPositionOracle` | [`0x6C8b765E21C467c182362C28e86bF1695333BD9e`](https://explorer.testnet.chain.robinhood.com/address/0x6C8b765E21C467c182362C28e86bF1695333BD9e) | Reads two Chainlink rounds, returns a fraction |
| `RichterMarketFactory` | [`0x95640a28c99587BE263E58f6a372Cb1f7C8e5e24`](https://explorer.testnet.chain.robinhood.com/address/0x95640a28c99587BE263E58f6a372Cb1f7C8e5e24) | Opens a market in every currency at once |
| `RichterCore` (aUSD) | [`0xB5b6A320572f84fDa5e01e889E3e52a59d229678`](https://explorer.testnet.chain.robinhood.com/address/0xB5b6A320572f84fDa5e01e889E3e52a59d229678) | Graded settlement, one core per currency |
| `RichterCore` (TSLA) | [`0xe3B635dCd1A8689aC55589ba0F72759F82d17e61`](https://explorer.testnet.chain.robinhood.com/address/0xe3B635dCd1A8689aC55589ba0F72759F82d17e61) | |
| `RichterCore` (AMD) | [`0xFE9B847792313C18A09427Cd55f4647da2124952`](https://explorer.testnet.chain.robinhood.com/address/0xFE9B847792313C18A09427Cd55f4647da2124952) | |
| `RichterCore` (AMZN) | [`0x946BeA18233dF4A83A8363eb83ED0b7174E091Fe`](https://explorer.testnet.chain.robinhood.com/address/0x946BeA18233dF4A83A8363eb83ED0b7174E091Fe) | |
| `RichterCore` (PLTR) | [`0xEa8C0C329719eB086910E8c8f481CDE9daa13D2F`](https://explorer.testnet.chain.robinhood.com/address/0xEa8C0C329719eB086910E8c8f481CDE9daa13D2F) | |
| `RichterOrderBook` (aUSD) | [`0x2636fa5bE45606A2c123839f4317ACEe3c0aae84`](https://explorer.testnet.chain.robinhood.com/address/0x2636fa5bE45606A2c123839f4317ACEe3c0aae84) | One book per core, bound at deployment |
| `RichterOrderBook` (TSLA) | [`0x6139Fa5C1F71913e098f1e25344b8E0E26092efb`](https://explorer.testnet.chain.robinhood.com/address/0x6139Fa5C1F71913e098f1e25344b8E0E26092efb) | |
| `RichterOrderBook` (AMD) | [`0x3E28Fefc6FA14cda772E24880209Bd837e2f4d6E`](https://explorer.testnet.chain.robinhood.com/address/0x3E28Fefc6FA14cda772E24880209Bd837e2f4d6E) | |
| `RichterOrderBook` (AMZN) | [`0x59F0aE534bC7981b111E1DadbB63e81481eEd1F4`](https://explorer.testnet.chain.robinhood.com/address/0x59F0aE534bC7981b111E1DadbB63e81481eEd1F4) | |
| `RichterOrderBook` (PLTR) | [`0x3965Ff1d6A6Db8F328680860dD856b383B568751`](https://explorer.testnet.chain.robinhood.com/address/0x3965Ff1d6A6Db8F328680860dD856b383B568751) | |

One core and one book per settlement currency, because collateral is immutable on
the core and the core is immutable on the book. A market opened by the factory
exists in all five at once.

The four `MirrorAggregator` contracts are testnet only and are listed in
`deployments/richter-46630.json`. Mainnet 4663 has real Chainlink equity feeds, so
no mirror is deployed there and the deploy script refuses to.

Adding a currency needed no contract change at all: the same bytecode, a
different collateral address, and the relayer picks it up from a deployment file
on its next cycle.

All source-verified on Blockscout.

> On mainnet `TestDollar` is not deployed. `COLLATERAL` is set to the real USDG
> address issued by Paxos and no contract changes.

---

## Roles, deliberately separated

| Role | Address | Can | Cannot |
|---|---|---|---|
| Owner | `0xB162c126512B13eB947B5E4AB1b936607DC32427` | Parameters, funding, unpause | **Rule on disputes** |
| Arbiter | `0x9D9e5e12a2b81BE250FdB50Fd80afF52C6379899` | Rule on disputes | **Touch funds** |
| Relayer | `0xAca9c51F0015e57f2070a2D068e9E0442CB94577` | Mirror, halt, propose, write prices | Everything above |
| Guardian | `0x35bEFA8b5f72D4B9F4cA3E7A227f82B8F26BED44` | **Pause** | Unpause, funds, disputes |

### The arbiter is the most dangerous role, and it is fenced four ways

A disputed market must be decided by somebody, and a decentralised escalation
layer needs its own token, staking and slashing. Until that exists there is a
human arbiter, confined:

1. **Separate address.** Draining the protocol needs two compromised keys.
2. **Announced, not applied.** `proposeRuling` records a decision;
   `executeRuling` applies it only after 24 hours, so every ruling is public
   before it binds and can be checked against the upstream source.
3. **Execution is permissionless.** Anyone may execute an announced ruling, so
   the arbiter cannot quietly sit on a decision it already made.
4. **Silence expires.** If nothing executes within 7 days, anyone may call
   `resolveByTimeout` and settle the market Invalid at 0.5 per side.

And the strongest protection needs no arbiter at all: **`Disputed` is not
`Resolved`**, so `merge` stays open right through a dispute. One YES plus one NO
always exits for exactly one unit whatever is eventually decided. Verified on
chain by `script/smoke_dispute.sh`.

**What remains:** a directional holder in a disputed market still depends on the
arbiter ruling honestly. That cannot be removed without a real escalation layer.

### Emergency pause

Entry stops, exit never does. `split`, `placeOrder`, `pledge` and `borrow` can
be halted; `merge`, `redeem`, `cancelOrder`, `repay`, `unpledge` and `settle`
cannot. A pause that traps user funds turns one bug into a hostage situation, so
the split is fixed in code rather than left to judgement at the worst moment.

A guardian may pause but not unpause. Pausing is the safe direction, so it is
delegated; resuming asserts the danger has passed and stays with the owner.

---

## The order book

Four ways two resting orders can clear, not one:

| | Match | Result |
|---|---|---|
| `matchMint` | buy YES 0.60 + buy NO 0.45 | both bring cash, a fresh pair is minted |
| `matchMerge` | sell YES 0.55 + sell NO 0.40 | both bring tokens, burned back to cash |
| `matchCross` | buy YES 0.60 + sell YES 0.55 | ordinary bid against ask |
| `fill` | a taker against one resting order | cash against token |

**`matchMint` is what lets a brand new market trade from nothing.** Nobody holds
tokens in a fresh market, so nobody can sell, so nobody can buy. Two buyers who
between them cover one whole unit break that deadlock, and the surplus between
their limits pays whoever matched them. Verified on chain by
`script/smoke_orderbook.sh`, starting from `totalSupply() == 0`.

Every order is **fully funded when placed**: a buy escrows collateral, a sell
escrows tokens. An order that cannot be honoured is a lie told to everyone
reading the book.

Rounding always favours the contract. Escrow rounds up, payouts round down.

**What a public book costs, stated plainly:** a stale quote is visible to
everyone, so fast participants pick off slow ones. Expiries and cheap
cancellation limit that; they do not remove it. Robinhood Chain runs an Arbitrum
sequencer with no public mempool, so the classic mempool sandwich does not
apply, but a latency race still does.

---

## The relayer

Node 22, ethers v6, systemd service, HTTP on `:8420`.

Each cycle, in this order:

1. **Equity prices** relayed from Chainlink on mainnet 4663
2. **Outcome-token odds** from Polymarket, with a per-update move cap
3. **Track mirrored markets**: halt on upstream resolution, propose bonded
   outcomes, **dispute proposals that contradict the source**, finalize
4. **Resolve parlays** whose legs are all final
5. **Match the book**, in every settlement currency
6. **Discover new markets**

Chain reads and API calls run with bounded concurrency; **writes stay
sequential** because they share one nonce.

**Dry-run is the default.** Every write goes through one `send()` that refuses
to broadcast without `--live`, so the guarantee holds in exactly one place.

```bash
node src/index.js            # one dry-run cycle
node src/index.js --live     # broadcast, loop
npm test                     # 13 unit tests
```

### HTTP endpoints

| Endpoint | Purpose |
|---|---|
| `/config` | Every contract address, live. **The authoritative source.** |
| `/markets` | Every mirrored market and its status |
| `/book` | Open orders, best bid and ask, per settlement currency, plus the question, image, category and event grouping |
| `/rules` | The resolution rules for one market, fetched from upstream on demand |
| `/richter` | Every Richter market, its window and cap, its settlement fraction, and its book |

`/rules` is fetched rather than stored. Descriptions run to a thousand
characters at the median and three thousand at the top, so keeping one on every
market would roughly double a state file that is rewritten every cycle, to serve
text that is only read when a single market is opened.

`/book` also carries `eventId` and `eventTitle`, which group markets that are
one question with different answers: nine candidates for a nomination, six
strike prices on the same day. An interface can then show them as one card with
rows instead of nine cards repeating a sentence.

`/book` is served from a background refresh rather than read on demand. The
public RPC rate limits, and a full sweep across five currencies took seventy-two
seconds and returned 429s when parallelised harder. One refresh now runs at a
pace the RPC tolerates and every request is answered from what it last produced,
in about fifteen milliseconds. The response carries `builtMsAgo`, so a caller
can see how far behind the head it is. Nothing that decides a transaction is
read from it: a wallet reads balances and orders from chain directly.

`/richter` is separate from `/book` rather than folded into it. That list is built
from Polymarket metadata and drops anything without a question, which every
Richter market is, and it reads the mirrored book, which cannot see a Richter
pair. The market list here comes from `MarketOpened` instead, because the factory
keeps a mapping and no array, so the log is the index. Like `/book`, it is served
from a background refresh and carries `builtMsAgo`.

`/config` exists because addresses change whenever a contract with an immutable
dependency is replaced, and a stale address fails **silently**: a call to a dead
registry simply returns nothing. Anything written down, including this file,
should be checked against it.

### The relayer never takes a position

`fill` is deliberately not used by the matcher. Filling requires the taker to
deliver the counter-asset, which would leave the relayer holding an outcome
token and therefore a directional bet. `matchMint`, `matchMerge` and
`matchCross` move value between two makers without the matcher ever holding
anything, and the surplus between the two limits pays the gas.

---

## Prices

**Outcome odds** are mirrored from Polymarket by the relayer. Only the YES side
is stored; NO is derived as `1 - YES`, so the two can never disagree. A
per-update move cap stops one bad write from zeroing every position at once; a
real gap still arrives, it just takes several cycles.

**Equity prices** come from Chainlink feeds on Robinhood Chain **mainnet**,
because testnet 46630 has none. Verified 2026-08-02: `oraclePaused()` answers on
the mainnet stock token and reverts on the testnet one, and no aggregator on
46630 answers the AggregatorV3 interface.

| Feed | Mainnet aggregator |
|---|---|
| RHTSLA / USD | `0x4A1166a659A55625345e9515b32adECea5547C38` |
| RHAMD / USD | `0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72` |
| RHAMZN / USD | `0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C` |
| RHPLTR / USD | `0x820ABedFF239034956B7A9d2F0a331f9F075eB4c` |

The feed quotes the price of one **token**, already multiplied by the token's
`uiMultiplier()`, so stock splits are handled upstream and must not be applied
again.

NFLX is issued by the faucet but has no Robinhood feed, so it has no price and
no equity-backed lending. Push mode is left disabled for it, and the contract
refuses a price nobody can source.

**Staleness is measured in days, not hours.** Equity feeds publish 24/5 and stop
at the weekend. Measured on a Sunday, every feed was about 1.6 days old against
a 24 hour heartbeat, which is normal rather than broken. A one hour freshness
rule would freeze the system from Friday close to Monday open.

---

## Live parameters

Read from chain, not from memory.

| | |
|---|---|
| Resolution bond | 100 aUSD |
| Challenge window | 120s (testnet UX; deploy default 7200) |
| Ruling delay | 24 hours |
| Dispute timeout | 7 days |
| Minimum source depth | 0, gate removed |
| aUSD faucet | 1,000 per claim, 24 hour cooldown, 100M cap |
| Order book fee | 20 bps, capped at 200 in code |
| LendingVault haircut | 5% below the proven floor |
| LendingVault reserve | 10% of interest, held against loss |
| Rate curve, hedged | 2% idle, 15% at the 80% kink, 30% at full |
| Rate curve, risk | 3% idle, 12% at the 80% kink, 60% at full |
| Rate ceilings | 30% hedged, 60% directional and cross. Immutable per vault |
| DirectionalVault | 30% LTV, 50% liquidation, 8% bonus |
| CrossVault | 15% LTV, 35% liquidation, 10% bonus |
| Deadline buffer | 1 hour before resolution, both vaults |
| Debt cap per market | 10,000 aUSD |
| Equity price max age | 3 days, spanning a weekend |
| Position odds max age | 1 hour |
| Position move cap | 20% per update |

---

## Testing

```bash
cd contracts
forge test                                    # 332 tests
FOUNDRY_PROFILE=deep forge test --match-test testFuzz   # 23 invariants, 50k runs

cd ../relayer && npm test                     # 13 tests
```

| Suite | Tests | Covers |
|---|---|---|
| `AlphaMarket.t.sol` | 27 | Core, registry, the fenced arbiter |
| `OrderBook.t.sol` | 29 | Placement, all four match kinds, solvency |
| `DirectionalVault.t.sol` | 26 | One-sided lending, deadline, absorb |
| `LendingVault.t.sol` | 17 | The proven floor, supply shares, the moving rate |
| `InterestModel.t.sol` | 16 | The rate curve and its bounds |
| `MarginVault.t.sol` | 17 | The vault LendingVault replaced |
| `CrossVault.t.sol` | 17 | Two-price collateral, cross-asset lending |
| `ParlayFactory.t.sol` | 14 | Boolean combinations |
| `Pause.t.sol` | 14 | Entry stops, **exit never does** |
| `Reentrancy.t.sol` | 11 | A genuinely hostile token attacking every entry |
| `TestDollar.t.sol` | 11 | Faucet limits and the supply cap |
| `CrossContract.t.sol` | 5 | Six mint/burn paths against one core at once |
| `RevertAtomicity.t.sol` | 2 | A failed redeem must not burn the token |
| `ChainlinkRounds.t.sol` | 16 | Locating a round by timestamp, replayed from real history |
| `ChainlinkRoundsFork.t.sol` | 10 | The same walk against the live mainnet aggregators |
| `RichterOracle.t.sol` | 24 | Graded settlement, every void path, the factory rules |
| `RichterCore.t.sol` | 21 | The pair invariant and solvency at every fraction |
| `MirrorAggregator.t.sol` | 14 | The testnet feed, walked by the same library |
| `RichterMultiCurrency.t.sol` | 7 | One market, five currencies, two decimal widths |
| `RichterOrderBook.t.sol` | 29 | The same book against a core that settles to a fraction |
| `RichterVaultSeparation.t.sol` | 5 | `DirectionalVault` cannot lend against Richter |

Three of those suites exist because they found real bugs:

- **`CrossContract.t.sol`** runs every contract against one core simultaneously.
  Individually correct contracts can still be wrong together.
- **`Reentrancy.t.sol`** uses a token that calls back mid-transfer. Two of its
  tests prove the attack itself fires, so the other nine are not vacuous.
- **`CrossVault.t.sol`** caught a division by zero that would have made
  liquidation revert every time: pricing one base unit of an 18-decimal
  collateral in 6-decimal debt floors to zero.

### End-to-end, against deployed contracts

```bash
./script/smoke_journey.sh      # claim, order, match, resolve, redeem, exit while paused
./script/smoke_orderbook.sh    # cold start from zero tokens
./script/smoke_dispute.sh      # ruling delay, timeout, merge during a dispute
./script/smoke_directional.sh  # one-sided pledge, liquidation, repay
./script/smoke_vault.sh        # the proven floor
./script/smoke_parlay.sh       # combinations
./script/smoke_testnet.sh      # the core cycle
./script/smoke_richter.sh      # graded settlement in two decimal widths
```

Each asserts its final state and exits non-zero on failure.

### Against the live Chainlink feeds, no gas

```bash
FOUNDRY_PROFILE=fork forge test --match-contract ChainlinkRoundsFork -vv
```

Ten tests read the real equity aggregators on mainnet 4663 over a fork. They are
excluded from the default run because a full pass takes over two minutes.

The `fork` profile exists because those aggregators were compiled for Shanghai and
use `PUSH0`, 341 occurrences in the TSLA aggregator with the first at offset 12.
Under `paris`, revm reports `NotActivated`, burns the whole gas limit, and every
test fails with a bare `Revert`. The profile sets `evm_version = "shanghai"` and
writes to `out-fork`, so the default profile and every deployed contract keep
their `paris` bytecode.

The suite gates on `FOUNDRY_PROFILE` and skips under any other profile. It cannot
gate on `block.prevrandao`: that is still zero when `setUp` begins, before
`createSelectFork` replaces the environment, so every test would skip silently. A
skipped test costs about 5,600 gas and finishes in under a millisecond, a real one
costs tens of thousands and takes minutes. Check the gas number before believing a
pass.

---

## Design notes

Work that needs more than a section here lives in `docs/`, so this file stays a
description of what runs today.

- [`docs/richter-markets.md`](docs/richter-markets.md) — the design behind Richter:
  the calibration study, the round-walking rules, every void path, and the
  reasoning behind decisions this file only states.

---

## Layout

```
contracts/
  src/            19 contracts + 3 interfaces, 1 testing-only
  test/           21 suites, 332 tests
  script/         9 deploy scripts
  deployments/    the addresses that matter, per chain and per pair
relayer/
  src/            config, chain, polymarket, equity, positions, richter,
                  richterApi, matcher, pairs, api, relayer, index
  test/           13 unit tests over the pure logic
script/           8 end-to-end smoke tests
research/         Stage 1 measurement, and the Richter calibration study
```

The web interface lives in its own repository and is deployed separately.

## Build and deploy

```bash
cd contracts && forge build && forge test

cp .env.example .env
# DEPLOYER_PRIVATE_KEY, RELAYER_PRIVATE_KEY, ARBITER_PRIVATE_KEY,
# GUARDIAN_PRIVATE_KEY. The arbiter must not be the deployer.

forge script script/DeployTestDollar.s.sol:DeployTestDollar --rpc-url $RH_TESTNET_RPC --broadcast
forge script script/Deploy.s.sol:Deploy                     --rpc-url $RH_TESTNET_RPC --broadcast
forge script script/DeployVault.s.sol:DeployVault           --rpc-url $RH_TESTNET_RPC --broadcast
forge script script/DeployParlay.s.sol:DeployParlay         --rpc-url $RH_TESTNET_RPC --broadcast
forge script script/DeployDirectional.s.sol:DeployDirectional --rpc-url $RH_TESTNET_RPC --broadcast
forge script script/DeployOrderBook.s.sol:DeployOrderBook   --rpc-url $RH_TESTNET_RPC --broadcast
```

**A second settlement currency** is deployed with `cast` rather than `forge
script`. Robinhood stock tokens are beacon proxies, and `AlphaMarketCore` reads
`decimals()` from its collateral in the constructor; a local simulator cannot
execute proxy to beacon to implementation, so the script reverts with
`NotActivated` before broadcasting anything. Deploying directly skips simulation
and the call succeeds on chain.

If a deploy fails with a block-number race, retry. Blocks arrive at roughly 13
per second and local simulation can run ahead of a non-archive RPC.

---

## Known limitations

Deliberate for a testnet milestone. **None may reach mainnet as-is.**

- **`TestDollar` is not USDG.** USDG is issued by Paxos and is not on testnet
  46630: verified from the faucet transfer history, which sends ETH and five
  stock tokens and no stablecoin. Named so nobody can mistake it.
- **The arbiter is a single party.** Fenced four ways, but a directional holder
  in a disputed market depends on it.
- **The L2 sequencer uptime feed is not checked.** Robinhood documents one, its
  address is not in the Chainlink feed directory for this chain, and it has not
  been located. During a sequencer outage a price could be stale beyond what
  `updatedAt` reveals.
- **Outcome odds come from Polymarket through a single writer.** The interface
  is swappable; once the book has real volume the source should be the book.
- **`DirectionalVault` and `CrossVault` can accrue bad debt.** Both have passing
  tests proving it. `LendingVault` cannot.
- **The relayer is a single point of failure** for halting, disputing and price
  freshness. Outcome proposal is already permissionless and bonded.
- **The owner is an EOA, not a multisig.**
- **Market questions and categories come from Polymarket** and are relayed
  through a single service. A market whose upstream record disappears keeps the
  text it last had.
- **Richter settles against a mirror on testnet.** Chain 46630 has no equity
  feeds, so its Richter markets read `MirrorAggregator` contracts filled with real
  mainnet prices by the relayer. Enough to exercise every path including the void
  ones, which a live feed will not perform on demand, but not the production
  shape. Mainnet 4663 reads Chainlink directly and the deploy script refuses to
  deploy a mirror there.
- **The Richter caps rest on five weeks of data.** 26 daily windows per ticker,
  and no earnings window at all, so the event tier has no cap and must not open
  until one full earnings season is on chain. Recompute monthly with
  `research/richter_calibration.mjs` until the sample reaches a few hundred.
- **No external audit.**

## Build order

1. ~~Stage 1 measurement~~
2. ~~Mirror and bonded resolution~~
3. ~~Outcome tokens~~
4. ~~Margin against a proven floor~~
5. ~~Liquidation~~ — **dropped for `MarginVault`.** The proven-floor design makes
   it unnecessary. It reappears only where collateral genuinely has no floor.
6. ~~Combination tokens~~
7. ~~On-chain order book~~
8. ~~Multi-currency settlement~~
9. ~~Cross-collateral lending~~
10. ~~Web interface~~
11. ~~Richter, markets on the size of a move~~ — deployed to testnet 46630 on
    6 August 2026. Mainnet needs an earnings season measured first.
12. Decentralised dispute escalation

## License

MIT
