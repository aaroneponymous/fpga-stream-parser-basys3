// top_basys3.sv - Basys 3 streaming parser accelerator top
module top_basys3 (
    input  logic       clk,          // 100 MHz
    input  logic       btnC,         // reset (active high)
    input  logic [15:0] sw,
    output logic [15:0] led,
    output logic [6:0] seg,
    output logic       dp,
    output logic [3:0] an
);

  import protocol_pkg::*;

  // sw[0] = start replay
  // sw[1] = loop enable
  // sw[2] = drain events (auto-pop FIFO)
  logic rst;
  assign rst = btnC;

  logic        byte_valid, byte_ready;
  logic [7:0]  byte_data;
  logic        replay_done;

  logic        ev_valid, ev_ready, fifo_full, fifo_empty;
  logic [127:0] ev_data, fifo_rdata;
  logic [5:0]  fifo_count;

  logic        sync_accept, parser_busy;
  logic [7:0]  last_flags;
  logic [2:0]  parser_state;

  logic [31:0] msg_count, crc_err_count, gap_count, cycle_sum;
  logic [15:0] last_latency, max_latency;

  bram_replay #(
      .MEM_DEPTH(4096),
      .INIT_FILE("frames.mem")
  ) u_replay (
      .clk      (clk),
      .rst      (rst),
      .start    (sw[0]),
      .loop_en  (sw[1]),
      .out_ready(byte_ready),
      .out_valid(byte_valid),
      .out_data (byte_data),
      .done     (replay_done),
      .addr_o   ()
  );

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

  event_fifo #(.DEPTH(32)) u_fifo (
      .clk    (clk),
      .rst    (rst),
      .wr_en  (ev_valid && !fifo_full),
      .wr_data(ev_data),
      .full   (fifo_full),
      .rd_en  (!fifo_empty),  // always drain so looped replay never backpressures
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

  // LEDs: activity + status
  assign led[0]     = parser_busy;
  assign led[1]     = sync_accept;
  assign led[2]     = ev_valid;
  assign led[3]     = fifo_full;
  assign led[4]     = fifo_empty;
  assign led[5]     = replay_done;
  assign led[6]     = |crc_err_count;
  assign led[7]     = |gap_count;
  assign led[11:8]  = parser_state;
  assign led[15:12] = rate_kmsg[3:0];

  // -------------------------------------------------------------------------
  // Readable 7-seg (raw msg_count[15:0] wraps ~every 15 ms at 4M msg/s)
  //   sw[3]=1          → last latency in cycles (expect ~0x017)
  //   sw[3]=0, sw[2]=0 → total >> 10  (~K msgs), frozen when sw[0]=0
  //   sw[3]=0, sw[2]=1 → throughput >> 10 per second (~K msg/s; ~0x10C0 ≈ 4.3M/s)
  // -------------------------------------------------------------------------
  logic [26:0] sec_div;
  logic [31:0] msg_snap;
  logic [15:0] rate_kmsg;
  logic [15:0] total_kmsg;
  logic [15:0] disp_val;
  logic [15:0] disp_latched;

  localparam logic [26:0] CYCLES_PER_SEC = 27'd100_000_000;

  always_comb begin
    if (sw[3])
      disp_val = last_latency;
    else if (sw[2])
      disp_val = rate_kmsg;
    else
      disp_val = total_kmsg;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      sec_div      <= '0;
      msg_snap     <= '0;
      rate_kmsg    <= '0;
      total_kmsg   <= '0;
      disp_latched <= '0;
    end else begin
      if (sec_div == CYCLES_PER_SEC - 27'd1) begin
        sec_div   <= '0;
        // /1024 ≈ K msg/s (avoids slow divider)
        rate_kmsg <= (msg_count - msg_snap) >> 10;
        msg_snap  <= msg_count;
      end else begin
        sec_div <= sec_div + 27'd1;
      end

      if (sw[0])
        total_kmsg <= msg_count[25:10];  // >> 10

      if (sec_div[19:0] == 20'd0)
        disp_latched <= disp_val;
    end
  end

  // Decimal point ON when showing rate
  assign dp = ~(sw[2] & ~sw[3]);

  logic [16:0] div;
  logic [1:0]  dig_sel;
  logic [3:0]  nibble;

  always_ff @(posedge clk) begin
    if (rst) begin
      div     <= '0;
      dig_sel <= '0;
    end else begin
      div <= div + 17'd1;
      if (div == '0)
        dig_sel <= dig_sel + 2'd1;
    end
  end

  always_comb begin
    unique case (dig_sel)
      2'd0: begin an = 4'b1110; nibble = disp_latched[3:0];   end
      2'd1: begin an = 4'b1101; nibble = disp_latched[7:4];   end
      2'd2: begin an = 4'b1011; nibble = disp_latched[11:8];  end
      2'd3: begin an = 4'b0111; nibble = disp_latched[15:12]; end
    endcase
  end

  always_comb begin
    unique case (nibble)
      4'h0: seg = 7'b1000000;
      4'h1: seg = 7'b1111001;
      4'h2: seg = 7'b0100100;
      4'h3: seg = 7'b0110000;
      4'h4: seg = 7'b0011001;
      4'h5: seg = 7'b0010010;
      4'h6: seg = 7'b0000010;
      4'h7: seg = 7'b1111000;
      4'h8: seg = 7'b0000000;
      4'h9: seg = 7'b0010000;
      4'hA: seg = 7'b0001000;
      4'hB: seg = 7'b0000011;
      4'hC: seg = 7'b1000110;
      4'hD: seg = 7'b0100001;
      4'hE: seg = 7'b0000110;
      4'hF: seg = 7'b0001110;
    endcase
  end

endmodule
