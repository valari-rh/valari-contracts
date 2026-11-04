# X-Ray Report

> ValariRouterV3 | 878 nSLOC (779 contract + 99 scripts) | no git history (directory is not a repository) | Foundry 0.8.26 / via-IR / Cancun | 06/10/26

> **Scope note.** The audit target is `src/ValariRouterV3.sol` plus `script/DeployValariRouterV3.s.sol` and `script/AddValariRouterV3Pools.s.sol`. `src/ValariRouter.sol` (655 nSLOC) is the previous, already-deployed router and is referenced only as lineage. The enumeration total of 1434 nSLOC includes that file. Dependencies are vendored under `lib/` at the revisions in `DEPENDENCIES.md`; where this report cites them it says so.

---

## 1. Protocol Overview

**What it does:** Custodies Uniswap v4 USDG/stock LP NFTs on Robinhood Chain for the depositor who minted them, pays that depositor on collect/exit, and skims 10% of realized LP fees into withdrawable treasury credits.

- **Users**: Depositors (any address) who fund a position in a listed pool and become its sole, non-transferable beneficiary; the fee recipient (treasury) who withdraws accrued commission credits.
- **Core flow**: `openPosition` pulls two budgets, mints a v4 position to the router at a user-bounded price, refunds the slack; `collectFees`/`exitPosition` realise fees (and principal) into the router, split them, pay the user, credit the treasury.
- **Key mechanism**: Balance-delta accounting against the router's own ERC20 balances (`_pull`/`_refund`/`_distribute`/`_checkRetained`) with a 2-raw-unit rounding tolerance on payouts; a pre-burn principal snapshot from `StateView.getSlot0` separates principal from fees.
- **Token model**: USDG (6 dec) paired with tokenized stocks (18 dec), either side may be `currency0`; both are issuer-upgradeable proxies with pause/blocklist (per README). No protocol token. The v4 LP NFT is held by the router; the depositor holds only a storage record.
- **Admin model**: Single `Ownable2Step` owner (deployer EOA, also initial `feeRecipient`). Four instant owner functions: `addPool` (append-only), `setDepositsDisabled`, `setEjectEnabled`, `setFeeRecipient`. No timelock, no multisig, no proxy, no global pause.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Router | ValariRouterV3 | 779 | Custody, deposit sizing/price bounds, payout split, commission credits, append-only catalog, eject |
| Deployment | DeployValariRouterV3, AddValariRouterV3Pools | 99 | Deploy with the 100-pool catalog; idempotently append catalog pools |

Lineage (not in scope): `ValariRouter` (V1, deployed twice on chain 4663). V3 is a ~300-line diff of V1 adding price bounds, append-only catalog, multi-tier-per-stock, dust tolerance, `*To` payouts, per-pool deposit stop and eject. The subgraph/frontend still consume the V1 ABI (per `audit/2026-10-05-v3/trailofbits/differential-review.md` I-3).

### How It Fits Together

The core trick: the router is the ERC721 owner of every position, so Uniswap's own access control (`onlyIfApproved`) is what stops users from bypassing the fee split — the router never approves, permits or subscribes, and it re-reads `ownerOf` on every path. Fees are never read from Uniswap; they are inferred as `received − snapshotted principal` from the router's balance deltas.

### Deposit

```
Depositor ─► openPosition(poolId, max0, max1, ticks, minLiq, sqrtMin, sqrtMax, deadline)
   ├─ previewDeposit()  ── StateView.getSlot0 → LiquidityAmounts         *quote at pool spot*
   ├─ bounds check: sqrtMin ≤ spot ≤ sqrtMax ; liquidity ≥ minLiq
   ├─ _pull(token0), _pull(token1)      ── safeTransferFrom, exact-delta check
   ├─ _approve ×2                       ── forceApprove(permit2) + permit2.approve(PM, amt, exp=0)
   ├─ StateView.getSlot0 again  ── must equal quote                      *closes callback window*
   ├─ tokenId = PM.nextTokenId()
   ├─ PM.modifyLiquidities(MINT_POSITION → router, SETTLE_PAIR)          *PM pulls via Permit2*
   ├─ verify ownerOf==router, liquidity==quote, nextTokenId==tokenId+1
   ├─ _approve(0) ×2 ; _refund ×2        ── router balance must return to pre-op exactly
   └─ _deposits[tokenId] = {depositor=msg.sender, …}                     *beneficiary fixed forever*
```

