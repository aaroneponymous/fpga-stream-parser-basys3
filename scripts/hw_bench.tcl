# hw_bench.tcl - program the Basys 3 and run the hardware benchmark
#
# Usage (from the repo root):
#   vivado -mode batch -nojournal -log results/<run>/vivado_hw.log \
#          -source scripts/hw_bench.tcl -tclargs <run_dir> [build_dir]
#
# Steps:
#   1. Verify the bitstream: SHA-256 matches build_info.json, the build is from a
#      clean commit, and the bitstream header part matches the build part.
#   2. Connect over JTAG and verify exactly one device, part xc7a35t, IDCODE
#      x362D093, and that it matches the bitstream part.
#   3. Program, then check DONE=1 and that the VIO and ILA cores are present.
#   4. Read the monitor build ID register and compare it with build_info.json.
#   5. Run the tests and write raw results (JSON + ILA CSV) under <run_dir>/raw.
# No result is computed here; scripts/make_report.py derives everything from raw.

set root      [file normalize [file dirname [info script]]/..]
set run_dir   [file normalize [lindex $argv 0]]
set build_dir [expr {[llength $argv] > 1 ? [file normalize [lindex $argv 1]] : "$root/build/impl"}]
set raw       $run_dir/raw
file mkdir $raw

set bit  $build_dir/top_bench.bit
set ltx  $build_dir/top_bench.ltx
set info $build_dir/build_info.json

proc fail {msg} { puts "HWBENCH FAIL: $msg"; exit 2 }
proc now_us {} { return [clock microseconds] }
proc json_field {text key} {
  if {[regexp "\"$key\": *\"?(\[^\",\}\]+)\"?" $text -> v]} { return [string trim $v] }
  return ""
}

# ---------------------------------------------------------------------------
# 1. Bitstream checks
# ---------------------------------------------------------------------------
foreach f [list $bit $ltx $info] { if {![file exists $f]} { fail "missing $f" } }
set fh [open $info r]; set info_text [read $fh]; close $fh
set exp_sha   [json_field $info_text bitstream_sha256]
set build_id  [json_field $info_text build_id]
set exp_part  [json_field $info_text part]
set git_dirty [json_field $info_text git_dirty]
set act_sha   [lindex [exec sha256sum $bit] 0]
if {$act_sha ne $exp_sha} { fail "bitstream SHA-256 $act_sha != build_info $exp_sha" }
if {$git_dirty ne "false"} { fail "bitstream was built from a dirty tree" }

# Xilinx .bit header: field 'b' holds the part name, e.g. 7a35tcpg236
set fh [open $bit rb]; set hdr [read $fh 256]; close $fh
set bpos [string first "b\x00" $hdr]
binary scan [string range $hdr [expr {$bpos + 1}] [expr {$bpos + 2}]] Su blen
set bit_part [string trimright [string range $hdr [expr {$bpos + 3}] [expr {$bpos + 2 + $blen}]] "\x00"]
if {![string match "xc${bit_part}*" $exp_part]} { fail "bitstream header part $bit_part does not match build part $exp_part" }
puts "HWBENCH bitstream ok: sha256=$act_sha header_part=$bit_part build_id=$build_id"

# ---------------------------------------------------------------------------
# 2. Device checks
# ---------------------------------------------------------------------------
open_hw_manager
connect_hw_server -url localhost:3121
set targets [get_hw_targets]
if {[llength $targets] != 1} { fail "expected one JTAG target, found: $targets" }
set target [lindex $targets 0]
current_hw_target $target
set_property PARAM.FREQUENCY 15000000 $target
open_hw_target
set devs [get_hw_devices]
if {[llength $devs] != 1} { fail "expected one device on the chain, found: $devs" }
set dev [lindex $devs 0]
set dev_part [get_property PART $dev]
set idcode   [string toupper [get_property IDCODE_HEX $dev]]
if {$dev_part ne "xc7a35t"} { fail "device part $dev_part is not xc7a35t" }
if {![string match "?362D093" $idcode]} { fail "IDCODE $idcode is not an XC7A35T (x362D093)" }
if {![string match "${dev_part}*" $exp_part]} { fail "device $dev_part does not match bitstream part $exp_part" }
set target_uid [get_property UID $target]
puts "HWBENCH device ok: $dev_part IDCODE=$idcode target=$target"

