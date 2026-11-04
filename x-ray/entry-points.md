# Entry Point Map

> ValariRouterV3 | 14 entry points | 1 permissionless | 7 role-gated | 6 admin-only

All functions below are in `src/ValariRouterV3.sol` unless noted. `transferOwnership`, `acceptOwnership` and `renounceOwnership` are inherited from OpenZeppelin `Ownable2Step`/`Ownable` 5.0.2. The two scripts are off-chain operator entry points and are listed at the end.

Note on the grep scan: the skill's two signature greps surfaced 7 of the 11 non-view functions declared in `ValariRouterV3.sol`; `openPosition:292`, `collectFees:417`, `collectFeesTo:427` and `exitPosition:438` put `external` on its own line and were classified from the source read.

---

## Protocol Flow Paths

### Setup (Deployer → Owner)

`DeployValariRouterV3.run()` → `constructor(pm, stateView, usdg, keys[100])`  ◄── chainid 4663, catalog IDs match keys
        → `[AddValariRouterV3Pools.run()` → `addPool(key)`]*  ◄── signer must be owner; skips listed pools
        → (optional) `transferOwnership(new)` → `acceptOwnership()`  ◄── feeRecipient does NOT follow ownership

### Depositor Flow

`[setup above]` → ERC20.approve(router) ×2  ◄── off-chain, user's wallet
        → `previewDeposit()` (view)  ◄── derive minLiquidity + sqrtPrice bounds from this + an independent reference
        → `openPosition()`  ◄── !depositsDisabled[pool], pool price within bounds, price unchanged at mint
            ├─→ `collectFees()` / `collectFeesTo(to)`  (repeatable; liquidity stays)
            ├─→ `exitPosition()` / `exitPositionTo(to)`  ◄── principal ≥ mins → record.closed, NFT burned
            └─→ `ejectPosition(to)`  ◄── owner called `setEjectEnabled(pool, true)` → record.closed, NFT to `to`

### Treasury Flow

`[collectFees / exitPosition above]` → `claimableCommission[feeRecipient][token] += 10% of fees`
        → `withdrawCommission(token, to, amount)`  ◄── caller's own credit; router balance ≥ totalClaimableCommission

### Owner Maintenance

`[setup above]` → `addPool()` | `setDepositsDisabled()` | `setEjectEnabled()` | `setFeeRecipient()`  (all instant, no timelock)

---

## Permissionless

### `ValariRouterV3.openPosition()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (`:292-306`) |
| Caller | Depositor (any EOA or contract; `msg.sender` becomes the permanent beneficiary) |
| Parameters | poolId (user-controlled), amount0Max / amount1Max (user-controlled), tickLower / tickUpper (user-controlled), minLiquidity (user-controlled, nonzero), sqrtPriceMinX96 / sqrtPriceMaxX96 (user-controlled), deadline (user-controlled) |
| Call chain | `→ getPoolKey() → previewDeposit() → StateView.getSlot0() → LiquidityAmounts.getLiquidityForAmounts() → _pull(token0) → _pull(token1) [IERC20.safeTransferFrom sender→router] → _approve() ×2 [IERC20.forceApprove(permit2), Permit2.approve(token, PositionManager, amount, 0)] → StateView.getSlot0() (re-read, must equal quote) → PositionManager.nextTokenId() → PositionManager.modifyLiquidities(MINT_POSITION + SETTLE_PAIR) [PM: Permit2.transferFrom router→PoolManager] → IERC721.ownerOf / getPositionLiquidity / nextTokenId (verify) → _approve(0) ×2 → _refund() ×2 [IERC20.safeTransfer router→sender]` |
| State modified | `_deposits[tokenId]` (new record: poolId, depositor, openedAt, ticks, initialLiquidity, amounts), `_positionIds.push`, `_depositorPositionIds[msg.sender].push` |
| Value flow | in: up to amount0Max/amount1Max of currency0/currency1 sender → router → PoolManager; out: unspent budget router → sender (same tx) |
| Reentrancy guard | yes |

---

## Role-Gated

### Beneficiary (`_deposits[tokenId].depositor == msg.sender`, enforced in `_ownedPosition:741-747`)

#### `ValariRouterV3.collectFees()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (`:417-423`) |
| Caller | Beneficiary of `tokenId` |
| Parameters | tokenId (user-controlled, must be theirs), deadline (user-controlled) |
| Call chain | `→ _collectFees(tokenId, msg.sender, deadline) → _ownedPosition() [IERC721.ownerOf] → _checkRecipient() → IERC20.balanceOf ×2 → PositionManager.getPositionLiquidity() → PositionManager.modifyLiquidities(DECREASE_LIQUIDITY(0) + TAKE_PAIR → router) → getPositionLiquidity / ownerOf (verify) → _distribute() → _split() ×2 → _commission() ×2 → _accrueCommission() ×2 → IERC20.safeTransfer(to) ×2 → _checkRetained() ×2` |
| State modified | `record.commissionRemainder0/1`, `record.feesCollected0/1`, `record.commissionAccrued0/1`, `claimableCommission[feeRecipient][token0/1]`, `totalClaimableCommission[token0/1]` |
| Value flow | PoolManager → router (gross fees); router → beneficiary (90% of fees); 10% retained in router as credit |
| Reentrancy guard | yes |

#### `ValariRouterV3.collectFeesTo()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (`:427-433`) |
| Caller | Beneficiary of `tokenId` |
| Parameters | tokenId (user-controlled), to (user-controlled; ≠ 0, ≠ router), deadline (user-controlled) |
| Call chain | identical to `collectFees` with `to` as the payout destination |
| State modified | as `collectFees` |
| Value flow | PoolManager → router; router → `to` (90% of fees) |
| Reentrancy guard | yes |

