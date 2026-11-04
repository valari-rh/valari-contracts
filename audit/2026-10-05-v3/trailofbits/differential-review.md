# Differential Security Review: ValariRouter -> ValariRouterV3 (second pass)

Method: Trail of Bits `differential-review` skill (SKILL.md, methodology.md, adversarial.md,
patterns.md, reporting.md), applied by hand. Date: 2026-10-06. Supersedes the 2026-10-05 report,
which reviewed HEAD at source `19d3d512…`; HEAD is now `f851cb15…`. The first pass's results for
the unchanged parts of the diff (C1-C10) are carried over in summary form and were not redone; the
new effort is on the five additions since (C11-C15).

Every statement below is tagged **[verified]** (executed, or read directly in the cited code)
or **[inferred]** (reasoned, not executed).

# Executive Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 0 |
| LOW | 2 (L-3 new, L-2 carried over) |
| INFORMATIONAL | 4 (I-6, I-7, I-8 new; I-3 carried over and widened) |

**Overall Risk:** LOW for the code change itself. The additions sit in HIGH-risk areas (a new
privileged switch pair, a new NFT-transferring entry point, payout redirection, a relaxed inbound
value check), and none was found exploitable against the audited base or against the previous
HEAD.

**Recommendation:** CONDITIONAL. Conditions before deployment:

1. Add the one missing test (L-3; ready-made, Appendix B).
2. Update the subgraph event signatures and the frontend ABI before pointing either at V3
   (I-3): the two changed events will otherwise be silently dropped.
3. Run the fork suite, including the two new exit-path tests, against the chain (L-2, carried
   over; no network here).

**Key Metrics:**
- Files analyzed: 7/7 changed files (router, 2 scripts, 3 tests, README V3 section), plus the
  vendored PositionManager/solmate code on the eject path.
- Mutation check of the additions: 10 behavioural mutants of the new code; 8 killed by the
  project suite, 1 killed only by a reviewer probe (L-3), 1 equivalent. The project's own
  separate run of 21 mutants (all killed) was not repeated.
- Test coverage gaps in the additions: 1 (currency1 inbound tolerance).
- High blast radius changes: 0 by caller count (every new function has 0 internal callers and
  5-13 test call sites). `_split` nevertheless sits on every collection and exit.
- Security regressions detected: 0. No validation was removed between the previous HEAD and this
  one; the only relaxed check (`_split`) is bounded by the same constant as the existing outbound
  tolerance.
- Baseline suite on HEAD: 76/76 (`ValariRouterV3Test`, shadow build) [verified].

# What Changed

**Commit Range:** none. The directory has no git history [verified]. BASE = `src/ValariRouter.sol`
(sha256 `71958775…`, the live router). HEAD = `src/ValariRouterV3.sol` (sha256 `f851cb15…`, the
hash recorded by the Slither log, Echidna and Manticore runs in `audit/2026-10-05-v3/`).
**Commits:** n/a. **Timeline:** BASE 2026-09-14, previous HEAD 2026-10-05 15:57, HEAD 2026-10-05
20:15 (file mtimes).

| File | +Lines | -Lines | Risk | Blast Radius |
|------|--------|--------|------|--------------|
| src/ValariRouterV3.sol (vs ValariRouter.sol) | +239 | -62 | HIGH | LOW by count; all payout paths |
| script/DeployValariRouterV3.s.sol, script/AddValariRouterV3Pools.s.sol | unchanged since the first pass (mtimes 16:08, 17:22) | | MEDIUM | reviewed before |
| test/ValariRouterV3.t.sol | 76 tests (was 65): 7 new for the additions, 4 from the first pass's Appendix B | | LOW | - |
| test/ValariRouterV3Fork.t.sol | +2 fork tests (`ValariRouterV3ForkExitPathsTest`) | | LOW | not runnable offline |
| test/ValariRouterV3AccountingAudit.t.sol | unchanged | | LOW | - |
| README.md (V3 section), NatSpec | wording for the five additions | | LOW | - |
| abi/ValariRouterV3.json | regenerated, equals the compiled ABI (86 entries) [verified] | | LOW | consumers, see I-3 |

