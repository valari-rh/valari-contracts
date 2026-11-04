=== TOKEN INTEGRATION ANALYSIS REPORT ===

Project: Valari — `src/ValariRouterV3.sol` (custodies Uniswap v4 LP NFTs, Robinhood Chain 4663)
Token Analyzed: none implemented. Integration safety against (a) stock tokens (BeaconProxy, 18 dec), (b) USDG (ERC-1967 proxy, 6 dec), (c) any ERC20 the owner lists through `addPool`
Platform: Solidity 0.8.26, Foundry, via-IR; OpenZeppelin 5.0.2, Uniswap v4 core/periphery, Permit2 (all vendored under `lib/`)
Analysis Date: 2026-10-06 (re-applied; supersedes the 2026-10-05 report written against source `19d3d512…`)
Method: Trail of Bits `token-integration-analyzer` skill (Building Secure Contracts token integration checklist + weird-ERC20 list)
Source SHA-256: `f851cb15c188ddb2de32761b996799df856e56d7b9e1362ebbe1a4ac077e0b96`

Line numbers without a file name refer to `src/ValariRouterV3.sol`.

---

## EXECUTIVE SUMMARY

Token Type: protocol integrating external ERC20 tokens (no token implementation in scope) and holding ERC721 position NFTs
Overall Risk Level: LOW for the integration code; the accepted issuer-trust risk on both real tokens is unchanged in kind and reduced in consequence
Critical Issues: 0
High Issues: 0
Medium Issues: 0
Low Issues: 0 (previous N-1 closed by `setDepositsDisabled`)
Informational: 2 new (N-5, N-6); N-2 and N-4 carried over unchanged; N-3 downgraded (now recoverable)

Result in one paragraph: since the previous report the router gained the two things the token checklist asks of an integrator of upgradeable, pausable, blocklisting tokens and that it lacked: a way to freeze the integration on the deposit side (`setDepositsDisabled`, per pool) and a way out for custodied funds when the token refuses the router (`setEjectEnabled` + `ejectPosition`, which moves only the NFT), plus payout-to-another-address variants for a beneficiary the token refuses (`collectFeesTo`, `exitPositionTo`). The receiving-side rounding gap flagged last time is closed by `_split` (two raw units of shortfall against the principal are paid out as they arrived). Every weird-ERC20 row was re-read against the new code; the rows that changed are marked in section 7. Nothing new was found that affects the two real tokens as they behave today. The two new items are informational: the escape hatch and deposit stop are per-pool switches with no batch form, although the most likely trigger (USDG restricting the router) is global; and the payout destination check refuses only the router, so protocol addresses are accepted as `to`.

