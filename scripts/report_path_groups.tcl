open_checkpoint top_bench_routed.dcp
foreach {name pat} {parser u_sys/u_parser/* fifo u_sys/u_fifo/* replay u_sys/u_replay/* perf u_sys/u_perf/* monitor u_sys/u_mon/*} {
  set p [get_timing_paths -setup -max_paths 1 -to [get_cells -hier -filter "NAME=~$pat && IS_SEQUENTIAL"]]
  puts "PATHGROUP $name worst_setup_slack_to=[get_property SLACK $p]"
}
report_timing -setup -max_paths 1 -to [get_cells -hier -filter {NAME=~u_sys/u_parser/* && IS_SEQUENTIAL}] -file parser_worst_path.rpt
