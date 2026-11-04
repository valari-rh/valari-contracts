#!/usr/bin/env bash
# Run from valari-contracts after compile.sh. One process per scenario; results as JSON.
# Usage: run-all.sh [timeout-seconds-per-scenario]
set -uo pipefail
export PATH=${MANTICORE_VENV:-/tmp/valari-manticore.L3Hm1e/venv310}/bin:$PATH
here=audit/2026-10-14/manticore
limit=${1:-3000}
mkdir -p "$here/results"
for scenario in recipient outsider treasury value pending addpool; do
  ( timeout $((limit + 300)) python "$here/run.py" "$scenario" "$limit" \
      > "$here/results/$scenario.json" 2> "$here/results/$scenario.stderr"
    echo "$scenario exit $?" >> "$here/results/exit-codes.txt" ) &
done
wait
cat "$here/results/exit-codes.txt"
