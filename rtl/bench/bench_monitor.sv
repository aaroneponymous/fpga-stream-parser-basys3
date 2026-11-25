// bench_monitor.sv - passive hardware benchmark monitor for the streaming parser
//
// Observes the replay -> parser -> event FIFO handshakes and never drives them.
// After an arm pulse it counts for exactly window_len clock cycles, then freezes
// every result so the host can read them back one 64-bit register at a time.
//
// Latency is matched per message with timestamp queues, so it stays correct when
// more than one message is in flight:
//   - A candidate start time is taken when a SYNC0 byte is accepted by the parser
//     in HUNT, SYNC1 or RESYNC (the states in which parser_core starts a frame).
//   - The candidate is committed (pushed to q1) when the following SYNC1 byte is
//     accepted. From ST_HDR onward parser_core always reaches ST_EMIT, so every
//     committed frame produces exactly one event.
//   - lat1: SYNC0 handshake -> parser event handshake (pop q1, push q2).
//   - lat2: SYNC0 handshake -> event leaves event_fifo (pop q2).
// Queue overflow/underflow counters and the start/end occupancies let the host
// prove that every message was matched and none was dropped.
module bench_monitor #(
    parameter logic [31:0] BUILD_ID = 32'h0
) (
    input  logic        clk,
    input  logic        rst,
    // control
    input  logic        arm,           // 1-cycle pulse: clear and start a window
    input  logic [31:0] window_len,    // cycles per window (0 is treated as 1)
    // replay -> parser
    input  logic        byte_valid,
    input  logic        byte_ready,
    input  logic [7:0]  byte_data,
    input  logic [2:0]  pstate,        // parser_core.state_o (state before this edge)
    // parser -> FIFO
    input  logic        ev_valid,
    input  logic        ev_ready,
    input  logic [7:0]  ev_status,
    // FIFO -> sink
    input  logic        fifo_rd,       // rd_en && !empty
    input  logic        fifo_full,
    input  logic [5:0]  fifo_count,
    // original perf_counters (read live, for cross-checking)
    input  logic [31:0] orig_msg_count,
    input  logic [15:0] orig_last_latency,
    input  logic [31:0] cfg_echo,
    // readout
    input  logic [7:0]  sel,
    output logic [63:0] rdata,
    output logic [7:0]  rsel,          // sel that rdata belongs to
    output logic [7:0]  status
);

  import protocol_pkg::*;
  import parser_pkg::*;

  localparam int Q1_DEPTH = 4;
  localparam int Q2_DEPTH = 64;

  // ---------------------------------------------------------------------------
  // Free-running cycle counter (not reset, so the host can time the clock)
  // ---------------------------------------------------------------------------
  logic [63:0] uptime = '0;
  always_ff @(posedge clk) uptime <= uptime + 64'd1;

  wire [31:0] now = uptime[31:0];

  // ---------------------------------------------------------------------------
  // Handshake decode
  // ---------------------------------------------------------------------------
  wire take     = byte_valid && byte_ready;
  wire ev_fire  = ev_valid && ev_ready;
  wire st_hunt  = (pstate == ST_HUNT);
  wire st_sync1 = (pstate == ST_SYNC1);
  wire st_rsync = (pstate == ST_RESYNC);
  wire cand     = take && (byte_data == SYNC0) && (st_hunt || st_sync1 || st_rsync);
  wire commit   = take && st_sync1 && (byte_data == SYNC1);

  logic [31:0] cand_ts;
  always_ff @(posedge clk) begin
    if (rst)       cand_ts <= '0;
    else if (cand) cand_ts <= now;
  end

  // ---------------------------------------------------------------------------
  // Timestamp queues
  // ---------------------------------------------------------------------------
  logic [31:0] q1 [0:Q1_DEPTH-1];
  logic [1:0]  q1_wp, q1_rp;
  logic [2:0]  q1_n;
  logic [31:0] q2 [0:Q2_DEPTH-1];
  logic [5:0]  q2_wp, q2_rp;
  logic [6:0]  q2_n;

  wire q1_push = commit && (q1_n != 3'(Q1_DEPTH));
  wire q1_pop  = ev_fire && (q1_n != 0);
  wire q2_push = ev_fire && (q1_n != 0) && (q2_n != 7'(Q2_DEPTH));
  wire q2_pop  = fifo_rd && (q2_n != 0);

  wire [31:0] q1_head = q1[q1_rp];
  wire [31:0] q2_head = q2[q2_rp];

  always_ff @(posedge clk) begin
    if (rst) begin
      q1_wp <= '0; q1_rp <= '0; q1_n <= '0;
      q2_wp <= '0; q2_rp <= '0; q2_n <= '0;
    end else begin
      if (q1_push) begin q1[q1_wp] <= cand_ts; q1_wp <= q1_wp + 1'b1; end
      if (q1_pop)  q1_rp <= q1_rp + 1'b1;
      q1_n <= q1_n + 3'(q1_push) - 3'(q1_pop);

      if (q2_push) begin q2[q2_wp] <= q1_head; q2_wp <= q2_wp + 1'b1; end
      if (q2_pop)  q2_rp <= q2_rp + 1'b1;
      q2_n <= q2_n + 7'(q2_push) - 7'(q2_pop);
    end
  end

  // ---------------------------------------------------------------------------
  // Window control
  // ---------------------------------------------------------------------------
  logic        active, done;
  logic [63:0] wcnt;
  wire  [31:0] wlen = (window_len == 0) ? 32'd1 : window_len;

  always_ff @(posedge clk) begin
    if (rst) begin
      active <= 1'b0;
      done   <= 1'b0;
      wcnt   <= '0;
    end else if (arm) begin
      active <= 1'b1;
      done   <= 1'b0;
      wcnt   <= '0;
    end else if (active) begin
      wcnt <= wcnt + 64'd1;
      if (wcnt + 64'd1 == {32'd0, wlen}) begin
        active <= 1'b0;
        done   <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Latency samples, registered so the stats update stays short
  // ---------------------------------------------------------------------------
  logic        s1_v, s2_v;
  logic [31:0] s1_lat, s2_lat;
  always_ff @(posedge clk) begin
    if (rst) begin
      s1_v <= 1'b0; s2_v <= 1'b0; s1_lat <= '0; s2_lat <= '0;
    end else begin
      s1_v   <= active && q1_pop;
      s1_lat <= now - q1_head;
      s2_v   <= active && q2_pop;
      s2_lat <= now - q2_head;
    end
  end

  // Second stage: histogram bin (latencies above 63 go to bin 63)
  logic        t1_v, t2_v;
  logic [31:0] t1_lat, t2_lat;
  logic [5:0]  b1, b2;
  always_ff @(posedge clk) begin
    if (rst) begin
      t1_v <= 1'b0; t2_v <= 1'b0; t1_lat <= '0; t2_lat <= '0; b1 <= '0; b2 <= '0;
    end else begin
      t1_v <= s1_v; t1_lat <= s1_lat; b1 <= (s1_lat > 32'd63) ? 6'd63 : s1_lat[5:0];
      t2_v <= s2_v; t2_lat <= s2_lat; b2 <= (s2_lat > 32'd63) ? 6'd63 : s2_lat[5:0];
    end
  end

  // ---------------------------------------------------------------------------
  // Window counters
  // ---------------------------------------------------------------------------
  logic [63:0] c_bytes, c_cand, c_commit, c_events, c_ok, c_crc, c_gap, c_rsync;
  logic [63:0] c_fifo_rd, c_in_stall, c_src_idle, c_out_bp, c_fifo_full;
  logic [5:0]  fifo_max;
  logic [31:0] l1_min, l1_max, l2_min, l2_max;
  logic [63:0] l1_sum, l1_n, l2_sum, l2_n;
  logic [15:0] q1_ovf, q1_unf, q2_ovf, q2_unf;
  logic [7:0]  q1_start, q1_end, q2_start, q2_end;
  logic [63:0] first_ev, last_ev;
  logic        seen_ev;
  logic [31:0] hist1 [0:63];
  logic [31:0] hist2 [0:63];

  always_ff @(posedge clk) begin
    if (rst || arm) begin
      c_bytes <= '0; c_cand <= '0; c_commit <= '0; c_events <= '0;
      c_ok <= '0; c_crc <= '0; c_gap <= '0; c_rsync <= '0;
      c_fifo_rd <= '0; c_in_stall <= '0; c_src_idle <= '0; c_out_bp <= '0; c_fifo_full <= '0;
      fifo_max <= '0;
      l1_min <= '1; l1_max <= '0; l1_sum <= '0; l1_n <= '0;
      l2_min <= '1; l2_max <= '0; l2_sum <= '0; l2_n <= '0;
      q1_ovf <= '0; q1_unf <= '0; q2_ovf <= '0; q2_unf <= '0;
      // occupancy after the arm cycle, i.e. just before the first counted cycle
      q1_start <= 8'(q1_n + 3'(q1_push) - 3'(q1_pop));
      q2_start <= 8'(q2_n + 7'(q2_push) - 7'(q2_pop));
      q1_end <= '0; q2_end <= '0;
      first_ev <= '0; last_ev <= '0; seen_ev <= 1'b0;
      for (int i = 0; i < 64; i++) begin hist1[i] <= '0; hist2[i] <= '0; end
    end else begin
      if (active) begin
        c_bytes     <= c_bytes     + 64'(take);
        c_cand      <= c_cand      + 64'(cand);
        c_commit    <= c_commit    + 64'(commit);
        c_events    <= c_events    + 64'(ev_fire);
        c_fifo_rd   <= c_fifo_rd   + 64'(fifo_rd);
        c_in_stall  <= c_in_stall  + 64'(byte_valid && !byte_ready);
        c_src_idle  <= c_src_idle  + 64'(!byte_valid);
        c_out_bp    <= c_out_bp    + 64'(ev_valid && !ev_ready);
        c_fifo_full <= c_fifo_full + 64'(fifo_full);
        if (fifo_count > fifo_max) fifo_max <= fifo_count;
        if (ev_fire) begin
          unique case (ev_status)
            EVT_OK:      c_ok    <= c_ok    + 64'd1;
            EVT_CRC_ERR: c_crc   <= c_crc   + 64'd1;
            EVT_GAP:     c_gap   <= c_gap   + 64'd1;
            EVT_RESYNC:  c_rsync <= c_rsync + 64'd1;
            default: ;
          endcase
          if (!seen_ev) begin first_ev <= wcnt; seen_ev <= 1'b1; end
          last_ev <= wcnt;
        end
        if (commit && q1_n == 3'(Q1_DEPTH))   q1_ovf <= q1_ovf + 16'd1;
        if (ev_fire && q1_n == 0)             q1_unf <= q1_unf + 16'd1;
        if (ev_fire && q1_n != 0 && q2_n == 7'(Q2_DEPTH)) q2_ovf <= q2_ovf + 16'd1;
        if (fifo_rd && q2_n == 0)             q2_unf <= q2_unf + 16'd1;
        // occupancy as of the last counted cycle (after its updates)
        q1_end <= 8'(q1_n + 3'(q1_push) - 3'(q1_pop));
        q2_end <= 8'(q2_n + 7'(q2_push) - 7'(q2_pop));
      end

      if (t1_v) begin
        if (t1_lat < l1_min) l1_min <= t1_lat;
        if (t1_lat > l1_max) l1_max <= t1_lat;
        l1_sum    <= l1_sum + {32'd0, t1_lat};
        l1_n      <= l1_n + 64'd1;
        hist1[b1] <= hist1[b1] + 32'd1;
      end
      if (t2_v) begin
        if (t2_lat < l2_min) l2_min <= t2_lat;
        if (t2_lat > l2_max) l2_max <= t2_lat;
        l2_sum    <= l2_sum + {32'd0, t2_lat};
        l2_n      <= l2_n + 64'd1;
        hist2[b2] <= hist2[b2] + 32'd1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Readout (two register stages)
  // ---------------------------------------------------------------------------
  logic [7:0]  sel_r;
  logic [63:0] mux;
  always_comb begin
    mux = '0;
    if (sel_r[7:6] == 2'b01)      mux = {32'd0, hist1[sel_r[5:0]]};
    else if (sel_r[7:6] == 2'b10) mux = {32'd0, hist2[sel_r[5:0]]};
    else begin
      unique case (sel_r)
        8'h00: mux = {32'hB0E1_0001, BUILD_ID};
        8'h01: mux = uptime;
        8'h02: mux = wcnt;
        8'h03: mux = {32'd0, wlen};
        8'h04: mux = c_bytes;
        8'h05: mux = c_cand;
        8'h06: mux = c_commit;
        8'h07: mux = c_events;
        8'h08: mux = c_ok;
        8'h09: mux = c_crc;
        8'h0A: mux = c_gap;
        8'h0B: mux = c_rsync;
        8'h0C: mux = c_fifo_rd;
        8'h0D: mux = c_in_stall;
        8'h0E: mux = c_src_idle;
        8'h0F: mux = c_out_bp;
        8'h10: mux = c_fifo_full;
        8'h11: mux = {58'd0, fifo_max};
        8'h12: mux = {32'd0, l1_min};
        8'h13: mux = {32'd0, l1_max};
        8'h14: mux = l1_sum;
        8'h15: mux = l1_n;
        8'h16: mux = {32'd0, l2_min};
        8'h17: mux = {32'd0, l2_max};
        8'h18: mux = l2_sum;
        8'h19: mux = l2_n;
        8'h1A: mux = {32'd0, q1_start, q1_end, q2_start, q2_end};
        8'h1B: mux = {q1_ovf, q1_unf, q2_ovf, q2_unf};
        8'h1C: mux = first_ev;
        8'h1D: mux = last_ev;
        8'h1E: mux = {16'd0, orig_last_latency, orig_msg_count};
        8'h1F: mux = {32'd0, cfg_echo};
        default: mux = 64'hDEAD_BEEF_DEAD_BEEF;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    sel_r <= sel;
    rdata <= mux;
    rsel  <= sel_r;
  end

  assign status = {6'd0, done, active};

endmodule
