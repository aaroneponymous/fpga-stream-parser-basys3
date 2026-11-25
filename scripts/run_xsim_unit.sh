#!/usr/bin/env bash
# Standalone xsim for crc16_tb and replay_tb
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/home/aaroneponymous/tools/amd/2025.2/2025.2/Vivado/bin:$PATH"
mkdir -p "$ROOT/sim/xsim"
cd "$ROOT/sim/xsim"

echo "=== crc16_tb ==="
xvlog -sv ../../rtl/protocol_pkg.sv ../../rtl/crc16_ccitt.sv ../../tb/crc16_tb.sv
xelab -debug typical -timescale 1ns/1ps crc16_tb -s crc16_tb_sim
xsim crc16_tb_sim -runall -log crc16_tb.log

echo "=== replay_tb ==="
# Copy mem next to sim so relative path resolves
cp -f ../../mem/frames.mem .
xvlog -sv \
  ../../rtl/protocol_pkg.sv \
  ../../rtl/parser_pkg.sv \
  ../../rtl/crc16_ccitt.sv \
  ../../rtl/msg_table.sv \
  ../../rtl/event_fifo.sv \
  ../../rtl/parser_core.sv \
  ../../rtl/bram_replay.sv \
  ../../rtl/perf_counters.sv \
  ../../tb/replay_tb.sv
xelab -debug typical -timescale 1ns/1ps \
  -generic_top "INIT_FILE=frames.mem" \
  replay_tb -s replay_tb_sim 2>/dev/null || \
xelab -debug typical -timescale 1ns/1ps replay_tb -s replay_tb_sim
xsim replay_tb_sim -runall -log replay_tb.log
