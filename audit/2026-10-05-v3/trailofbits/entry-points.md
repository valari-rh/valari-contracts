# Entry Point Analysis: ValariRouterV3

**Analyzed**: 2026-10-06 (re-applied; supersedes the 2026-10-05 report written against source `19d3d512…`)
**Scope**: `src/ValariRouterV3.sol` only (directory filter: this one file, plus the OpenZeppelin bases it inherits entry points from). `src/ValariRouter.sol`, `script/`, `test/` and `lib/` are out of scope.
**Languages**: Solidity 0.8.26 (via-IR, Cancun, optimizer 200)
**Focus**: State-changing functions only (view/pure excluded)
**Source SHA-256**: `f851cb15c188ddb2de32761b996799df856e56d7b9e1362ebbe1a4ac077e0b96`
**Method**: Trail of Bits `entry-point-analyzer` skill. Slither 0.11.6 `--print entry-points` (through the SafeCast scope-fix shim, `--disallow-partial`; raw output `printers/entry-points.txt`) as the foundation, then each restriction traced by hand to the code that enforces it. Cross-checked against the compiled ABI (14 non-view functions, no `payable`, no `receive`, no `fallback`; `abi/ValariRouterV3.json` equals the compiled ABI, 86 entries) and the custom Slither API check `printers/custom_checks.py` (output `printers/custom-checks.txt`, extended for the new switches and `ejectPosition`).

## What changed since the previous report

Five entry points were added: `setDepositsDisabled`, `setEjectEnabled` (owner), `collectFeesTo`, `exitPositionTo`, `ejectPosition` (recorded depositor). `collectFees` and `exitPosition` now delegate to private `_collectFees` / `_exitPosition` with the payout destination as a parameter; their access check is unchanged. No entry point was removed and no restriction was relaxed.

## Summary

| Category | Count | Previous |
|----------|-------|----------|
| Public (Unrestricted) | 2 | 2 |
| Role-Restricted | 6 | 4 |
| Restricted (Review Required) | 6 | 3 |
| Contract-Only | 0 | 0 |
| **Total** | **14** | **9** |

The constructor (`ValariRouterV3.sol:L222`) is a one-time initializer, not a recurring entry point, and is not counted. It sets `owner` and `feeRecipient` to the deployer and lists up to 100 pools through the same `_addPool` checks as `addPool`.

---

## Public Entry Points (Unrestricted)

State-changing functions callable by anyone—prioritize for attack surface analysis.

| Function | File | Notes |
|----------|------|-------|
| `openPosition(bytes32,uint128,uint128,int24,int24,uint128,uint160,uint160,uint256)` | `src/ValariRouterV3.sol:L292` | `nonReentrant`. No caller check; the caller becomes the recorded depositor (`record.depositor = msg.sender`, L369). No on-behalf-of parameter, so a caller can only create a record and grow the ID list for itself. New since the previous report: reverts `DepositsDisabled` when the owner has switched the pool off (L313), checked after the pool lookup and before any token is pulled, so a refused deposit moves nothing (`testOwnerStopsAndResumesDepositsForOnePool`). Pulls both budgets from `msg.sender`, sets Permit2 allowances valid for the current block only, mints the NFT to the router, refunds, then zeroes allowances. Writes `_deposits`, `_positionIds`, `_depositorPositionIds`. Highest complexity in the contract and the only entry point that calls untrusted token code before its main external action. |
| `withdrawCommission(address,address,uint256)` | `src/ValariRouterV3.sol:L396` | `nonReentrant`. No modifier or `msg.sender` revert; authority is implicit: it debits `claimableCommission[msg.sender][token]` (L400-401), so a caller with no credit reverts with `InsufficientCommission`. `token` is caller-supplied and unchecked against the catalog, but a credit can only exist for a token that a listed pool paid fees in. `to` may be any address except zero and the router. Writes `claimableCommission`, `totalClaimableCommission`. Unchanged. |

---

## Role-Restricted Entry Points

