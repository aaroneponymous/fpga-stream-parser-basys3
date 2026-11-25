# build_bench.tcl - non-project build of top_bench (VIO + ILA) for the Basys 3
# Usage: vivado -mode batch -nojournal -source scripts/build_bench.tcl
# Outputs in build/impl/: top_bench.bit, top_bench.ltx, reports, build_info.json
# Exits non-zero if any setup or hold constraint fails.

set root  [file normalize [file dirname [info script]]/..]
set build $root/build/impl
set part  xc7a35tcpg236-1

file delete -force $build
file mkdir $build $build/ip
cd $build
# $readmemh resolves INIT_A/INIT_B relative to the working directory
file copy -force $root/mem/frames.mem $root/mem/frames_b2b.mem $build

set build_id   [format %08X [expr {[clock seconds] & 0xFFFFFFFF}]]
set git_commit [string trim [exec git -C $root rev-parse HEAD]]
set git_dirty  [expr {[string length [string trim [exec git -C $root status --porcelain -- rtl parser.srcs/constrs_1 mem scripts tb]]] > 0}]
puts "BUILD_ID=$build_id commit=$git_commit dirty=$git_dirty"

create_project -in_memory -part $part
set_property target_language Verilog [current_project]

# --- Debug IP -----------------------------------------------------------------
create_ip -name vio -vendor xilinx.com -library ip -version 3.0 -module_name vio_bench -dir $build/ip
set_property -dict [list \
  CONFIG.C_NUM_PROBE_IN    {2}  \
  CONFIG.C_NUM_PROBE_OUT   {4}  \
  CONFIG.C_PROBE_IN0_WIDTH {64} \
  CONFIG.C_PROBE_IN1_WIDTH {16} \
  CONFIG.C_PROBE_OUT0_WIDTH {8} \
  CONFIG.C_PROBE_OUT1_WIDTH {32} \
  CONFIG.C_PROBE_OUT2_WIDTH {8} \
  CONFIG.C_PROBE_OUT3_WIDTH {8} \
] [get_ips vio_bench]

create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_bench -dir $build/ip
set_property -dict [list \
  CONFIG.C_NUM_OF_PROBES {10}   \
  CONFIG.C_DATA_DEPTH    {2048} \
  CONFIG.C_PROBE0_WIDTH  {1}  \
  CONFIG.C_PROBE1_WIDTH  {8}  \
  CONFIG.C_PROBE2_WIDTH  {3}  \
  CONFIG.C_PROBE3_WIDTH  {1}  \
  CONFIG.C_PROBE4_WIDTH  {8}  \
  CONFIG.C_PROBE5_WIDTH  {16} \
  CONFIG.C_PROBE6_WIDTH  {1}  \
  CONFIG.C_PROBE7_WIDTH  {32} \
  CONFIG.C_PROBE8_WIDTH  {1}  \
  CONFIG.C_PROBE9_WIDTH  {1}  \
] [get_ips ila_bench]

generate_target all [get_ips]
synth_ip [get_ips]

# --- Sources --------------------------------------------------------------------
read_verilog -sv [list \
  $root/rtl/protocol_pkg.sv $root/rtl/parser_pkg.sv $root/rtl/crc16_ccitt.sv \
  $root/rtl/msg_table.sv $root/rtl/event_fifo.sv $root/rtl/parser_core.sv \
  $root/rtl/bram_replay.sv $root/rtl/perf_counters.sv \
  $root/rtl/bench/bench_monitor.sv $root/rtl/bench/bench_system.sv $root/rtl/bench/top_bench.sv]
read_xdc $root/parser.srcs/constrs_1/imports/ddca/Basys-3-Master.xdc

# --- Implementation -------------------------------------------------------------
synth_design -top top_bench -part $part -generic "BUILD_ID=32'h$build_id"
report_utilization -file $build/utilization_synth.rpt
opt_design
place_design
phys_opt_design
route_design

report_timing_summary -max_paths 10 -report_unconstrained -file $build/timing_summary_routed.rpt
report_utilization -file $build/utilization_routed.rpt
report_route_status -file $build/route_status.rpt
report_drc -file $build/drc_routed.rpt
report_methodology -file $build/methodology_routed.rpt
report_clocks -file $build/clocks.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set clk_period [get_property PERIOD [get_clocks sys_clk_pin]]
puts "TIMING: clock sys_clk_pin period=$clk_period ns WNS=$wns WHS=$whs"

write_checkpoint -force $build/top_bench_routed.dcp
write_bitstream -force $build/top_bench.bit
write_debug_probes -force $build/top_bench.ltx

set bit_sha [lindex [exec sha256sum $build/top_bench.bit] 0]
set ltx_sha [lindex [exec sha256sum $build/top_bench.ltx] 0]
set fh [open $build/build_info.json w]
puts $fh "{"
puts $fh "  \"build_id\": \"$build_id\","
puts $fh "  \"built_at\": \"[clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S%z}]\","
puts $fh "  \"git_commit\": \"$git_commit\","
puts $fh "  \"git_dirty\": [expr {$git_dirty ? "true" : "false"}],"
puts $fh "  \"vivado\": \"[version -short]\","
puts $fh "  \"part\": \"$part\","
puts $fh "  \"top\": \"top_bench\","
puts $fh "  \"clock\": {\"name\": \"sys_clk_pin\", \"period_ns\": $clk_period},"
puts $fh "  \"wns_ns\": $wns,"
puts $fh "  \"whs_ns\": $whs,"
puts $fh "  \"bitstream\": \"top_bench.bit\", \"bitstream_sha256\": \"$bit_sha\","
puts $fh "  \"probes\": \"top_bench.ltx\", \"probes_sha256\": \"$ltx_sha\""
puts $fh "}"
close $fh

if {$wns < 0 || $whs < 0} {
  puts "ERROR: timing not met (WNS=$wns WHS=$whs)"
  exit 1
}
puts "BUILD OK: timing met at $clk_period ns (WNS=$wns WHS=$whs)"