### Collect / Exit

```
Beneficiary ─► collectFees[To] / exitPosition[To]
   ├─ _ownedPosition: depositor==msg.sender, !closed, PM.ownerOf==router
   ├─ (exit only) price = getSlot0 ; principal = _amounts(price, ticks, liq, roundDown)
   │             require principal ≥ mins ; record.closed = true           *CEI before burn*
   ├─ before0/1 = balanceOf(router)
   ├─ PM.modifyLiquidities(DECREASE_LIQUIDITY(0) | BURN_POSITION(mins), TAKE_PAIR → router)
   ├─ verify liquidity unchanged & custody (collect) | ownerOf reverts (exit)
   └─ _distribute
        ├─ received = balance − before ; (principal, fees) = _split(received, principal)   *≤2-unit shortfall tolerated*
        ├─ commission = floor-with-carry(fees × 10%) ; record.feesCollected/commissionAccrued +=
        ├─ claimableCommission[feeRecipient][token] += ; totalClaimableCommission[token] +=
        ├─ safeTransfer(to, received − commission)
        └─ _checkRetained(token, before + commission)                         *held ∈ [expected, expected+2]*
```

### Eject (escape hatch)

```
Owner ─► setEjectEnabled(poolId, true)
Beneficiary ─► ejectPosition(tokenId, to)
   ├─ _ownedPosition ; require ejectEnabled[pool]
   ├─ record.closed = true
   └─ PM.transferFrom(router, to, tokenId) ; verify ownerOf==to      *no tokens move; fees travel uncharged*
```

### Treasury