## Risk classification and blast radius, per change

Line numbers are in `src/ValariRouterV3.sol`.

| # | Change | Lines | Risk class (skill triggers) | Blast radius |
|---|--------|-------|-----------------------------|--------------|
| C1-C10 | Price bounds and pre-mint re-read; `_checkRetained` with `MAX_PAYOUT_DUST`; `addPool`/`_addPool`; constructor accepts 0 pools; `getStockPoolIds`; scripts; tests | see first pass | HIGH/MEDIUM | Reviewed 2026-10-05; the four test gaps found then (M13, M17, M20/21, M35) are now closed by tests in the suite [verified: `testApproveCallbackCannotMovePriceBetweenBoundsCheckAndMint`, `testCodelessCurrencyIsNotListableOnEitherSide` and companions present; 76/76 pass] |
| C11 | `collectFeesTo` / `exitPositionTo`; `collectFees`/`exitPosition` become wrappers over `_collectFees`/`_exitPosition` with a `to` parameter; `_checkRecipient`; `to` appended to `FeesCollected`/`PositionExited` | 417-456, 472-567, 817-819, 195-216 | HIGH (value transfer to a caller-named address) | 2 new entries, 0 internal callers; 12 test call sites. Event signature change reaches every indexer (I-3) |
| C12 | `setDepositsDisabled` + `depositsDisabled` mapping + check in `openPosition` | 137-138, 262-266, 313 | HIGH (new privileged entry point; validation added on the deposit path) | 1 entry, read at exactly 1 site [verified, custom check 8] |
| C13 | `setEjectEnabled` + `ejectEnabled` mapping | 139-140, 272-276 | HIGH (new privilege that unlocks C14) | 1 entry, read at exactly 1 site [verified, custom check 8] |
| C14 | `ejectPosition`: closes the record and transfers the LP NFT out with `IERC721.transferFrom`; `PositionEjected` event | 462-470, 217-218 | HIGH (new external call that moves custody; new state transition open→closed without a burn) | 1 entry, 0 internal callers; 13 test call sites. Touches `_deposits` and the PositionManager only [verified, custom check 9] |
| C15 | `_split`: inbound shortfall of up to `MAX_PAYOUT_DUST` against the exact principal is paid out as principal; larger reverts | 803-813, called 778-779 | HIGH (validation relaxed on value transfer) | 2 call sites in `_distribute`, reached from all four collect/exit entries |

By the skill's thresholds (1-5 callers = LOW) no change has a HIGH blast radius, so none is P0/P1;
all five were analysed at P2 depth with adversarial modelling.

# Critical Findings

None at CRITICAL, HIGH or MEDIUM. The adversarial pass (Phase 5) on C11-C15, with the attacker
models the skill asks for, is summarised so the absence is checkable:

- **C11, attacker = another user or the owner (goal: redirect someone's payout).** Both `*To`
  functions reach `_ownedPosition` first (L476, L521), the same `record.depositor != msg.sender`
  check as the plain variants; `to` is a parameter, never stored, so it cannot leak into a later
  call. Write sets of each `*To` equal its sibling's [verified, custom check 10]. Mutants T1/T2 (a
  `*To` ignoring its destination) and R1 (`_checkRecipient` allowing the router) are killed
  (table below). Attacker = depositor (goal: profit from a destination): `to == address(this)` is
  refused because the router's balance is the payout measurement; with it allowed, `_checkRetained`
  (L827) would revert anyway because the payout stays in the router (surplus > 2) [inferred from
  the code; mutant R1 killed by the suite's `expectRevert(InvalidRecipient)`]. Any other `to`,
  including protocol contracts, only spends the depositor's own payout (probe
  `testProbePayoutToPoolManagerIsAccepted` [verified]; see `token-integration.md` N-6).
