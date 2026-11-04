# Manticore run — 2026-10-05

The unchanged ValariRouter runtime could not be meaningfully analyzed by Manticore
0.3.7. Both a concrete `poolCount()` call and a transaction with 260 symbolic
calldata bytes stop at program counter **19 / 0x13**, where the router contains
the valid `PUSH0` opcode (`0x5f`) but Manticore reports `INVALID` and terminates the
state with `THROW`. This is a tool compatibility limitation, **not a contract
vulnerability and not a clean audit result**.

The same engine successfully executed a legacy-EVM positive control returning 42.
No production source or compiler settings were changed. The runtime was loaded
verbatim from the existing Foundry artifact, using empty storage and unpatched
immutables solely as an opcode compatibility probe. Constructor execution,
external dependencies, and valid deployment state were not modeled. The failing
opcode occurs before any function body or immutable/storage access.

## Evidence and scope

- [runtime_probe.py](runtime_probe.py): reproducible Manticore EVM API harness.
- [runtime-probe.log](runtime-probe.log): complete executed instruction traces and
  findings for the control, concrete call, and symbolic calldata call.
- [environment.log](environment.log): installed versions and opcode decoder check.
- [cli-version-failure.log](cli-version-failure.log): the legacy CLI's WASM import
  fails on `collections.Callable`; the EVM Python API imports and runs successfully.
- [commission_model.py](commission_model.py) and [commission-model.log](commission-model.log):
  separately labeled, bounded arithmetic model (details below).
- [requirements-frozen.txt](requirements-frozen.txt): exact isolated Python packages.

Registered EVM detectors: `DetectInvalid`, `DetectIntegerOverflow`,
`DetectReentrancySimple`, and `DetectUnusedRetVal`. Only the invalid-instruction
detector emits a finding, caused by unsupported `PUSH0`. **Zero detectors completed
meaningful ValariRouter application-path analysis.** No vulnerability counts or
coverage claims should be inferred from their otherwise empty output.

The compiled runtime contains 209 `PUSH0` instructions and one `MCOPY` at PC 9000
after skipping PUSH immediates and Solidity CBOR metadata. It contains no `TLOAD`
or `TSTORE` instructions. The installed decoder treats all four new opcodes as
`INVALID`; execution stops at `PUSH0` before `MCOPY` can be reached. Dependency
contracts were not included in this opcode inventory.

Target metadata:

```text
source: src/ValariRouter.sol
source SHA-256: 7195877547776d89f84b4dab60396962074898fef1d8706cb5131b4f434be4f5
source Keccak-256: 0x9103f870f878e7071adb43ef1b266aaa5712fdb900c9c332e515bfb1fc6e2715
artifact: out/ValariRouter.sol/ValariRouter.json
compiler: 0.8.26+commit.8a97fa7a
EVM target: cancun
viaIR: true
optimizer: enabled, 200 runs
runtime length: 17302 bytes
runtime SHA-256: 976745d2cf6736150a84fe4b1705b5c707060f6480beca4e2940234448e1069e
```

The current router source's Keccak-256 was checked against the source hash embedded
in the artifact metadata and matched. The probe does not rebuild the contract.

## Limited commission model

Manticore's SMT API with Z3 5.1.0.0 checked a re-expression of `_commission` for two
independent symbolic fee amounts in `[0, 65535]`, starting with remainder zero.
The calculation uses 32-bit intermediates, sufficient for this bounded domain.
It does **not** execute Solidity or verify the production `FullMath` implementation,
arbitrary uint256 fees, storage updates, recipients, or token transfers.

| Property | Result |
| --- | --- |
| First commission does not exceed first fee amount | Passed in bounded model |
| Second commission does not exceed second fee amount | Passed in bounded model |
| Carried remainder remains below 10,000 | Passed in bounded model |
| Two commissions sum to floor(total fees / 10) | Inconclusive: 30-second solver timeout |
| Final remainder matches cumulative fraction | Inconclusive: 30-second solver timeout |

Manticore reports those timeouts as `SolverUnknown('unsat')`: its installed
`_is_sat()` rewrites the status before raising `SolverUnknown`. These exceptions
were conservatively recorded as **inconclusive**, never as proofs.

## Setup and exact commands

Commands below ran from `/home/redkidd/SoloTime/HedgeyFund/valari`.
The isolated environment is under `/tmp/valari-manticore.L3Hm1e`.

```sh
uv venv --cache-dir /tmp/valari-manticore.L3Hm1e/uv-cache /tmp/valari-manticore.L3Hm1e/venv
uv pip install --cache-dir /tmp/valari-manticore.L3Hm1e/uv-cache --python /tmp/valari-manticore.L3Hm1e/venv/bin/python manticore
```

The first command used host Python 3.12.3. Installation failed building
`pysha3==1.0.2` with `fatal error: pystrhex.h: No such file or directory`.
Network access was approved after the initial sandbox DNS failure.

```sh
uv python install 3.10 --install-dir /tmp/valari-manticore.L3Hm1e/python --cache-dir /tmp/valari-manticore.L3Hm1e/uv-cache --no-bin
uv venv --python /tmp/valari-manticore.L3Hm1e/python/cpython-3.10.19-linux-x86_64-gnu/bin/python3.10 --cache-dir /tmp/valari-manticore.L3Hm1e/uv-cache /tmp/valari-manticore.L3Hm1e/venv310
uv pip install --cache-dir /tmp/valari-manticore.L3Hm1e/uv-cache --python /tmp/valari-manticore.L3Hm1e/venv310/bin/python manticore
uv pip install --cache-dir /tmp/valari-manticore.L3Hm1e/uv-cache --python /tmp/valari-manticore.L3Hm1e/venv310/bin/python 'protobuf==3.20.3' 'setuptools<81'
```

Pinning protobuf resolved `TypeError: Descriptors cannot be created directly`
with the initially resolved protobuf 7.36.2. Pinning setuptools preserves the
legacy `pkg_resources` API. The unmodified Manticore Python EVM API then ran.

```sh
PATH=/tmp/valari-manticore.L3Hm1e/venv310/bin:$PATH /tmp/valari-manticore.L3Hm1e/venv310/bin/python valari-contracts/audit/2026-10-05/manticore/runtime_probe.py valari-contracts/out/ValariRouter.sol/ValariRouter.json --workspace /tmp/valari-manticore.L3Hm1e/final-probe-inventory | tee valari-contracts/audit/2026-10-05/manticore/runtime-probe.log
PATH=/tmp/valari-manticore.L3Hm1e/venv310/bin:$PATH /tmp/valari-manticore.L3Hm1e/venv310/bin/python valari-contracts/audit/2026-10-05/manticore/commission_model.py | tee valari-contracts/audit/2026-10-05/manticore/commission-model.log
```

Both harness commands exited zero; this indicates the harness completed, **not**
that ValariRouter passed an audit. Refer to per-case results and limits above.

Upstream context: the [Manticore repository](https://github.com/trailofbits/manticore)
documents incomplete support even for Istanbul EVM semantics. The local executed
traces, rather than that general statement, establish this target's incompatibility.
