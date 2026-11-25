// bench_system.sv - original replay -> parser -> FIFO datapath plus bench_monitor
//
// The datapath is wired exactly as in top_basys3.sv. Two additions, both inert
// at their default control values (corpus_sel=0, drain_div=0):
//   - corpus B: a second bram_replay holding back-to-back frames, selected by
//     corpus_sel. With corpus_sel=0 the original replay (frames.mem) sees the
//     same start/loop/ready signals as in top_basys3.
//   - drain throttle: drain_div=N>0 lets the FIFO be read only once every N+1
//     cycles, to exercise backpressure. drain_div=0 is the original always-drain.
module bench_system #(
    parameter              INIT_A   = "frames.mem",
    parameter              INIT_B   = "frames_b2b.mem",
    parameter logic [31:0] BUILD_ID = 32'h0
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic        loop_en,
    input  logic        corpus_sel,
    input  logic [7:0]  drain_div,
    input  logic        arm,
    input  logic [31:0] window_len,
    input  logic [7:0]  sel,
    output logic [63:0] rdata,
    output logic [7:0]  rsel,
    output logic [7:0]  mon_status,
    // original signals used by the board display / LEDs
    output logic        replay_done,
    output logic        parser_busy,
    output logic        sync_accept,
    output logic        ev_valid,
    output logic        fifo_full,
    output logic        fifo_empty,
    output logic [2:0]  parser_state,
    output logic [31:0] msg_count,
    output logic [31:0] crc_err_count,
    output logic [31:0] gap_count,
    output logic [15:0] last_latency,
    // debug taps for the ILA
    output logic        dbg_take,
    output logic [7:0]  dbg_byte,
    output logic        dbg_byte_valid,
    output logic        dbg_ev_fire,
    output logic [7:0]  dbg_ev_status,
    output logic [15:0] dbg_ev_seq,
    output logic        dbg_fifo_rd
);

  import protocol_pkg::*;

  logic        byte_valid, byte_ready;
  logic [7:0]  byte_data;

  // ---------------------------------------------------------------------------
  // Replay sources
  // ---------------------------------------------------------------------------
  logic        a_valid, b_valid, a_done, b_done;
  logic [7:0]  a_data, b_data;

  bram_replay #(
      .MEM_DEPTH(4096),
      .INIT_FILE(INIT_A)
  ) u_replay (
      .clk      (clk),
      .rst      (rst),
      .start    (start && !corpus_sel),
      .loop_en  (loop_en),
      .out_ready(byte_ready && !corpus_sel),
      .out_valid(a_valid),
      .out_data (a_data),
      .done     (a_done),
      .addr_o   ()
  );

  bram_replay #(
      .MEM_DEPTH(4094),
      .INIT_FILE(INIT_B)
  ) u_replay_b2b (
      .clk      (clk),
      .rst      (rst),
      .start    (start && corpus_sel),
      .loop_en  (loop_en),
      .out_ready(byte_ready && corpus_sel),
      .out_valid(b_valid),
      .out_data (b_data),
      .done     (b_done),
      .addr_o   ()
  );

  assign byte_valid  = corpus_sel ? b_valid : a_valid;
  assign byte_data   = corpus_sel ? b_data  : a_data;
  assign replay_done = corpus_sel ? b_done  : a_done;

  // ---------------------------------------------------------------------------
  // Parser, FIFO and original counters (as in top_basys3)
  // ---------------------------------------------------------------------------
  logic         ev_ready;
  logic [127:0] ev_data, fifo_rdata;
  logic [5:0]   fifo_count;
  logic [7:0]   last_flags;
  logic [31:0]  cycle_sum;
  logic [15:0]  max_latency;

  assign ev_ready = !fifo_full;

  parser_core u_parser (
      .clk        (clk),
      .rst        (rst),
      .in_valid   (byte_valid),
      .in_data    (byte_data),
      .in_ready   (byte_ready),
      .event_valid(ev_valid),
      .event_data (ev_data),
      .event_ready(ev_ready),
      .last_flags (last_flags),
      .state_o    (parser_state),
      .sync_accept(sync_accept),
      .busy       (parser_busy)
  );

  // Drain throttle (drain_div=0: read whenever not empty, as in top_basys3)
  logic [7:0] dcnt;
  wire        drain_ok = (drain_div == 8'd0) || (dcnt == 8'd0);
  wire        rd_en    = !fifo_empty && drain_ok;

  always_ff @(posedge clk) begin
    if (rst || drain_div == 8'd0) dcnt <= '0;
    else if (dcnt == 8'd0)        dcnt <= drain_div;
    else                          dcnt <= dcnt - 8'd1;
  end

  event_fifo #(.DEPTH(32)) u_fifo (
      .clk    (clk),
      .rst    (rst),
      .wr_en  (ev_valid && !fifo_full),
      .wr_data(ev_data),
      .full   (fifo_full),
      .rd_en  (rd_en),
      .rd_data(fifo_rdata),
      .empty  (fifo_empty),
      .count  (fifo_count)
  );

  perf_counters u_perf (
      .clk           (clk),
      .rst           (rst),
      .sync_accept   (sync_accept),
      .event_valid   (ev_valid),
      .event_ready   (!fifo_full),
      .event_status  (ev_data[127:120]),
      .msg_count     (msg_count),
      .crc_err_count (crc_err_count),
      .gap_count     (gap_count),
      .cycle_sum     (cycle_sum),
      .last_latency  (last_latency),
      .max_latency   (max_latency)
  );

  // ---------------------------------------------------------------------------
  // Monitor
  // ---------------------------------------------------------------------------
  wire fifo_rd = rd_en;  // rd_en already includes !fifo_empty

  bench_monitor #(.BUILD_ID(BUILD_ID)) u_mon (
      .clk              (clk),
      .rst              (rst),
      .arm              (arm),
      .window_len       (window_len),
      .byte_valid       (byte_valid),
      .byte_ready       (byte_ready),
      .byte_data        (byte_data),
      .pstate           (parser_state),
      .ev_valid         (ev_valid),
      .ev_ready         (ev_ready),
      .ev_status        (ev_data[127:120]),
      .fifo_rd          (fifo_rd),
      .fifo_full        (fifo_full),
      .fifo_count       (fifo_count),
      .orig_msg_count   (msg_count),
      .orig_last_latency(last_latency),
      .cfg_echo         ({22'd0, corpus_sel, loop_en, drain_div}),
      .sel              (sel),
      .rdata            (rdata),
      .rsel             (rsel),
      .status           (mon_status)
  );

  assign dbg_take       = byte_valid && byte_ready;
  assign dbg_byte       = byte_data;
  assign dbg_byte_valid = byte_valid;
  assign dbg_ev_fire    = ev_valid && ev_ready;
  assign dbg_ev_status  = ev_data[127:120];
  assign dbg_ev_seq     = ev_data[111:96];
  assign dbg_fifo_rd    = fifo_rd;

endmodule