- **C12, attacker = owner (goal: freeze funds).** The flag is read at L313 only, after the pool
  lookup and before any pull; collection, exit and eject do not read it [verified, custom check
  8; `testOwnerStopsAndResumesDepositsForOnePool`]. The owner gains a deposit-side pause and
  nothing over custodied funds. Attacker = anyone: `onlyOwner` traced through OZ 5.0.2, no
  forwarder [verified]; Manticore `outsider`/`treasury`/`pending` include both setters, 0
  violations [verified, results against this hash].
- **C13/C14, attacker = owner (goal: take a position).** `setEjectEnabled` writes one boolean;
  `ejectPosition` requires `msg.sender == record.depositor` before reading it (L463-464). The
  owner has no function with `_deposits` in its write set [verified, custom check 3]. Attacker =
  depositor (goal: eject without the switch, eject twice, eject a position already exited,
  eject someone else's): each is a reverted path (`EjectDisabled`, `PositionClosed`,
  `PositionClosed`, `NotPositionOwner`), all covered by the suite and by mutants E1/E2. Attacker =
  depositor (goal: dodge the 10% on uncollected fees): possible once the owner enables eject for
  the pool, known and by design. Attacker = malicious `to` contract (goal: re-enter during the
  transfer): solmate `transferFrom` has no receiver callback; the PositionManager override only
  unsubscribes an existing subscriber, and the router never subscribes (`subscribe` is
  `onlyIfApproved`) [verified by reading `PositionManager.sol` L549-552, `Notifier.sol` L40-45];
  `nonReentrant` regardless. Attacker = holder of an ejected NFT (goal: get the router to act on
  it again): sending it back makes `_ownerOf == router` true but the record is `closed`, so every
  entry point reverts; the NFT is stranded (probe `testProbeEjectedNftReturnedToRouterIsStranded`
  [verified]). Same class as the known "no sweep".
- **C15, attacker = misbehaving token or depositor (goal: draw on reserves, or pay less than
  owed to a third party).** `_split` lowers only what the *depositor* receives, to exactly what
  arrived (L812); the router's retained balance is still floored at `before + commission`
  (L827, lower bound unchanged, mutant M09 of the first pass killed), so commission reserves and
  dust cannot be drawn on. Fees are computed as `received − principal`, so a shortfall first eats
  the fees, then up to 2 units of principal, then reverts (L811; mutant S1 killed). The only
  party that can lose is the depositor, and only what the token withheld. Attacker = MEV (goal:
  use the tolerance to defeat `amount0Min`): the minimum is checked on the exact principal before
  the burn (L536) and by v4 on the pool delta; the dust tolerance cannot be induced by a price
  move, only by the token itself [inferred]. See I-7 for the semantic gap.

# Findings

## LOW L-3: The inbound tolerance on the currency1 leg has no test that fails when it is removed

**File**: src/ValariRouterV3.sol:779 (`_split(received1, payout.principal1)`); test/ValariRouterV3.t.sol:2490-2549
**Blast Radius**: `_distribute` (all collections and exits)
**Test Coverage**: PARTIAL

**Description** [verified by mutation, S2 below]: the suite's rounding token (`StickySenderToken`)
sorts below USDG in the fixture, so it is always currency0 (the test handles both orders with a
`stockIs0` branch, but only one is ever taken). Reverting L779 to the strict V1 comparison passes
all 76 tests; only the reviewer probe `testProbeInboundToleranceAppliesToCurrency1` fails. This
is the same shape as the first pass's M13 (currency1 `_checkRetained`), which has since been fixed
by a test; the new tolerance reintroduced the gap on the inbound side.

**Why it matters**: HEAD is correct. The gap means a refactor that drops or mistypes the
currency1 line passes CI, and a stock listed as currency1 (any stock whose address sorts above
USDG) would then revert on exit under exactly the rounding the tolerance was added for.

**Recommendation**: add the probe test in Appendix B; it passes on HEAD and kills S2 [verified].