# ---------------------------------------------------------------------------
# 3. Program
# ---------------------------------------------------------------------------
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
set_property PROBES.FILE  $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
set t_prog [now_us]
program_hw_devices $dev
refresh_hw_device $dev
set done_pin [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]
if {$done_pin != 1} { fail "DONE pin is $done_pin after programming" }
set vio [get_hw_vios -of_objects $dev]
set ila [get_hw_ilas -of_objects $dev]
if {[llength $vio] != 1 || [llength $ila] != 1} { fail "expected 1 VIO and 1 ILA, found vio=$vio ila=$ila" }
puts "HWBENCH programmed: DONE=1 vio=$vio ila=$ila"

proc P {name} { global vio; return [get_hw_probes $name -of_objects $vio] }
foreach p {ctrl window_len sel drain_div} { set_property OUTPUT_VALUE_RADIX HEX [P $p] }
foreach p {rdata rsel mon_status}         { set_property INPUT_VALUE_RADIX  HEX [P $p] }

proc vio_set {args} {
  global vio
  foreach {name val} $args { set_property OUTPUT_VALUE $val [P $name] }
  commit_hw_vio $vio
}
# ctrl bits: 0 rst, 1 start, 2 loop, 3 arm, 4 corpus_sel, 5 arm_on_start
proc ctrl_hex {bits} {
  set v 0
  foreach b $bits { set v [expr {$v | (1 << $b)}] }
  return [format %02X $v]
}
proc status {} {
  global vio
  refresh_hw_vio $vio
  return [expr {"0x[get_property INPUT_VALUE [P mon_status]]"}]
}
# Read one monitor register; returns {hex t_us}
proc reg {sel} {
  global vio
  set s [format %02X $sel]
  vio_set sel $s
  for {set i 0} {$i < 50} {incr i} {
    set t0 [now_us]
    refresh_hw_vio $vio
    set t1 [now_us]
    if {[string toupper [get_property INPUT_VALUE [P rsel]]] eq $s} {
      return [list [string toupper [get_property INPUT_VALUE [P rdata]]] [expr {($t0 + $t1) / 2}]]
    }
  }
  fail "readout of register $s never settled"
}
proc read_all {} {
  set out {}
  for {set s 0} {$s < 0x20} {incr s} { lappend out [format %02X $s] [lindex [reg $s] 0] }
  for {set s 0x40} {$s < 0xC0} {incr s} { lappend out [format %02X $s] [lindex [reg $s] 0] }
  return $out
}
proc write_json {path test cfg regs extra} {
  set fh [open $path w]
  puts $fh "{"
  puts $fh "  \"test\": \"$test\","
  puts $fh "  \"config\": {[join [lmap {k v} $cfg {format {"%s": "%s"} $k $v}] {, }]},"
  foreach {k v} $extra { puts $fh "  \"$k\": $v," }
  puts $fh "  \"regs\": {[join [lmap {k v} $regs {format {"%s": "%s"} $k $v}] {, }]}"
  puts $fh "}"
  close $fh
}
proc wait_done {timeout_s} {
  set deadline [expr {[clock milliseconds] + int($timeout_s * 1000)}]
  while {[clock milliseconds] < $deadline} {
    if {([status] & 2) != 0} { return }
    after 20
  }
  fail "window did not complete within $timeout_s s"
}

# ---------------------------------------------------------------------------
# 4. Identity
# ---------------------------------------------------------------------------
vio_set ctrl [ctrl_hex {0}] window_len 00000001 sel 00 drain_div 00
vio_set ctrl 00
set id [lindex [reg 0] 0]
if {[string range $id end-7 end] ne $build_id || [string range $id 0 7] ne "B0E10001"} {
  fail "monitor ID register $id does not match build_id $build_id"
}
puts "HWBENCH identity ok: monitor reports $id"

set fh [open $raw/session.json w]
puts $fh "{\"host_time\": \"[clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S%z}]\", \"vivado\": \"[version -short]\", \"target\": \"$target\", \"target_uid\": \"$target_uid\", \"device\": \"$dev_part\", \"idcode\": \"$idcode\", \"jtag_hz\": [get_property PARAM.FREQUENCY $target], \"done_pin\": $done_pin, \"bitstream_sha256\": \"$act_sha\", \"bit_header_part\": \"$bit_part\", \"build_id\": \"$build_id\", \"monitor_id\": \"$id\", \"programmed_at_us\": $t_prog}"
close $fh