Already known and accepted items (issuer upgrade/pause/blocklist, fee-on-transfer and rebasing unsupported, `MAX_PAYOUT_DUST` cannot tell rounding from an unmade transfer of 1–2 units, `addPool` lists any hookless initialized USDG pool, eject bypasses commission on uncollected fees, ejected NFTs sent with plain `transferFrom` to the depositor's chosen address, no sweep, single-EOA owner with `renounceOwnership`) were re-checked against the code. Their handling is as described; none was found wrong or incomplete.

---

## 1. GENERAL CONSIDERATIONS

- Security review of the integrated tokens: not available in this repository. The stock token implementation and USDG are known here only through their on-chain ABI (facts supplied by the project). Not assessed.
- Issuer contact / security mailing list for the stock issuer and for USDG: not recorded in the repository. Action unchanged: subscribe to both issuers' upgrade and incident channels. The new switches make the response concrete: `setDepositsDisabled` on an upgrade whose behaviour is not yet understood, `setEjectEnabled` when the router's address is restricted.
- Router review history: `AUDIT.md`, `audit/2026-10-05`, `audit/2026-10-05-v3` (Slither, Echidna, Manticore; the Echidna and Manticore runs in that directory were made against this source hash and include the new functions). This report adds only the token-integration view.

---

## 2. CONTRACT COMPOSITION (the integrator)

Slither 0.11.6 printers, re-run on a fresh build of this source hash (`printers/human-summary.txt`, `printers/contract-summary.txt`; the project's library-scope shim was needed):

- 2 contracts in source (`ValariRouterV3`, `IPermit2Source`), 50 in dependencies; 779 SLOC in source (was 702), 0 assembly lines in source.
- `ValariRouterV3`: 59 functions including inherited (was 50); flagged "Complex code: Yes" (driven by `openPosition`, L292-381) and "Tokens interaction". "Send ETH" is OpenZeppelin `Address.functionCallWithValue` in the dependency closure, always value 0; the ABI has no payable function.
- State-changing entry points: 11 router-declared (`openPosition`, `collectFees`, `collectFeesTo`, `exitPosition`, `exitPositionTo`, `ejectPosition`, `withdrawCommission`, `addPool`, `setDepositsDisabled`, `setEjectEnabled`, `setFeeRecipient`), plus 3 `Ownable2Step` functions. All 11 are `nonReentrant` (`printers/custom-checks.txt`, check 1).
- Solidity 0.8.26 checked arithmetic. One `unchecked` block (L729-732), intentional: v4 fee growth wraps modulo 2^256. It is in a view function. `_split` (L808-811) subtracts only after the ordering check.
- No proxy, no `delegatecall`, not upgradeable, no `receive`/`fallback`/`payable`.
- Token-facing surface is five private helpers and two inline transfers: `_pull` (L899-905), `_approve` (L907-912), `_refund` (L914-928), `_checkRetained` (L825-830), `_distribute` (L764-798) with `_split` (L803-813), `withdrawCommission` (L396-413). `ejectPosition` (L462-470) is the one position path with no ERC20 call (check 9).
- Runtime bytecode 19,567 bytes (EIP-170 limit 24,576; was 18,611).

Checks:
- [x] Avoids unnecessary complexity (token paths are small and separated; the two `To` variants add no token code, only a parameter)
- [x] Solidity 0.8+
- [x] Single address entry point (n/a – integrator; router is one immutable address)

Status: PASS

---

## 3. OWNER PRIVILEGES

### 3a. Privileges of the integrated tokens' issuers (facts supplied, not re-queried)

| Capability | Stock tokens | USDG |
|---|---|---|
| Upgradeable | Yes — BeaconProxy; one beacon upgrade changes every stock token at once | Yes — ERC-1967 proxy |
| Mint | `mint(address,uint256)` | yes |
| Burn from any holder | Yes — `burn(address,uint256)` | Not in the supplied ABI |
| Pause | yes | Not in the supplied ABI; reachable by upgrade |
| Blocklist | `isBlocked` | Not in the supplied ABI; reachable by upgrade |
| Other | `uiMultiplier` (display-only; `balanceOf` is raw) | roles, `owner()` |

Checks:
- [ ] Token is not upgradeable — both are; risk understood and accepted (known). New: the integration can now be frozen on the deposit side per pool (`setDepositsDisabled`) and evacuated per pool (`setEjectEnabled`), which is what the checklist's "freeze integration on upgrade" asks for.
- [ ] Owner has limited minting — unlimited on both; no effect on router accounting (it never reads `totalSupply` and never prices by balance)
- [ ] Not pausable / no blocklist — stock tokens have both; risk understood and accepted (known). New: a pause or a block of the router no longer freezes custodied funds permanently; the owner can enable eject and each depositor takes the NFT out (section 7, rows 7.7/7.8). A block of the depositor's own address is handled by `collectFeesTo`/`exitPositionTo`.
- [ ] Team known and accountable — not assessed here

USDG is one leg of every pool, so an issuer action on USDG reaches every position and every commission balance, while an action on one stock implementation reaches all stock pools through the shared beacon. This is the known freeze risk; what changed is the recovery path, and its shape is the subject of N-5.

### 3b. Privileges of the router owner over token flows

- `addPool` (L255-257, L832-859): lists any hookless, initialized pool with USDG on one side. The other side can be any contract with code except PositionManager, PoolManager, Permit2 and the router (L849-852). Append-only; there is no delist.
- `setDepositsDisabled` (L262-266): per-pool deposit stop, read only by `openPosition` (L313; `printers/custom-checks.txt` check 8). Quotes, collection, exit and eject are unaffected (`testOwnerStopsAndResumesDepositsForOnePool`). This closes the previous report's N-1.
- `setEjectEnabled` (L272-276): per-pool permission for depositors to call `ejectPosition`; read only there (L464; check 8). The owner cannot call `ejectPosition` on anyone's position (`_ownedPosition` L744; `testEjectFreesAPositionTheRouterCanNoLongerPayOut` tries the owner and a stranger). Enabling it gives that pool's depositors a way to leave custody with uncollected fees uncharged (known, by design).
- `setFeeRecipient` (L384-391): future accrual only. Commission is pull-based (L396-413) with a caller-chosen destination, so a restricted fee recipient cannot block user payouts (verified by `testBlockedTreasuryCannotBlockCollectionOrPrincipalExitAndCanUseOtherDestination`).
- The owner has no function that moves a user's tokens or NFT. No rescue/sweep function exists.

---

## 4. ERC20 CONFORMITY

n/a – integrator. `slither-check-erc` and `slither-prop` target a token implementation; the router implements no ERC20 (re-run for completeness, `printers/check-erc-erc20.txt`: every ERC20 function missing, as expected), and the real tokens' source is not in the repository, so neither tool applies to them. What the checklist asks of the tokens, as far as the supplied ABI shows:

- `transfer`/`transferFrom` return bool: assumed for both real tokens; the router does not depend on it (SafeERC20, section 7 row 7.2).
- `name`/`symbol`/`decimals`: the router never calls them. Decimals 18 (stock) and 6 (USDG).
- Approve race: the router only ever sets its own allowance to Permit2 and resets it to zero in the same transaction (L326-327, L362-363).

---

## 5. ERC20 EXTENSION RISKS

- External calls in transfers: the stock tokens call their registry (`isBlocked`) on transfer. That is an issuer-controlled call, not a holder hook; today it gives no third party control mid-transfer. If either token gained holder hooks through an upgrade, the router's `nonReentrant` guards and its price re-read (L344-347) already cover it (row 7.1). `ejectPosition` makes no token call, so a hook cannot run inside it at all.
- Transfer fees: none today on either token. Unsupported by design on the deposit side (exact pull, L902). On the exit side a fee of up to 2 raw units is now absorbed by `_split` (L811); a larger fee still reverts `InsufficientProceeds` unless LP fees cover it (row 7.3).
- Interest / yield: stock tokens accrue corporate actions through `uiMultiplier` while raw balances stay fixed. Raw-unit accounting in the router and in v4 is therefore unaffected. Off-chain consequence: N-2, unchanged. Any entitlement an issuer distributes by holder snapshot instead would be credited to the PoolManager address, not to depositors; nothing in the router or v4 can forward it. Inferred; applies to any AMM custody of these tokens.

Checks:
- [x] No ERC777-style holder hooks today (stock: registry call only)
- [x] No transfer fees today
- [x] Yield accounted for (multiplier, not rebase)

---

## 6. TOKEN SCARCITY ANALYSIS

Not performed: no network access was allowed for this review, and the skill forbids guessing on-chain values. Unchanged from the previous report: liquidity is fragmented across many fee tiers, so a listed pool can be thin and its spot price cheap to move; the router does not price anything from balances or supply, and the only place spot price matters is `openPosition`, bounded by caller-supplied price limits (L311, L316-318) and the pre-mint re-read (L344-347). `exitPosition`'s principal minimums (L536) are the exit-side protection. Flash-loan and flash-mint exposure of the router itself: none found; `ejectPosition` moves no value.

---

## 7. WEIRD ERC20 PATTERN ANALYSIS

"Real today" = a behaviour the stock tokens or USDG have now. "Upgrade" = one they can acquire by issuer upgrade. "Listed" = only an arbitrary owner-listed token could have it. Rows marked **changed** differ from the previous report because of the new code; all other rows were re-read and their line numbers updated.
Verification: "PoC" = shadow-project probe (`/tmp/tob-rerun/shadow/test/TobProbe.t.sol`, this review) or the previous review's PoCs where the code path is unchanged; "suite" = existing project test; "read" = traced through the cited code.

| # | Behaviour | Router handles it? | Lines | Applies to | Verified |
|---|---|---|---|---|---|
| 7.1 | Reentrant calls (ERC777 hooks, callbacks) | Yes. Every mutating entry point is `nonReentrant`; state is written before payouts; the pool price is re-read after the last foreign call and must equal the quoted price. `ejectPosition` closes the record before its only external call, an ERC721 transfer with no receiver hook | L255, L262, L272, L304, L384, L396, L418, L428, L440, L454, L462; L344-347; L466-467; L780-795 | Upgrade, Listed | suite: `testFundingCallbackCannotReenter`, `testCollectionCallbackCannotReenterExit`, `testExitCallbackCannotReenterCollection`, `testCommissionWithdrawalCallbackCannotReenter`, `testTokenCallbackCannotMovePriceBetweenBoundsCheckAndMint`, `testApproveCallbackCannotMovePriceBetweenBoundsCheckAndMint` |
| 7.2 | Missing return values (USDT, BNB, OMG) | Yes, on all three transfer paths: router (OZ SafeERC20), Permit2 pull (solmate), PoolManager payout (v4 `CurrencyLibrary`) | L901, L908, L924, L410, L794-795 | Listed | previous PoC (path unchanged) |
| 7.2b | False returned on success (Tether Gold) | Reverts safely at the first pull; nothing custodied | L901 | Listed | previous PoC |
| 7.3 **changed** | Fee on transfer | Deposit: reverts safely (exact pull, L902; exact refund, L919-927). Exit: a fee of at most `MAX_PAYOUT_DUST` (2 units) on the pool-to-router leg is absorbed and paid out as it arrived (`_split` L808-812); larger reverts `InsufficientProceeds` unless LP fees in that token cover it (then it comes silently out of the reported fees, as before). Previously any shortfall reverted | L899-905, L914-928, L803-813 | Upgrade, Listed | suite: `testFeeOnTransferFundingRevertsAtomically`, `testExitSurvivesTokenThatDeliversLessThanThePoolSent` (currency0); PoC `testProbeInboundToleranceAppliesToCurrency1` (currency1) |
| 7.4 | Balance changes outside transfers (rebase, airdrop, admin mint/burn) | Rebase: unsupported, reverts (known). Admin mint or airdrop to the router: ignored by per-call baselines, stays locked (N-4). Admin burn of the router balance: commission withdrawals revert until refilled, positions unaffected (known) | L900, L482-483, L539-540, L773-777, L403-405 | Real today (issuer mint/burn), Upgrade (rebase) | suite: `testExistingRouterDustCannotBeSpentOrRefundedToDepositor`, `testCollectionAndExitCannotDistributeExistingRouterDust` |
| 7.5 **changed** | Upgradable tokens | No upgrade detection (known). New: the owner can stop deposits into any pool (`setDepositsDisabled`, L262-266, L313) and, if the upgraded token refuses the router, let depositors leave with their NFTs (`setEjectEnabled` L272-276, `ejectPosition` L462-470). Both are manual, per pool, and depend on a live owner key | L262-276, L313, L462-470 | Real today | suite: `testOwnerStopsAndResumesDepositsForOnePool`, `testEjectFreesAPositionTheRouterCanNoLongerPayOut`; Echidna `echidna_pool_switches_hold` |
| 7.6 | Flash mintable | Not affected: no logic depends on supply or on balances as a price | — | Listed | read |
| 7.7 **changed** | Blocklists | Blocked fee recipient: handled (pull-based, alternate destination). Blocked depositor: handled, `collectFeesTo`/`exitPositionTo` pay an address the depositor names (L427-433, L448-456; `_checkRecipient` L817-819). Blocked router or PoolManager: payouts revert atomically and the position stays intact; the owner can then enable eject and the depositor takes the NFT out with no token transfer (L462-470), then burns on Uniswap directly. Scope unchanged: only a nonzero leg in the restricted token blocks a payout | L396-413, L427-456, L462-470, L794-795, L817-819 | Real today (stock), Upgrade (USDG) | suite: `testBlockedTreasury...`, `testBeneficiaryWhoCannotReceiveATokenIsPaidAtAnotherAddress`, `testEjectFreesAPositionTheRouterCanNoLongerPayOut`; fork (not run here): `testForkEjectedPositionExitsDirectlyOnUniswap`, `testForkBeneficiaryIsPaidAtAnotherAddressAndDepositsCanBeStopped` |
| 7.8 **changed** | Pausable | Same as 7.7: reverts atomically while paused, nothing lost; eject works during a pause because it moves no token | same | Real today (stock), Upgrade (USDG) | read; same code path as 7.7 |
| 7.9 | Approval race protection (USDT, KNC) | Yes. `forceApprove`, and the allowance to Permit2 is back at zero before the transaction ends | L908, L362-363 | Listed | previous PoC |
| 7.10 | Revert on approval to zero address | n/a: the only spender is Permit2, which the constructor requires to have code | L908, L234-237 | — | read |
| 7.11 | Revert on zero-value approval (BNB) | Reverts safely: the post-mint reset reverts, so no position can be opened with such a token. Availability only | L362-363, L908 | Listed | previous PoC |
| 7.12 | Revert on zero-value transfer (LEND) | Yes. Every router transfer is guarded by a nonzero check; PositionManager skips zero settles and takes | L901, L924, L794-795, L397 | Listed | previous PoC |
| 7.13 **changed** | Multiple token addresses (double entry point) | No sweep or rescue function exists, so the classic exploit is absent. Two entry points as the two currencies of one pool: a one-sided position can open and cannot exit through the router (previous N-3). New: it is no longer stuck for good; the owner can enable eject for that pool and the depositor burns on Uniswap directly, where the PoolManager pays both legs from the one ledger | L773-779, L794-797, L462-470 | Listed | previous PoC for the stuck exit; eject path by read (the direct burn is the same `BURN_POSITION + TAKE_PAIR` the fork test `testForkEjectedPositionExitsDirectlyOnUniswap` uses) |
| 7.14 | Low decimals (USDG 6) | Yes. Raw-unit accounting throughout; commission uses a per-position carry; payout dust tolerance is 2 raw units on each side | L751-760, L50 | Real today | suite: `testTinyRepeatedClaimsCarryCommissionRoundingThroughExit`, `testAsymmetricRawAmountsAtStockUsdPriceScale` |
| 7.15 | High decimals / very large amounts | Yes. Budgets are `uint128`; liquidity is capped at `int128.max`; recorded amounts go through `SafeCast` | L294-295, L591-593, L374-375 | Listed | suite: `testFuzzBudgetsBoundActualSpendingAndKeepNftInRouterCustody` |
| 7.16 | `transferFrom` with `src == msg.sender` | n/a: the source is never the spender | L901 | — | read |
| 7.17 | Non-string metadata (MKR) | n/a on-chain: the router never calls `name`, `symbol` or `decimals` | — | Listed | read |
| 7.18 | Revert on transfer to zero address | n/a: recipients are `msg.sender`, or a `to` checked nonzero by `_checkRecipient` (payouts) or by `withdrawCommission` | L397, L817-819, L924 | — | read |
| 7.19 | No revert on failure (ZRX, EURS) | Yes. A `false` return reverts in SafeERC20, in solmate (Permit2) and in v4 `CurrencyLibrary` | lib code unchanged | Listed | previous PoC |
| 7.19b **changed** | Returns `true` but moves nothing or the wrong amount | Deposit and refund: exact-delta checks revert. Payout, outbound: a surplus above 2 units left in the router reverts `UnsupportedToken` (`_checkRetained`). Payout, inbound (new): a shortfall above 2 units against the exact principal reverts `InsufficientProceeds` (`_split`). The router never knows the fee amount independently, so on the inbound leg a token can withhold any part of the LP fees undetected (true of the strict V1 check too) plus 2 units of principal; the depositor is paid exactly what arrived, so no third party gains | L902, L919-927, L825-830, L803-813 | Upgrade, Listed | suite: `testTokenReportingTransfersItDidNotMakeCannotCollectOrCloseAPosition`, `testSurplusToleranceStopsAtMaxPayoutDust`, `testPayoutStillCannotDrawOnEarlierBalances`, `testExitSurvivesTokenThatDeliversLessThanThePoolSent`; PoC `testProbeShortfallSwallowsSmallFeesWithoutCommission` |
| 7.20 | Revert on large approvals/transfers (UNI, COMP: 2^96) | Reverts safely for a budget at or above 2^96; works below | L908, L901 | Listed | previous PoC |
| 7.21 | Code injection via token name | n/a on-chain. Any UI that renders `name`/`symbol` of a listed pool must escape them | — | Listed | read |
| 7.22 | Unusual `permit` | n/a: the router never calls a token's `permit` | L901 | — | read |
| 7.23 | Transfers less than requested (cUSDCv3 `uint256.max`) | n/a for the sentinel; any other under-delivery is caught as in 7.19b | L294-295, L784-785 | Listed | read |
| 7.24 | ERC20 representation of the native currency | n/a: a currency without code, including `address(0)`, cannot be listed, and the router has no payable path | L841 | Listed | suite: `testCodelessCurrencyIsNotListableOnEitherSide` |

Summary for the two real tokens as they behave today: only 7.4 (issuer mint/burn), 7.5, 7.7, 7.8 and 7.14 apply, and each is either handled or a known, accepted issuer-trust item. For 7.5, 7.7 and 7.8 the consequence of the accepted item changed from "funds frozen while the condition lasts" to "funds recoverable by eject once the owner enables it".

---

## 8. TOKEN INTEGRATION SAFETY

Safe transfer usage
- Every router token call goes through OZ 5.0.2 SafeERC20: `safeTransferFrom` (L901), `forceApprove` (L908), `safeTransfer` (L410, L794, L795, L924). No raw `transfer`/`approve`.
- The two transfers the router does not make itself are also safe wrappers: Permit2's pull to the PoolManager (solmate) and the PoolManager's payout to the router (v4 `CurrencyLibrary`).
- The one ERC721 transfer the router makes (`ejectPosition` L467) is `IERC721.transferFrom` on the immutable PositionManager, followed by an `ownerOf == to` check (L468). No receiver check, by design (known).

Balance verification
- No cached balances anywhere. Each operation takes its own baseline (L900, L482-483, L539-540, L403) and compares after the fact: exact on deposit (L902) and refund (L919-927); on payout, `received = balance - before` with a floor of `principal - 2` on the inbound leg (L808-812) and `before + commission` with at most 2 units above it on the outbound leg (L827-829).
- Consequence: balances the router already holds (commission, dust, donations) can be neither spent by a deposit nor paid out to a depositor. Verified by the existing suite; mutant M09 of the previous review (shortfall no longer reverts) is killed.
- The PoolManager measures what it actually received on settle, so a short Permit2 pull cannot mint an under-funded position; it reverts the mint.

Allowances
- Authority given for the mint is exact, lasts one transaction (Permit2 expiration 0) and is revoked on both layers after the mint (L362-363). The router never approves an ERC721 operator.

Reentrancy
- All 11 mutating entry points are `nonReentrant`; effects precede payouts (L543, L466, L780-793, L408-409).
- View functions are not guarded (unchanged, informational).

Allowlist
- Contract-level allowlist: yes, the owner-curated pool catalog. Structural only (hookless, initialized, USDG on one side, code present, four protocol addresses excluded). New: a listing can be switched off for deposits (`depositsDisabled`), which is the amendment the checklist asks for; it still cannot be removed, which keeps exits unstoppable.

Upgrade detection / circuit breaker
- No automatic detection. Manual, per pool, owner-operated: deposit stop and eject enable. Both depend on the owner key being live (known: single EOA, `renounceOwnership` enabled). See N-5 for the shape of the switches.

Payout destinations (new)
- `collectFeesTo`, `exitPositionTo`, `ejectPosition`: `to` must be nonzero and not the router (L817-819). The router is refused because its own balance is how payouts are measured; nothing else is refused. See N-6.

---

## 9. ERC721 CONFORMITY

n/a – integrator. The router holds PositionManager NFTs; it implements no ERC721 (`printers/check-erc-erc721.txt` re-run: every ERC721 function missing, as expected).

## 10. ERC721 COMMON RISKS (router as holder, and now as sender)

- PositionManager mints with solmate `_mint`, not `_safeMint` (`PositionManager.sol` L369), so no `onERC721Received` callback reaches the router during a mint. The router does not implement the receiver interface: `safeTransferFrom` of a foreign NFT to it reverts, while a plain `transferFrom` succeeds and leaves that NFT unusable. New variant: an ejected NFT sent back to the router by its holder is also stranded, with a `closed` record that blocks every entry point (`testProbeEjectedNftReturnedToRouterIsStranded`). Loss falls on the sender only; same class as the known "no sweep".
- `ownerOf` reverts for a burned id in solmate; the router wraps it (L868-874) and requires the NFT to be gone after an exit (L553), still in custody after a collection (L495-500), and held by `to` after an eject (L468).
- The router never approves an operator on its NFTs. The one function that transfers one, `ejectPosition`, uses `transferFrom` (no receiver callback; `PositionManager.sol` L549-552 adds only an unsubscribe when a subscriber exists, and the router never subscribes; `subscribe` is `onlyIfApproved`, `Notifier.sol` L40-45, so nobody else can). Transfer clears `getApproved` in solmate; the router granted none.
- Because ERC721 `approve`/`transferFrom` share selectors with ERC20, PositionManager is excluded as a listable stock (L849-852). Known; re-checked, correct.

---

## NEW CONCERNS (not in the already-known list), most severe first

### N-5 (Informational, operational) — The escape hatch and deposit stop are per pool; their likely trigger is global

Lines: `setDepositsDisabled` L262-266, `setEjectEnabled` L272-276 (one `bytes32 poolId` each; no array or global form); catalog size 100 at deployment and growing (`MAX_INITIAL_POOLS` L43, `addPool` L255).
Status: verified by reading; the count of 100 initial pools is from `config/robinhood.json` and the deploy script.

The NatSpec names the use case: "an issuer restricted the router's address". USDG is one leg of every pool and the stock implementations share one beacon, so the realistic trigger affects every pool at once, while the remedy is one owner transaction per pool: 100+ `setEjectEnabled` calls (and, for a deposit freeze, 100+ `setDepositsDisabled` calls) from a single EOA, during an incident. Nothing is at risk from the delay itself (positions stay intact), but the hatch's usefulness is bounded by how fast one key can push a few hundred transactions, and a partially applied freeze leaves some pools accepting deposits into an unexitable token in the meantime.

Minimal fix: array parameters (`setEjectEnabled(bytes32[] calldata poolIds, bool enabled)`, same for deposits), or an additional global flag checked alongside the per-pool one. Both keep "the owner gains no access to any position" intact (the write sets stay `ejectEnabled`/`depositsDisabled` only). If the code stays as is, pre-sign or script the batch and keep the signer funded.

### N-6 (Informational) — `_checkRecipient` refuses only the router; protocol addresses are accepted as `to`

Lines: `_checkRecipient` L817-819; callers L465, L478, L523.
Status: verified by probe (`testProbePayoutToPoolManagerIsAccepted`, shadow project).

The check enforces exactly the invariant the router needs (its own balance is the payout measurement), and the comment says so. The PoolManager, Permit2 and the PositionManager pass it. ERC20s sent to the PoolManager outside `sync`/`settle` are unrecoverable; an NFT ejected to the PositionManager is stuck forever. These are the depositor's own choices and their own loss, so this is not a defect; it is listed because `setFeeRecipient` and `_addPool` already refuse the same addresses for their own reasons, so a front end may assume the router does too. Minimal fix: none in the contract, or add the three protocol addresses to `_checkRecipient` for consistency; in the front end, never offer protocol addresses as destinations.

### Carried over from the previous report

- N-1 (catalog cannot be frozen): closed by `setDepositsDisabled`. Verified: `testOwnerStopsAndResumesDepositsForOnePool`, custom check 8, Echidna `echidna_pool_switches_hold`.
- N-2 (one raw stock unit is not one share; scale price references by `uiMultiplier`): unchanged, off-chain.
- N-3 (double-entry-point pair opens and cannot exit): downgraded. The router-side exit still cannot complete, but the position is recoverable by eject (row 7.13). Listing runbook line stays.
- N-4 (nothing that reaches the router outside a payout can be recovered): unchanged, now also covers returned ejected NFTs.

---

## COMPLIANCE CHECKLIST

General considerations
- [ ] Security review of the integrated tokens available — not in repository
- [ ] Issuer contactable / security mailing list — not recorded

Contract composition (router)
- [x] Avoids unnecessary complexity
- [x] Solidity 0.8+
- [x] Single address entry point (n/a – integrator)

Owner privileges (integrated tokens)
- [ ] Not upgradeable — both upgradeable; risk understood (known); integration can now be frozen and evacuated per pool
- [ ] Limited minting — unlimited; no router impact
- [ ] Not pausable — stock tokens pausable; risk understood (known); eject works during a pause
- [ ] No blocklist — stock tokens have one; risk understood (known); depositor block handled by `*To`, router block by eject
- [ ] Known team — not assessed

ERC20 conformity — n/a – integrator (router side: missing/false returns handled; metadata unused)
- [x] No holder hooks in transfers today
- [x] No transfer fees today
- [x] Yield accounted for (multiplier is display-only; see N-2)

Token scarcity — not performed (no network access)

Integration safety
- [x] SafeERC20 on every router token call
- [x] Balance verified before/after on every inbound and outbound flow (with a 2-unit tolerance on each payout leg)
- [x] Reentrancy guard on every mutating entry point
- [x] Zero-value transfers skipped
- [x] Allowances exact, single-transaction, revoked
- [x] Contract-level allowlist exists
- [x] Allowlist can be amended / deposits can be frozen on upgrade — yes, per pool (was: no)
- [x] Escape path when a token refuses the integrator — yes, per pool, owner-enabled, depositor-executed (was: none)
- [ ] Upgrade detection — none; manual switches instead (known, by design)

ERC721 — n/a – integrator (holder/sender-side notes in section 10)

---

## PRIORITIZED RECOMMENDATIONS

CRITICAL: none.

HIGH: none.

MEDIUM: none.

LOW: none.

INFORMATIONAL
1. N-5: give both switches a batch or global form, or script the per-pool batch now and rehearse it on a fork.
2. N-6: never offer protocol addresses as payout or eject destinations in the front end; optionally refuse them in `_checkRecipient`.
3. N-2: scale every share-price reference and share-denominated display by `uiMultiplier()`; monitor multiplier changes.
4. Monitor the stock beacon `upgradeTo` and USDG `upgradeTo*` events, `pause`, and blocklist changes for the router, PoolManager and Permit2 addresses; these are the triggers for `setDepositsDisabled` and `setEjectEnabled`.
5. Listing runbook for `addPool`: confirm the stock address against the issuer's registry, confirm it is canonical, never list a pool whose two currencies share a ledger, run one open/collect/exit on a fork before listing. Escape `name`/`symbol` in any UI.
6. State in user documentation that tokens and NFTs sent directly to the router (including an ejected NFT sent back) are lost, and that an ejected NFT goes to `to` with no receiver check.

---

## VERIFICATION LOG

Tools
- Slither 0.11.6 printers `human-summary` and `contract-summary`, re-run on a fresh build of this source hash through the scope-fix shim (`printers/`). `slither-check-erc` erc20/erc721 re-run (not applicable, confirmed). `slither-prop`: not applicable (no token implementation in scope).
- On-chain analysis: not performed (no network access).
- Foundry probes in a shadow project outside the repository (`/tmp/tob-rerun/shadow`, copies of `src/`, `test/ValariRouterV3.t.sol`, `test/ValariRouter.t.sol`, `foundry.toml`, `remappings.txt`; `lib` symlinked). The probe contract inherits the project's `ValariRouterV3Test`, so it runs against real v4 core, v4 periphery and Permit2, and the 76 project tests run alongside it.

Probe tests (file `/tmp/tob-rerun/shadow/test/TobProbe.t.sol`, all PASS on HEAD)

| Test | Shows |
|---|---|
| `testProbeInboundToleranceAppliesToCurrency1` | rows 7.3/7.19b on the currency1 leg: 3-unit shortfall reverts `InsufficientProceeds`, 2-unit shortfall exits and pays `principal - 2` |
| `testProbeExitMinimumCanBeUndershotByInboundDust` | the exit minimum is met by the pool's delivery and the depositor receives 2 units less (differential review, I-7) |
| `testProbeShortfallSwallowsSmallFeesWithoutCommission` | row 7.19b: a token withholding `fees + 2` passes; fees report 0, commission 0, depositor paid what arrived |
| `testProbeEjectedNftReturnedToRouterIsStranded` | section 10: returned ejected NFT is stranded with a closed record |
| `testProbePayoutToPoolManagerIsAccepted` | N-6 |

Existing project suite: 76 tests of `ValariRouterV3Test`, 76/76 passed in the shadow build (`/tmp/tob-rerun/baseline.txt`). Fork tests (`ValariRouterV3Fork.t.sol`, including the two new exit-path tests on the deployed GOOGL token) could not be run: no network.

Not verified by execution (read only): 7.5 switches on a real upgrade, 7.6, 7.8, 7.10, 7.13 eject recovery, 7.16-7.18, 7.21-7.24, N-2, N-5.
