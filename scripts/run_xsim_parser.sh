#!/usr/bin/env bash
# Standalone xsim compile+run for parser_tb (no GUI project needed)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/home/aaroneponymous/tools/amd/2025.2/2025.2/Vivado/bin:$PATH"

mkdir -p sim/xsim
cd sim/xsim

xvlog -sv -d SIMULATION \
  ../../rtl/protocol_pkg.sv \
  ../../rtl/parser_pkg.sv \
  ../../rtl/crc16_ccitt.sv \
  ../../rtl/msg_table.sv \
  ../../rtl/event_fifo.sv \
  ../../rtl/parser_core.sv \
  ../../tb/parser_tb.sv

xelab -debug typical -timescale 1ns/1ps parser_tb -s parser_tb_sim
xsim parser_tb_sim -runall -log parser_tb.log