# ---------------------------------------------------------------------------
# 5. Tests
# ---------------------------------------------------------------------------
# Deterministic cold window: reset, then start replay and arm in the same cycle.
proc cold {name corpus ddiv wlen} {
  global raw
  set base [list 2 5]
  if {$corpus} { lappend base 4 }
  vio_set ctrl [ctrl_hex [concat $base 0]] drain_div [format %02X $ddiv] window_len [format %08X $wlen]
  vio_set ctrl [ctrl_hex $base]
  vio_set ctrl [ctrl_hex [concat $base 1]]
  set t0 [now_us]
  wait_done [expr {$wlen / 1.0e8 + 5}]
  set t1 [now_us]
  set regs [read_all]
  write_json $raw/$name.json $name [list corpus $corpus drain_div $ddiv window_len $wlen mode cold] $regs \
    [list host_arm_us $t0 host_done_seen_us $t1]
  vio_set ctrl [ctrl_hex [concat $base 0]]
  puts "HWBENCH $name done"
}

# Sustained: start looping replay, let it run, then arm windows while it runs.
proc sustained {name corpus ddiv wlen trials} {
  global raw
  set base [list 2]
  if {$corpus} { lappend base 4 }
  vio_set ctrl [ctrl_hex [concat $base 0]] drain_div [format %02X $ddiv] window_len [format %08X $wlen]
  vio_set ctrl [ctrl_hex $base]
  vio_set ctrl [ctrl_hex [concat $base 1]]
  after 500
  for {set k 1} {$k <= $trials} {incr k} {
    vio_set ctrl [ctrl_hex [concat $base 1]]
    vio_set ctrl [ctrl_hex [concat $base 1 3]]
    set t0 [now_us]
    wait_done [expr {$wlen / 1.0e8 + 5}]
    set t1 [now_us]
    set regs [read_all]
    write_json $raw/${name}_t$k.json ${name}_t$k [list corpus $corpus drain_div $ddiv window_len $wlen mode sustained trial $k] $regs \
      [list host_arm_us $t0 host_done_seen_us $t1]
    puts "HWBENCH ${name}_t$k done"
  }
  vio_set ctrl [ctrl_hex [concat $base 0]]
}

# ILA capture while the replay loops. trig: probe name that must be 1.
proc capture {name corpus ddiv trig} {
  global ila raw
  set base [list 2]
  if {$corpus} { lappend base 4 }
  vio_set ctrl [ctrl_hex [concat $base 0]] drain_div [format %02X $ddiv]
  vio_set ctrl [ctrl_hex $base]
  vio_set ctrl [ctrl_hex [concat $base 1]]
  after 200
  reset_hw_ila $ila
  set_property CONTROL.DATA_DEPTH 2048 $ila
  set_property CONTROL.TRIGGER_POSITION 512 $ila
  set_property TRIGGER_COMPARE_VALUE eq1'b1 [get_hw_probes $trig -of_objects $ila]
  run_hw_ila $ila
  wait_on_hw_ila -timeout 1 $ila
  set d [upload_hw_ila_data $ila]
  write_hw_ila_data -force -csv_file $raw/${name}.csv $d
  write_hw_ila_data -force $raw/${name}.ila $d
  vio_set ctrl [ctrl_hex [concat $base 0]]
  puts "HWBENCH capture $name done"
}

# Clock check: free-running cycle counter against host time.
set c0 [reg 1]
after 10000
set c1 [reg 1]
set fh [open $raw/clock_check.json w]
puts $fh "{\"test\": \"clock_check\", \"uptime0_hex\": \"[lindex $c0 0]\", \"host0_us\": [lindex $c0 1], \"uptime1_hex\": \"[lindex $c1 0]\", \"host1_us\": [lindex $c1 1]}"
close $fh
puts "HWBENCH clock_check done"

cold A_cold 0 0 1000000
cold B_cold 1 0 1000000
cold A_drain31_cold 0 31 1000000
sustained A_1s 0 0 100000000 5
sustained B_1s 1 0 100000000 5
sustained A_drain31_1s 0 31 100000000 3
sustained A_10s 0 0 1000000000 1
capture ila_A 0 0 dbg_ev_fire
capture ila_B 1 0 dbg_ev_fire
capture ila_A_drain31 0 31 fifo_full

vio_set ctrl 00 drain_div 00
close_hw_target
disconnect_hw_server
puts "HWBENCH COMPLETE"