```
feeRecipient (or any former recipient) ─► withdrawCommission(token, to, amount)
   ├─ require amount ≤ claimableCommission[msg.sender][token]
   ├─ require balanceOf(router) ≥ totalClaimableCommission[token]        *full backing gate*
   ├─ credit −= ; total −=  (effects first)
   └─ safeTransfer(to, amount) ; _checkRetained(token, before − amount)
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **DEX/AMM (concentrated-liquidity position custodian)** with **Vault/custody** characteristics

Signals: `sqrtPriceX96`, ticks, `LiquidityAmounts`, `modifyLiquidities`, LP fee accrual (DEX/AMM); the router holds user assets (LP NFTs) on their behalf with a fee skim and balance-delta accounting (vault-like custody). There is no swap, no share token, no oracle other than the pool's own spot, and no lending/leverage.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Owner (`Ownable2Step`) | Bounded (cannot touch positions, NFTs or balances — E-5) | 4 instant functions: `addPool` (append-only), `setDepositsDisabled`, `setEjectEnabled`, `setFeeRecipient` (future accrual only). Can `renounceOwnership` (inherited), which permanently disables all four. No timelock, no pause. |
| Fee recipient / former recipients | Bounded (own credits only — G-11) | `withdrawCommission` of own `claimableCommission` to any non-router address; blocked entirely for a token whenever router balance < aggregate liability (G-12). |
| Depositor / beneficiary | Bounded (own position only — G-22) | `openPosition` (anyone), then `collectFees[To]`, `exitPosition[To]`, `ejectPosition` on positions they opened; choose payout destination; cannot transfer beneficiary rights. |
| Token issuers (USDG, each stock) | Trusted-by-necessity, external | Upgradeable proxies with pause/blocklist (per README/AUDIT.md); can freeze the router or any user, change transfer semantics, or (in principle) debit the router's balance. |
| Uniswap v4 PositionManager / PoolManager / StateView / Permit2 | Trusted, immutable (per vendored source) | Custody and settlement; v4 protocol-fee controller can take a cut of LP fees. |

**Adversary Ranking** (ordered by threat level for this protocol type):

1. **Misbehaving or restricted listed token** — the only external code that runs inside every router path; its issuer's upgrade/pause/blocklist powers define what the router can and cannot pay out.
2. **Price-positioning searcher on a thin listed tier** — a stock may be listed under several fee tiers; the quote and bounds come from the chosen pool's own spot.
3. **Compromised or absent owner** — cannot steal, but controls the only escape hatch (`setEjectEnabled`) and the deposit stop, and can redirect future commission.
4. **Rogue beneficiary / recipient** — bounded to their own position or credit; the interesting cases are payout-destination choice under issuer blocklists and the 2-unit dust tolerance.

See [entry-points.md](entry-points.md) for the full entry point map.

### Trust Boundaries

- **Owner ↔ users** — no delay of any kind; the worst instant action is *inaction*: refusing `setEjectEnabled` on a pool whose token has blocklisted the router leaves positions unrecoverable through this contract (`setEjectEnabled:272`, `_ownedPosition:746`). Ownership transfer is two-step; `renounceOwnership` is not overridden.

- **Router ↔ listed tokens** — enforced by exact balance deltas on deposit (`_pull:902`, `_refund:925`) and by ±2-unit deltas on payout (`_checkRetained:827`, `_split:811`); nothing enforces token behaviour *between* calls (upgrades, pauses) — a changed token is handled only by `setDepositsDisabled` + eject.

- **Router ↔ Uniswap v4** — custody rests on the PositionManager's `onlyIfApproved` and on the router never granting approvals/permits (X-1); the fee split rests on the catalog being hookless (G-28) so nothing runs between the exit's principal snapshot and the burn (`:528-552`).

- **Beneficiary ↔ payout destination** — `collectFeesTo`/`exitPositionTo` let a beneficiary route value to any non-router address (`_checkRecipient:818`); no allow-list, no owner involvement.

### Key Attack Surfaces

- **Listed-token behaviour envelope on the payout leg** &nbsp;&#91;[X-6](invariants.md#x-6), [G-24](invariants.md#g-24), [G-26](invariants.md#g-26), [I-10](invariants.md#i-10)&#93; — `_split:803-813` and `_checkRetained:825-830` admit ≤2 raw units of shortfall/surplus per token per payout; worth tracing every combination of (inbound short, outbound unmade, outbound over-debit) on *both* currencies, including the `currency1 == stock` ordering, and confirming that dust left in the router is genuinely unreachable (there is no sweep).

- **Owner-dependent escape hatch with adverse incentive** &nbsp;&#91;[I-11](invariants.md#i-11), [I-9](invariants.md#i-9), [E-5](invariants.md#e-5)&#93; — `ejectPosition:462-470` is the only exit when a token restricts the router, it is gated on `ejectEnabled[pool]` (`:464`), it forfeits all uncollected commission, and `renounceOwnership` / a lost key removes the owner's ability to ever enable it. Worth confirming there is no owner-independent recovery and whether that is acceptable for an EOA owner.

- **Reference price for the deposit bounds is the listed pool's own spot** &nbsp;&#91;[G-5](invariants.md#g-5), [G-7](invariants.md#g-7), [I-8](invariants.md#i-8)&#93; — `previewDeposit:573-597` and `openPosition:314-320` compare `sqrtPriceMin/Max` against the same thin tier the user is about to LP into; the equality re-read at `:344-347` guarantees "mint at the quoted price", not "quoted price is fair". Worth tracing what a searcher can do by pre-positioning a low-liquidity second tier of a stock (`addPool` allows several per stock) before the user's quote, and how one-sided ranges interact with the bounds.

- **Principal/fee split depends on a pre-burn snapshot and exact v4 delivery** &nbsp;&#91;[X-2](invariants.md#x-2), [G-16](invariants.md#g-16), [E-2](invariants.md#e-2)&#93; — `_exitPosition:528-535` computes principal from `getSlot0` *before* the burn and `_distribute:776-779` attributes everything above it to fees (then charges 10%). Worth checking the rounding direction of `_amounts(…, roundUp=false)` vs. what `BURN_POSITION + TAKE_PAIR` actually delivers across both token orders and at range boundaries, since any under-estimate of principal is silently taxed as "fees".

- **Payout redirection vs. issuer compliance controls** &nbsp;&#91;[G-25](invariants.md#g-25), [G-22](invariants.md#g-22)&#93; — `collectFeesTo:427` / `exitPositionTo:448` pay a beneficiary-chosen `to`; a beneficiary whom an issuer has blocklisted can still extract value through the (unblocked) router to a fresh address. Worth confirming this matches the issuers' expectations, because the likely issuer response is to blocklist the router — the exact scenario eject exists for.

- **Catalog listing is the token-trust gate** &nbsp;&#91;[G-28](invariants.md#g-28), [G-29](invariants.md#g-29), [G-30](invariants.md#g-30), [I-6](invariants.md#i-6)&#93; — `_addPool:832-859` admits any initialised hookless USDG pair with code on both sides; the stock's semantics are unchecked and a listing can never be removed. Worth checking the code-length and protocol-address checks against CREATE2-predeployed or metamorphic token addresses, and that `setDepositsDisabled` is the only remedy for a bad listing.

- **Commission-credit custody and backing gate** &nbsp;&#91;[I-1](invariants.md#i-1), [E-1](invariants.md#e-1), [G-12](invariants.md#g-12)&#93; — `withdrawCommission:396-413` reverts *all* withdrawals of a token when `balanceOf(router) < totalClaimableCommission` (`:405`); an external debit of the router's balance (issuer seize/burn) therefore freezes every recipient's credit in that token, not just the shortfall. Worth confirming this all-or-nothing behaviour is intended and that credits for a `feeRecipient` set to a contract without a withdrawal path are an accepted loss.

- **Eject delivers via `transferFrom`, not `safeTransferFrom`** &nbsp;&#91;[G-14](invariants.md#g-14)&#93; — `ejectPosition:467` sends the NFT to a beneficiary-chosen `to` with no ERC721 receiver check; the record is already `closed` (`:466`). Worth confirming a position ejected to a non-receiving contract is an accepted user error.

- **Deployment scripts** &nbsp;&#91;[G-36](invariants.md#g-36), [G-38](invariants.md#g-38), [X-4](invariants.md#x-4), [X-5](invariants.md#x-5)&#93; — `DeployValariRouterV3.run():42-44` never transfers ownership or changes the fee recipient, so the broadcasting EOA holds both roles; `AddValariRouterV3Pools.run():28-31` identifies a V3 router only by the presence of `MAX_PAYOUT_DUST()`. Worth checking the post-broadcast `require`s cannot leave a half-appended catalog unreported.

### Protocol-Type Concerns

**As a DEX/AMM position custodian:**
- `previewDeposit:588-596` rounds required amounts *up* while `_exitPosition:529-535` rounds principal *down*; worth confirming `G-20` cannot reject a budget that v4 itself would accept, and that `uint128(type(int128).max)` (`:591`) is the right ceiling for `modifyLiquidity`'s `int256` delta.
- `collectFees` uses `DECREASE_LIQUIDITY(0)` (`:486`) to realise fees; worth confirming the v4-core `CannotUpdateEmptyPosition` path is unreachable (liquidity is always > 0 while open, G-8/G-15) and that a v4 protocol fee set by the fee controller is reflected only as "less fees", never as a principal shortfall tripping G-24.
- `_positionView:726-738` reproduces v4's wrapping `feeGrowthInside` subtraction in `unchecked`; worth checking the view agrees with what `_distribute` later realises (the view is what frontends show as `netFees`).

**As a custody vault:**
- No share token, so no inflation/donation attack on shares; the equivalent concern is `balanceOf`-based measurement — a direct token donation to the router before a payout raises `before` and is thereby isolated (G-23), but worth checking a donation *during* the `modifyLiquidities` call (impossible without hooks; relies on I-8).

### Temporal Risk Profile

**Deployment & Initialization:**
- Deployer EOA = owner = `feeRecipient` (`constructor:243`, `DeployValariRouterV3.s.sol:42-44`); unmitigated until a manual `transferOwnership` + `acceptOwnership` and a separate `setFeeRecipient`.
- Constructor accepts 0 pools (`MAX_INITIAL_POOLS` is an upper bound only, `:230`); the append script requires the signer to be the owner and is idempotent (X-4). Partially mitigated.

**Market Stress:**
- A pool price crossing out of a position's range turns the exit one-sided (`_amounts:935-940`); stale `amount0Min/amount1Min` revert atomically (G-16) — mitigated for principal, but fees are never slippage-protected (by design, `:436-437`).
- A thin fee tier's spot can be off-market when quoted (`:288-291` NatSpec acknowledges); unmitigated on-chain, delegated to the frontend's choice of reference.

**Deprecation:**
- Two V1 routers remain live with open positions and no migration path; V3 does not import them (`:654` `UnknownPosition`). Residual-funds and abandoned-approval concerns apply to V1, outside this scope.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **USDG and each listed stock (issuer-upgradeable ERC20 proxies)** — via `_pull:899`, `_refund:914`, `_distribute:764`, `withdrawCommission:396`
> - Assumes: standard `transfer`/`transferFrom`/`balanceOf`; no fee-on-transfer; `balanceOf` deltas reflect transfers within ±2 units on payout, exactly on deposit
> - Validates: exact-delta on deposit (G-32/G-33); ±2-unit window on payout (G-24/G-26); `SafeERC20` for non-reverting tokens
> - Mutability: Upgradeable by each issuer; pause/blocklist per issuer policy (per README)
> - On failure: revert (position stays open, retry / `*To` destination / eject); a token that *lies* by ≤2 units passes

> **Uniswap v4 PositionManager** — via `openPosition:349-360`, `_collectFees:484-500`, `_exitPosition:527-553`, `ejectPosition:467`
> - Assumes: `nextTokenId` monotonic; `ownerOf` reverts for burned IDs; mins in `BURN_POSITION` apply to principal only; no callback on `_mint`
> - Validates: post-call `ownerOf` / `getPositionLiquidity` / `nextTokenId` checks (G-8, G-15, G-17); `_ownerOf` try/catch
> - Mutability: Immutable (vendored 1.0.4); v4 protocol-fee controller can reduce LP fees
> - On failure: revert

> **Uniswap v4 StateView** — via `previewDeposit:585`, `openPosition:344`, `_exitPosition:528`, `_positionView:711-727`
> - Assumes: `getSlot0` returns the PoolManager's current `sqrtPriceX96`; `poolManager()` matches the PositionManager's (checked in constructor, G-34)
> - Validates: equality re-read before mint (G-7)
> - Mutability: Immutable
> - On failure: revert

> **Permit2** — via `_approve:907-912`
> - Assumes: `expiration = 0` means "this block"; `amount = 0` revokes
> - Validates: none beyond Permit2's own checks (confirmed in `lib/permit2/src/libraries/Allowance.sol:40`)
> - Mutability: Immutable canonical deployment
> - On failure: revert

**Token Assumptions** *(unvalidated only)*:
- Any listed stock: assumes the issuer will not pause or blocklist the router — impact if violated: all collect/exit on that pool revert until the owner enables eject.
- Any listed stock: assumes no transfer hook that re-enters a *view* (`previewDeposit`, `getPosition`) during `openPosition`/`_distribute` — impact: read-only reentrancy sees `record.closed=true` before the burn completes (views only; no state effect found).

**Shared State Exposure**:
- The listed v4 pools are public; any party can swap, add liquidity, or `donate` to them. The router neither reads them as an oracle nor exposes a price to others, so blast radius is limited to deposit sizing (price bounds) and fee realisation.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **39 Enforced Guards** (`G-1` … `G-39`) — per-call preconditions with `Check` / `Location` / `Purpose`
> - **11 Single-Contract Invariants** (`I-1` … `I-11`) — Conservation, Bound, Ratio, StateMachine (no Temporal invariant over storage exists)
> - **6 Cross-Contract Invariants** (`X-1` … `X-6`) — three against vendored Uniswap code (marked), two script↔router, one token assumption
> - **5 Economic Invariants** (`E-1` … `E-5`) — commission backing, 10%-of-fees-only, user payout floor, no post-close accrual, owner cannot move user value
>
> Every inferred block cites a concrete Δ-pair, guard-lift + write-sites, state edge, or NatSpec quote. The single **On-chain=No** block (`X-6`, the 2-unit payout tolerance) is the high-signal one — it is both the design's stated trade-off and the only place a token can cost a caller value without a revert.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` §"ValariRouterV3" (lines 70-181) is the V3 spec; the rest describes V1. Owner-power claim at L173-175 verified per code (E-5). |
| NatSpec | ~56 tags in V3 | `@title/@notice/@dev/@param` on every external function and most private helpers; `openPosition` params fully documented. |
| Spec/Whitepaper | README section only | No separate spec. Prior review artefacts: `AUDIT.md` (V1 M-01 remediation), `audit/2026-10-05-v3/trailofbits/*.md` (differential review, token-integration, entry-points, secure-workflow), `audit/2026-10-05/slither/REPORT.md` (V1). |
| Inline Comments | Thorough | Load-bearing comments at `:341-343` (callback window), `:541-542` (hookless snapshot), `:728` (fee-growth wrap), `:847-848` (protocol-address listing). |

