# === SECURE DEVELOPMENT WORKFLOW REPORT ===

Project: ValariRouterV3 (`src/ValariRouterV3.sol`), custody router for Uniswap v4 LP NFTs on Robinhood Chain
Platform: Solidity 0.8.26, via-IR, Cancun, optimizer 200 (Foundry). Not deployed. Not upgradeable.
Workflow date: 2026-10-06 (re-applied; supersedes the 2026-10-05 report written against source `19d3d512…`)
Source SHA-256: `f851cb15c188ddb2de32761b996799df856e56d7b9e1362ebbe1a4ac077e0b96` (the hash the current Slither detector log, Echidna campaign and Manticore runs in `audit/2026-10-05-v3/` record)
Method: Trail of Bits `secure-workflow-guide` skill, five steps. Printers re-run on a fresh build of this hash; raw output in `printers/` (overwritten).

What changed since the previous report: `collectFeesTo`, `exitPositionTo`, `setDepositsDisabled`, `setEjectEnabled`, `ejectPosition`, `_checkRecipient`, `_split` with the inbound `MAX_PAYOUT_DUST` tolerance; `FeesCollected`/`PositionExited` gained a trailing `to`. The previous report's two concerns were acted on: concern 1 (rounding tolerance only on the sending side) is closed by `_split`; concern 2 (mistaken fee recipient) is unchanged and remains an operating-procedure item.

Result in one line: no new High or Medium issue. One Low test gap on the new `_split` tolerance (currency1 leg untested), two Informational precision items, and one open workflow limit (diagrams still DOT only). Details in "New concerns".

---

## STEP 1: KNOWN SECURITY ISSUES

### Slither security scan

Not re-run, as instructed. Triage below is of the existing run against this source hash. Note on the artefacts: `audit/2026-10-05-v3/slither/slither-scope-fix.log` (20:48 local) is the run against `f851cb15…` (its line numbers match the current file, e.g. `_pull` at L899-905); `results-scope-fix.json` / `.sarif` (17:32) were not overwritten by that run ("exists already, the overwrite is prevented", log L497-498) and still carry the previous revision's line numbers. The log is authoritative; the JSON should be regenerated when the detectors are next run.

Status: no confirmed issue after triage. 116 raw results; 20 reference the router, the same 20 as before with shifted lines. None references any of the new functions.

| Raw severity | All | Reference `src/ValariRouterV3.sol` |
|---|---:|---:|
| High | 4 | 1 |
| Medium | 19 | 7 |
| Low | 13 | 11 |
| Informational | 80 | 1 |

### Router findings, triaged

| Detector (raw severity) | Count | Lines (current) | Assessment |
|---|---:|---|---|
| `reentrancy-balance` (High) | 1 | `_pull` L899-905 | False positive. L902 requires the post-transfer balance to equal snapshot plus budget. Only caller is `openPosition`, `nonReentrant`. |
| `incorrect-equality` (Medium) | 1 | `_accrueCommission` L862 | False positive: early return on zero commission. |
| `uninitialized-local` (Medium) | 1 | `getUserPositions` L671 | False positive: `count` starts at zero by language rule. View. |
| `unused-return` (Medium) | 5 | L344, L528, L585, L715, L853 | Intentional: `getSlot0` returns four values; the router needs the price (and at L715 the tick). |
| `calls-loop` (Low) | 5 | `_positionView`, `_ownerOf` via `getUserPositions`; `_addPool` via constructor | Bounded by `MAX_PAGE_SIZE` (L894) and `MAX_INITIAL_POOLS` (L230). |
| `reentrancy-benign` (Low) | 1 | `openPosition` L292-381 | Accepted: whole function `nonReentrant`; record keyed by a token ID that did not exist before the call; L356-360 verify custody first. |
| `timestamp` (Low) | 4 | L307, L477, L522; `getPosition` L653 | Caller-chosen deadlines; the fourth is taint noise from `openedAt`. |
| `shadowing-local` (Low) | 1 | `_ownerOf` L869 | Cosmetic (`try ... returns (address owner)`). |
| `pragma` (Informational) | 1 | L2 | Dependencies use ranges; the router pins 0.8.26. |

