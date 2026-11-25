# scripts/run_sim.tcl - run parser_tb in xsim batch
set proj_dir [file normalize [file dirname [info script]]/..]
cd $proj_dir

open_project parser.xpr
set_property top parser_tb [get_filesets sim_1]
launch_simulation
run all
close_sim -quiet
close_project