Claims from the README are tagged `(per spec)` where not code-verified; everything in Sections 2-3 above was verified against the source.

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 11 (3 target V3: `ValariRouterV3.t.sol`, `ValariRouterV3AccountingAudit.t.sol`, `ValariRouterV3Fork.t.sol`) | File scan (always reliable) |
| Test functions | 151 total; 87 `test*` functions in the three V3 files (76 + 1 + 10) | File scan (always reliable) |
| Line coverage | Unavailable — `forge coverage` fails to compile `ValariRouterV3.openPosition` ("Stack too deep", `:324`) with the optimizer disabled; `--ir-minimum` also fails ("too deep in the stack by 2 slots") | Coverage tool (requires compilation) |
| Branch coverage | Unavailable — same reason | Coverage tool |

Coverage was run with `--no-match-path 'test/*Fork*'`; fork suites self-skip without `RUN_ROBINHOOD_FORK=true` anyway.

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit / integration (real v4 core + periphery + Permit2) | 77 (V3.t + accounting) | ValariRouterV3: both token orders, one-sided ranges, dust/sticky/greedy/muted tokens, approve-hook and transfer-hook price moves, reentry, eject, `*To` payouts, catalog append, price bounds |
| Fork (opt-in, chain 4663) | 10 in `ValariRouterV3Fork.t.sol` | Both deploy scripts, real GOOGL/NVDA pools, eject on live Uniswap, second fee tier |
| Stateless Fuzz | 4 (`testFuzz*`; 2 target V3) | Budgets/custody fuzz; 256-seed accounting conservation across overlapping ranges |
| Stateful Fuzz (Foundry invariant) | 0 | none |
| Stateful Fuzz (Echidna) | 14 properties for V3 in `audit/2026-10-05-v3/echidna/harness/RouterEchidnaV3.sol` (configs at depth 4, not detected by the enumerator); 8 for V1 | Commission backing, custody, allowance clearing, supply conservation, catalog append-only |
| Formal Verification (Certora / Halmos / HEVM) | 0 | none (`audit/2026-10-05-v3/manticore/` holds a symbolic-execution run, not a spec) |

