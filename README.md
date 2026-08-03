# Alpha Market

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

**Status:** live and source-verified on testnet 46630. 173 contract tests, 13
relayer tests, 13 fuzzed invariants at 50,000 runs each, and 7 end-to-end smoke
scripts that run against the deployed contracts rather than a local simulator.

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
curl -s http://<relayer-host>:8420/book | jq '.markets[0]'

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

| | `MarginVault` | `DirectionalVault` | `CrossVault` |
|---|---|---|---|
| Pledge | 1,000 YES **and** 1,000 NO | 1,000 YES **only** | 1,000 YES-TSLA |
| Debt asset | same as the pledge | same as the pledge | **a different asset** |
| Worst case | `min(Y, N)` = 1,000 | 0, YES can lose | 0, and two prices move |
| How that is known | **proven by enumeration** | one price | two prices multiplied |
| Price oracle | **none** | required | two required |
| Liquidation | **never** | yes | yes |
| Max LTV | 95% | 30% | 15% |
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
every failure mode `MarginVault` avoids.

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
                    MarketRegistry          one registry, one resolution
                   /              \
        AlphaMarketCore        AlphaMarketCore
          (aUSD, 6dp)            (TSLA, 18dp)
             |                       |
        OrderBook               OrderBook       separate books, separate prices
        MarginVault             MarginVault     both need no oracle
        DirectionalVault        CrossVault ---> borrows aUSD against TSLA
        ParlayFactory
```

YES-aUSD and YES-TSLA on the same question are **different tokens with
different books and different prices**, and that is correct: they are quoted in
different units, exactly as BTC/USD and BTC/EUR differ. Mixing them into one
book would make the contract insolvent.

The aUSD book is the one whose price reads as a probability. A TSLA-denominated
price moves with Tesla as well as with the event, so it is a price, not a
forecast.

---

## Deployed on Robinhood Chain Testnet (chainId 46630)

### aUSD, the settlement currency

| Contract | Address | Purpose |
|---|---|---|
| `MarketRegistry` | [`0x5ee116f6145158C395106AE6806b9FDa2bB94c9e`](https://explorer.testnet.chain.robinhood.com/address/0x5ee116f6145158C395106AE6806b9FDa2bB94c9e) | Mirrored markets, bonded resolution, fenced arbiter |
| `TestDollar` | [`0x7Bb22D6F8B1b1d8799B21Baa94e6829a85F9ffA5`](https://explorer.testnet.chain.robinhood.com/address/0x7Bb22D6F8B1b1d8799B21Baa94e6829a85F9ffA5) | Settlement collateral with a public faucet |
| `AlphaMarketCore` | [`0xc2E980AB433D4Ef2AA3d6139e05b4e82e81fd102`](https://explorer.testnet.chain.robinhood.com/address/0xc2E980AB433D4Ef2AA3d6139e05b4e82e81fd102) | Split / merge / redeem outcome tokens |
| `OrderBook` | [`0xe91EF60A8036F0D2d5d12E9507f92A0B7Cf12464`](https://explorer.testnet.chain.robinhood.com/address/0xe91EF60A8036F0D2d5d12E9507f92A0B7Cf12464) | On-chain limit book, four ways to match |
| `MarginVault` | [`0xD86A54c64e49c4158B20aa26D08fd4732B0A1c56`](https://explorer.testnet.chain.robinhood.com/address/0xD86A54c64e49c4158B20aa26D08fd4732B0A1c56) | Lends against a **proven** floor |
| `DirectionalVault` | [`0xEF86596Ffe80C33839BFd6541Ea41DFe76719015`](https://explorer.testnet.chain.robinhood.com/address/0xEF86596Ffe80C33839BFd6541Ea41DFe76719015) | Lends against one side, oracle priced |
| `ParlayFactory` | [`0xd6B758a8db803bA684B4953129d618f3a4d0D1A6`](https://explorer.testnet.chain.robinhood.com/address/0xd6B758a8db803bA684B4953129d618f3a4d0D1A6) | Boolean combinations of markets |
| `MirrorPositionOracle` | [`0x4f5a75964F128c0Cb709ea1B37C88be4E281C59e`](https://explorer.testnet.chain.robinhood.com/address/0x4f5a75964F128c0Cb709ea1B37C88be4E281C59e) | Outcome-token odds, swappable source |
| `PriceOracle` | [`0xe04062cbab194cc2ac65618ddb606d9bdeaabdcb`](https://explorer.testnet.chain.robinhood.com/address/0xe04062cbab194cc2ac65618ddb606d9bdeaabdcb) | Equity prices, relayed from mainnet Chainlink |

### TSLA, a second settlement currency

| Contract | Address |
|---|---|
| Stock token (faucet) | [`0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E`](https://explorer.testnet.chain.robinhood.com/address/0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E) |
| `AlphaMarketCore` | [`0x7f6d15b0d9052579bd38463be1cdf6af75e8e2e6`](https://explorer.testnet.chain.robinhood.com/address/0x7f6d15b0d9052579bd38463be1cdf6af75e8e2e6) |
| `OrderBook` | [`0xd7e7c86d8ba4f0aaae96bfe29415da9f2e9311c2`](https://explorer.testnet.chain.robinhood.com/address/0xd7e7c86d8ba4f0aaae96bfe29415da9f2e9311c2) |
| `MarginVault` | [`0xa1a2c9d7048fc1c745d726477d42d02985ce28aa`](https://explorer.testnet.chain.robinhood.com/address/0xa1a2c9d7048fc1c745d726477d42d02985ce28aa) |
| `CrossVault` (TSLA to aUSD) | [`0xfeb16fbc3578828ac65f788b2c3cca1f43a9e1e9`](https://explorer.testnet.chain.robinhood.com/address/0xfeb16fbc3578828ac65f788b2c3cca1f43a9e1e9) |

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
| `/book` | Open orders, best bid and ask, per settlement currency |

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
| aUSD faucet | 10,000 per claim, 12 hour cooldown, 100M cap |
| Order book fee | 20 bps, capped at 200 in code |
| MarginVault haircut | 5% below the proven floor |
| MarginVault rate | 15% APR, stops at market end |
| DirectionalVault | 30% LTV, 50% liquidation, 8% bonus |
| CrossVault | 15% LTV, 35% liquidation, 10% bonus |
| Deadline buffer | 1 hour before resolution, both vaults |
| Debt cap per market | 5,000 aUSD |
| Equity price max age | 3 days, spanning a weekend |
| Position odds max age | 1 hour |
| Position move cap | 20% per update |

---

## Testing

```bash
cd contracts
forge test                                    # 173 tests
FOUNDRY_PROFILE=deep forge test --match-test testFuzz   # 13 invariants, 50k runs