### Admin / Owner
| Function | File | Restriction |
|----------|------|-------------|
| `addPool((address,address,uint24,int24,address))` | `src/ValariRouterV3.sol:L255` | `onlyOwner`, `nonReentrant`. Append-only: writes `_pools`, `_poolIds`, `_stockPoolIds` through `_addPool` (L832), the only function that assigns them (custom check 6). |
| `setDepositsDisabled(bytes32,bool)` | `src/ValariRouterV3.sol:L262` | `onlyOwner`, `nonReentrant`. **New.** Reverts `InvalidPool` for an unlisted ID (L263). Writes `depositsDisabled[poolId]` only. The flag is read in exactly one place, `openPosition` L313 (custom check 8), so it cannot touch collection, exit or eject. Reversible. |
| `setEjectEnabled(bytes32,bool)` | `src/ValariRouterV3.sol:L272` | `onlyOwner`, `nonReentrant`. **New.** Same pool check. Writes `ejectEnabled[poolId]` only; read in exactly one place, `ejectPosition` L464 (custom check 8). Grants a right to that pool's depositors; gives the owner no call path to any position (custom check 3: no `onlyOwner` function has `_deposits` in its write set). Reversible. |
| `setFeeRecipient(address)` | `src/ValariRouterV3.sol:L384` | `onlyOwner`, `nonReentrant`. Writes `feeRecipient` only; rejects zero and the router. |
| `transferOwnership(address)` | `lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol:L35` | `onlyOwner` (inherited, not overridden by the router). Writes `_pendingOwner` only. |
| `renounceOwnership()` | `lib/openzeppelin-contracts/contracts/access/Ownable.sol:L76` | `onlyOwner` (inherited, not disabled). Sets `_owner` to zero and clears `_pendingOwner`; permanently removes `addPool`, `setFeeRecipient` and, new, both switches. After a renounce, eject can never be enabled for any pool and a disabled pool stays disabled. Already known to the owner. |

`onlyOwner` was traced, not assumed: `Ownable.onlyOwner` (Ownable.sol:L48) calls `_checkOwner` (L63), which reverts unless `owner() == _msgSender()`; `Context._msgSender` (Context.sol:L17) returns `msg.sender` and the router does not override it, so there is no trusted-forwarder path. The router overrides none of `owner`, `_checkOwner`, `_transferOwnership`. Confirmed by `testOnlyOwnerSetsPoolSwitchesAndOnlyForListedPools` (depositor and fee recipient rejected) and by the Manticore `outsider`, `treasury` and `pending` scenarios, whose symbolic selector set includes both setters (`audit/2026-10-05-v3/manticore/results/*.json`, 0 violations, same source hash).

### Governance
| Function | File | Restriction |
|----------|------|-------------|
| none | | |

### Guardian / Pauser
| Function | File | Restriction |
|----------|------|-------------|
| none | | `setDepositsDisabled` is the nearest thing: a per-pool deposit stop that leaves collection, exit and eject untouched. There is no global pause and no pause on exits. |

### Other Roles
| Function | File | Restriction | Role |
|----------|------|-------------|------|
| none | | | |

---

## Restricted (Review Required)

Functions with access control patterns that need manual verification. All six were reviewed; the outcome is in the last column. The five position functions share one check, `_ownedPosition` (L741-747): unknown ID, caller is not the recorded depositor, record closed, or NFT not held by the router each revert, in that order.