### Gaps

- No Foundry `invariant_` suite under `test/`; the Echidna harness lives in `audit/` and does not run under `forge test`, so CI does not exercise the stateful properties.
- No formal verification of `_commission` (floor-with-carry), `_split`, or `_checkRetained` — the arithmetic that defines who bears rounding.
- Coverage cannot be measured on this contract as written (stack-too-deep under coverage settings); mutation evidence exists only in the prior differential review (its L-1 mutants M13/M17/M20/M21/M35 now have correspondingly named tests in `ValariRouterV3.t.sol`, but mutation-kill was not re-verified here).
- Fork lifecycle tests require an RPC and are opt-in; script failure branches ("Wrong chain", "not a ValariRouterV3", "Catalog size mismatch") are untested offline.
- The 2-unit dust tolerance is tested only with the stock as `currency0` in most fixtures (per the differential review); one `currency1` case now exists (`testFaultyStockAsCurrency1CannotCloseAPosition`).

---

## 6. Developer & Git History

> Repo shape: **not a git repository** — `valari-contracts/` has no `.git`; the skill's `analyze_git_security.py` and the enumerator's git stats could not run and were skipped (no `git init` was performed). Contributors, review signals, hotspots, fix candidates, dangerous-area evolution and tech-debt blame are therefore unavailable.

