#!/usr/bin/env bash
# Run from valari-contracts. Creates fresh outputs; preserves the recorded run.
# Requires Echidna 2.3.3, Forge, solc 0.8.26, and Slither/crytic-compile.
set -euo pipefail
test -f src/ValariRouter.sol
audit_project_root=$(pwd -P)
audit_run=$(mktemp -d /tmp/valari-echidna-rerun.XXXXXX)
audit_echidna=${VALARI_ECHIDNA_BIN:-/tmp/valari-echidna.TRvFAj/echidna}
export VIRTUAL_ENV=${VALARI_SLITHER_VENV:-/tmp/valari-slither-venv}
export PATH="$VIRTUAL_ENV/bin:$PATH"
export FOUNDRY_OUT="$audit_run/out"
export FOUNDRY_CACHE_PATH="$audit_run/cache"
export FOUNDRY_BUILD_INFO_PATH="$audit_run/out/build-info"
export FOUNDRY_SOLC=${VALARI_SOLC_BIN:-/home/redkidd/.local/share/svm/0.8.26/solc-0.8.26}

"$audit_echidna" --version | tee "$audit_run/version.txt"
sha256sum src/ValariRouter.sol audit/2026-10-05/echidna/RouterEchidna.sol \
  | tee "$audit_run/source-sha256.txt"
forge build audit/2026-10-05/echidna/RouterEchidna.sol --build-info --deny never \
  2>&1 | tee "$audit_run/build.log"

cd "$audit_project_root/audit/2026-10-05/echidna"
mkdir -p "$audit_run/corpus/coverage"
# The recorded 20,014-call campaign began with these two smoke-run seeds.
cp corpus/coverage/3723968978946920190.txt "$audit_run/corpus/coverage/"
cp corpus/coverage/5371424224199943472.txt "$audit_run/corpus/coverage/"
set +e
"$audit_echidna" RouterEchidna.sol --contract RouterEchidna --config config.yaml \
  --format text --corpus-dir "$audit_run/corpus" \
  --crytic-args "--compile-force-framework foundry --ignore-compile --foundry-build-info-directory $FOUNDRY_BUILD_INFO_PATH" \
  2>&1 | tee "$audit_run/campaign.log"
audit_status=${PIPESTATUS[0]}
set -e
printf 'Echidna exit code: %s\nArtifacts: %s\n' "$audit_status" "$audit_run" \
  | tee "$audit_run/exit-code.txt"
exit "$audit_status"