## LOW L-2 (carried over): The scripts are untested offline and their failure branches untested everywhere

Unchanged from the first pass (scripts have the same mtimes). The fork fixture's assertion of
exactly 100 pools is on the known list. Not re-analysed.

## INFORMATIONAL I-6: The two switches are per pool with no batch form, while their stated trigger is global

**File**: src/ValariRouterV3.sol:262-276
[verified by reading] Each setter takes one `bytes32 poolId`. The NatSpec's use case, "an issuer
restricted the router's address", applies to USDG (one leg of every pool) and to the shared stock
beacon, i.e. to all 100+ pools at once, so the response is 100+ owner transactions from a single
EOA. Positions are safe meanwhile; the hatch is merely slow, and a half-applied deposit freeze
leaves some pools open. Minimal fix: array parameters or an additional global flag; both keep the
write sets to the two booleans. Detailed in `token-integration.md` N-5.

## INFORMATIONAL I-7: `amount0Min`/`amount1Min` bound the pool's delivery, not what reaches `to`

**File**: src/ValariRouterV3.sol:536, 808-812, 827-829; NatSpec 436-437
[verified by probe `testProbeExitMinimumCanBeUndershotByInboundDust`] With `amount0Min` equal to
the live principal and a token delivering 2 units less, the exit succeeds and the depositor
receives `amount0Min − 2`; the outbound `_checkRetained` tolerance allows 2 more. Value at most 4
raw units per leg; nobody else gains. A strict post-check would make the tolerance useless when a
UI passes the view amount as the minimum, so the fix is wording in the NatSpec and README.

## INFORMATIONAL I-8: README bound on unmade transfers describes principal and outbound only

**File**: README.md:104-105; src/ValariRouterV3.sol:808-809
[verified by probe `testProbeShortfallSwallowsSmallFeesWithoutCommission`] The router learns the
fee amount only as `received − principal`, so on the inbound leg a token can withhold any part of
the LP fees undetected (also true of BASE and the previous HEAD), plus now 2 units of principal.
The depositor is paid what arrived and the fee recipient gets no commission on withheld fees.
Qualify the README sentence.

## INFORMATIONAL I-3 (carried over, widened): Off-chain consumers are on the V1 interface, and now the changed events

[verified by grep] `valari/src/lib/abis.js:67` still declares the 7-argument `openPosition` and
`abis.js:74` `stockPoolId`; no frontend file references the five new functions. New since the
first pass: `valari-subgraph/subgraph.yaml:379` and `:385` subscribe to
`FeesCollected(indexed address,indexed uint256,indexed address,uint256,uint256,uint256,uint256)`
and the 9-field `PositionExited`. Both events gained a trailing `address to`, which changes their
topic0, so a V3 router indexed by this subgraph records **no** collections or exits (and no
`PositionEjected`, `PoolAdded`, `DepositsDisabledSet`, `EjectEnabledSet`). This fails silently,
unlike the frontend's unknown-selector failure. Update the ABI, the event signatures and add
handlers for the four new events before indexing V3.

# Test Coverage Analysis

**Method.** Shadow project `/tmp/tob-rerun/shadow` (copies of `src/`, `foundry.toml`,
`remappings.txt`, `test/ValariRouterV3.t.sol`, `test/ValariRouter.t.sol`; `lib` symlinked; test
files copied so `../src/ValariRouterV3.sol` resolves to the mutated copy). A reviewer probe
contract `test/TobProbe.t.sol` inherits `ValariRouterV3Test`, so each run executes the 76 project
tests plus 5 probes against the same build. Each mutant changes one behaviour of the new code,
is applied by `/tmp/tob-rerun/mutants.py`, run with
`forge test --offline --match-contract '^TobProbeTest$'`, then reverted. Baseline: 76/76 project
tests and 5/5 probes pass on HEAD [verified]. The project tree was not modified.