#### `ValariRouterV3.exitPosition()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (`:438-444`) |
| Caller | Beneficiary of `tokenId` |
| Parameters | tokenId (user-controlled), amount0Min / amount1Min (user-controlled, principal-only), deadline (user-controlled) |
| Call chain | `→ _exitPosition(tokenId, msg.sender, …) → _ownedPosition() → _checkRecipient() → PositionManager.getPositionLiquidity() → StateView.getSlot0() → _amounts() (principal snapshot) → IERC20.balanceOf ×2 → PositionManager.modifyLiquidities(BURN_POSITION(mins) + TAKE_PAIR → router) → _ownerOf() (must be 0) → _distribute() → … → IERC20.safeTransfer(to) ×2 → _checkRetained() ×2` |
| State modified | `record.closed = true` (before the burn), plus all `_distribute` fields as in `collectFees` |
| Value flow | PoolManager → router (principal + fees); router → beneficiary (principal + 90% fees); 10% of fees retained as credit |
| Reentrancy guard | yes |

#### `ValariRouterV3.exitPositionTo()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (`:448-456`) |
| Caller | Beneficiary of `tokenId` |
| Parameters | tokenId (user-controlled), to (user-controlled; ≠ 0, ≠ router), amount0Min / amount1Min (user-controlled), deadline (user-controlled) |
| Call chain | identical to `exitPosition` with `to` as destination |
| State modified | as `exitPosition` |
| Value flow | router → `to` (principal + 90% fees) |
| Reentrancy guard | yes |

#### `ValariRouterV3.ejectPosition()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (`:462-470`) |
| Caller | Beneficiary of `tokenId`, only when `ejectEnabled[record.poolId]` |
| Parameters | tokenId (user-controlled), to (user-controlled; ≠ 0, ≠ router; receives the NFT via `transferFrom`, no ERC721 receiver check) |
| Call chain | `→ _ownedPosition() → _checkRecipient() → IERC721(PositionManager).transferFrom(router, to, tokenId) → _ownerOf() (must be to)` |
| State modified | `record.closed = true` |
| Value flow | none (NFT custody router → `to`; uncollected fees travel with the NFT, uncharged) |
| Reentrancy guard | yes |

### Commission recipient (`claimableCommission[msg.sender][token] ≥ amount > 0`, `:400-401`)

#### `ValariRouterV3.withdrawCommission()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (`:396-413`) |
| Caller | Any address holding credit for `token` (current or former `feeRecipient`) |
| Parameters | token (user-controlled), to (user-controlled; ≠ 0, ≠ router), amount (user-controlled, ≤ credit) |
| Call chain | `→ IERC20.balanceOf(router) → IERC20.safeTransfer(to, amount) → _checkRetained()` |
| State modified | `claimableCommission[msg.sender][token] -= amount`, `totalClaimableCommission[token] -= amount` (both before the transfer) |
| Value flow | router → `to` |
| Reentrancy guard | yes |

### Pending owner (`Ownable2Step`)

#### `ValariRouterV3.acceptOwnership()` (inherited)

| Aspect | Detail |
|--------|--------|
| Visibility | public, no reentrancy guard (`lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol:52`) |
| Caller | `pendingOwner()` only |
| Parameters | none |
| Call chain | `→ Ownable2Step._transferOwnership()` |
| State modified | `_owner`, `_pendingOwner = 0` |
| Value flow | none |
| Reentrancy guard | no |

---

## Admin-Only

All `onlyOwner`; the four router functions are also `nonReentrant`. No timelock, no multisig requirement, no pause modifier anywhere in the contract. The deploy script leaves the deployer EOA as both owner and `feeRecipient`.

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| ValariRouterV3 | `addPool(key)` `:255` | key (owner-provided PoolKey; validated G-27..G-30) | `_pools[id]`, `_poolIds`, `_stockPoolIds[stock]` (append-only) |
| ValariRouterV3 | `setDepositsDisabled(poolId, disabled)` `:262` | poolId (listed), disabled (bool) | `depositsDisabled[poolId]` |
| ValariRouterV3 | `setEjectEnabled(poolId, enabled)` `:272` | poolId (listed), enabled (bool) | `ejectEnabled[poolId]` |
| ValariRouterV3 | `setFeeRecipient(newRecipient)` `:384` | newRecipient (≠ 0, ≠ router) | `feeRecipient` (future accrual only; existing credits stay with old recipient) |
| ValariRouterV3 (Ownable2Step) | `transferOwnership(newOwner)` | newOwner | `_pendingOwner` |
| ValariRouterV3 (Ownable) | `renounceOwnership()` | none | `_owner = 0`, `_pendingOwner = 0` — permanently removes addPool / setDepositsDisabled / setEjectEnabled / setFeeRecipient |

---

## Deployment Scripts (off-chain operator entry points)

| Script | Function | Reads | On-chain effect |
|--------|----------|-------|-----------------|
| `script/DeployValariRouterV3.s.sol` | `run()` | `VALARI_POOLS_CONFIG` (default `config/robinhood.json`); requires chainid 4663, exactly 100 pools, IDs match keys, manager/Permit2 addresses match config | `new ValariRouterV3(manager, stateView, usdg, keys)`; deployer = owner = feeRecipient; no ownership transfer |
| `script/AddValariRouterV3Pools.s.sol` | `run()` | `VALARI_ROUTER_V3`, same config; probes `MAX_PAYOUT_DUST()` to reject non-V3 routers; checks manager/stateView/usdg match | `router.addPool(key)` for each catalog pool not yet listed (idempotent; signer must be owner) |

No proxy, no `initialize()`; the constructor is the only one-time entry point.
