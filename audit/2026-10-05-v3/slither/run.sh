#!/usr/bin/env bash
# Run from valari-contracts. Install Slither 0.11.6 in the isolated venv first.
set -uo pipefail
export VIRTUAL_ENV=/tmp/valari-slither-venv
export FOUNDRY_OUT=/tmp/valari-slither-build-v3/out
export FOUNDRY_CACHE_PATH=/tmp/valari-slither-build-v3/cache
export FOUNDRY_BUILD_INFO_PATH=/tmp/valari-slither-build-v3/out/build-info
export FOUNDRY_SOLC=/home/redkidd/.local/share/svm/0.8.26/solc-0.8.26
audit_dir=${1:-audit/2026-10-05-v3/slither}
# Start from an empty build: an incremental build-info only lists the files that changed.
rm -rf /tmp/valari-slither-build-v3
# Slither refuses to overwrite existing JSON/SARIF output; start those fresh as well.
rm -f "$audit_dir"/results*.json "$audit_dir"/results*.sarif
mkdir -p "$audit_dir"
"$VIRTUAL_ENV/bin/slither" --version | tee "$audit_dir/version.txt"
forge config --json | tee "$audit_dir/foundry-config.json"
sha256sum src/ValariRouterV3.sol | tee "$audit_dir/source-sha256.txt"
"$VIRTUAL_ENV/bin/slither" src/ValariRouterV3.sol \
  --compile-force-framework foundry --skip-clean \
  --json "$audit_dir/results.json" --sarif "$audit_dir/results.sarif" \
  --disable-color 2>&1 | tee "$audit_dir/slither.log"
audit_status=${PIPESTATUS[0]}
printf 'Slither exit code: %s\n' "$audit_status" | tee "$audit_dir/exit-code.txt"
"$VIRTUAL_ENV/bin/python" audit/2026-10-05/slither/run_with_scope_fix.py \
  src/ValariRouterV3.sol --compile-force-framework foundry --ignore-compile \
  --foundry-build-info-directory "$FOUNDRY_BUILD_INFO_PATH" \
  --disallow-partial --fail-none --disable-color \
  --json "$audit_dir/results-scope-fix.json" \
  --sarif "$audit_dir/results-scope-fix.sarif" \
  2>&1 | tee "$audit_dir/slither-scope-fix.log"
audit_status=${PIPESTATUS[0]}
printf 'Strict compatibility-run exit code: %s\n' "$audit_status" \
  | tee "$audit_dir/scope-fix-exit-code.txt"
exit "$audit_status"