**Coverage of the additions:** 8 of 10 mutants killed by the project suite; 9 of 10 counting the
probe; 1 equivalent against the pinned PositionManager.

| ID | Mutation (HEAD line) | Result | Killed by |
|----|----------------------|--------|-----------|
| E1 | `ejectPosition`: remove the `ejectEnabled` check (464) | killed | testEjectIsOffUntilTheOwnerEnablesItForThatPool |
| E2 | `ejectPosition`: do not set `record.closed` (466) | killed | testEjectFreesAPositionTheRouterCanNoLongerPayOut (+ probe) |
| E3 | `ejectPosition`: remove the post-transfer `ownerOf == to` check (468) | survived (equivalent) | solmate `transferFrom` sets `_ownerOf[id] = to` or reverts (`ERC721.sol` L87-104); the check guards against a different PositionManager implementation, which the immutable rules out |
| E5 | `ejectPosition`: remove `_checkRecipient(to)` (465) | killed | testEjectFreesAPositionTheRouterCanNoLongerPayOut (`expectRevert(InvalidRecipient)` for zero and router) |
| S1 | `_split`: shortfall unbounded (remove 811) | killed | testExitSurvivesTokenThatDeliversLessThanThePoolSent (+ probe) |
| S2 | `_split` not applied on currency1: strict V1 comparison at 779 | **SURVIVED the project suite** (76/76 pass) | reviewer probe testProbeInboundToleranceAppliesToCurrency1 only (L-3) |
| R1 | `_checkRecipient`: allow the router (818) | killed | testBeneficiaryWhoCannotReceiveATokenIsPaidAtAnotherAddress, testEjectFreesAPositionTheRouterCanNoLongerPayOut |
| T1 | `collectFeesTo` pays `msg.sender` instead of `to` (432) | killed | testBeneficiaryWhoCannotReceiveATokenIsPaidAtAnotherAddress |
| T2 | `exitPositionTo` pays `msg.sender` instead of `to` (455) | killed | testBeneficiaryWhoCannotReceiveATokenIsPaidAtAnotherAddress (+ probe) |
| D1 | `openPosition`: ignore `depositsDisabled` (313) | killed | testOwnerStopsAndResumesDepositsForOnePool |

