# 🔐 Security Review — valari-contracts

---

## Scope

|  |  |
| --- | --- |
| **Mode** | filename |
| **Files reviewed** | `src/ValariRouterV3.sol` · `script/DeployValariRouterV3.s.sol` · `script/AddValariRouterV3Pools.s.sol` |
| **Confidence threshold (1-100)** | 75 |

---

## Findings

_None — this scan raised no findings._

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **addPool accepts a pool that anyone initialized at any price** — `ValariRouterV3._addPool` — Code smells: `_addPool` accepts any key whose `sqrtPriceX96 != 0`; anyone can call `PoolManager.initialize` for a (USDG, stock, fee, tickSpacing) key before the owner lists it and choose the initial price; `previewDeposit` returns that pool's own `sqrtPriceX96`, which a user may centre the price bounds on. — An attacker initializes a pool at a chosen price before the owner lists it, so a user who trusts the quote deposits at that price. The NatSpec warns about thin pools, so the remaining gap is a user who follows the quote.
- **openPosition sends a zero approve to both pool tokens** — `ValariRouterV3._approve` — Code smells: `openPosition` always ends with `_approve(token0, 0)` and `_approve(token1, 0)` and also calls `_approve(token, 0)` for a zero budget; `SafeERC20.forceApprove` with value 0 on a token that reverts on `approve(spender, 0)` retries `approve(spender, 0)` and reverts again; the listed tokens are upgradeable proxies whose `approve` behaviour is not in the repository. — A token that rejects a zero approval blocks every deposit into its pool. We did not verify that any listed token rejects a zero approval.
- **ejectPosition moves uncollected fees out with no commission** — `ValariRouterV3.ejectPosition` — Code smells: `ejectPosition` sets `record.closed = true` and transfers the NFT without a prior `DECREASE_LIQUIDITY(0) + TAKE_PAIR`, so `_distribute` and `_accrueCommission` never run for the fees the position still holds; `ejectEnabled` is pool-wide, so it also covers depositors the router can still pay; the NatSpec on line 461 states that Valari charges nothing from then on. — When the owner enables eject for a pool, every depositor in that pool can take uncollected fees out with no commission. The NatSpec accepts this, so we did not confirm it is unintended.
- **An issuer block of the router leaves exit to the owner alone** — `ValariRouterV3.ejectPosition` — Code smells: `_collectFees` and `_exitPosition` move tokens through the router and revert when the stock issuer blocks or pauses the router; the only path that moves no tokens is `ejectPosition`, which reverts with `EjectDisabled` until the owner calls `setEjectEnabled`; `renounceOwnership` stays callable and no timelock or depositor-triggered fallback exists. — If an issuer blocks the router and the owner cannot act, every depositor in that pool keeps no exit. We did not verify that an issuer blocks the router.
- **exitPositionTo pays a blocklisted depositor at any address** — `ValariRouterV3.exitPositionTo` — Code smells: `_ownedPosition` authorizes on `record.depositor == msg.sender` only; the stock blocklist is evaluated against the router as sender and `to` as receiver, never against the beneficiary; `exitPositionTo`, `collectFeesTo` and `ejectPosition` accept any `to` other than zero and the router. — A depositor that the issuer blocklisted can still send the stock to any address through the router, because the router checks only the depositor record. We could not verify the issuer policy.
- **getPosition takes the range flag and the amounts from different sources** — `ValariRouterV3._positionView` — Code smells: `p.inRange = tick >= p.tickLower && tick < p.tickUpper` uses `slot0.tick`, while `p.amount0`, `p.amount1` and the exit principal branch on `sqrtPriceX96`; after a zeroForOne swap that stops at `getSqrtPriceAtTick(tickUpper)`, v4 stores `tick = tickUpper - 1`, so the view reports `inRange == true` with `amount0 == 0`. — At a tick boundary the view reports the position as in range while its amounts are one-sided, so off-chain readers see two answers. No tokens move on this path.
- **setEjectEnabled leaves deposits open on an eject-enabled pool** — `ValariRouterV3.setEjectEnabled` — Code smells: `setEjectEnabled(poolId, true)` does not set `depositsDisabled[poolId]`, and `openPosition` checks only `depositsDisabled`; a depositor can open a position on an eject-enabled pool, wait for fees, then eject and collect them on Uniswap with no commission. — A depositor opens a position on a pool where eject is enabled, then ejects it, so the depositor pays no commission. We did not verify a token that blocks only outbound transfers from the router.
- **MAX_PAYOUT_DUST is two raw units for every token decimal** — `ValariRouterV3._split` — Code smells: `MAX_PAYOUT_DUST = 2` raw units applies the same to USDG (6 decimals) and to the stock (18 decimals); a listed stock whose proxy rounds a transfer by more than 2 wei makes `_split` revert `InsufficientProceeds` and `_checkRetained` revert `UnsupportedToken` on every exit and collect for that pool. — The depositor cannot exit or collect when the stock token delivers more than two units short, until the owner enables eject. We found no listed token that rounds this way.
- **Commission withdrawal reverts for every recipient when the router balance is short** — `ValariRouterV3.withdrawCommission` — Code smells: `if (beforeBalance < total) revert InsufficientProceeds();` compares the whole router balance of `token` with `totalClaimableCommission[token]`, not with the caller's `amount`; nothing in the router lowers `totalClaimableCommission` except a successful withdrawal, and `_checkRetained(currency, beforeBalance - amount)` already protects each payout. — An issuer that removes tokens from the router blocks every commission recipient, even one whose credit the remaining balance covers. We did not verify that any listed token exposes a seize, wipe or rebase function.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
