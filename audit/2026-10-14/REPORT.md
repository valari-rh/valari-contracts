# ValariRouterV3 re-run of the audit tooling — 2026-10-14

Same source as the 2026-10-05-v3 run: `src/ValariRouterV3.sol` SHA-256
`66c3b1b111e2e1706dfa65f74bdcef01a0f7dcff763cf23e102eb6ccfcecf573` (see `source-sha256.txt`).
Every tool below was re-run from this folder's own scripts, copied from `audit/2026-10-05-v3`
with only the paths changed. Tool binaries: Foundry 1.5.1, Slither 0.11.6 / crytic-compile 0.4.2,
Echidna 2.3.3, Medusa 1.5.1, Manticore 0.3.7 (Python 3.9, protobuf 3.20.3).

## Results at a glance

| Tool | Scope | Result |
| --- | --- | --- |
| Foundry, full suite | 437 tests, 13 suites | 421 passed, 15 skipped (fork tests without `RUN_ROBINHOOD_FORK`), 1 failed: the exploratory scratch test, see below |
| Foundry, focused audit suites | `ValariRouterTest` (50), Access/Accounting/V3Accounting audit (3 incl. 2 × 256 seeds), fizz `FoundryTester` (2) | all passed |
| Foundry, Robinhood fork | 5 lifecycle and blocked-recipient tests at block 88,597,367 | all passed |
| Contract size | `ValariRouterV3` runtime | 20,044 bytes, under the 24,576 EIP-170 limit |
| Slither | V3 router and dependency closure, standard and strict scope-fix passes | identical to 2026-10-05-v3: 118 warnings, 22 touching the router, same detector mix, strict pass exit 0 |
| Manticore | 6 symbolic scenarios, 1800 s budget each | 0 violations, all exit 0; `addpool` explored no accepted-key path this time (busy machine), re-run noted below |
| Echidna | 10 properties, 200,000-call campaign seeded with the previous corpus | stopped at 110,855 calls by the session's low-memory guard; 0 of 10 properties falsified up to there, coverage 46,733 instructions (equal to the previous run's final figure); the 2,340-call calibration run passed 10/10 |
| Medusa | fizz harness (GL/SP properties), 25-minute budget | not run: the first start lacked `crytic-compile` on PATH (exit 6), the second was killed by the low-memory guard while still compiling the harness; no fuzzing happened |

## Foundry

`forge/full-suite-tail.log`, `forge/focused.log`, `forge/fork.log`.

The one failure is `ValariRouterScratchAuditTest.testScratchUpwardLiquidityManipulation`
in `test/ValariRouterScratchAudit.t.sol`, against the **old** `ValariRouter` (out of scope
per `PROPERTIES.md`). It is an exploratory attack sketch: it swaps to push the price, expects
`previewDeposit` to quote *more* liquidity afterwards (`assertGt`), and the two quotes came
out equal (`34867952798114284185 <= 34867952798114284185`). The premise of the sketch does
not hold, which is the opposite of a vulnerability; the test should assert `>=` or be
retired. No production code is involved.

## Slither

`slither/slither.log`, `slither/results-scope-fix.json` and `.sarif`, `slither/driver.log`.
The unmodified run still ends with exit 255 on the known `SafeCast` library-resolution
problem and the strict compatibility run (`run_with_scope_fix.py`, `--disallow-partial
--fail-none`) exits 0. Counts by detector on the router are unchanged from the triaged
2026-10-05 report (`reentrancy-balance` 1, `incorrect-equality` 1, `uninitialized-local` 1,
`unused-return` 6, `shadowing-local` 1, `calls-loop` 5, `reentrancy-benign` 1,
`reentrancy-events` 1, `timestamp` 4, `pragma` 1); the triage in
`audit/2026-10-05/slither/REPORT.md` stands.

## Manticore

`manticore/results/*.json`, `*.stderr`, `exit-codes.txt`. Router compiled for Istanbul
(`compile.sh`) against `Mocks.sol`, one symbolic call per scenario:

| Scenario | Claim | Paths succeeded / reverted | Violations |
| --- | --- | ---: | ---: |
| outsider | no role can change storage | 0 / 57 | 0 |
| treasury | commission recipient cannot change storage | 0 / 62 | 0 |
| value | any call with 1 wei reverts | 0 / 45 | 0 |
| pending | pending owner changes storage only via `acceptOwnership` | 1 / 61 | 0 |
| recipient | `setFeeRecipient(x)` stores x, never 0 or the router | 1 / 3 | 0 |
| addpool | every accepted key meets the listing rules | 0 / 30 | 0 (vacuous: no accepted path reached in 246 s under load) |

## Echidna

`echidna/calibration-2k.log` (10/10 passing, 2,340 calls, 46,711 instructions), then
`echidna/campaign.log` for the 200,000-call campaign with the 2026-10-05-v3 corpus copied
in as the seed. Claude Code's memory guard killed the campaign process at 22:20, after
110,855 calls, with the status line still reading `tests: 0/10` (no property falsified) and
coverage at 46,733 unique instructions, the same number the previous full campaign ended on.
The corpus directory holds what was saved up to that point. The remaining 89,000 calls were
not run; start them with `ECHIDNA=… CRYTIC_VENV=… bash audit/2026-10-14/echidna/run.sh 200000
campaign-resume` when the machine has memory to spare (the harness build alone takes two solc
processes of about a gigabyte each while medusa or another build runs beside it).

## Medusa

`medusa/campaign.log` and `fizz_data/logs_medusa/log-1792004134.log`. The campaign never
reached fuzzing: the first start failed because medusa shells out to `crytic-compile`, which
was not on PATH (exit 6); the second start, with the crytic venv on PATH and an isolated
`FOUNDRY_OUT`, was killed by the session's low-memory guard during the via-IR compile of the
fizz harness, at the same moment as the echidna campaign. Nothing in `medusa.json` changed.
To run it: `PATH=<crytic venv>/bin:$PATH FOUNDRY_OUT=/tmp/valari-medusa/out
FOUNDRY_CACHE_PATH=/tmp/valari-medusa/cache medusa fuzz --config medusa.json --timeout 1500`,
on its own, not beside echidna.

## Not completed in this session

- Echidna: 89,000 of 200,000 calls (see above).
- Medusa: the whole campaign.
- Manticore `addpool`: a re-run alone on a quiet machine, as the previous audit did, so the
  scenario actually reaches an accepted `addPool` path and the claim is checked rather than
  vacuous. Command: `MANTICORE_VENV=<venv> PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python
  <venv>/bin/python audit/2026-10-14/manticore/run.py addpool 3000`, after `compile.sh`.

Memory, not findings, cut the session short: two fuzzers compiling via-IR beside six
Manticore processes on a 15 GiB machine. Every check that did complete agrees with the
2026-10-05-v3 results on byte-identical source.
