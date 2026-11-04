#!/usr/bin/env bash
# Run from valari-contracts. Needs the echidna binary and crytic-compile (ECHIDNA, CRYTIC_VENV).
# Usage: run.sh [test-limit] [log-name] [contract] [config]
set -uo pipefail
ECHIDNA=${ECHIDNA:-/tmp/valari-echidna.TRvFAj/echidna}
CRYTIC_VENV=${CRYTIC_VENV:-/tmp/valari-slither-venv}
here=audit/2026-10-14/echidna
# Compile the harness with the project's own Foundry settings (0.8.26, via-IR, Cancun) by
# pointing Foundry's test directory at harness/ (corpora must stay outside it: Echidna writes
# Solidity reproducers there); build output stays out of the project.
export FOUNDRY_TEST=$here/harness
export FOUNDRY_OUT=/tmp/valari-echidna-20261014/out
export FOUNDRY_CACHE_PATH=/tmp/valari-echidna-20261014/cache
export PATH=$CRYTIC_VENV/bin:$PATH
"$ECHIDNA" --version | tee "$here/version.txt"
sha256sum src/ValariRouterV3.sol "$here/harness/RouterEchidnaV3.sol" | tee "$here/source-sha256.txt"
"$ECHIDNA" . --contract "${3:-RouterEchidnaV3}" --config "$here/${4:-config.yaml}" --disable-slither \
  --test-limit "${1:-2000}" --format text \
  --crytic-args "--compile-force-framework foundry --foundry-compile-all" 2>&1 | tee "$here/${2:-campaign}.log"
status=${PIPESTATUS[0]}
printf 'Echidna exit code: %s\n' "$status" | tee -a "$here/${2:-campaign}.log"
exit "$status"
