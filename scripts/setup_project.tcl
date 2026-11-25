# scripts/setup_project.tcl - add RTL/TB sources to existing parser.xpr
# Usage: vivado -mode batch -source scripts/setup_project.tcl

set proj_dir [file normalize [file dirname [info script]]/..]
cd $proj_dir

open_project parser.xpr

# Remove any stale file sets entries carefully - add sources
set rtl_files [list \
  rtl/protocol_pkg.sv \
  rtl/parser_pkg.sv \
  rtl/crc16_ccitt.sv \
  rtl/msg_table.sv \
  rtl/event_fifo.sv \
  rtl/parser_core.sv \
  rtl/bram_replay.sv \
  rtl/perf_counters.sv \
  rtl/top_basys3.sv \
]

foreach f $rtl_files {
  if {[llength [get_files -quiet $f]] == 0} {
    add_files -fileset sources_1 $f
  }
}

set sim_files [list \
  tb/crc16_tb.sv \
  tb/parser_tb.sv \
  tb/replay_tb.sv \
]

foreach f $sim_files {
  if {[llength [get_files -quiet $f]] == 0} {
    add_files -fileset sim_1 $f
  }
}

# Memory init for simulation + synthesis
if {[llength [get_files -quiet mem/frames.mem]] == 0} {
  add_files -fileset sources_1 mem/frames.mem
}
set_property file_type {Memory Initialization Files} [get_files mem/frames.mem]

set_property top top_basys3 [current_fileset]
set_property top_lib xil_defaultlib [current_fileset]

# Help $readmemh find frames.mem during elab/synth
set_property verilog_define MEM_FILE=frames.mem [current_fileset]

set_property top parser_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# Ensure SystemVerilog
foreach f [get_files *.sv] {
  set_property file_type SystemVerilog $f
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "Project setup complete."
close_project
