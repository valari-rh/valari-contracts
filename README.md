# Valari contracts

`ValariRouter` opens Uniswap v4 USDG/stock liquidity positions on Robinhood
Chain (4663). The user supplies both token budgets and a tick range; the router
holds the resulting LP NFT and records that user as its beneficiary. Unused
deposit tokens are refunded. On fee collection or full exit, Valari receives
**10% of newly realized LP fees** as an accrued credit, and the user receives the remaining fees plus
any withdrawn principal. Principal and deposits carry no Valari commission.

## Live Robinhood deployment

The current router, where every deposit goes:

- Router: [`0x669092861489E6abdCB3aaA16994cF31253967b7`](https://robinhoodchain.blockscout.com/address/0x669092861489E6abdCB3aaA16994cF31253967b7).
- Chain ID: **4663**; deployment block: **77,462,031**.
- Creation transaction: [`0xd2df011ffaa2dd54bdacbed9ea56c866006e286a812c0f60d58d5557d76b44bb`](https://robinhoodchain.blockscout.com/tx/0xd2df011ffaa2dd54bdacbed9ea56c866006e286a812c0f60d58d5557d76b44bb).
- Same source and runtime bytecode as the first router. Its catalog,
  `config/robinhood.json`, replaces the empty CSCO and PWR pools with SPY and
  USO; the first router's catalog is kept as `config/robinhood-router-v1.json`.
- Owner and treasury recipient: `0x09D08d66dF2ebE0DB3D589Ac528Fd589E064C5A2`.
- Deployment cost: about **0.000295 ETH**, using 14,495,596 gas.
- Metadata: [`deployments/robinhood-mainnet-v2.json`](deployments/robinhood-mainnet-v2.json).

The first router opens nothing new; positions opened there still collect and
exit through it:

- Router: [`0x7DD01E8Da0cE263368f06BE8c7114731cA0DB04d`](https://robinhoodchain.blockscout.com/address/0x7DD01E8Da0cE263368f06BE8c7114731cA0DB04d).
- Chain ID: **4663**; deployment block: **63,151,100**.
- Creation transaction: [`0xa8da7c1437e34157593ec8f3e65aa162279ae6ad354bb16a756098fdc6518ff5`](https://robinhoodchain.blockscout.com/tx/0xa8da7c1437e34157593ec8f3e65aa162279ae6ad354bb16a756098fdc6518ff5).
- Initial owner and treasury recipient: `0x09D08d66dF2ebE0DB3D589Ac528Fd589E064C5A2`.
- Deployment cost: **0.00108180184896 ETH**, using 14,004,270 gas.
- Verified on-chain: compiled runtime bytecode, all 100 pool IDs and keys, manager addresses, owner, treasury recipient, and 10% commission.

Public transaction and verification metadata are stored in
[`deployments/robinhood-mainnet.json`](deployments/robinhood-mainnet.json).
The deployed bytecode comes from the pinned Foundry artifact. The deployment
was signed locally with the provided environment key; no private key or signed
transaction is stored in the public deployment record.

Explorer source verification is not yet complete: Blockscout's API returned a
Cloudflare challenge before accepting the submission. The exact compiler input,
constructor arguments, and attempt status are saved as `blockscout-*` files in
`deployments/` for submission when the explorer API is available. This does not
affect the mined contract or the on-chain bytecode/configuration checks above.

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

- `src/ValariRouter.sol`: deposits, NFT custody, collection, exits, commission and getters.
- `abi/ValariRouter.json`: frontend ABI, exported from the compiled contract.
- `config/robinhood.json`: the exact 100 pools selected by Valari's verified catalog.
- `script/DeployValariRouter.s.sol`: deployment script with chain and catalog checks.
- `test/ValariRouter.t.sol`: integration tests using real v4 core/periphery and Permit2.
- `test/ValariRouterFork.t.sol`: opt-in tests against deployed Robinhood contracts.
- `lib/`: pinned upstream dependencies, described in [DEPENDENCIES.md](DEPENDENCIES.md).

Solidity is pinned to 0.8.26 with Cancun, the optimizer (200 runs), and via-IR,
matching the existing contract projects. Dependencies are vendored. If the
compiler is not installed, run `forge build` once without `--offline`.

## ValariRouterV3 (current router)

`src/ValariRouterV3.sol` is the current router, deployed on 6 Oct 2026 at
`0x4Fe8ccbc4Ac98D68b69DbF9c2fbc13F8BdCA915d` (block 81799944) with the 16 curated
pools the Valari frontend lists (`config/robinhood-curated.json`, written by
`tools/curated-catalog.mjs`; record in `deployments/robinhood-mainnet-v3.json`).
The two earlier routers keep running
`src/ValariRouter.sol`, which is unchanged; everything below this section
describes that deployed source. V3 differs from it in these ways:

- **Price bounds on deposits.** `openPosition` takes `sqrtPriceMinX96` and
  `sqrtPriceMaxX96` before `deadline` and reverts with `PriceOutOfBounds` when
  the pool price is outside them. `minLiquidity` alone does not bound the
  execution price when a budget has slack. The minimum must be nonzero and not
  above the maximum (`InvalidPriceBounds`). Derive both from a reference
  price and the user's tolerance. `previewDeposit` returns the pool's own
  `sqrtPriceX96`, which is a sound reference only for a deep pool: a thin fee
  tier can already sit off-market, so compare it with the stock's deepest
  listed tier (or an external price) before centring the bounds on it.
- **Appendable catalog.** The owner can call `addPool(PoolKey)`. It applies the
  constructor's checks (hookless, one side USDG, initialized, not already
  listed) and emits `PoolAdded`, as the constructor now does for each initial
  pool. Listed pools can never be removed or changed. The constructor accepts
  0–100 initial pools (`MAX_INITIAL_POOLS`); there is no cap on appended pools.
- **Several fee tiers per stock.** A stock can be listed under any number of
  fee tiers or tick spacings; each is a separate pool with its own ID, and a
  position belongs to exactly one. Only listing the same pool twice is
  rejected (`DuplicatePool`, replacing `DuplicateStock`). The single-valued
  `stockPoolId(stock)` getter is replaced by `stockPoolCount(stock)` and the
  paginated `getStockPoolIds(stock, offset, limit)`, in listing order.
- **Payouts tolerate rounding dust, and nothing more.** The deployed source
  requires exact amounts on both sides of a payout. V3 tolerates up to
  `MAX_PAYOUT_DUST` (2 raw units) on each: the pool may deliver that much less
  than the exact principal (the exit pays out what arrived and reports it as
  the principal), and the payout may leave that much behind in the router. A
  token that rounds no longer blocks collection, exit or commission
  withdrawal. Anything larger still reverts (`InsufficientProceeds` inbound,
  `UnsupportedToken` outbound) and leaves the position open. The tolerance
  cannot tell rounding from an unmade transfer of 1–2 raw units of principal,
  so that much per token per payout is the most a misbehaving token can cost a
  caller on principal; LP fees are only ever measured as what arrives above
  the principal, so a token withholding fees is not detectable (as in the
  deployed router). The exit minimums bound what the pool must release; what
  reaches the recipient can be up to 2 units below them on each transfer hop.
- **Payout to another address.** `collectFeesTo` and `exitPositionTo` are
  `collectFees` and `exitPosition` with a destination the beneficiary chooses,
  for a beneficiary who cannot receive one of the tokens at their own address.
  Only the beneficiary can call them; zero and the router are refused
  (`InvalidRecipient`). `FeesCollected` and `PositionExited` carry the
  destination as a final `to` field.
- **Deposits can be stopped per pool.** The owner's
  `setDepositsDisabled(poolId, bool)` makes `openPosition` revert with
  `DepositsDisabled` for that pool: for a mistaken listing, or a token whose
  behaviour changed. Open positions collect and exit as before, and quotes
  still work. Read the flag with `depositsDisabled(poolId)`.
- **Eject: a way out when the router cannot pay.** If an issuer restricts the
  router's address, no payout can pass through it. The owner can then call
  `setEjectEnabled(poolId, true)`, after which each depositor in that pool can
  call `ejectPosition(tokenId, to)`: the LP NFT moves to `to`, no token is
  transferred, and the position is the holder's to manage on Uniswap directly,
  uncollected fees included. The router records it as closed (`getPosition`
  then shows `closed` with `nftOwner` set to the holder) and charges nothing
  on it afterwards. Before moving the NFT, eject attempts an ordinary fee
  collection so that the commission on fees realized so far is charged and
  the net fees go to `to`; if that collection cannot complete (the router
  cannot receive one of the tokens), the fees travel with the NFT instead.
  Eject is off by default; enabling it gives the owner no access to any
  position.
- **Ownership cannot be renounced.** `renounceOwnership` reverts with
  `OwnershipNotRenounceable`: the owner is the only party who can enable
  eject, so an ownerless router would have no recovery path.
- **Commission withdrawals are solvency-checked per withdrawal.** If tokens
  ever leave the router out of band (an issuer action), what remains stays
  withdrawable instead of every recipient's credit in that token freezing.
- **Payout destinations exclude the protocol contracts.** `to` may not be
  zero, the router, the PositionManager, the PoolManager or Permit2, matching
  the other address checks.
- **The mint executes at the checked price.** The pool price is read again
  immediately before the mint and must equal the quoted one, so a token whose
  transfer or approval moves the pool cannot slip a deposit past the bounds.
- **Protocol contracts are not listable.** A pool whose non-USDG side is the
  PositionManager, PoolManager, Permit2 or the router itself is rejected.

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

collectFeesTo(uint256 tokenId, address to, uint256 deadline) returns (Payout memory)
exitPositionTo(uint256 tokenId, address to, uint128 amount0Min, uint128 amount1Min, uint256 deadline)
    returns (Payout memory)
ejectPosition(uint256 tokenId, address to)      // only where the owner enabled it

addPool(PoolKey key) returns (bytes32 poolId)   // owner only
setDepositsDisabled(bytes32 poolId, bool disabled)   // owner only
setEjectEnabled(bytes32 poolId, bool enabled)        // owner only
stockPoolCount(address stock) returns (uint256)
getStockPoolIds(address stock, uint256 offset, uint256 limit) returns (bytes32[] memory)
```

Deploy with the same 100-pool catalog as the current router, then keep the
catalog current with the second script, which appends whatever
`config/robinhood.json` lists that the router does not and skips the rest
(a catalog may list a stock more than once, under different fee tiers):

```sh
# simulate; add --broadcast and a signer to send
forge script script/DeployValariRouterV3.s.sol:DeployValariRouterV3 --rpc-url robinhood
VALARI_ROUTER_V3=0x... \
  forge script script/AddValariRouterV3Pools.s.sol:AddValariRouterV3Pools --rpc-url robinhood
```

`VALARI_POOLS_CONFIG` points either script at another catalog file under
`config/`. The deploy script requires exactly 100 pools; the append script
takes any number. The frontend ABI is `abi/ValariRouterV3.json`.

The owner's powers in V3 are: the fee recipient, appending pools, stopping
deposits per pool, and enabling eject per pool. None of them can move, redirect
or freeze a user's position or funds, and ownership cannot be renounced.

`test/ValariRouterV3.t.sol` runs the deployed router's integration suite
against V3 and adds tests for each change;
`test/ValariRouterV3AccountingAudit.t.sol` and `test/ValariRouterV3Fork.t.sol`
port the accounting property and the fork lifecycle tests, and the fork suite
also runs both scripts.

## Deposit API

```solidity
openPosition(
    bytes32 poolId,
    uint128 amount0Max,
    uint128 amount1Max,
    int24 tickLower,
    int24 tickUpper,
    uint128 minLiquidity,
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
   **nonzero** `minLiquidity`, and choose a short deadline. A fresh on-chain
   quote must precede submission; the historical backtest is not a mint quote.
4. Approve each funded ERC20 to **the ValariRouter address**, then call
   `openPosition`. Existing adequate allowances can be reused.
5. Obtain `tokenId` and actual deposited amounts from the `PositionOpened`
   receipt event. Call `getPosition(tokenId)` for the live view.

The router uses explicit `MINT_POSITION` plus `SETTLE_PAIR`. The maximum token
budgets and minimum liquidity constrain execution; stale deadlines, unsupported
pools, invalid ranges and inadequate liquidity revert atomically. Permit2 and
ERC20 approvals made by the router are limited to the current budgets and reset
to zero after settlement. Preexisting router token balances are isolated from
the deposit and refund. Fee-on-transfer/rebasing tokens are unsupported.

## Collection, exit and commission

```solidity
collectFees(uint256 tokenId, uint256 deadline) returns (Payout memory)

exitPosition(
    uint256 tokenId,
    uint128 amount0Min,
    uint128 amount1Min,
    uint256 deadline
) returns (Payout memory)
```

Only the user who opened the position can call either function. Collection
leaves liquidity invested. Exit removes all liquidity and burns the NFT.
The exit minimums protect **principal amounts only**, excluding accrued fees;
the user chooses them from the live position view and their slippage tolerance.

`Payout` returns `principal0/1`, newly realized gross `fees0/1`, Valari's
`commission0/1`, and the total net user payment `amount0/1`. Commission is retained
in each earned token without swapping or USD valuation. For example, 100 USDG
of LP fees produces 10 USDG of treasury credit and 90 USDG for the user; exiting also
returns all withdrawn principal.

Collection uses `DECREASE_LIQUIDITY(0)` and `TAKE_PAIR` to realize fees into
the router. Exit uses `BURN_POSITION` and `TAKE_PAIR`; the router subtracts
the exact rounded-down principal from actual received tokens to identify fees.
This separation relies on the fixed hookless catalog. Slippage failures,
unexpected receipts and failed payouts revert the entire operation.

The fixed rate is `COMMISSION_BPS = 1000` out of 10,000. Fractional commission
is carried across collections separately for each position and token, including
the final exit. Total commission equals the integer floor of cumulative fees
divided by 10. Repeated small collections cannot avoid commission through
rounding. A final fraction smaller than one raw token unit rounds down.

The deployer is the initial contract owner and commission recipient. The owner
can call `setFeeRecipient(address)` to change the recipient of future accruals.
Zero and router-self destinations are rejected. Ownership transfers use
`transferOwnership` followed by the new owner's `acceptOwnership`; changing
ownership does not automatically change the fee recipient. There is no function
to change the 10% rate, withdraw users' assets, or release/approve their LP NFTs.
Administrative ownership never grants permission to collect or exit another
user's position.

Treasury commission is withdrawn separately:

```solidity
claimableCommission(address recipient, address token) returns (uint256)
totalClaimableCommission(address token) returns (uint256)
withdrawCommission(address token, address to, uint256 amount)
```

Each recipient owns its accrued token credits. It calls `withdrawCommission`
with a positive amount up to its available credit, choosing itself or another
valid destination. Zero destinations and the router itself are rejected. The
owner cannot withdraw another recipient's credit. Changing `feeRecipient`
affects future accrual only; old recipients retain the right to withdraw their
existing credits. Ownership changes do not transfer those credits either.

User collection and exit do not send any tokens to the treasury. A token that
blocks the treasury therefore cannot prevent otherwise valid user payouts.
A failed commission withdrawal restores both recipient credit and total token
liabilities. The credited recipient can try another destination. LP operations
preserve existing commission reserves and unrelated dust. `CommissionAccrued`
and `CommissionWithdrawn` events distinguish charging fees from treasury payment.

## Frontend getters

| Getter | Result |
| --- | --- |
| `previewDeposit(poolId, amount0Max, amount1Max, tickLower, tickUpper)` | Current liquidity and required token amounts |
| `getPoolKey(poolId)` | Currencies, fee, tick spacing, hooks |
| `poolCount()`, `getPoolIds(offset, limit)` | Fixed supported pool catalog |
| `stockPoolId(stock)` | Supported pool for a configured stock |
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
`nextCursor == depositCount(user)`. Events are `PositionOpened`, `FeesCollected`,
`PositionExited` and `FeeRecipientUpdated`. Positions opened outside this router
are not imported or managed by it.

`getPosition` separates rounded-down principal (`amount0`, `amount1`) from
currently uncollected gross fees (`fees0`, `fees1`), pending `commission0/1`,
and `netFees0/1` payable to the user. These are live chain amounts, not USD
valuations or backtest estimates. `feesCollected0/1` and `commissionAccrued0/1`
record cumulative realized fees and commission charges, including the final exit.
The accrued counters do not decrease when the treasury withdraws. They replace
the former `commissionPaid0/1` field names in the frontend ABI.

`PositionView.owner` is the beneficiary, while `nftOwner` is the actual ERC721
holder (the router while active). After exit, the original beneficiary and
deposit/collection history remain, `closed=true`, `exists=false`, `nftOwner=0`,
and live liquidity, principal and pending fees are zero. Users interact with
Valari to collect or exit; they cannot transfer the NFT or bypass the fee logic
through Uniswap's PositionManager. The contract is not upgradeable.

## Configuration and deployment

The constructor accepts 1–100 initialized, hookless USDG pools with distinct
stock currencies. Its configuration cannot change after deployment. The checked-in
deployment script requires **exactly the selected 100 Robinhood stock pools**,
checks their full pool IDs, and validates the chain and manager addresses.
Issuer eligibility comes from the verified deployment catalog; ERC20 contracts
do not provide a universal on-chain issuer attestation.

To regenerate that configuration after deliberately changing Valari's source
catalog (requires the adjacent UI's installed ethers dependency):

```sh
node script/generate-config.mjs
```

Simulate the deployment against Robinhood without broadcasting:

```sh
forge script script/DeployValariRouter.s.sol:DeployValariRouter --rpc-url robinhood
```

Deployment requires a separately selected signer and explicit broadcasting.
That signer becomes the initial owner and commission recipient. No deployment
is performed by building or testing this project.

Regenerate the frontend ABI after changing the contract:

```sh
forge inspect ValariRouter abi --json > abi/ValariRouter.json
```

## Verification

Local integration tests cover actual v4 minting and settlement, both token
orders, one-sided ranges, refunds, dust isolation, allowance cleanup, custody,
beneficiary authorization, recipient administration, reentry, deadline/slippage
failures, live fee growth, fees-only commission and its cumulative rounding,
collection/exit payouts, pagination, and fuzzed funding amounts/ranges.

Run the optional Robinhood fork tests with synthetic balances on a local fork:

```sh
RUN_ROBINHOOD_FORK=true forge test --match-contract '^ValariRouter(ForkTest|IntegrationAuditTest)$' -vv
```

`ROBINHOOD_FORK_BLOCK` optionally pins a block, subject to RPC state retention.
The default local test run skips these network-dependent tests. Fork tests
deploy the complete 100-pool configuration locally and exercise GOOGL/USDG
and USDG/NVDA using the deployed managers and token implementations. Four
cases cover both currency orders, donations, actual swaps in both directions,
collection, and exits after price changes. A narrow-range position is crossed
out of range to verify one-sided principal, stopped fee accrual, and an atomic
revert when the user supplies stale exit minimums. Payouts are checked against
live getters, actual beneficiary/recipient balance changes, and cumulative
10% commission on fees alone, retained credits and separate treasury withdrawals.
They use no private keys or live transactions.

A fifth fork regression simulates a blocked treasury using the deployed stock
registry. It verifies that user collection and exit succeed, a rejected treasury
withdrawal restores credit, and the credited recipient can choose another
destination without owner intervention.

Verified on 2026-09-15 for the 10% accrued-commission implementation:
**50 local integration tests passed**, including 256 funding/range fuzz cases;
the two focused audit regressions passed, including another 256 randomized
accounting sequences. All **5 fork tests passed at Robinhood block 63,116,190**
with no failures or skips. Full compilation and formatting passed.

The fork run validated all 100 configured pools, with lifecycle execution on
GOOGL and NVDA for both currency orders, actual swaps, range crossings,
commission accrual and separate withdrawals. The blocked-treasury regression
confirmed collection and full exit without owner intervention, failed-claim
rollback and withdrawal to an alternate eligible destination. The other 98
pools were configuration-checked, not individually exercised through a lifecycle.

RPC: `https://rpc.mainnet.chain.robinhood.com`.
Saved output: `cache/commission-remediation-fork.log`.
The earlier audit and original 1% results are recorded in [AUDIT.md](AUDIT.md).

```sh
RUN_ROBINHOOD_FORK=true ROBINHOOD_FORK_BLOCK=63116190 \
  forge test --match-contract '^ValariRouter(ForkTest|IntegrationAuditTest)$' -vvv
```

The public RPC prunes older state; omit the block pin for future latest-state
runs if this snapshot becomes unavailable.

This implementation has automated tests and a code review; it has not received
an independent external security audit.

The [router audit and remediation record](AUDIT.md) documents the original
Medium finding and the change to independently withdrawable commission credits.
The updated blocked-treasury regressions require user collection and exit to
succeed while treasury transfers are rejected, with failed treasury claims
preserving their credits and an alternate destination remaining available.