### What can be said without history

- **Single-author signals** — the README, AUDIT.md and all three review folders are written in one voice and the deployer/owner/treasury is one EOA (`0x09D08d66…C5A2`, README L20/L30); treat as single-developer until proven otherwise.
- **Lineage** — V3 is a ~300-line evolution of the deployed V1 (`diff` of the two sources, names normalised); the differential review in `audit/2026-10-05-v3/` documents the change set and classified it CONDITIONAL on L-1 (tests since added).
- **Technical debt markers** — none (`TODO|FIXME|HACK|XXX` absent from `src/ValariRouterV3.sol` and both scripts).
- **Forked dependencies** — all six `lib/` entries are vendored at pinned upstream commits with `REVISION` files (`DEPENDENCIES.md`); no internalised/modified copies were detected. `lib/permit2/test/utils/DeployPermit2.sol` is a test-only helper.

### Cross-Reference Synthesis

- **No history + single EOA owner → the owner-dependence surface is also a key-management surface**: `setEjectEnabled` (attack surface #2) is the only recovery path and has no fallback if the key is lost or renounced.
- **Prior review L-1 (untested checks) + coverage unmeasurable → rely on the named regression tests, not on coverage**: the hookless check (G-28) and the price re-read ordering (G-7) are the two whose silent removal would be most damaging.
- **Echidna properties in `audit/`, not `test/` → I-1/E-1 (commission backing) and I-6 (append-only catalog) are the invariants with existing stateful harness coverage**; I-2 (carry ratio), I-4 (closed latch) and X-6 (dust bound) are not.

---

## X-Ray Verdict

**ADEQUATE** — unit + stateless fuzz + an out-of-tree Echidna harness, thorough NatSpec and a README spec, and clearly bounded roles, but a single un-timelocked EOA owner with no multisig and no pause, and coverage that cannot be measured.

**Structural facts:**
1. 779 nSLOC in one non-upgradeable contract plus 99 nSLOC of deployment scripts; six vendored, pinned dependencies.
2. 14 state-changing entry points: 1 permissionless (`openPosition`), 7 role-gated (5 beneficiary, 1 credit holder, 1 pending owner), 6 owner-only — all four router admin functions are instant.
3. 87 V3 test functions across 3 files (10 fork, opt-in), 2 V3 stateless fuzz tests, 14 Echidna properties under `audit/`, 0 Foundry invariant tests, 0 formal verification; line/branch coverage unmeasurable (stack-too-deep under coverage compilation).
4. 39 enforced guards, 22 inferred invariants, 1 not enforced on-chain (the 2-raw-unit payout tolerance, by design).
5. No git history available; no TODO/FIXME markers; prior in-house review artefacts present for V1 and the V1→V3 diff; no independent external audit (per README L417-418).
