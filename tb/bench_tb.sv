// bench_tb.sv - simulation checks for the hardware benchmark instrumentation
//
// 1. Equivalence: bench_system (corpus A, drain_div=0) and the original
//    top_basys3 are driven with the same reset/start/loop sequence; their parser
//    event handshakes and event words must match cycle for cycle.
// 2. Monitor accuracy: an independent scoreboard in this testbench tracks frame
//    starts and event handshakes and recomputes counts and latency stats.
// 3. Reference: every monitor register is printed as "REG <scenario> <sel> <hex>"
//    so hardware runs with the same deterministic window can be compared.
`timescale 1ns/1ps

module bench_tb;

  import protocol_pkg::*;
  import parser_pkg::*;

  localparam int WIN = 1_000_000;

  logic clk = 0;
  always #5 clk = ~clk;

  logic        rst, start, loop_en, corpus_sel, arm;
  logic [7:0]  drain_div, sel;
  logic [31:0] window_len;
  logic [63:0] rdata;
  logic [7:0]  rsel, mon_status;
  logic        replay_done, parser_busy, sync_accept, ev_valid, fifo_full, fifo_empty;
  logic [2:0]  parser_state;
  logic [31:0] msg_count, crc_err_count, gap_count;
  logic [15:0] last_latency;
  logic        dbg_take, dbg_byte_valid, dbg_ev_fire, dbg_fifo_rd;
  logic [7:0]  dbg_byte, dbg_ev_status;
  logic [15:0] dbg_ev_seq;

  bench_system #(.INIT_A("frames.mem"), .INIT_B("frames_b2b.mem"), .BUILD_ID(32'h5151_0000)) dut (
      .clk(clk), .rst(rst), .start(start), .loop_en(loop_en), .corpus_sel(corpus_sel),
      .drain_div(drain_div), .arm(arm), .window_len(window_len), .sel(sel),
      .rdata(rdata), .rsel(rsel), .mon_status(mon_status),
      .replay_done(replay_done), .parser_busy(parser_busy), .sync_accept(sync_accept),
      .ev_valid(ev_valid), .fifo_full(fifo_full), .fifo_empty(fifo_empty),
      .parser_state(parser_state), .msg_count(msg_count), .crc_err_count(crc_err_count),
      .gap_count(gap_count), .last_latency(last_latency),
      .dbg_take(dbg_take), .dbg_byte(dbg_byte), .dbg_byte_valid(dbg_byte_valid),
      .dbg_ev_fire(dbg_ev_fire), .dbg_ev_status(dbg_ev_status), .dbg_ev_seq(dbg_ev_seq),
      .dbg_fifo_rd(dbg_fifo_rd)
  );

  // Original top, driven by the same reset/start/loop (sw[0], sw[1], btnC)
  logic [15:0] o_led, o_sw;
  logic [6:0]  o_seg;
  logic        o_dp;
  logic [3:0]  o_an;
  assign o_sw = {14'd0, loop_en, start && !corpus_sel};
  top_basys3 ref_top (
      .clk(clk), .btnC(rst), .sw(o_sw), .led(o_led), .seg(o_seg), .dp(o_dp), .an(o_an)
  );

  // ---------------------------------------------------------------------------
  // Equivalence check (only meaningful while corpus A, drain_div=0)
  // ---------------------------------------------------------------------------
  logic        eq_en = 0;
  longint      eq_cycles = 0, eq_events = 0, eq_mismatch = 0;
  always @(posedge clk) if (eq_en) begin
    eq_cycles++;
    if (ref_top.ev_valid !== dut.ev_valid ||
        (ref_top.ev_valid && ref_top.ev_data !== dut.ev_data) ||
        ref_top.u_parser.state !== dut.u_parser.state ||
        ref_top.byte_valid !== dut.byte_valid || ref_top.byte_data !== dut.byte_data) begin
      if (eq_mismatch < 5) $display("EQ MISMATCH at %0t", $time);
      eq_mismatch++;
    end
    if (ref_top.ev_valid && !ref_top.fifo_full) eq_events++;
  end

  // ---------------------------------------------------------------------------
  // Independent scoreboard
  // ---------------------------------------------------------------------------
  longint cyc = 0;
  always @(posedge clk) cyc++;

  logic         sb_on = 0;
  longint       sb_ev, sb_commit, sb_bytes, sb_fifo_rd, sb_ok, sb_crc, sb_gap;
  longint       sb_l1_sum, sb_l1_n, sb_l1_min, sb_l1_max;
  longint       sb_l2_sum, sb_l2_n, sb_l2_min, sb_l2_max;
  longint       sb_cand, q1[$], q2[$];

  always @(posedge clk) begin
    if (rst) begin
      q1.delete(); q2.delete();
    end else begin
      automatic logic tk = dbg_take;
      automatic logic [2:0] st = parser_state;
      if (tk && dbg_byte == SYNC0 && (st == ST_HUNT || st == ST_SYNC1 || st == ST_RESYNC))
        sb_cand = cyc;
      if (tk && st == ST_SYNC1 && dbg_byte == SYNC1) begin
        q1.push_back(sb_cand);
        if (sb_on) sb_commit++;
      end
      if (dbg_ev_fire) begin
        automatic longint t = q1.pop_front();
        automatic longint l = cyc - t;
        q2.push_back(t);
        if (sb_on) begin
          sb_ev++;
          if (dbg_ev_status == EVT_OK) sb_ok++;
          if (dbg_ev_status == EVT_CRC_ERR) sb_crc++;
          if (dbg_ev_status == EVT_GAP) sb_gap++;
          sb_l1_sum += l; sb_l1_n++;
          if (l < sb_l1_min) sb_l1_min = l;
          if (l > sb_l1_max) sb_l1_max = l;
        end
      end
      if (dbg_fifo_rd) begin
        automatic longint t = q2.pop_front();
        automatic longint l = cyc - t;
        if (sb_on) begin
          sb_fifo_rd++;
          sb_l2_sum += l; sb_l2_n++;
          if (l < sb_l2_min) sb_l2_min = l;
          if (l > sb_l2_max) sb_l2_max = l;
        end
      end
      if (sb_on && tk) sb_bytes++;
    end
  end

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  int errors = 0;

  task automatic rd(input logic [7:0] s, output logic [63:0] v);
    sel = s;
    repeat (4) @(posedge clk);
    if (rsel !== s) begin $display("FAIL readout tag %02h != %02h", rsel, s); errors++; end
    v = rdata;
  endtask

  task automatic check(input string what, input longint got, input longint exp);
    if (got !== exp) begin
      $display("FAIL %s: monitor=%0d scoreboard/expected=%0d", what, got, exp);
      errors++;
    end else
      $display("ok   %s = %0d", what, got);
  endtask

  task automatic dump(input string scen);
    logic [63:0] v;
    for (int s = 0; s < 32; s++) begin rd(8'(s), v); $display("REG %s %02h %016h", scen, s, v); end
    for (int s = 8'h40; s < 8'hC0; s++) begin rd(8'(s), v); if (v != 0) $display("REG %s %02h %016h", scen, s, v); end
  endtask

  // Reset, then start replay and arm the window in the same cycle (as the
  // host does with ctrl[5]=1), wait for the window to finish, check, dump.
  task automatic run(input string scen, input logic csel, input logic [7:0] ddiv, input bit equiv);
    logic [63:0] v, ev, cm, by, rdc, ok, crc, gap, l1s, l1n, l1mn, l1mx, l2s, l2n, l2mn, l2mx, qs, qe;
    @(negedge clk);
    rst = 1; start = 0; arm = 0; corpus_sel = csel; drain_div = ddiv; loop_en = 1;
    window_len = WIN;
    repeat (5) @(negedge clk);
    rst = 0;
    repeat (10) @(negedge clk);
    sb_ev = 0; sb_commit = 0; sb_bytes = 0; sb_fifo_rd = 0; sb_ok = 0; sb_crc = 0; sb_gap = 0;
    sb_l1_sum = 0; sb_l1_n = 0; sb_l1_min = 64'h7fffffffffffffff; sb_l1_max = 0;
    sb_l2_sum = 0; sb_l2_n = 0; sb_l2_min = 64'h7fffffffffffffff; sb_l2_max = 0;
    eq_cycles = 0; eq_events = 0; eq_mismatch = 0;
    start = 1; arm = 1;
    @(negedge clk);
    arm = 0; sb_on = 1; eq_en = equiv;
    wait (mon_status[1]);
    @(negedge clk);
    sb_on = 0; eq_en = 0;
    repeat (4) @(negedge clk);

    $display("=== %s (corpus_sel=%0d drain_div=%0d window=%0d cycles) ===", scen, csel, ddiv, WIN);
    if (equiv) begin
      $display("equivalence vs top_basys3: %0d cycles, %0d events, %0d mismatching cycles",
               eq_cycles, eq_events, eq_mismatch);
      if (eq_mismatch != 0) errors++;
    end
    rd(8'h02, v);  check("window cycles", v, WIN);
    rd(8'h04, by); check("bytes accepted", by, sb_bytes);
    rd(8'h06, cm); check("frames committed", cm, sb_commit);
    rd(8'h07, ev); check("events", ev, sb_ev);
    rd(8'h08, ok); check("ok events", ok, sb_ok);
    rd(8'h09, crc); check("crc_err events", crc, sb_crc);
    rd(8'h0A, gap); check("gap events", gap, sb_gap);
    rd(8'h0C, rdc); check("fifo reads", rdc, sb_fifo_rd);
    rd(8'h12, l1mn); check("lat1 min", l1mn, sb_l1_min);
    rd(8'h13, l1mx); check("lat1 max", l1mx, sb_l1_max);
    rd(8'h14, l1s); check("lat1 sum", l1s, sb_l1_sum);
    rd(8'h15, l1n); check("lat1 n", l1n, sb_l1_n);
    rd(8'h16, l2mn); check("lat2 min", l2mn, sb_l2_min);
    rd(8'h17, l2mx); check("lat2 max", l2mx, sb_l2_max);
    rd(8'h18, l2s); check("lat2 sum", l2s, sb_l2_sum);
    rd(8'h19, l2n); check("lat2 n", l2n, sb_l2_n);
    rd(8'h1A, qs);
    rd(8'h1B, qe); check("queue over/underflows", qe, 0);
    // conservation: commits + q1_start == events + q1_end; events + q2_start == reads + q2_end
    check("q1 conservation", cm + qs[31:24], ev + qs[23:16]);
    check("q2 conservation", ev + qs[15:8], rdc + qs[7:0]);
    $display("SUMMARY %s events=%0d rate=%.4f Mmsg/s@100MHz lat1 min/avg/max=%0d/%.3f/%0d lat2 min/avg/max=%0d/%.3f/%0d",
             scen, ev, real'(ev) * 100.0 / WIN, l1mn, real'(l1s) / l1n, l1mx, l2mn, real'(l2s) / l2n, l2mx);
    dump(scen);
    start = 0;
  endtask

  initial begin
    rst = 1; start = 0; loop_en = 0; corpus_sel = 0; arm = 0; drain_div = 0; sel = 0; window_len = WIN;
    run("A_cold", 1'b0, 8'd0, 1'b1);
    run("B_cold", 1'b1, 8'd0, 1'b0);
    run("A_drain31", 1'b0, 8'd31, 1'b0);
    if (errors == 0) $display("bench_tb: ALL PASS");
    else             $display("bench_tb: %0d FAILURES", errors);
    $finish;
  end

endmodule
