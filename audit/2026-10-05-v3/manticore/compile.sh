#!/usr/bin/env bash
# Run from valari-contracts. Compiles the UNMODIFIED router source for the Istanbul EVM,
# the newest target Manticore 0.3.7 executes (no PUSH0, MCOPY or transient storage), with
# the project's other settings (0.8.26, via-IR, optimizer 200). Output stays out of the project.
set -euo pipefail
export FOUNDRY_EVM_VERSION=istanbul
export FOUNDRY_OUT=${1:-/tmp/valari-manticore-v3/out}
export FOUNDRY_CACHE_PATH=/tmp/valari-manticore-v3/cache
forge build src/ValariRouterV3.sol audit/2026-10-05-v3/manticore/Mocks.sol
sha256sum src/ValariRouterV3.sol | tee audit/2026-10-05-v3/manticore/source-sha256.txt