| Function | File | Pattern | Why Review |
|----------|------|---------|------------|
| `collectFees(uint256,uint256)` | `src/ValariRouterV3.sol:L417` | `_ownedPosition` at L476 (`record.depositor != msg.sender` → `NotPositionOwner`). | Dynamic role (the recorded depositor of that token ID), not a modifier. Reviewed: `record.depositor` is written once, at L369, after the mint is verified, and no function reassigns it. The owner has no path around the check. Payout goes to `msg.sender` (L422). |
| `collectFeesTo(uint256,address,uint256)` | `src/ValariRouterV3.sol:L427` | Same `_ownedPosition`; destination `to` checked by `_checkRecipient` (L478, L817-819: not zero, not the router). | **New.** Same caller as `collectFees`; only the destination differs. Reviewed: the check runs before any external call; `to` is not stored, so it cannot leak into a later operation. Write set identical to `collectFees` (custom check 10). `testBeneficiaryWhoCannotReceiveATokenIsPaidAtAnotherAddress` shows a third party cannot redirect another depositor's payout. |
| `exitPosition(uint256,uint128,uint128,uint256)` | `src/ValariRouterV3.sol:L438` | `_ownedPosition` at L521. | Same review as `collectFees`. Sets `record.closed = true` (L543) before the burn, so a second exit, collect or eject reverts with `PositionClosed`. |
| `exitPositionTo(uint256,address,uint128,uint128,uint256)` | `src/ValariRouterV3.sol:L448` | Same `_ownedPosition`; `_checkRecipient` at L523. | **New.** As `collectFeesTo`. The record is closed and the NFT burned before the payout to `to`; a failed transfer to `to` reverts the whole call, leaving the position open and retryable to another address. |
| `ejectPosition(uint256,address)` | `src/ValariRouterV3.sol:L462` | `_ownedPosition` at L463, then `ejectEnabled[record.poolId]` (L464), then `_checkRecipient(to)` (L465). | **New.** Two-key: the owner's per-pool switch and the depositor's call. Reviewed: closes the record (L466) before the only external call, `IERC721.transferFrom(router, to, tokenId)` on the PositionManager (L467), then requires `ownerOf == to` (L468). The PositionManager's `transferFrom` (`lib/v4-periphery/src/PositionManager.sol:L549-552`) is solmate's, with no receiver callback, and unsubscribes only if a subscriber exists; the router never subscribes and `subscribe` is `onlyIfApproved`, so no third-party hook can run. Moves no ERC20 (custom check 9: the function's only high-level calls are `IERC721.transferFrom` and `IERC721.ownerOf`; it writes only `_deposits`). No `deadline` parameter, and none is needed: nothing in it is price-sensitive. |
| `acceptOwnership()` | `lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol:L52` | Inline: reverts unless `pendingOwner() == _msgSender()`. | No modifier. Reviewed: standard OpenZeppelin 5.0.2 two-step acceptance; only the address the current owner nominated can call it. Writes `_owner` and `_pendingOwner` and nothing else; `feeRecipient` does not follow the ownership. |

---

## Contract-Only (Internal Integration Points)

Functions only callable by other contracts—useful for understanding trust boundaries.

| Function | File | Expected Caller |
|----------|------|-----------------|
| none | | |

Verified by search, not assumed. The router declares no `onERC721Received`, `unlockCallback`, `isValidSignature`, hook, `multicall`, `permit`, `receive` or `fallback`. Consequences:

- The v4 PositionManager mints with solmate `_mint`, not `_safeMint` (`lib/v4-periphery/src/PositionManager.sol:L369`), so the router needs no ERC721 receiver. A `safeTransferFrom` of a foreign NFT to the router reverts; a plain `transferFrom` succeeds but changes no router state. New since eject: an NFT the router ejected can be sent back to it by its holder with `transferFrom`; the record is `closed`, so every entry point reverts with `PositionClosed` and the NFT is stranded (probe `testProbeEjectedNftReturnedToRouterIsStranded`, shadow project). Same class as the known "no sweep for stray NFTs"; the sender alone loses.
- The router never calls `PoolManager.unlock` itself; it goes through `PositionManager.modifyLiquidities`, so the PoolManager never calls back into the router.
- With no `isValidSignature`, nobody can produce an ERC-1271 signature for the router, so `PositionManager.permit` / `permitForAll` and Permit2's signature paths cannot be used against the NFTs or allowances it holds.
- The router never calls `subscribe`, so the PositionManager's notifier never calls a subscriber on its positions, including during an eject transfer.

---

## Trust boundaries reached from the entry points

| Entry point | External contracts called (state-changing calls in bold) |
|-------------|----------------------------------------------------------|
| `addPool` | StateView `getSlot0` |
| `setDepositsDisabled`, `setEjectEnabled` | none (storage read of `_pools` through `getPoolKey`) |
| `openPosition` | StateView `getSlot0` (twice); token0/token1 **`transferFrom`**, **`approve`**, **`transfer`**, `balanceOf`; Permit2 **`approve`**; PositionManager `nextTokenId`, **`modifyLiquidities`** (MINT_POSITION + SETTLE_PAIR), `ownerOf`, `getPositionLiquidity` |
| `collectFees`, `collectFeesTo` | PositionManager `ownerOf`, `getPositionLiquidity`, **`modifyLiquidities`** (DECREASE_LIQUIDITY with zero liquidity + TAKE_PAIR); token0/token1 `balanceOf`, **`transfer`** (to `msg.sender` / to `to`) |
| `exitPosition`, `exitPositionTo` | PositionManager `ownerOf`, `getPositionLiquidity`, **`modifyLiquidities`** (BURN_POSITION + TAKE_PAIR); StateView `getSlot0`; token0/token1 `balanceOf`, **`transfer`** (to `msg.sender` / to `to`) |
| `ejectPosition` | PositionManager `ownerOf`, **`transferFrom`** (ERC721). No ERC20 call. |
| `withdrawCommission` | caller-named token `balanceOf`, **`transfer`** |
| `setFeeRecipient`, `transferOwnership`, `acceptOwnership`, `renounceOwnership` | none |

PositionManager, PoolManager, StateView and Permit2 are immutables fixed in the constructor and treated as trusted. The token contracts are the untrusted side: every call to them sits inside a `nonReentrant` entry point and is bracketed by balance checks (`_pull` L899, `_refund` L914, `_distribute` L764, `_split` L803, `_checkRetained` L825). `ejectPosition` is the one position entry point that makes no token call at all, which is what lets it work when a token refuses the router.

## Observations from the entry-point pass

1. Every router-declared entry point (11) carries `nonReentrant`; the three inherited ownership functions do not. That is harmless: they touch only `_owner` / `_pendingOwner`, make no external call, and are reachable only by the owner or pending owner. Checked mechanically (custom check 1).
2. No entry point takes an arbitrary call target or calldata, and none is `payable` (custom check 5; Manticore `value`: 43 paths, all revert).
3. The state an unprivileged caller can write is limited to its own deposit record and ID list (`openPosition`), its own positions' accounting (`collectFees[To]`, `exitPosition[To]`, `ejectPosition`) and its own commission credit (`withdrawCommission`). The one cross-account write is the commission credited to `feeRecipient` during collect and exit, which is the intended flow. `ejectPosition` credits nothing.
4. The owner's entry points write the catalog, the two per-pool switches, the fee recipient and ownership, and nothing else (custom check 3). The two switches are the new owner powers: one can stop new deposits into a pool (a deposit-side pause, reversible, no effect on funds in custody); the other lets that pool's depositors leave custody with their NFT and uncollected fees (bypassing commission on those fees, known and by design). Neither gives the owner a call path to a position or a credit.
5. The payout destination (`to`) of the three new depositor functions is validated only against zero and the router itself (L817-819). That is the right invariant for the router (its own balance is the payout measurement), and any other destination is the depositor's own choice; a probe confirmed the PoolManager is accepted as `to` (`testProbePayoutToPoolManagerIsAccepted`), where ERC20s sent outside sync/settle are unrecoverable. Not a router defect; noted so the front end does not offer protocol addresses as destinations.

## Analysis Warnings

- Stock Slither 0.11.6 mis-resolves `using SafeCast for uint256` and fails to build the IR for `openPosition`, so anything it derives for that function is unreliable. The run used here goes through the scope-fix shim with `--disallow-partial` and lists all 14 entry points. The raw output is `printers/entry-points.txt`.
- Slither's `entry-points` printer reports modifiers only. It shows `collectFees[To]`, `exitPosition[To]`, `ejectPosition`, `withdrawCommission` and `acceptOwnership` with no access modifier; their restrictions are inline and were classified by reading the code. `vars-and-auth` (`printers/vars-and-auth.txt`) does list `record.depositor != msg.sender` as the condition for the five position functions, which agrees with the classification above.

## Files Analyzed

- `src/ValariRouterV3.sol` (11 state-changing entry points: `addPool`, `setDepositsDisabled`, `setEjectEnabled`, `openPosition`, `setFeeRecipient`, `withdrawCommission`, `collectFees`, `collectFeesTo`, `exitPosition`, `exitPositionTo`, `ejectPosition`)
- `lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol` (2 inherited: `transferOwnership`, `acceptOwnership`)
- `lib/openzeppelin-contracts/contracts/access/Ownable.sol` (1 inherited: `renounceOwnership`; its `transferOwnership` is overridden by Ownable2Step and not dispatchable)
- `lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol`, `lib/openzeppelin-contracts/contracts/utils/Context.sol` (0; modifier and `_msgSender` implementations read for the classification)
- `lib/v4-periphery/src/PositionManager.sol` (0; `transferFrom` L549-552 and `subscribe` read for the `ejectPosition` review)
