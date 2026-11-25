# scripts/impl_timing.tcl - synth + impl, report timing @ 100 MHz
set proj_dir [file normalize [file dirname [info script]]/..]
cd $proj_dir

open_project parser.xpr

# Ensure part is set even if board store missing
set_property part xc7a35tcpg236-1 [current_project]

set_property top top_basys3 [current_fileset]
update_compile_order -fileset sources_1

# Make frames.mem visible to $readmemh during synth
set mem_path [file normalize mem/frames.mem]
if {[llength [get_files -quiet frames.mem]] == 0 && [llength [get_files -quiet mem/frames.mem]] == 0} {
  add_files -fileset sources_1 $mem_path
}
foreach f [get_files -quiet *frames.mem] {
  set_property file_type {Memory Initialization Files} $f
}

# Copy into synth run directory helper via verilog include dirs
set_property include_dirs [list [file normalize mem] $proj_dir] [current_fileset]

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "synth_1 status: $synth_status"
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
  puts "ERROR: synthesis failed"
  exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
  puts "ERROR: implementation failed"
  exit 1
}

open_run impl_1
report_timing_summary -file timing_summary.rpt
report_utilization -file utilization.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "WNS = $wns ns"
if {$wns < 0} {
  puts "ERROR: timing not met"
  exit 1
}
puts "Timing met at 100 MHz (WNS=$wns)"
close_project
