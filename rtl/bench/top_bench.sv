// top_bench.sv - Basys 3 top for hardware benchmarking
//
// Same ports, switches, LEDs and 7-seg display as top_basys3.sv. Adds:
//   - vio_bench: host control and 64-bit register readout over JTAG
//   - ila_bench: raw per-cycle capture of the replay/parser/FIFO handshakes
// VIO outputs default to 0, which leaves the board behaving like top_basys3.
//
// VIO probe_out0 (ctrl):
//   [0] soft reset (ORed with btnC)
//   [1] start replay (ORed with sw[0])
//   [2] loop enable  (ORed with sw[1])
//   [3] arm window   (rising edge)
//   [4] corpus select (0 = frames.mem, 1 = back-to-back corpus)
//   [5] arm on start (if set, the rising edge of [1] also arms the window)
module top_bench #(
    parameter logic [31:0] BUILD_ID = 32'h0
) (
    input  logic        clk,          // 100 MHz
    input  logic        btnC,         // reset (active high)
    input  logic [15:0] sw,
    output logic [15:0] led,
    output logic [6:0]  seg,
    output logic        dp,
    output logic [3:0]  an
);

  // ---------------------------------------------------------------------------
  // Host control (VIO)
  // ---------------------------------------------------------------------------
  logic [7:0]  ctrl, sel, drain_div;
  logic [31:0] window_len;
  logic [63:0] rdata;
  logic [7:0]  rsel, mon_status;

  vio_bench u_vio (
      .clk       (clk),
      .probe_in0 (rdata),
      .probe_in1 ({rsel, mon_status}),
      .probe_out0(ctrl),
      .probe_out1(window_len),
      .probe_out2(sel),
      .probe_out3(drain_div)
  );

  logic ctrl_d1, ctrl_d3;
  always_ff @(posedge clk) begin
    ctrl_d1 <= ctrl[1];
    ctrl_d3 <= ctrl[3];
  end

  wire rst     = btnC | ctrl[0];
  wire start   = sw[0] | ctrl[1];
  wire loop_en = sw[1] | ctrl[2];
  wire arm     = (ctrl[3] && !ctrl_d3) || (ctrl[5] && ctrl[1] && !ctrl_d1);

  // ---------------------------------------------------------------------------
  // Datapath + monitor
  // ---------------------------------------------------------------------------
  logic        replay_done, parser_busy, sync_accept, ev_valid, fifo_full, fifo_empty;
  logic [2:0]  parser_state;
  logic [31:0] msg_count, crc_err_count, gap_count;
  logic [15:0] last_latency;
  logic        dbg_take, dbg_byte_valid, dbg_ev_fire, dbg_fifo_rd;
  logic [7:0]  dbg_byte, dbg_ev_status;
  logic [15:0] dbg_ev_seq;

  bench_system #(
      .INIT_A  ("frames.mem"),
      .INIT_B  ("frames_b2b.mem"),
      .BUILD_ID(BUILD_ID)
  ) u_sys (
      .clk           (clk),
      .rst           (rst),
      .start         (start),
      .loop_en       (loop_en),
      .corpus_sel    (ctrl[4]),
      .drain_div     (drain_div),
      .arm           (arm),
      .window_len    (window_len),
      .sel           (sel),
      .rdata         (rdata),
      .rsel          (rsel),
      .mon_status    (mon_status),
      .replay_done   (replay_done),
      .parser_busy   (parser_busy),
      .sync_accept   (sync_accept),
      .ev_valid      (ev_valid),
      .fifo_full     (fifo_full),
      .fifo_empty    (fifo_empty),
      .parser_state  (parser_state),
      .msg_count     (msg_count),
      .crc_err_count (crc_err_count),
      .gap_count     (gap_count),
      .last_latency  (last_latency),
      .dbg_take      (dbg_take),
      .dbg_byte      (dbg_byte),
      .dbg_byte_valid(dbg_byte_valid),
      .dbg_ev_fire   (dbg_ev_fire),
      .dbg_ev_status (dbg_ev_status),
      .dbg_ev_seq    (dbg_ev_seq),
      .dbg_fifo_rd   (dbg_fifo_rd)
  );

  // ---------------------------------------------------------------------------
  // Raw capture (ILA). probe7 is a free-running cycle stamp so the host can
  // check that a capture is contiguous.
  // ---------------------------------------------------------------------------
  logic [31:0] stamp = '0;
  always_ff @(posedge clk) stamp <= stamp + 32'd1;

  ila_bench u_ila (
      .clk    (clk),
      .probe0 (dbg_take),
      .probe1 (dbg_byte),
      .probe2 (parser_state),
      .probe3 (dbg_ev_fire),
      .probe4 (dbg_ev_status),
      .probe5 (dbg_ev_seq),
      .probe6 (dbg_fifo_rd),
      .probe7 (stamp),
      .probe8 (dbg_byte_valid),
      .probe9 (fifo_full)
  );

  // ---------------------------------------------------------------------------
  // LEDs and 7-seg: identical to top_basys3
  // ---------------------------------------------------------------------------
  logic [26:0] sec_div;
  logic [31:0] msg_snap;
  logic [15:0] rate_kmsg;
  logic [15:0] total_kmsg;
  logic [15:0] disp_val;
  logic [15:0] disp_latched;

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
        rate_kmsg <= (msg_count - msg_snap) >> 10;
        msg_snap  <= msg_count;
      end else begin
        sec_div <= sec_div + 27'd1;
      end

      if (start)
        total_kmsg <= msg_count[25:10];

      if (sec_div[19:0] == 20'd0)
        disp_latched <= disp_val;
    end
  end

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
