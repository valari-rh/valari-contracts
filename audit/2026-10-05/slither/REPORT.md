# Slither audit — ValariRouter.sol — 2026-10-05

Slither identified no confirmed exploitable issue after manual triage of the router warnings. The complete run generated **120 raw warnings**, of which **24 reference ValariRouter**. Raw severity labels are detector output, not validated vulnerability severities.

## Execution and scope

- Slither **0.11.6**, crytic-compile **0.4.2**, Python **3.12.3**; full package versions in `requirements.lock.txt`.
- Compiler: **0.8.26+commit.8a97fa7a.Linux.g++**, optimizer enabled, 200 runs, **via-IR**, **Cancun**. Recorded in `foundry-config.json`.
- Target: `src/ValariRouter.sol` and its dependency closure; **52 contracts**, **102 detectors**.
- Source SHA-256: `7195877547776d89f84b4dab60396962074898fef1d8706cb5131b4f434be4f5`.
- Compilation was isolated under `/tmp/valari-slither-build`; generated compiler inputs/outputs and ASTs are archived in `compilation-build-info.tar.gz`.
- No production sources or existing tests were changed. This Slither task did not execute a live chain or deployment, nor replace dynamic tests.

## Necessary analyzer compatibility fix

The unmodified Slither run reported `Impossible to generate IR` for `openPosition` and `_commission`, then continued with partial analysis. It resolved `using SafeCast for uint256` to Uniswap's library instead of the directly imported OpenZeppelin library. The missing `toUint64` and `toUint16` methods caused `NoneType.parameters` errors. That run returned exit status 255 and 117 warnings; `results.json`, `results.sarif`, and `slither.log` retain it for transparency. Its three high `uninitialized-state` findings and three router `dead-code` findings are consequences of skipping `openPosition`.

`run_with_scope_fix.py` changes only Slither's in-memory library-name resolution: it selects the library identified by solc's existing `referencedDeclaration` AST ID. It does **not** edit Solidity, change ASTs, suppress detectors, or change compiler options. Its log records the one corrected selection: OpenZeppelin SafeCast, AST ID 2873, in place of Uniswap SafeCast.

The compatibility run completed with **`--disallow-partial`**, eliminating the IR failures and the misleading uninitialized/dead-code findings. `results-scope-fix.json` and `results-scope-fix.sarif` contain the complete run. A second strict validation with `--fail-none` exited **0** and produced the same 120 warnings; see `strict-validation.log`. `--fail-none` changes only the exit policy for detector warnings, while `--disallow-partial` still rejects parser failures. The compatibility shim is a local analyzer workaround, not an upstream Slither release.

## Detector counts

| Raw detector severity | All dependencies included | Findings referencing router |
| --- | ---: | ---: |
| High | 9 | 6 |
| Medium | 18 | 6 |
| Low | 13 | 11 |
| Informational | 80 | 1 |
| Total | 120 | 24 |

The router count includes the compilation-wide pragma warning because it references the router's pragma. It excludes findings confined to dependency files.

## Router warning triage

| Detector | Count | Assessment |
| --- | ---: | --- |
| `reentrancy-balance` (High) | 6 | No exploitable reentrancy found. Four warnings cover `_distribute`'s balance checks, one `_pull`, one `withdrawCommission`. Every reachable fund-mutating entry point holds `nonReentrant`; commission accounting is updated before payouts. Fresh balances are compared against deliberate snapshots, preserving earlier balances. Unexpected token callbacks that alter the balances cause atomic reversion. |
| `incorrect-equality` (Medium) | 1 | `_accrueCommission` line 683 skips zero commissions. This is a valid no-op branch, not an externally controlled balance equality that freezes funds. |
| `uninitialized-local` (Medium) | 1 | `getUserPositions.count` at line 547 is a Solidity value-type local initialized to zero by the language. |
| `unused-return` (Medium) | 4 | `getSlot0` calls intentionally use price, and where necessary tick, while ignoring unrelated fee fields. |
| `calls-loop` (Low) | 5 | Constructor and paginated view lookups call the fixed state/position managers. Pool count and page scan size are capped at 100. This is a bounded gas/dependency consideration, not an unbounded withdrawal loop. |
| `reentrancy-benign` (Low) | 1 | `openPosition` writes its deposit record after mint/refund interactions but holds `nonReentrant` for the entire operation. It validates NFT ownership, minted liquidity, and token-ID progression before recording the position. |
| `timestamp` (Low) | 4 | Three checks enforce caller-selected deadlines. The fourth is spurious timestamp taint on `getPosition`'s depositor existence check; it does not use timestamp for authorization. |
| `shadowing-local` (Low) | 1 | Local `_ownerOf` return variable named `owner` shadows the inherited `owner()` name; the call and value are unambiguous. |
| `pragma` (Informational) | 1 | Dependencies use several compatible pragma ranges; the router and build pin compiler 0.8.26. |

References for the guarded balance paths: `ValariRouter.sol` lines 245–320, 335–354, 358–397, 402–451, 640–680, 707–713; OpenZeppelin `ReentrancyGuard.sol` lines 55–74. Existing repository tests include `testFundingCallbackCannotReenter`, `testCollectionCallbackCannotReenterExit`, `testExitCallbackCannotReenterCollection`, and `testCommissionWithdrawalCallbackCannotReenter`; their execution is outside this Slither run.

## Dependency warnings and limitations

The other three High results flag intentional operations in Uniswap math: the XOR inverse seed in `FullMath.mulDiv` and the table-lookup shifts in `BitMath`. Twelve Medium `divide-before-multiply` results concern exact modular division in `FullMath`, tick alignment/price calculations in `TickMath`, and word padding in `CustomRevert`. Review found no router-specific defect from these patterns. The other dependency warnings concern assembly, large constants, low-level calls, names, unused code, pragmas, and Ownable2Step's intentionally cancellable pending ownership transfer.

The static run does not establish safety of deployed token upgrades, blacklists, pauses, malicious manager implementations, or actual chain configuration. Its reentrancy triage assumes the constructor's immutable manager addresses identify the intended trusted implementations. It does not prove that all user-defined token behaviors are supported or that all economic/integration invariants hold.

## Reproduction

From `valari-contracts`, with approval for package download as needed:

```bash
uv venv /tmp/valari-slither-venv --python python3 --cache-dir /tmp/valari-slither-uv-cache
uv pip install --python /tmp/valari-slither-venv/bin/python --cache-dir /tmp/valari-slither-uv-cache -r audit/2026-10-05/slither/requirements.lock.txt
bash audit/2026-10-05/slither/run.sh audit/2026-10-05/slither/rerun
```

The script runs both stock Slither and the strict compatibility run. Use a new output directory for each reproduction because Slither does not overwrite existing JSON/SARIF outputs. The compiler path is explicit in `run.sh`; adjust it to an installed copy of the same compiler build on another machine.