Not run (outcome predictable from the suite's `expectRevert` selectors, or covered by the
project's own 21-mutant run): `setEjectEnabled`/`setDepositsDisabled` without `onlyOwner` or
without the `getPoolKey` check; `_split` reporting `expectedPrincipal` instead of `received`;
`MAX_PAYOUT_DUST` off by one (the first pass's M07/M08 still apply to the shared constant).

**Untested Changes:**

| Function | Risk | Impact |
|----------|------|--------|
| `_distribute` currency1 inbound tolerance (779) | HIGH area | A dropped tolerance would make a currency1 stock that rounds unexitable through the router (eject would still work) |
| Both fork tests for the new paths (`ValariRouterV3ForkExitPathsTest`) | MEDIUM | Not runnable offline; the only coverage of eject/`*To`/deposit stop against the deployed GOOGL and USDG |

# Blast Radius Analysis

| Function | Call sites | Reached from | Risk | Priority |
|----------|-----------|--------------|------|----------|
| `_split` (new) | 2 | `collectFees[To]`, `exitPosition[To]` | HIGH | P2 |
| `_checkRecipient` (new) | 3 | `collectFeesTo`, `exitPositionTo`, `ejectPosition` | HIGH | P2 |
| `_collectFees` / `_exitPosition` (extracted) | 2 each | plain and `*To` entries | HIGH | P2 |
| `ejectPosition` (new) | 0 internal | depositors; tests ×13; frontend ×0 | HIGH | P2 |
| `setDepositsDisabled` / `setEjectEnabled` (new) | 0 internal | owner; tests ×5 / ×8; scripts ×0 | HIGH | P2 |
| `depositsDisabled` / `ejectEnabled` (new storage) | 1 reader each | `openPosition` L313 / `ejectPosition` L464 | - | - |
| `FeesCollected` / `PositionExited` (signature) | - | subgraph ×2 handlers | MEDIUM (off-chain) | I-3 |

Transitive dependencies read for C14: `PositionManager.transferFrom` (L549-552),
`Notifier.subscribe` (L40-45), solmate `ERC721.transferFrom` (L82-107).

# Historical Context

Git blame/log were not available. Substitutes: the first-pass report, `AUDIT.md`, the README V3
section, and the previous reports' recommendations, which the additions trace to:

- `setDepositsDisabled` implements `token-integration.md` (first pass) N-1 exactly as recommended
  ("a per-pool, owner-settable flag checked only in `openPosition`").
- `_split` implements `secure-workflow.md` (first pass) New concern 1 ("give L682 the same
  two-unit allowance, treating a shortfall of up to `MAX_PAYOUT_DUST` as zero fees").
- The four tests of the first pass's Appendix B are in the suite.
- `ejectPosition` and the `*To` variants address the known "no escape hatch / no alternate
  payout recipient" item.

**Security-relevant removals (previous HEAD to HEAD):** none. The strict `received < principal`
revert in `_distribute` was replaced by `_split`, which keeps the revert beyond 2 units; nothing
else was removed.

**Regression risks:** none found. The M-01 remediation (credit-based commission) is unchanged;
`ejectPosition` bypasses it only for uncollected fees, by design, and never credits or debits.

# Recommendations

### Immediate (Blocking)
- [ ] Add `testProbeInboundToleranceAppliesToCurrency1` (L-3, Appendix B).
- [ ] Update `valari-subgraph/subgraph.yaml` event signatures and `valari/src/lib/abis.js`
      before indexing or calling V3 (I-3).

### Before Production
- [ ] Run `RUN_ROBINHOOD_FORK=true forge test --match-contract 'ValariRouterV3Fork'` including
      `ValariRouterV3ForkExitPathsTest`, and both script simulations (L-2).
- [ ] Decide on batch/global switches (I-6).

### Technical Debt
- [ ] NatSpec L436-437 and README L96-105 wording (I-7, I-8).

# Analysis Methodology

**Strategy:** DEEP (2 source files, 2 scripts, 3 tests; SMALL codebase), focused on the five
additions since the first pass.

**Analysis Scope:**
- Files reviewed: 7/7 changed files; the router read in full; the additions line by line against
  the previous HEAD as described in the task brief and against BASE.
- HIGH RISK changes (C11-C15): 100%, with adversarial modelling.
- C1-C10: carried over from the first pass; re-checked only where the additions touch them
  (`_distribute`, event definitions, `openPosition` L313).

**Techniques:**
- Invariant comparison previous HEAD vs HEAD (access matrix via `printers/custom_checks.py`,
  extended with checks 8-10 for the switches, eject and the `*To` write sets; all hold).
- Mutation testing in a shadow copy (10 mutants + the first pass's sanity mutant already shown to
  fail 48 tests on this fixture).
- Reviewer probes (5), all passing on HEAD, two of them demonstrating I-7 and I-8.
- Dependency reading on the eject path.
- ABI check: `abi/ValariRouterV3.json` equals the compiled ABI (86 entries) [verified]. Runtime
  size 19,567 bytes [verified].
- Off-chain consumer grep across `valari/`, `valari-subgraph/`, `ui/`.

**Skill steps not performed, and why:**
- Git blame / `git log -S`: no history exists. Replaced by the first-pass report and the task
  brief's list of additions.
- `audit-context-building` and `issue-writer`: not installed.
- Fork tests and script execution: no network or RPC permitted.
- `forge coverage`: not run (via-IR); mutation results used instead.
- The project's own 21-mutant run was not repeated; 10 mutants of the same code were run here.

**Limitations:** the stock tokens and USDG could not be inspected; whether any of them rounds on
transfer (the case `_split` exists for) is unverified. The machine was shared with other jobs.

**Confidence:** HIGH for the router additions; MEDIUM for off-chain consequences (grep only).

# Appendix A: Known items (not re-reported)

No escape hatch except the owner-enabled eject; single-EOA owner with `renounceOwnership`; no
sweep for stray tokens/NFTs; price bounds relative to the pool's own spot; `addPool` lists any
hookless initialized USDG pool; the dust tolerance cannot distinguish rounding from an unmade
transfer of 1–2 units; eject bypasses commission on uncollected fees; ejected NFTs sent with plain
`transferFrom` to the depositor's chosen address; deploy script requires exactly 100 pools and the
fork fixture asserts 100. None was found to be handled wrongly by the additions. Two are touched
in passing where the handling has a sharper edge than the known wording: I-7/I-8 (the 1–2 unit
bound) and the returned-NFT case under "no sweep" (C14 adversarial pass).

# Appendix B: Test that closes L-3

Passes on HEAD; fails on mutant S2 [verified]. Extends `ValariRouterV3Test` (imports: `PoolKey`,
`Currency`, `StickySenderToken`; uses the suite's `_newStockPool` and `_openOn`).

```solidity
// The suite's rounding stock is always currency0. Here it is currency1, so the
// `_split(received1, ...)` tolerance is the one exercised.
function testInboundToleranceAppliesToCurrency1() public {
    StickySenderToken stock;
    do {
        stock = new StickySenderToken();
    } while (address(stock) < address(token0));
    PoolKey memory added = _newStockPool(address(stock));
    bytes32 addedId = router.addPool(added);
    assertEq(Currency.unwrap(added.currency1), address(stock));
    stock.mint(alice, 2 * BUDGET);
    vm.prank(alice);
    stock.approve(address(router), 2 * BUDGET);
    uint256 tokenId = _openOn(addedId, alice, BUDGET, BUDGET, -2000, 2000);
    ValariRouterV3.PositionView memory held = router.getPosition(tokenId);

    stock.setStickySender(address(manager));
    stock.setStickyUnits(3);
    vm.expectRevert(ValariRouterV3.InsufficientProceeds.selector);
    vm.prank(alice);
    router.exitPosition(tokenId, 0, 0, block.timestamp);

    stock.setStickyUnits(2);
    uint256 stockBefore = stock.balanceOf(alice);
    vm.prank(alice);
    ValariRouterV3.Payout memory payout = router.exitPosition(tokenId, 0, 0, block.timestamp);
    assertEq(payout.principal1, held.amount1 - 2);
    assertEq(payout.fees1, 0);
    assertEq(payout.amount1, held.amount1 - 2);
    assertEq(stock.balanceOf(alice) - stockBefore, held.amount1 - 2);
    assertEq(payout.principal0, held.amount0);
    assertTrue(router.getPosition(tokenId).closed);
}
```

# Appendix C: Reproduction

```sh
cd /tmp/tob-rerun/shadow
# baseline + probes
FOUNDRY_OUT=/tmp/tob-rerun/shadow-out FOUNDRY_CACHE_PATH=/tmp/tob-rerun/shadow-cache \
  forge test --offline --match-contract '^TobProbeTest$'
# one mutant: apply, test, restore
python3 /tmp/tob-rerun/mutants.py S2 /tmp/tob-rerun/V3.orig.sol src/ValariRouterV3.sol
FOUNDRY_OUT=/tmp/tob-rerun/shadow-out FOUNDRY_CACHE_PATH=/tmp/tob-rerun/shadow-cache \
  forge test --offline --match-contract '^TobProbeTest$'
cp /tmp/tob-rerun/V3.orig.sol src/ValariRouterV3.sol
```

Mutant definitions: `/tmp/tob-rerun/mutants.py`. Results: `/tmp/tob-rerun/results.txt`;
per-mutant logs `/tmp/tob-rerun/logs/`. Probes: `/tmp/tob-rerun/shadow/test/TobProbe.t.sol`.
These live in `/tmp` and are not preserved; the table above is the record.
