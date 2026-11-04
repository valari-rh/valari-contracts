# Invariant Map

> ValariRouterV3 | 39 guards | 22 inferred (11 single-contract, 6 cross-contract, 5 economic) | 1 not enforced on-chain

Scope: `src/ValariRouterV3.sol` (all `:LN` references below are to this file unless prefixed), `script/DeployValariRouterV3.s.sol`, `script/AddValariRouterV3Pools.s.sol`. Where a cross-contract block cites vendored Uniswap/OZ code under `lib/`, it is marked **(vendored)** — those files are pinned at the revisions in `DEPENDENCIES.md` and were read for this report, but they are not audit scope.

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (block.timestamp > deadline) revert DeadlineExpired()` · `ValariRouterV3.sol:307` (also `:477`, `:522`) · Rejects a stale transaction before any token moves; the same deadline is forwarded to `PositionManager.modifyLiquidities`, which re-checks it.

#### G-2
`if (minLiquidity == 0) revert InvalidLiquidity()` · `ValariRouterV3.sol:310` · Forces every deposit to carry a quote-derived liquidity floor; a zero floor would let any price accept the budgets.

#### G-3
`if (sqrtPriceMinX96 == 0 || sqrtPriceMinX96 > sqrtPriceMaxX96) revert InvalidPriceBounds()` · `ValariRouterV3.sol:311` · Price bounds must be deliberately chosen; a zero minimum would silently disable the lower bound.

#### G-4
`if (depositsDisabled[poolId]) revert DepositsDisabled(poolId)` · `ValariRouterV3.sol:313` · Owner's per-pool stop applies to new deposits only; collect/exit paths never read this flag.

#### G-5
`if (quote.sqrtPriceX96 < sqrtPriceMinX96 || quote.sqrtPriceX96 > sqrtPriceMaxX96) revert PriceOutOfBounds(...)` · `ValariRouterV3.sol:316-318` · Bounds the pool spot at which the deposit is sized, independent of `minLiquidity` (which does not bound price when a budget has slack).

#### G-6
`if (liquidity < minLiquidity) revert LiquidityBelowMinimum(liquidity, minLiquidity)` · `ValariRouterV3.sol:320` · Liquidity-side slippage floor from the caller's prior quote.

#### G-7
`if (mintPrice != quote.sqrtPriceX96) revert PriceOutOfBounds(mintPrice, quote.sqrtPriceX96, quote.sqrtPriceX96)` · `ValariRouterV3.sol:344-347` · The mint executes at exactly the quoted/bounded price; closes the window in which token `transferFrom`/`approve` callbacks (the only foreign calls since the quote) could move the pool.

#### G-8
`ownerOf(tokenId) != address(this) || getPositionLiquidity(tokenId) != liquidity || nextTokenId() != tokenId + 1` → `UnexpectedPosition` · `ValariRouterV3.sol:356-360` · The ID recorded as the user's position is the one just minted, custodied by the router and sized as quoted.

#### G-9
`if (newRecipient == address(0) || newRecipient == address(this)) revert InvalidFeeRecipient()` · `ValariRouterV3.sol:385-387` · The router's own balance is how payouts are measured, so it may never be a commission destination.

#### G-10
`if (token == address(0) || to == address(0) || to == address(this) || amount == 0) revert InvalidCommissionWithdrawal()` · `ValariRouterV3.sol:397-399` · Same self-destination rule for treasury withdrawals; zero amount would emit a misleading event.

#### G-11
`if (amount > credit) revert InsufficientCommission()` · `ValariRouterV3.sol:401` · Credit ownership is keyed by `msg.sender`; the owner cannot spend another recipient's credit.

#### G-12
`if (beforeBalance < total) revert InsufficientProceeds()` · `ValariRouterV3.sol:405` · Aggregate liabilities must be fully backed by the router's balance before any recipient withdraws.

#### G-13
`if (!ejectEnabled[record.poolId]) revert EjectDisabled(record.poolId)` · `ValariRouterV3.sol:464` · Eject bypasses the commission, so it is off until the owner enables it per pool.

#### G-14
`if (_ownerOf(tokenId) != to) revert UnexpectedPosition()` · `ValariRouterV3.sol:468` · The ejected NFT actually arrived at the chosen holder.

#### G-15
`getPositionLiquidity(tokenId) != liquidity || _ownerOf(tokenId) != address(this)` → `UnexpectedPosition` · `ValariRouterV3.sol:495-500` · Fee collection leaves liquidity invested and custody unchanged.

#### G-16
`if (payout.principal0 < amount0Min || payout.principal1 < amount1Min) revert InsufficientProceeds()` · `ValariRouterV3.sol:536-538` · Exit minimums protect principal only (fees excluded), computed from the pre-burn price snapshot.

#### G-17
`if (_ownerOf(tokenId) != address(0)) revert UnexpectedPosition()` · `ValariRouterV3.sol:553` · The NFT was burned by the exit, so no later call can act on it.

#### G-18
`tickLower >= tickUpper || tickLower < MIN_TICK || tickUpper > MAX_TICK || tickLower % key.tickSpacing != 0 || tickUpper % key.tickSpacing != 0` → `InvalidRange` · `ValariRouterV3.sol:581-584` · Range must be a valid, spacing-aligned v4 range for the listed pool.

#### G-19
`if (quote.liquidity == 0 || quote.liquidity > uint128(type(int128).max)) revert InvalidLiquidity()` · `ValariRouterV3.sol:591-593` · Liquidity must be representable as a positive `int128` delta for `modifyLiquidity`.

#### G-20
`if (quote.amount0 > amount0Max || quote.amount1 > amount1Max) revert InvalidLiquidity()` · `ValariRouterV3.sol:596` · Rounded-up funding never exceeds the caller's budget (the mint's `amount0Max/amount1Max`).

#### G-21
`if (key.tickSpacing == 0) revert InvalidPool(poolId)` · `ValariRouterV3.sol:601` · Catalog membership test; `tickSpacing` is never zero for a listed pool (G-28).

#### G-22
`record.depositor == address(0)` → `UnknownPosition`; `record.depositor != msg.sender` → `NotPositionOwner`; `record.closed` → `PositionClosed`; `_ownerOf(tokenId) != address(this)` → `UnexpectedPosition` · `ValariRouterV3.sol:743-746` · Beneficiary authorisation and liveness for collect/exit/eject; only the original depositor may act, only once closed=false, only while custodied.

#### G-23
`if (balance0 < before0 || balance1 < before1) revert InsufficientProceeds()` · `ValariRouterV3.sol:775` · An LP payout can never draw on balances the router held before the operation (commission reserves, dust).

#### G-24
`if (expectedPrincipal - received > MAX_PAYOUT_DUST) revert InsufficientProceeds()` · `ValariRouterV3.sol:811` · Principal shortfall from the pool is tolerated only up to 2 raw units; larger shortfalls leave the position open.

#### G-25
`if (to == address(0) || to == address(this)) revert InvalidRecipient()` · `ValariRouterV3.sol:818` · Payout destination may not be the measuring contract.

#### G-26
`if (held < expected || held - expected > MAX_PAYOUT_DUST) revert UnsupportedToken(address(token))` · `ValariRouterV3.sol:827-829` · After a payout the router retains exactly its reserves (prior balance + new commission) within +2 units; less means reserves were spent, more means the token reported a transfer it did not make.

#### G-27
`if (_pools[id].tickSpacing != 0) revert DuplicatePool(id)` · `ValariRouterV3.sol:837` · Catalog is a set keyed by pool ID.

#### G-28
`token0 >= token1 || token0.code.length == 0 || token1.code.length == 0 || (token0 != usdg_ && token1 != usdg_) || hooks != 0 || tickSpacing < MIN || tickSpacing > MAX` → `InvalidPool` · `ValariRouterV3.sol:840-845` · Listing admits only sorted, deployed, USDG-paired, hookless keys; hookless is load-bearing for the exit split (no hook can run between snapshot and burn) and implies a static LP fee (v4 rejects dynamic fees without a hook).

#### G-29
`stock == positionManager || stock == poolManager || stock == permit2 || stock == address(this)` → `InvalidPool` · `ValariRouterV3.sol:849-852` · ERC20 selectors the router sends to the stock must never land on a contract it holds positions or allowances with.

#### G-30
`if (sqrtPriceX96 == 0) revert InvalidPool(id)` · `ValariRouterV3.sol:854` · Only pools initialised in the PoolManager are listable.

#### G-31
`if (limit == 0 || limit > MAX_PAGE_SIZE) revert InvalidPageSize()` · `ValariRouterV3.sol:894` · Bounds view-side iteration.

#### G-32
`if (token.balanceOf(address(this)) != beforeBalance + budget) revert UnsupportedToken(address(token))` · `ValariRouterV3.sol:902-904` · Funding must arrive exactly; fee-on-transfer or short-crediting tokens are refused at deposit.

#### G-33
`remaining < beforeBalance || remaining - beforeBalance > budget` → `UnsupportedToken`; after refund `balanceOf != beforeBalance` → `UnsupportedToken` · `ValariRouterV3.sol:919-927` · A deposit ends with the router's balance exactly where it started; refunds cannot touch pre-existing reserves.

#### G-34
`positionManager_.code.length == 0 || stateView_.code.length == 0 || usdg_.code.length == 0 || pools_.length > MAX_INITIAL_POOLS`; `manager.code.length == 0 || stateView_.poolManager() != manager || allowanceTransfer.code.length == 0` → `InvalidConfiguration` · `ValariRouterV3.sol:228-237` · Immutable wiring is self-consistent (StateView and PositionManager agree on the PoolManager; Permit2 is read from the PositionManager, not supplied).

#### G-35
`require(block.chainid == 4663 && vm.parseJsonUint(config, ".chainId") == 4663, "Wrong chain")` · `DeployValariRouterV3.s.sol:20-22` (same in `AddValariRouterV3Pools.s.sol:22-24`) · Scripts refuse to run against any chain but Robinhood.

#### G-36
`require(keys.length == 100 && ids.length == 100, "Expected 100 pools")` · `DeployValariRouterV3.s.sol:36` · Deployment is pinned to the full checked-in catalog.

#### G-37
`require(PoolId.unwrap(keys[i].toId()) == ids[i], "Pool ID mismatch")` · `DeployValariRouterV3.s.sol:38`, `AddValariRouterV3Pools.s.sol:48` · The catalog's declared IDs match its keys, so a hand-edited config cannot list a different pool than it names.

#### G-38
`try router.MAX_PAYOUT_DUST() returns (uint256) {} catch { revert("VALARI_ROUTER_V3 is not a ValariRouterV3"); }` · `AddValariRouterV3Pools.s.sol:28-31` · Stops the append script from running "0 pools added" against a V1 router that passes every other address check.

#### G-39
`require(router.poolCount() == countBefore + added, "Catalog size mismatch")` · `AddValariRouterV3Pools.s.sol:65` · Post-broadcast assertion that every appended pool landed.

---

## 2. Inferred Invariants (Single-Contract)

Inferred invariants are derived from structural analysis of the source code. Each block cites one of five extraction methods in its `Derivation` field: Δ-pair analysis, guard lift, state-machine edge, temporal predicate, or NatSpec-stated global property. Categories: `Conservation` · `Bound` · `Ratio` · `StateMachine` · `Temporal`.

---

#### I-1

`Conservation` · On-chain: **Yes**

> `totalClaimableCommission[t] == Σ_r claimableCommission[r][t]` for every token `t`.

**Derivation** — Δ-pair: `ValariRouterV3.sol:863 ↔ :864` (`_accrueCommission`: both `+= amount`) and `ValariRouterV3.sol:408 ↔ :409` (`withdrawCommission`: both `-= amount`). These are the only write sites of either mapping (grep over `src/ValariRouterV3.sol`).

**If violated** — G-12 would admit a withdrawal against a phantom aggregate, or refuse a legitimate one.

---

#### I-2

`Ratio` · On-chain: **Yes**

> Per position and per currency: `feesCollected_i * COMMISSION_BPS == commissionAccrued_i * BPS_DENOMINATOR + commissionRemainder_i`, i.e. lifetime commission is exactly `floor(lifetime realized fees / 10)` with the fraction carried.

**Derivation** — Ratio write at `ValariRouterV3.sol:780-789`: `_commission(fees, prevRem)` (`:756-759`) yields `fees*1000 + prevRem == commission*10000 + rem`; `feesCollected += fees` and `commissionAccrued += commission` are written in the same body with no intervening external call. These four record fields are written nowhere else. Snapshot ordering: `payout.fees` is fixed by `_split` (`:778-779`) before the ratio is applied.

**If violated** — Commission drifts from 10% of realized fees (either direction); `getPosition.commissionAccrued` would misreport charges.

---

#### I-3

`Bound` · On-chain: **Yes**

> `commissionRemainder0/1 ∈ [0, 9999]` for every record (fits `uint16`; `fractional < 2 * BPS_DENOMINATOR`).

**Derivation** — guard-lift of `remainder = (fractional % BPS_DENOMINATOR).toUint16()` at `ValariRouterV3.sol:759`; the only write sites are `:780` and `:782`, both via `_commission`. `fractional = mulmod(fees,1000,10000) + previousRemainder ≤ 9999 + 9999`, so `fractional / BPS_DENOMINATOR ≤ 1`.

**If violated** — `SafeCast.toUint16` revert would brick every collect/exit on that position.

---

#### I-4

`StateMachine` · On-chain: **Yes**

> A record's `closed` flag is a one-shot latch: `false → true` via exit or eject, never back. A closed record can never be collected, exited or ejected again.

**Derivation** — edge: `closed=false (default at :367-375) → true @ :543` (`_exitPosition`) and `→ true @ :466` (`ejectPosition`); guard `if (record.closed) revert PositionClosed()` at `:745` precedes every transition. No write of `closed = false` exists in the file.

**If violated** — Double exit / double payout, or commission charged on a position Valari no longer holds.

---

#### I-5

`Conservation` · On-chain: **Yes**

> `_positionIds.length == Σ_d _depositorPositionIds[d].length`, and every record with `depositor != 0` appears exactly once in each.

**Derivation** — Δ-pair: `ValariRouterV3.sol:376 ↔ :377` (`_positionIds.push(tokenId)` and `_depositorPositionIds[msg.sender].push(tokenId)` in the same body, after the record is written at `:367-375`). Only write sites of both arrays; no pops or deletes.

**If violated** — `positionCount()` / `depositCount()` / `getUserPositions` pagination disagree with `getPosition`.

---

#### I-6

`Conservation` · On-chain: **Yes**

> Catalog is append-only and consistent: `_poolIds.length == Σ_s _stockPoolIds[s].length`, and `_pools[id].tickSpacing != 0 ⇔ id ∈ _poolIds`. No listed pool is ever removed or changed.

**Derivation** — Δ-pair: `ValariRouterV3.sol:855 ↔ :856 ↔ :857` (`_pools[id] = key`, `_poolIds.push(id)`, `_stockPoolIds[stock].push(id)` in `_addPool`), guarded by G-27 against re-listing. These are the only write sites of the three structures; no `delete`, `pop`, or re-assignment exists. NatSpec at `:252-254` states the same ("Append-only: listed pools can never be removed or changed").

**If violated** — An open position's `_pools[record.poolId]` could change under it, breaking the token0/token1 assignment used by every payout.

---

#### I-7

`Bound` · On-chain: **Yes**

> `feeRecipient ∉ {address(0), address(this)}` at all times.

**Derivation** — guard-lift of G-9 (`:385-387`) + write sites: `:243` (constructor, `msg.sender`, which cannot be zero or the contract under construction) and `:389` (guarded). No other write site.

**If violated** — Commission would be credited to a key nobody can withdraw from, or to the router itself (breaking balance-based payout measurement).

---

#### I-8

`Bound` · On-chain: **Yes**

> Every listed pool key is sorted, has code on both currencies *at listing time*, has USDG on exactly one side, has no hooks, a tick spacing in `[MIN_TICK_SPACING, MAX_TICK_SPACING]`, a non-protocol stock, and was initialised in the PoolManager at listing time.

**Derivation** — guard-lift of G-27..G-30 (`:837-854`) + write site enumeration: `_pools[id] = key` at `:855` is the single write site and is reached only after those guards. Constructor (`:246-248`) and `addPool` (`:255-257`) both route through `_addPool`.

**If violated** — A hooked pool would let a hook run between the exit's principal snapshot and burn (`:528-552`), invalidating the fee split; a protocol contract as "stock" would receive ERC20 selectors (`approve`, `transfer`) with foreign meaning.

---

#### I-9

`Bound` · On-chain: **Yes**

> `depositsDisabled[p] || ejectEnabled[p] ⇒ p is listed` — flags exist only for catalogued pools.

**Derivation** — guard-lift of `getPoolKey(poolId)` (G-21) at `:263` and `:273`, which precede the only write sites `:264` and `:274`. (The flags themselves are togglable and therefore not state-machine invariants.)

**If violated** — Harmless on its own; included because `ejectEnabled` is the only key to the escape hatch and auditors should know it cannot be pre-set for a not-yet-listed pool.

---

#### I-10

`Bound` · On-chain: **Yes**

> The router's balance of any token never decreases across an LP operation, and decreases by exactly the withdrawn amount (within +2 units) across a commission withdrawal: `Δbalance(open) == 0`; `Δbalance(collect|exit) ∈ [commission, commission + 2]`; `Δbalance(withdrawCommission) ∈ [−amount, −amount + 2]`.

**Derivation** — guard-lift across every function that moves tokens: `_pull` G-32 (`:902-904`, exact), `_refund` G-33 (`:919-927`, exact restore), `_distribute` G-23 + G-26 (`:775`, `:796-797`), `withdrawCommission` G-26 via `_checkRetained(currency, beforeBalance - amount)` (`:411`). No other function transfers tokens out (`safeTransfer` call sites: `:410`, `:794-795`, `:924`).

**If violated** — Commission reserves or earlier dust could be paid out to a user or refunded to a depositor.

---

#### I-11

`Bound` · On-chain: **Yes**

> `ejectEnabled[p] == true` is the only state in which a position in pool `p` can leave router custody without being burned.

**Derivation** — guard-lift of G-13 (`:464`): the single `transferFrom` of the NFT (`:467`) sits behind it; the only other custody-changing path is `BURN_POSITION` at `:547-552` (G-17 confirms burn). No `approve`/`setApprovalForAll`/`permit` call on the PositionManager exists in the file.

**If violated** — A position could be moved out of custody with its uncollected fees uncharged while the owner had not enabled eject.

---

**Temporal scan**: every `block.timestamp` comparison (`:307`, `:477`, `:522`) involves only the `deadline` parameter; `record.openedAt` (`:370`) is written but never compared. No temporal invariant over storage exists.

---

## 3. Inferred Invariants (Cross-Contract)

Trust assumptions that span contract boundaries. Blocks X-1..X-3 cite vendored Uniswap code; X-4..X-5 are script↔router pairs inside scope; X-6 is the one assumption that is enforced only up to a tolerance.

---

#### X-1

On-chain: **Yes**

> While a record is open (`depositor != 0 && !closed`), `PositionManager.ownerOf(tokenId) == router`, and the NFT cannot leave the router except through a router-originated call.

**Caller side** — `ValariRouterV3.sol:746`, `:497`, `:356`: every collect/exit/eject and the post-mint check re-verify custody. The router never calls `approve`, `setApprovalForAll` or `subscribe` on the PositionManager.

**Callee side (vendored)** — `lib/v4-periphery/src/PositionManager.sol:549` (`transferFrom` requires owner/approved), `lib/v4-periphery/src/base/ERC721Permit_v4.sol:27` (`permit` needs the owner's signature; for a contract owner it falls to EIP-1271, and the router exposes no `isValidSignature` or fallback — `test/ValariRouterLiveCustodyProbe.t.sol:95-115` probes this). `subscribe` is `onlyIfApproved` (`lib/v4-periphery/src/base/Notifier.sol:40-44`).

**If violated** — An outsider could withdraw a custodied position directly on Uniswap, bypassing beneficiary checks and commission.

---

#### X-2

On-chain: **Yes**

> The `amount0Min/amount1Min` the router forwards in `BURN_POSITION` are applied by the PositionManager to *principal only* (`liquidityDelta − feesAccrued`), matching the router's own pre-burn principal check.

**Caller side** — `ValariRouterV3.sol:536-538` (router check on `_amounts(price, …, roundUp=false)`), `:545` (same mins forwarded).

**Callee side (vendored)** — `lib/v4-periphery/src/PositionManager.sol:445` `(liquidityDelta - feesAccrued).validateMinOut(amount0Min, amount1Min)` in `_burn`.

**If violated** — If the PM applied mins to principal+fees, a stale-min exit could pass the PM but the router's split would misclassify fees; if the router's snapshot price could differ from the burn price, `_split` (G-24) would revert or misattribute.

---

#### X-3

On-chain: **Yes**

> `tokenId = positionManager.nextTokenId()` sampled at `:349` is the ID minted by the immediately following `modifyLiquidities`.

**Caller side** — `ValariRouterV3.sol:349-360`: sampled after all token callbacks, then `nextTokenId() == tokenId + 1` and `ownerOf(tokenId) == this` asserted (G-8).

**Callee side (vendored)** — `lib/v4-periphery/src/PositionManager.sol:353-369` (`_mint` uses `nextTokenId++`). Self-validating: a reentrant mint between sample and mint cannot occur (router `nonReentrant`, PM `unlock` single-entry).

**If violated** — The router would record the wrong tokenId as the user's position.

---

#### X-4

On-chain: **Yes**

> `AddValariRouterV3Pools` treats a `getPoolKey(id)` revert as "pool not listed" and a success as "listed".

**Caller side** — `AddValariRouterV3Pools.s.sol:50-53` (`try router.getPoolKey(ids[i]) … catch { missing[i] = true; }`).

**Callee side** — `ValariRouterV3.sol:599-602` reverts iff `_pools[poolId].tickSpacing == 0`; the only writer `:855` stores a key with `tickSpacing ≥ MIN_TICK_SPACING ≥ 1` (G-28 at `:843`).

**If violated** — The script would re-add a listed pool (reverting on `DuplicatePool`) or skip a missing one.

---

#### X-5

On-chain: **Yes**

> After `new ValariRouterV3(manager, state, usdg, keys)`, `poolCount() == 100` and `getPoolIds(i,1)[0] == ids[i]` in catalog order.

**Caller side** — `DeployValariRouterV3.s.sol:46-49`.

**Callee side** — `ValariRouterV3.sol:246-248` (constructor loop pushes in input order via `:856`).

**If violated** — Deployment aborts post-broadcast (the router is already on-chain; the script's `require` only fails the run).

---

#### X-6

On-chain: **No** (enforced up to `MAX_PAYOUT_DUST = 2` raw units)

> A token's reported `balanceOf` deltas are the truth of what was transferred on the router's outbound leg.

**Caller side** — `ValariRouterV3.sol:825-830` (`_checkRetained`), used at `:411`, `:796-797`: a surplus of ≤ 2 units over the expected retained balance is accepted as rounding dust. `_pull`/`_refund` (`:902`, `:925`) remain exact on the inbound/refund legs.

**Callee side** — The USDG/stock contracts are issuer-upgradeable proxies outside this repository (no in-scope write sites). The tolerance therefore cannot distinguish "token rounded 1–2 units" from "token moved nothing and the payout was 1–2 units" (documented in README §V3 and `audit/2026-10-05-v3/trailofbits/differential-review.md` I-1).

**If violated** — Bounded: at most 2 raw units per token per payout, borne by the caller; the surplus stays in the router as unclaimable dust (there is no sweep function).

---

## 4. Economic Invariants

---

#### E-1

On-chain: **Yes**

> Commission liabilities are fully backed: `balanceOf(router, t) ≥ totalClaimableCommission[t]` for every token, assuming no party other than the router can debit the router's balance.

**Follows from** — `I-1` + `I-10` + `G-12`. Each accrual (`:792-793`) is paired with `_checkRetained(token, before + commission)` (`:796-797`), so the balance rises by at least the accrued amount; withdrawals reduce balance and liability together.

**If violated** — Only by an external debit (issuer seize/burn/upgrade of the router's balance); then G-12 makes every `withdrawCommission` for that token revert until the balance is restored. User payouts are unaffected (they are measured against pre-op balance, G-23).

---

#### E-2

On-chain: **Yes**

> Over a position's life the treasury is credited exactly `floor(Σ realized fees / 10)` per currency, and never anything on principal or deposits.

**Follows from** — `I-2` (ratio with carry) + `G-24` (`_split` sets `fees = received − principal`, or `0` on a ≤2-unit shortfall) + `X-2` (the PM delivers principal exactly as snapshotted).

**If violated** — Either the user is overcharged on principal or the treasury under-collects relative to the README's 10% claim.

---

#### E-3

On-chain: **Yes** (within the X-6 tolerance)

> A beneficiary who exits receives 100% of principal and 90% of newly realized fees, minus at most 2 raw units per token.

**Follows from** — `E-2` + `I-10` (payout cannot draw on reserves, reserves cannot absorb the payout) + `X-6` (bounded dust). `payout.amount = received − commission` at `:784-785`.

**If violated** — Beyond the 2-unit bound, G-26 reverts and the position stays open (recoverable via retry, `*To` payout, or eject).

---

#### E-4

On-chain: **Yes**

> A position that was exited or ejected never accrues further commission, and an ejected holder owes Valari nothing.

**Follows from** — `I-4` (closed latch) + `G-22` (every accruing path requires `!closed`). The only accrual site `_distribute` is reachable solely from `_collectFees`/`_exitPosition`, both gated by `_ownedPosition`.

**If violated** — Valari would be charging on a position it no longer custodies.

---

#### E-5

On-chain: **Yes**

> No owner-gated function can move, redirect, freeze or re-price a user's position or token balance; owner powers are limited to catalog growth, per-pool deposit stop, per-pool eject enable, and the destination of *future* commission.

**Follows from** — `I-6` (addPool only appends), `I-9` (flags only), `I-7` (recipient bound), `I-11` (custody leaves only via eject, which the *beneficiary* must call). The four `onlyOwner` functions (`:255`, `:262`, `:272`, `:384`) write no `_deposits` field and make no token or NFT transfer. (README claim at `:173-175` is confirmed per code.)

**If violated** — The README's trust model ("none of them can move, redirect or freeze a user's position or funds") would be false. Note: `setDepositsDisabled(true)` plus a never-enabled eject does leave *future* deposits stopped and, if the router is blocklisted, existing positions stuck — that is an availability dependency on the owner, not a fund-movement power.
