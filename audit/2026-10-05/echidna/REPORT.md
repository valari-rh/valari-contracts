# Echidna stateful campaign — ValariRouter.sol — 2026-10-05

**All seven configured properties passed across 20,014 generated calls.** No counterexample was found within this campaign's model and bounds. This report covers `RouterEchidna.sol` and `campaign.log`; the separate `RouterSlippageEchidna.sol` experiment is outside this report.

## Recorded run

| Item | Value |
| --- | --- |
| Echidna | 2.3.3 |
| Compiler settings verified in build-info | Solidity 0.8.26, via-IR, Cancun, optimizer 200 runs |
| Mode / seed / workers | Property / 20261005 / 1 |
| Configured test limit / sequence length | 20,000 / 64 |
| Reported calls | 20,014 |
| Covered instructions / unique codehashes | 36,807 / 8 |
| Final corpus sequences | 11 |
| Main campaign duration | Approximately 5 minutes 28 seconds, including preparation and coverage export |
| Main log | `campaign.log` |
| Final coverage | `corpus/covered.1791183252.{html,txt,lcov}` |

The earlier `smoke.log` records a separate 130-call smoke test with Slither disabled. The main campaign enabled Slither preprocessing and started with the two saved smoke-test corpus sequences. Its 20,014-call total should not be added to the smoke total or described as 20,014 successful router operations: calls include harness no-ops, caught failures, and generated operations.

The build-info input was checked against current files byte for byte:

- `src/ValariRouter.sol`: SHA-256 `7195877547776d89f84b4dab60396962074898fef1d8706cb5131b4f434be4f5`.
- `RouterEchidna.sol`: SHA-256 `72e3a47624b624ff984dabd6c7f524d44c071715729f0761f2315f7d6d346a0f`.

The executed router is the unchanged production source. The harness deploys the repository's real Uniswap v4 PoolManager, PositionManager and StateView; Permit2 uses the precompiled runtime installed by the repository's `DeployPermit2` helper. ERC20 tokens and transaction actors are simplified test contracts. Deployment helpers use Foundry-compatible cheatcodes in Echidna.

## Properties exercised

| Property suffix | What was checked |
| --- | --- |
| `commission_is_backed_and_dust_preserved` | Each router token balance equals unsolicited dust plus aggregate commission liabilities; aggregate liabilities equal the two recipients' credits. |
| `custody_and_cumulative_commission` | Depositor identity persists; active NFTs remain in router custody with initial liquidity; closed NFTs are burned; cumulative commission equals floor(cumulative fees / 10) independently per token. |
| `allowances_are_cleared` | Router ERC20 allowances to Permit2 and Permit2 allowances to PositionManager are zero between operations. |
| `token_supply_is_conserved` | The sum of balances at all modeled holders equals the mock token total supply. |
| `payouts_match_actual_balance_changes` | Fee collections, exits, and commission withdrawals match recipient balance deltas, commission credits, and the pre-operation position view. |
| `owner_and_outsiders_cannot_take_positions` | A wrong depositor and router owner cannot collect or exit another user's position; users cannot withdraw treasury credits or change the fee recipient. |
| `deposit_budget_refund_and_quote` | Opens meet the immediate quote, respect budgets, and report the exact user token spend after refunds. |

The action whitelist contains open, swap, pool donation, collection, exit, treasury rotation, commission withdrawal, unauthorized attempts, and direct router dust transfers. Calls target the harness only; the fuzzer cannot call mock-token minting or arbitrary actor `invoke` functions directly.

## Coverage and vacuity review

The constructor requires two successfully opened positions, preventing an empty-position-only passing run. Final coverage marks the deposit, fee collection, exit, commission-accrual, and commission-withdrawal bodies as exercised. All nine action names are present even in the initial saved corpus. The properties therefore did execute against active positions and fund movement rather than only deployment defaults.

The final LCOV report marks **246 of 299 emitted router source-map lines** covered (**82.27%**). This is a source-map-based metric on optimized via-IR output, not branch coverage, not a percentage of all source lines, and not evidence that every critical edge case was reached. The instruction total includes the harness and dependencies, not only the router. Pagination and much of the validation/revert surface remain uncovered.

The harness has no per-action success counters, so exact counts of successful opens, swaps, collects, exits, or withdrawals cannot be recovered from the summary log. `_payout` and `_open` turn unexpected low-level router failures into persistent property failures; however, `previewDeposit` failures can revert the outer `actionOpen` before this bookkeeping. Swap and pool-donation failures are deliberately caught. Operations on closed positions return early; withdrawals with no credit return early; opens return early after eight historical positions. These reduce effective exploration and must not be counted as successful transitions.

## Bounds and limitations

- One initialized hookless pool: fee 3000, tick spacing 60, initial price 1:1; two depositors and two treasury recipients; at most eight historical positions per sequence.
- Three fixed tick-range shapes; generated open budgets from 1,000,000 raw units to approximately 100 ether; swaps up to 80 ether and pool donations below 1 ether.
- Benign ERC20s with standard transfer accounting. No token callbacks, rebasing, transfer taxes, token blacklisting, upgrades, or adversarial external managers are modeled.
- Deadlines and deposit quotes are generated immediately inside actions. This campaign does not test stale quotes, sandwich resistance, expired deadlines, or changes between an off-chain quote and execution. The separate slippage experiment addresses a different property.
- The payout oracle partly uses `router.getPosition`, which shares math with execution. A common-mode error in those calculations could evade the view/output comparison; actual balance and aggregate-liability checks provide additional but not complete independent checks.
- Pool catalog validation, pagination, arbitrary ownership changes, multi-pool interactions, live Robinhood token behavior, and deployed configuration are not comprehensively explored.
- One finite seeded campaign is evidence of tested behavior, not a proof over all inputs and transaction histories.

## Reproduction

From `valari-contracts`:

```bash
bash audit/2026-10-05/echidna/run.sh
```

`run.sh` rebuilds the unchanged harness with the same compiler settings into a fresh `/tmp` directory, copies the original two smoke corpus seeds, and runs the 20,000-call configuration without overwriting the recorded artifacts. It expects Echidna at `/tmp/valari-echidna.TRvFAj/echidna`, the Slither/crytic-compile environment at `/tmp/valari-slither-venv`, and solc at `/home/redkidd/.local/share/svm/0.8.26/solc-0.8.26`. These paths can be overridden with `VALARI_ECHIDNA_BIN`, `VALARI_SLITHER_VENV`, and `VALARI_SOLC_BIN`. The reproduction script was syntax-checked; the long campaign was not rerun during this reporting review.

Original compiler evidence remains in `/tmp/valari-echidna.TRvFAj/out/build-info/23102d337bdfe0fd.json`, and the audit directory retains `crytic-export/combined_solc.json` plus the final corpus and source coverage reports.
