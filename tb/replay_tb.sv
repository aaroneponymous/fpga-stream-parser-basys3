// replay_tb.sv - BRAM replay + parser end-to-end smoke
`timescale 1ns/1ps

module replay_tb;

  import protocol_pkg::*;

  logic clk, rst, start, loop_en;
  logic byte_valid, byte_ready;
  logic [7:0] byte_data;
  logic done;
  logic ev_valid, ev_ready, fifo_full, fifo_empty;
  logic [127:0] ev_data, fifo_rdata;
  logic sync_accept;
  logic [31:0] msg_count, crc_err_count, gap_count, cycle_sum;
  logic [15:0] last_latency, max_latency;

  initial clk = 0;
  always #5 clk = ~clk;

  bram_replay #(
      .MEM_DEPTH(4096),
      .INIT_FILE("frames.mem")
  ) u_replay (
      .clk(clk), .rst(rst), .start(start), .loop_en(loop_en),
      .out_ready(byte_ready), .out_valid(byte_valid), .out_data(byte_data),
      .done(done), .addr_o()
  );

  parser_core u_parser (
      .clk(clk), .rst(rst),
      .in_valid(byte_valid), .in_data(byte_data), .in_ready(byte_ready),
      .event_valid(ev_valid), .event_data(ev_data), .event_ready(!fifo_full),
      .last_flags(), .state_o(), .sync_accept(sync_accept), .busy()
  );

  event_fifo #(.DEPTH(32)) u_fifo (
      .clk(clk), .rst(rst),
      .wr_en(ev_valid && !fifo_full), .wr_data(ev_data), .full(fifo_full),
      .rd_en(!fifo_empty), .rd_data(fifo_rdata), .empty(fifo_empty), .count()
  );

  perf_counters u_perf (
      .clk(clk), .rst(rst), .sync_accept(sync_accept),
      .event_valid(ev_valid), .event_ready(!fifo_full),
      .event_status(ev_data[127:120]),
      .msg_count(msg_count), .crc_err_count(crc_err_count), .gap_count(gap_count),
      .cycle_sum(cycle_sum), .last_latency(last_latency), .max_latency(max_latency)
  );

  initial begin
    rst = 1; start = 0; loop_en = 0;
    repeat (4) @(posedge clk);
    rst = 0;
    @(posedge clk);
    start = 1;
    // Wait until done or enough messages
    wait (done || msg_count >= 200);
    repeat (20) @(posedge clk);
    start = 0;
    $display("replay_tb: msgs=%0d crc_err=%0d gaps=%0d last_lat=%0d max_lat=%0d",
             msg_count, crc_err_count, gap_count, last_latency, max_latency);
    if (msg_count < 50) $error("too few messages");
    else $display("replay_tb: PASS");
    $finish;
  end

  initial begin
    #5_000_000;
    $error("TIMEOUT");
    $finish;
  end

endmodule
