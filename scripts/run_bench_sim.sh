#!/usr/bin/env bash
# Simulate the benchmark instrumentation (bench_tb) with xsim.
# Writes results/sim/bench_tb.log. Usage: scripts/run_bench_sim.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIVADO_BIN="${VIVADO_BIN:-$HOME/tools/amd/2025.2/2025.2/Vivado/bin}"
export PATH="$VIVADO_BIN:$PATH"
cd "$ROOT"
python3 scripts/gen_b2b.py -o mem/frames_b2b.mem >/dev/null

W=build/sim
rm -rf "$W"; mkdir -p "$W" results/sim
cp mem/frames.mem mem/frames_b2b.mem "$W"/
cd "$W"
RTL="$ROOT/rtl"
xvlog -sv -d SIMULATION \
  "$RTL/protocol_pkg.sv" "$RTL/parser_pkg.sv" "$RTL/crc16_ccitt.sv" "$RTL/msg_table.sv" \
  "$RTL/event_fifo.sv" "$RTL/parser_core.sv" "$RTL/bram_replay.sv" "$RTL/perf_counters.sv" \
  "$RTL/bench/bench_monitor.sv" "$RTL/bench/bench_system.sv" "$ROOT/tb/bench_tb.sv" > xvlog.out
# top_basys3.sv uses rate_kmsg before declaring it; strict xvlog rejects that.
xvlog -sv --relax "$RTL/top_basys3.sv" >> xvlog.out
xelab -timescale 1ns/1ps bench_tb -s bench_tb_sim > xelab.out
xsim bench_tb_sim -runall -log "$ROOT/results/sim/bench_tb.log" > /dev/null
grep -E "bench_tb: |SUMMARY|equivalence|FAIL" "$ROOT/results/sim/bench_tb.log"