The new code was checked for what the detectors would have said about it: `ejectPosition` writes `record.closed` before its external call and emits after it (Slither's `reentrancy-events` did not fire; the call is an `IERC721` interface call on an immutable); `_split` has no unchecked arithmetic (the subtraction at L811 follows the ordering test at L808); `_checkRecipient` is `view`. Nothing to add.

### Dependency findings

Unchanged: High 3 (`incorrect-exp` in `FullMath`, `incorrect-shift` in `BitMath`, intended), Medium 12 (`divide-before-multiply` in Uniswap math), Low 2, Informational 79. Upstream code at the pinned commits.

Current status: nothing to fix from Step 1; regenerate the JSON artefacts at the next detector run.

---

## STEP 2: SPECIAL FEATURES

### Upgradeability: not applicable, verified

- Search of the router for `delegatecall`, `proxy`, `initializ`, `upgrade`, `selfdestruct`, `create2`, `assembly`: no code hits (comment hits only). Deploy script uses `new ValariRouterV3(...)`.
- `slither-check-upgradeability` re-run (`printers/check-upgradeability.txt`): one result, `init-missing` ("Initializable contract not found"), i.e. a constructor-initialised, non-proxy contract.
- Custom check 7 (`printers/custom-checks.txt`): no low-level call, `delegatecall` or `selfdestruct` in any function declared by the router.

### ERC conformance: not applicable, verified

- `slither-check-erc --erc erc20` and `--erc erc721` re-run (`printers/check-erc-erc20.txt`, `check-erc-erc721.txt`): every required function and event missing. The router is neither a token nor an NFT contract. It now *sends* one NFT (`ejectPosition`), which does not make it an ERC721.
- `slither-prop`: not applicable.

### Token integration: applies

Run this time as its own skill; see `token-integration.md` (same hash). Summary relevant to this step: the previous report's two integration gaps are closed (deposits can be frozen per pool; a token that refuses the router no longer freezes custodied funds, because `ejectPosition` moves the NFT without touching the token), the inbound rounding gap is closed by `_split`, and two Informational items were added (per-pool switches with no batch form; `_checkRecipient` refuses only the router).

---

## STEP 3: VISUAL SECURITY INSPECTION

Printers re-run through the scope-fix shim with `--disallow-partial` on a fresh build (`/tmp/tob-rerun/out`): `human-summary`, `contract-summary`, `function-summary`, `vars-and-auth`, `require`, `modifiers`, `entry-points`, `inheritance`, `inheritance-graph`, `call-graph`. Text outputs `printers/*.txt`; graphs as DOT (`printers/ValariRouterV3.inheritance-graph.dot`, `ValariRouterV3.ValariRouterV3.call-graph.dot`, `ValariRouterV3.all_contracts.call-graph.dot`). Graphviz is still not installed, so no PNG; render with `dot -Tpng <file> -o <file>.png`.

### Inheritance graph

```
ValariRouterV3
├─ ReentrancyGuard          (OpenZeppelin 5.0.2, storage-based: slot 0 `_status`)
└─ Ownable2Step
   └─ Ownable
      └─ Context
```

- Unchanged: depth 3, no diamond; linearisation ValariRouterV3, Ownable2Step, Ownable, Context, ReentrancyGuard. The router overrides nothing. No state-variable shadowing (`printers/inheritance.txt`).
- Storage layout by declaration order (not upgradeable, so informational): slot 0 `_status`, 1 `_owner`, 2 `_pendingOwner`, 3 `feeRecipient`, 4 `claimableCommission`, 5 `totalClaimableCommission`, 6 `_pools`, 7 `_poolIds`, 8 `_stockPoolIds`, **9 `depositsDisabled`, 10 `ejectEnabled`** (new), 11 `_deposits`, 12 `_positionIds`, 13 `_depositorPositionIds`. Five immutables in code.

### Function summary (state-changing and their helpers)

From `printers/function-summary.txt` (cyclomatic column as the printer reports it).

| Function | Lines | Visibility | Modifiers | Cyclomatic | Note |
|---|---|---|---|---:|---|
| `constructor` | L222 | public | (Ownable init) | 4 | one-time |
| `addPool` | L255 | external | `onlyOwner`, `nonReentrant` | 1 | wraps `_addPool` (6) |
| `setDepositsDisabled` | L262 | external | `onlyOwner`, `nonReentrant` | 1 | **new**; pool must be listed |
| `setEjectEnabled` | L272 | external | `onlyOwner`, `nonReentrant` | 1 | **new**; pool must be listed |
| `openPosition` | L292 | external | `nonReentrant` | 9 | +1 from the `DepositsDisabled` check; still "Complex code: Yes" |
| `setFeeRecipient` | L384 | external | `onlyOwner`, `nonReentrant` | 2 | |
| `withdrawCommission` | L396 | external | `nonReentrant` | 4 | authority = caller's own credit |
| `collectFees` / `collectFeesTo` | L417 / L427 | external | `nonReentrant` | 1 / 1 | thin wrappers over `_collectFees` (3); depositor check in `_ownedPosition` (5) |
| `exitPosition` / `exitPositionTo` | L438 / L448 | external | `nonReentrant` | 1 / 1 | wrappers over `_exitPosition` (4) |
| `ejectPosition` | L462 | external | `nonReentrant` | 3 | **new**; `_ownedPosition`, switch, `_checkRecipient`, close, ERC721 transfer, ownership check |
| `transferOwnership` / `acceptOwnership` / `renounceOwnership` | OZ | public | `onlyOwner` / inline / `onlyOwner` | 1 / 2 / 1 | inherited, unchanged |
| `_distribute` + `_split` | L764 / L803 | private | | 4 / 1 | shared payout path; inbound tolerance |
| `_checkRecipient` | L817 | private view | | 2 | not zero, not router |
| `_pull` / `_refund` / `_checkRetained` | L899 / L914 / L825 | private | | 3 / 4 / 2 | balance guards |

- All privileged functions carry `onlyOwner`; all 11 router-declared entry points carry `nonReentrant` (custom checks 1 and 2).
- Runtime bytecode 19,567 bytes (EIP-170 limit 24,576); creation 21,851. `abi/ValariRouterV3.json` equals the compiled ABI (86 entries, checked entry by entry).

### Variables and authorization (who can write what)

From `printers/vars-and-auth.txt` with transitive writes from `printers/custom-checks.txt`. `_status` omitted.

| State variable | Written by (entry point) | Who may call | Effect scope |
|---|---|---|---|
| `_owner`, `_pendingOwner` | ownership functions | owner; pending owner | ownership |
| `feeRecipient` | `setFeeRecipient` (and constructor) | owner | future commission only |
| `_pools`, `_poolIds`, `_stockPoolIds` | `addPool` (and constructor), only through `_addPool` | owner | append-only (check 6: single writer) |
| **`depositsDisabled`** | `setDepositsDisabled` | owner | read only by `openPosition` L313 (check 8) |
| **`ejectEnabled`** | `setEjectEnabled` | owner | read only by `ejectPosition` L464 (check 8) |
| `_deposits` | `openPosition`; `collectFees[To]`; `exitPosition[To]`; **`ejectPosition`** | anyone (own record); recorded depositor (×5) | one position; `ejectPosition` writes only `closed` |
| `_positionIds`, `_depositorPositionIds` | `openPosition` | anyone | appends the caller's own new ID |
| `claimableCommission`, `totalClaimableCommission` | `collectFees[To]`, `exitPosition[To]` (credit `feeRecipient`); `withdrawCommission` (debit own) | recorded depositor; credit holder | `ejectPosition` credits nothing |
| immutables | constructor | deployer | fixed |

Reading of the matrix:

- The owner can write the catalog, the two per-pool switches, the fee recipient and ownership, and nothing else (check 3). The switches are new owner powers; both are single booleans with exactly one reader each, so their blast radius is the one `if` that reads them.
- `ejectPosition` is the first function other than `_exitPosition` that closes a record, and the first that makes the router transfer an NFT. Its write set is `_deposits` only and its external calls are `IERC721.transferFrom`/`ownerOf` on the immutable PositionManager only (check 9), so it cannot touch balances or credits.
- `collectFeesTo`/`exitPositionTo` have write sets identical to their plain siblings (check 10); the destination is a parameter, never stored.

Printer caveats, as before: `vars-and-auth` shows an empty "Conditions on msg.sender" for `onlyOwner` functions and `withdrawCommission` (indirection through `owner()`; mapping index), and now correctly shows `record.depositor != msg.sender` for the five position functions. The `require` printer lists only Uniswap-library `require`s; the router's checks are custom-error reverts.

---

## STEP 4: SECURITY PROPERTIES DOCUMENTED

### Properties and where each is checked

Properties 1-18 of the previous report hold unchanged (same tests, same Echidna names, re-run against this hash). Adjustments and additions:

State machine and custody:

2'. A position goes open to closed once and never back, by exit **or eject**; a closed position cannot be collected, exited or ejected (L543, L466, L745). Foundry `testClosedPositionCannotBeCollectedOrExitedAgain`, `testEjectFreesAPositionTheRouterCanNoLongerPayOut` (second eject and collect revert `PositionClosed`).
3'. An open position's NFT is owned by the router with liquidity `initialLiquidity`; an exited one is burned; an ejected one is owned by the depositor's chosen `to` with its liquidity intact. Echidna `echidna_custody_and_cumulative_commission` (tracks `ejectedTo`).

Access control:

19. `ejectPosition` succeeds only when (a) the caller is the recorded depositor, (b) the owner has enabled eject for the position's pool, (c) `to` is neither zero nor the router; the owner cannot eject anyone's position. Echidna `echidna_pool_switches_hold`, `echidna_owner_and_outsiders_cannot_take_positions` (owner and wrong actor try `ejectPosition`); Foundry `testEjectIsOffUntilTheOwnerEnablesItForThatPool`, `testEjectFreesAPositionTheRouterCanNoLongerPayOut`; Manticore `outsider`/`treasury`/`pending` (selector set includes `ejectPosition` and both setters; 0 violations).
20. `depositsDisabled[pool]` blocks `openPosition` for that pool and nothing else; `ejectEnabled[pool]` gates `ejectPosition` and nothing else; both are owner-only and require a listed pool. Custom check 8 (single reader each); Foundry `testOwnerStopsAndResumesDepositsForOnePool`, `testOnlyOwnerSetsPoolSwitchesAndOnlyForListedPools`; Echidna `echidna_pool_switches_hold`.
21. `collectFeesTo`/`exitPositionTo` are callable only by the recorded depositor, pay `to` exactly what the plain variant would pay the caller, and change the same state. Custom check 10 (write sets equal); Foundry `testBeneficiaryWhoCannotReceiveATokenIsPaidAtAnotherAddress`; Echidna `echidna_payouts_match_actual_balance_changes` (drives `*To` with random `to`; `echidna_reach_refused_ejected_and_paid_elsewhere` falsified, so both paths ran).

Arithmetic and accounting:

12'. Payout = principal + fees − commission equals the recipient's actual balance change, where principal is the exact v4 principal **or up to `MAX_PAYOUT_DUST` less when the token delivered less**; a larger shortfall reverts. Echidna property 12 (standard tokens); Foundry `testExitSurvivesTokenThatDeliversLessThanThePoolSent` (currency0 only; see New concern 1).
22. `ejectPosition` moves no ERC20 and changes no commission state; router token balances and `totalClaimableCommission` are identical before and after. Custom check 9; Foundry `testEjectFreesAPositionTheRouterCanNoLongerPayOut` (router balances 0, commission 0 after eject and direct burn).

### Testing status

- Echidna (`audit/2026-10-05-v3/echidna`, campaign against this hash, `source-sha256.txt`): 200,214 calls, 10 of 10 properties passing (the tenth, `echidna_pool_switches_hold`, is new), four `echidna_reach_*` witnesses falsified by design, which shows the eject, paid-elsewhere, refused-deposit, appended-pool and moved-price paths were driven.
- Manticore (`audit/2026-10-05-v3/manticore/results`, against this hash): all six scenarios finished, exit 0, no violations: `recipient`, `value` (43 paths, all revert on 1 wei), `outsider` (55 paths), `treasury` (60), `pending` (60, one success: `acceptOwnership`), `addpool` (re-run with the corrected judge; 2 successful `addPool` paths, 0 violations). The previous report's open item on Manticore is closed.
- Foundry: 76 tests in `test/ValariRouterV3.t.sol` (76/76 pass in the shadow build; the four L-1 tests of the previous differential review are in, as `testApproveCallbackCannotMovePriceBetweenBoundsCheckAndMint`, `testCodelessCurrencyIsNotListableOnEitherSide` and companions), 1 accounting fuzz, 11 fork tests (two new, not runnable offline).
- Custom Slither check (`printers/custom_checks.py`, extended): ten project-specific assertions on the access matrix, now including the single-reader rule for the switches (8), the no-token-movement rule for `ejectPosition` (9) and write-set equality of the `*To` variants (10). All hold (`printers/custom-checks.txt`).
- Mutation check of the new code (differential review, this date): 10 mutants: 8 killed by the project suite, 1 (`_split` tolerance removed on currency1) killed only by a reviewer probe, 1 equivalent (post-transfer `ownerOf` check in `ejectPosition`).

### Gaps in the property set

- The inbound tolerance is exercised only on currency0 by the project suite (New concern 1).
- Non-standard tokens are still covered only by Foundry mocks, not by the stateful Echidna campaign.

---

## STEP 5: MANUAL REVIEW AREAS

### Privacy

- No secrets; nothing needs commit-reveal. `to` of a `*To` payout or eject is public in the event, which is intended.

### Front-running

- `openPosition`: unchanged (bounds L316-318, minimum liquidity L320, deadline L307, re-read L344-347). `setDepositsDisabled` landing first makes a pending deposit revert with nothing moved (L313 precedes every pull); no loss.
- `exitPosition[To]`: principal minimums checked by the router (L536) and by the PositionManager on principal only; deadline L522. New: the minimum is satisfied by the pool's delivery, and `_split` can then pay up to 2 units less (New concern 2). Not an ordering risk.
- `ejectPosition`: nothing price-sensitive, hence no deadline. `setEjectEnabled(false)` landing first makes it revert `EjectDisabled`; no loss.
- `collectFees[To]`: fee amounts do not depend on spot price; nothing to sandwich.

### Cryptography

- None. No signatures, hashing of user data, or randomness. Permit2 through direct `approve`. No `isValidSignature`.

### DeFi interactions

- Spot price is read at L344, L528, L585 and in views; never used as an oracle for value. Commission is computed from actual balance deltas (L776-783).
- Third parties cannot act on custodied NFTs: PositionManager increase/decrease/burn/subscribe are `onlyIfApproved` and the router grants no approval. `ejectPosition`'s `transferFrom` is `onlyIfPoolManagerLocked` and runs no subscriber code (the router never subscribes; `Notifier.subscribe` is `onlyIfApproved`).
- Hookless pools only (L842); no hook runs inside any router operation, including the exit whose principal/fee split (L541-542, L803-813) assumes it.
- Action encodings unchanged against the pinned periphery.
- Direct burn after eject uses the same `BURN_POSITION + TAKE_PAIR` the router uses; verified by the suite's `_burnDirectly`.

---

## NEW CONCERNS (not on the already-known list), most severe first

### 1. Low: the inbound dust tolerance on the currency1 leg has no test that fails when it is removed

Lines: `_distribute` L779 (`_split(received1, payout.principal1)`); test `testExitSurvivesTokenThatDeliversLessThanThePoolSent` L2490-2549.
Status: verified by mutation (differential review mutant S2: currency1 reverted to the strict V1 check; the 76-test suite passes; only the reviewer probe `testProbeInboundToleranceAppliesToCurrency1` fails).

The suite's rounding stock (`StickySenderToken`) sorts below USDG in the fixture, so it is always currency0 and only L778 is exercised with a shortfall. The code at L779 is correct in HEAD; the gap is that a later edit that reverts or mistypes the currency1 line passes CI. Minimal fix: add the probe (stock constructed in a loop until its address is above USDG, as the suite already does elsewhere); it passes on HEAD and kills S2.

### 2. Informational: `amount0Min`/`amount1Min` are met by the pool's delivery, not by what reaches `to`

Lines: `_exitPosition` L536 (check against the exact principal, before the burn), `_split` L808-812, `_checkRetained` L827-829; NatSpec L436-437 ("Minimum currency0 PRINCIPAL to withdraw").
Status: verified by probe (`testProbeExitMinimumCanBeUndershotByInboundDust`: `amount0Min = view.amount0`, token delivers 2 less, exit succeeds, depositor receives `amount0Min - 2`).

The minimum protects against a price move before the burn and still does; v4 enforces it on the pool delta too. The two dust tolerances then allow the depositor to receive up to `MAX_PAYOUT_DUST` less than the minimum on the inbound leg and up to `MAX_PAYOUT_DUST` less again on the outbound transfer. Value is at most 4 raw units per leg; no third party gains. A strict post-check would defeat the tolerance whenever a UI passes the live view amount as the minimum, so the fix is wording: state in the NatSpec and README that the minimums bound the pool's delivery and that the amount reaching `to` may be up to `MAX_PAYOUT_DUST` less per hop.

### 3. Informational: the README's "1–2 raw units" bound describes principal and outbound, not withheld fees

Lines: `_split` L808-809; README L104-105.
Status: verified by probe (`testProbeShortfallSwallowsSmallFeesWithoutCommission`: with real fees `F` accrued, a token withholding `F + 2` passes; fees report 0, commission 0, depositor paid what arrived).

The router never learns the fee amount except as `received − principal`, so on the inbound leg a token can withhold any part of the LP fees undetected. That was equally true of the strict V1 check; `_split` adds the 2 units of principal. The loss is the depositor's and the fee recipient's (no commission on withheld fees); nobody else gains. Fix: qualify README L104-105 ("...of principal; LP fees are measured as what arrives").

### Not contract concerns, but needed to close the workflow

- Diagrams exist as DOT source only (Step 3), unchanged.
- `results-scope-fix.json`/`.sarif` are stale relative to the log (Step 1).

---

## ACTION PLAN

Critical (before deployment): none from this workflow.

High priority (before deployment):

1. Add the currency1 shortfall test (New concern 1); it is in `/tmp/tob-rerun/shadow/test/TobProbe.t.sol` and in Appendix B of `differential-review.md`.
2. Run the fork suite, including the two new exit-path tests, against the chain (not possible here).

Medium priority:

3. Wording fixes for New concerns 2 and 3 (NatSpec L436-437; README L96-105).
4. Decide on the batch/global form of the two switches (`token-integration.md` N-5).
5. Regenerate the Slither JSON/SARIF so they match the log.

Nice to have:

6. Keep `printers/custom_checks.py` (now ten checks) on every change to the router.
7. Render the DOT graphs once Graphviz is available.

---

## WORKFLOW CHECKLIST

- [x] Step 1: Slither detector run triaged (existing log against this hash reused; 116 results, 20 on the router, none confirmed, none on new code)
- [x] Step 2: Special features checked (upgradeability and ERC conformance re-run, not applicable; token integration run as its own skill)
- [x] Step 3: Printers re-run and reviewed (inheritance, function summary, vars-and-auth, modifiers, require, entry points, call graph); graphs saved as DOT, not rendered
- [x] Step 4: Properties documented and mapped to tests; Echidna 10/10 passing; Manticore 6/6 scenarios clean; custom checks extended and passing; 10 mutants of the new code run
- [x] Step 5: Manual review of privacy, front-running, cryptography and DeFi interactions done for the new paths

Steps not fully performed, and why:

- Step 1 detectors were not re-run (instructed to reuse the existing run; the log matches the hash).
- Step 2 `slither-prop` not applicable (no token implementation).
- Step 3 PNG/PDF rendering not possible (no Graphviz).
- Step 4 Echidna and Manticore were not re-launched; the campaigns in `audit/2026-10-05-v3/` were made against this hash and were read.
- No fork or RPC was used anywhere (instructed), so nothing here verifies live token behaviour, including whether USDG or the stock tokens ever round on transfer.

Trail of Bits Secure Development Workflow, applied manually from the skill files