cd ../relayer && npm test                     # 13 tests
```

| Suite | Tests | Covers |
|---|---|---|
| `AlphaMarket.t.sol` | 27 | Core, registry, the fenced arbiter |
| `OrderBook.t.sol` | 29 | Placement, all four match kinds, solvency |
| `DirectionalVault.t.sol` | 26 | One-sided lending, deadline, absorb |
| `MarginVault.t.sol` | 17 | The proven floor, settlement |
| `CrossVault.t.sol` | 17 | Two-price collateral, cross-asset lending |
| `ParlayFactory.t.sol` | 14 | Boolean combinations |
| `Pause.t.sol` | 14 | Entry stops, **exit never does** |
| `Reentrancy.t.sol` | 11 | A genuinely hostile token attacking every entry |
| `TestDollar.t.sol` | 11 | Faucet limits and the supply cap |
| `CrossContract.t.sol` | 5 | Six mint/burn paths against one core at once |
| `RevertAtomicity.t.sol` | 2 | A failed redeem must not burn the token |

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
```

Each asserts its final state and exits non-zero on failure.

---

## Layout

```
contracts/
  src/            12 contracts + 2 interfaces
  test/           11 suites, 173 tests
  script/         7 deploy scripts
  deployments/    the addresses that matter, per chain and per pair
relayer/
  src/            config, chain, polymarket, equity, positions, matcher,
                  pairs, api, relayer, index
  test/           13 unit tests over the pure logic
script/           7 end-to-end smoke tests
research/         Stage 1 measurement against public Polymarket APIs
```

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
  tests proving it. `MarginVault` cannot.
- **The relayer is a single point of failure** for halting, disputing and price
  freshness. Outcome proposal is already permissionless and bonded.
- **The owner is an EOA, not a multisig.**
- **No frontend.** Everything is `cast` and the read API.
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
10. Frontend
11. Decentralised dispute escalation

## License

MIT
