# Valari contracts

`ValariRouterV3` opens Uniswap v4 USDG/stock liquidity positions on Robinhood
Chain (4663). The user supplies both token budgets, a tick range and price
bounds; the router holds the resulting LP NFT and records that user as its
beneficiary. Unused deposit tokens are refunded. On fee collection or full
exit, Valari receives **10% of newly realized LP fees** as an accrued credit,
and the user receives the remaining fees plus any withdrawn principal.
Principal and deposits carry no Valari commission.

## Live Robinhood deployment

- Router: [`0x4Fe8ccbc4Ac98D68b69DbF9c2fbc13F8BdCA915d`](https://robinhoodchain.blockscout.com/address/0x4Fe8ccbc4Ac98D68b69DbF9c2fbc13F8BdCA915d).
- Chain ID: **4663**; deployed 6 Oct 2026 at block **81,799,944**.
- Creation transaction: [`0xf1e6c17bea18d2572b34344f8c61cc8060987e9f791c1c5c97dc25e591611dbe`](https://robinhoodchain.blockscout.com/tx/0xf1e6c17bea18d2572b34344f8c61cc8060987e9f791c1c5c97dc25e591611dbe).
- Pools: the 16 the Valari frontend lists (META, SPY, MSTR, SPCX, NVDA, GOOGL,
  TSLA, AAPL, COIN, PLTR, INTC, AMD, MSFT, LLY, LMT, USO), from
  `config/robinhood-curated.json`.
- Owner and treasury recipient: `0x09D08d66dF2ebE0DB3D589Ac528Fd589E064C5A2`.
- Deployment cost: about **0.000132 ETH**, using 6,537,356 gas.
- Metadata: [`deployments/robinhood-mainnet-v3.json`](deployments/robinhood-mainnet-v3.json).

The deployed bytecode comes from the pinned Foundry artifact. No private key or
signed transaction is stored in the deployment record.

Explorer source verification is not yet complete: Blockscout's API returned a
Cloudflare challenge before accepting the submission. The exact compiler input
and constructor arguments are saved as `deployments/blockscout-*-v3.*` for
submission when the explorer API is available.

Position history is served by the
[Valari Goldsky subgraph](https://api.goldsky.com/api/public/project_cmh0hrj4k006pw2p2110k5nsz/subgraphs/valari/1.0.0/gn).
See [`../valari-subgraph/README.md`](../valari-subgraph/README.md) for queries,
historical synchronization, and RPC reads for pending fees.

```sh
cd valari/valari-contracts
forge build --offline
forge fmt --check
forge test --offline
```

- `src/ValariRouterV3.sol`: deposits, NFT custody, collection, exits, eject, commission and getters.
- `abi/ValariRouterV3.json`: frontend ABI, exported from the compiled contract.
- `config/robinhood-curated.json`: the 16 deployed pools, written by `tools/curated-catalog.mjs`.
- `config/robinhood.json`: the full 100-pool verified catalog the curated list is drawn from.
- `script/DeployValariRouterV3.s.sol`: deployment script with chain and catalog checks.
- `script/AddValariRouterV3Pools.s.sol`: appends catalog pools the router does not list yet.
- `test/ValariRouterV3.t.sol`: integration tests using real v4 core/periphery and Permit2.
- `test/ValariRouterV3AccountingAudit.t.sol`: randomized commission-accounting property.
- `test/ValariRouterV3Fork.t.sol`: opt-in tests against deployed Robinhood contracts.
- `test/fizz/`: Echidna/Medusa fuzzing harness; properties in [PROPERTIES.md](PROPERTIES.md).
- `audit/`: tool runs and reports (Slither, Manticore, Echidna, Medusa, Foundry).
- `lib/`: pinned upstream dependencies, described in [DEPENDENCIES.md](DEPENDENCIES.md).

Solidity is pinned to 0.8.26 with Cancun, the optimizer (200 runs), and via-IR,
matching the existing contract projects. Dependencies are vendored. If the
compiler is not installed, run `forge build` once without `--offline`.

## Deposit API

```solidity
openPosition(
    bytes32 poolId,
    uint128 amount0Max,
    uint128 amount1Max,
    int24 tickLower,
    int24 tickUpper,
    uint128 minLiquidity,
    uint160 sqrtPriceMinX96,
    uint160 sqrtPriceMaxX96,
    uint256 deadline
) returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
```

Amounts use the pool's currency0/currency1 order and raw token units. USDG has
6 decimals and the catalog stocks have 18; USDG can be either currency. Use
`getPoolKey(poolId)` to identify the order. Ranges are Uniswap ticks, not price
percentages: lower is inclusive, upper exclusive, and both must be multiples
of the pool's tick spacing. One-sided deposits work when price is outside the range.

Frontend sequence:

1. Read `getPoolKey` and choose aligned ticks using the live pool price.
2. Call `previewDeposit(poolId, amount0Max, amount1Max, tickLower, tickUpper)`.
   It returns liquidity, rounded-up required token amounts, and `sqrtPriceX96`.
3. Apply the user's slippage tolerance to that quoted liquidity to obtain a
   **nonzero** `minLiquidity`, derive `sqrtPriceMinX96`/`sqrtPriceMaxX96` from a
   reference price and the user's tolerance, and choose a short deadline. A
   fresh on-chain quote must precede submission; the historical backtest is not
   a mint quote.
4. Approve each funded ERC20 to **the router address**, then call
   `openPosition`. Existing adequate allowances can be reused.
5. Obtain `tokenId` and actual deposited amounts from the `PositionOpened`
   receipt event. Call `getPosition(tokenId)` for the live view.

**Price bounds.** `openPosition` reverts with `PriceOutOfBounds` when the pool
price is outside `[sqrtPriceMinX96, sqrtPriceMaxX96]`. `minLiquidity` alone does
not bound the execution price when a budget has slack. The minimum must be
nonzero and not above the maximum (`InvalidPriceBounds`). `previewDeposit`
returns the pool's own `sqrtPriceX96`, which is a sound reference only for a
deep pool: a thin fee tier can already sit off-market, so compare it with the
stock's deepest listed tier (or an external price) before centring the bounds
on it. The pool price is read again immediately before the mint and must equal
the quoted one, so a token whose transfer or approval moves the pool cannot
slip a deposit past the bounds.

The router uses explicit `MINT_POSITION` plus `SETTLE_PAIR`. The maximum token
budgets, minimum liquidity and price bounds constrain execution; stale
deadlines, unsupported pools, invalid ranges and inadequate liquidity revert
atomically. Permit2 and ERC20 approvals made by the router are limited to the
current budgets and reset to zero after settlement. Preexisting router token
balances are isolated from the deposit and refund. Fee-on-transfer/rebasing
tokens are unsupported.

## Collection, exit and commission

```solidity
collectFees(uint256 tokenId, uint256 deadline) returns (Payout memory)
collectFeesTo(uint256 tokenId, address to, uint256 deadline) returns (Payout memory)

exitPosition(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, uint256 deadline)
    returns (Payout memory)
exitPositionTo(uint256 tokenId, address to, uint128 amount0Min, uint128 amount1Min, uint256 deadline)
    returns (Payout memory)

ejectPosition(uint256 tokenId, address to)      // only where the owner enabled it
```

Only the user who opened the position can call these. Collection leaves
liquidity invested. Exit removes all liquidity and burns the NFT. The exit
minimums protect **principal amounts only**, excluding accrued fees; the user
chooses them from the live position view and their slippage tolerance.

The `…To` variants pay a destination the beneficiary chooses, for a
beneficiary who cannot receive one of the tokens at their own address. `to`
may not be zero, the router, the PositionManager, the PoolManager or Permit2
(`InvalidRecipient`). `FeesCollected` and `PositionExited` carry the
destination as a final `to` field.

`Payout` returns `principal0/1`, newly realized gross `fees0/1`, Valari's
`commission0/1`, and the total net user payment `amount0/1`. Commission is retained
in each earned token without swapping or USD valuation. For example, 100 USDG
of LP fees produces 10 USDG of treasury credit and 90 USDG for the user; exiting also
returns all withdrawn principal.

Collection uses `DECREASE_LIQUIDITY(0)` and `TAKE_PAIR` to realize fees into
the router. Exit uses `BURN_POSITION` and `TAKE_PAIR`; the router subtracts
the rounded-down principal from actual received tokens to identify fees.
This separation relies on the hookless catalog. Slippage failures and
unexpected receipts revert the entire operation.

**Rounding dust.** Payouts tolerate up to `MAX_PAYOUT_DUST` (2 raw units) on
each side: the pool may deliver that much less than the exact principal (the
exit pays out what arrived and reports it as the principal), and the payout
may leave that much behind in the router. A token that rounds does not block
collection, exit or commission withdrawal. Anything larger reverts
(`InsufficientProceeds` inbound, `UnsupportedToken` outbound) and leaves the
position open. The tolerance cannot tell rounding from an unmade transfer of
1–2 raw units of principal, so that much per token per payout is the most a
misbehaving token can cost a caller on principal; LP fees are only ever
measured as what arrives above the principal, so a token withholding fees is
not detectable. What reaches the recipient can be up to 2 units below the exit
minimums on each transfer hop.

**Eject.** If an issuer restricts the router's address, no payout can pass
through it. The owner can then call `setEjectEnabled(poolId, true)`, after
which each depositor in that pool can call `ejectPosition(tokenId, to)`: the LP
NFT moves to `to`, and the position is the holder's to manage on Uniswap
directly. The router records it as closed (`getPosition` then shows `closed`
with `nftOwner` set to the holder) and charges nothing on it afterwards.
Before moving the NFT, eject attempts an ordinary fee collection so that the
commission on fees realized so far is charged and the net fees go to `to`; if
that collection cannot complete (the router cannot receive one of the tokens),
the fees travel with the NFT instead. Eject is off by default; enabling it
gives the owner no access to any position.

The fixed rate is `COMMISSION_BPS = 1000` out of 10,000. Fractional commission
is carried across collections separately for each position and token, including
the final exit. Total commission equals the integer floor of cumulative fees
divided by 10. Repeated small collections cannot avoid commission through
rounding. A final fraction smaller than one raw token unit rounds down.

Treasury commission is withdrawn separately:

```solidity
claimableCommission(address recipient, address token) returns (uint256)
totalClaimableCommission(address token) returns (uint256)
withdrawCommission(address token, address to, uint256 amount)
```

Each recipient owns its accrued token credits. It calls `withdrawCommission`
with a positive amount up to its available credit, choosing itself or another
valid destination. The owner cannot withdraw another recipient's credit.
Changing `feeRecipient` affects future accrual only; old recipients retain the
right to withdraw their existing credits. Withdrawals are solvency-checked per
withdrawal: if tokens ever leave the router out of band (an issuer action),
what remains stays withdrawable instead of every recipient's credit in that
token freezing.

User collection and exit do not send any tokens to the treasury. A token that
blocks the treasury therefore cannot prevent otherwise valid user payouts.
A failed commission withdrawal restores both recipient credit and total token
liabilities. The credited recipient can try another destination. LP operations
preserve existing commission reserves and unrelated dust. `CommissionAccrued`
and `CommissionWithdrawn` events distinguish charging fees from treasury payment.

## Owner powers

```solidity
addPool(PoolKey key) returns (bytes32 poolId)        // owner only
setDepositsDisabled(bytes32 poolId, bool disabled)   // owner only
setEjectEnabled(bytes32 poolId, bool enabled)        // owner only
setFeeRecipient(address newRecipient)                // owner only
```

- **Appending pools.** `addPool` applies the constructor's checks (hookless,
  one side USDG, initialized, not already listed, not a protocol contract) and
  emits `PoolAdded`. Listed pools can never be removed or changed. A stock can
  be listed under any number of fee tiers or tick spacings; each is a separate
  pool with its own ID, and a position belongs to exactly one. `addPool`
  checks only that the pool is initialized, not that its price is on-market or
  that it has liquidity: anyone can initialize a Uniswap v4 pool at any price,
  so confirm both before listing.
- **Stopping deposits.** `setDepositsDisabled` makes `openPosition` revert with
  `DepositsDisabled` for that pool, for a mistaken listing or a token whose
  behaviour changed. Open positions collect and exit as before, and quotes
  still work.
- **Enabling eject**, per pool, as described above.
- **The fee recipient** for future accruals. Zero and router-self destinations
  are rejected.

Ownership transfers use `transferOwnership` followed by the new owner's
`acceptOwnership`; changing ownership does not change the fee recipient.
`renounceOwnership` reverts with `OwnershipNotRenounceable`: the owner is the
only party who can enable eject, so an ownerless router would have no recovery
path. There is no function to change the 10% rate, withdraw users' assets, or
release/approve their LP NFTs, and ownership never grants permission to
collect or exit another user's position.

## Frontend getters

| Getter | Result |
| --- | --- |
| `previewDeposit(poolId, amount0Max, amount1Max, tickLower, tickUpper)` | Current liquidity, required token amounts and pool `sqrtPriceX96` |
| `getPoolKey(poolId)` | Currencies, fee, tick spacing, hooks |
| `poolCount()`, `getPoolIds(offset, limit)` | Listed pool catalog, in listing order |
| `stockPoolCount(stock)`, `getStockPoolIds(stock, offset, limit)` | Listed pools for a stock, in listing order |
| `depositsDisabled(poolId)` | Whether new deposits into the pool are stopped |
| `getPosition(tokenId)` | Beneficiary, NFT custodian, live principal/fees, commission, range and collection history |
| `getUserPositions(user, cursor, limit)` | Active positions belonging to that user, plus next cursor |
| `positionCount()` | Number of positions ever opened through Valari |
| `depositCount(depositor)`, `getDepositorPositionIds(depositor, offset, limit)` | Original depositor history, including closed positions |
| `owner()`, `feeRecipient()`, `COMMISSION_BPS()` | Administration and current commission configuration |
| `claimableCommission(recipient, token)` | Outstanding token credit owned by a recipient |
| `totalClaimableCommission(token)` | Aggregate outstanding token commission liabilities |

`getUserPositions` uses the registered beneficiary and excludes closed
positions. Its cursor indexes that user's historical position list. Each call
scans at most `limit` entries (1–100), so a page containing only closed positions
can be empty with more pages remaining. Continue until
`nextCursor == depositCount(user)`. Positions opened outside this router are
not imported or managed by it.

`getPosition` separates rounded-down principal (`amount0`, `amount1`) from
currently uncollected gross fees (`fees0`, `fees1`), pending `commission0/1`,
and `netFees0/1` payable to the user. These are live chain amounts, not USD
valuations or backtest estimates. `feesCollected0/1` and `commissionAccrued0/1`
record cumulative realized fees and commission charges, including the final exit.

`PositionView.owner` is the beneficiary, while `nftOwner` is the actual ERC721
holder (the router while active). After exit, the original beneficiary and
deposit/collection history remain, `closed=true`, `exists=false`, `nftOwner=0`,
and live liquidity, principal and pending fees are zero. Users interact with
Valari to collect or exit; they cannot transfer the NFT or bypass the fee logic
through Uniswap's PositionManager, except through eject where the owner has
enabled it. The contract is not upgradeable.

## Configuration and deployment

The constructor accepts 0–100 initialized, hookless USDG pools
(`MAX_INITIAL_POOLS`); there is no cap on appended pools. The deploy script
reads `config/robinhood-curated.json` by default, checks the chain, manager
addresses and pool IDs, and deploys with those pools. `VALARI_POOLS_CONFIG`
points either script at another catalog file under `config/`. The append
script adds whatever its catalog (default `config/robinhood.json`) lists that
the router does not, and skips the rest.

```sh
# simulate; add --broadcast and a signer to send
forge script script/DeployValariRouterV3.s.sol:DeployValariRouterV3 --rpc-url robinhood
VALARI_ROUTER_V3=0x... \
  forge script script/AddValariRouterV3Pools.s.sol:AddValariRouterV3Pools --rpc-url robinhood
```

Deployment requires a separately selected signer and explicit broadcasting.
That signer becomes the initial owner and commission recipient. No deployment
is performed by building or testing this project.

To regenerate the catalogs after deliberately changing Valari's source catalog
(requires the adjacent UI's installed ethers dependency):

```sh
node script/generate-config.mjs     # config/robinhood.json
node tools/curated-catalog.mjs      # config/robinhood-curated.json
```

Regenerate the frontend ABI after changing the contract:

```sh
forge inspect ValariRouterV3 abi --json > abi/ValariRouterV3.json
```

## Verification

Local integration tests cover actual v4 minting and settlement, both token
orders, one-sided ranges, price bounds, refunds, dust isolation and tolerance,
allowance cleanup, custody, beneficiary authorization, alternate payout
destinations, eject, per-pool deposit stops, appended pools, recipient
administration, reentry, deadline/slippage failures, live fee growth,
fees-only commission and its cumulative rounding, collection/exit payouts,
pagination, and fuzzed funding amounts/ranges.

Run the optional Robinhood fork tests with synthetic balances on a local fork:

```sh
RUN_ROBINHOOD_FORK=true forge test --match-contract '^ValariRouterV3Fork' -vv
```

`ROBINHOOD_FORK_BLOCK` optionally pins a block, subject to RPC state retention.
The default local test run skips these network-dependent tests. The fork suite
exercises the position lifecycle and exit paths against the deployed managers
and token implementations, and also runs both scripts. It uses no private keys
or live transactions.

Tool runs are recorded under `audit/`: `audit/2026-10-05-v3` (Slither,
Manticore, Echidna, a Trail of Bits-style differential review) and
`audit/2026-10-14` (a re-run of the tooling on byte-identical source). This
implementation has automated tests and tool-assisted reviews; it has not
received an independent external security audit.
