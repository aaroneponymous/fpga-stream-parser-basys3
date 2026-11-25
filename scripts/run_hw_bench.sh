#!/usr/bin/env bash
# Program the Basys 3 with build/impl/top_bench.bit, run the benchmark, write the report.
# Usage: scripts/run_hw_bench.sh [run_name]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIVADO_BIN="${VIVADO_BIN:-$HOME/tools/amd/2025.2/2025.2/Vivado/bin}"
cd "$ROOT"
RUN="results/${1:-hw_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$RUN/build"
cp build/impl/build_info.json build/impl/timing_summary_routed.rpt build/impl/utilization_routed.rpt \
   build/impl/route_status.rpt build/impl/top_bench.ltx "$RUN/build/"
(cd "$RUN" && "$VIVADO_BIN/vivado" -mode batch -nojournal -log vivado_hw.log \
   -source "$ROOT/scripts/hw_bench.tcl" -tclargs "$ROOT/$RUN" "$ROOT/build/impl" > /dev/null)
grep -E "^HWBENCH" "$RUN/vivado_hw.log"
python3 scripts/make_report.py "$RUN" --build build/impl
