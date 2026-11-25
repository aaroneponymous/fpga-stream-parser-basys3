// parser_tb.sv - functional + performance bench for streaming parser
`timescale 1ns/1ps

module parser_tb;

  import protocol_pkg::*;
  import parser_pkg::*;

  logic         clk, rst;
  logic         in_valid, in_ready;
  logic [7:0]   in_data;
  logic         event_valid;
  logic [127:0] event_data;
  logic [7:0]   last_flags;
  logic [2:0]   state_o;
  logic         sync_accept, busy;

  logic         fifo_full, fifo_empty;
  logic [127:0] fifo_rdata;
  logic [6:0]   fifo_count;

  parser_core dut (
      .clk(clk), .rst(rst),
      .in_valid(in_valid), .in_data(in_data), .in_ready(in_ready),
      .event_valid(event_valid), .event_data(event_data),
      .event_ready(!fifo_full),
      .last_flags(last_flags), .state_o(state_o),
      .sync_accept(sync_accept), .busy(busy)
  );

  event_fifo #(.DEPTH(64)) u_fifo (
      .clk(clk), .rst(rst),
      .wr_en(event_valid && !fifo_full),
      .wr_data(event_data),
      .full(fifo_full),
      .rd_en(!fifo_empty),
      .rd_data(fifo_rdata),
      .empty(fifo_empty),
      .count(fifo_count)
  );

  initial clk = 0;
  always #5 clk = ~clk;

  function automatic logic [15:0] crc16(input logic [7:0] bytes[21]);
    logic [15:0] c;
    int i, b;
    begin
      c = CRC16_INIT;
      for (i = 0; i < 21; i++) begin
        c = c ^ {bytes[i], 8'h00};
        for (b = 0; b < 8; b++)
          c = c[15] ? ({c[14:0], 1'b0} ^ CRC16_POLY) : {c[14:0], 1'b0};
      end
      return c;
    end
  endfunction

  task automatic build_frame(
      input  logic [7:0]  msg_type,
      input  logic [15:0] seq,
      input  logic [31:0] timestamp,
      input  logic [31:0] price,
      input  logic [31:0] qty,
      input  logic [15:0] instr,
      input  logic [7:0]  flags,
      input  logic        bad_crc,
      output logic [7:0]  b [0:22]
  );
    logic [7:0] hdr [21];
    logic [15:0] c;
    int i;
    begin
      b[0]  = SYNC0;
      b[1]  = SYNC1;
      b[2]  = 8'(PAYLOAD_LEN);
      b[3]  = msg_type;
      b[4]  = seq[15:8];
      b[5]  = seq[7:0];
      b[6]  = timestamp[31:24];
      b[7]  = timestamp[23:16];
      b[8]  = timestamp[15:8];
      b[9]  = timestamp[7:0];
      b[10] = price[31:24];
      b[11] = price[23:16];
      b[12] = price[15:8];
      b[13] = price[7:0];
      b[14] = qty[31:24];
      b[15] = qty[23:16];
      b[16] = qty[15:8];
      b[17] = qty[7:0];
      b[18] = instr[15:8];
      b[19] = instr[7:0];
      b[20] = flags;
      for (i = 0; i < 21; i++) hdr[i] = b[i];
      c = crc16(hdr);
      if (bad_crc) c = c ^ 16'hFFFF;
      b[21] = c[15:8];
      b[22] = c[7:0];
    end
  endtask

  task automatic send_byte(input logic [7:0] d);
    begin
      @(negedge clk);
      in_data  <= d;
      in_valid <= 1'b1;
      @(posedge clk);
      while (!in_ready) @(posedge clk);
      @(negedge clk);
      in_valid <= 1'b0;
    end
  endtask

  task automatic send_frame(input logic [7:0] b [0:22]);
    int i;
    begin
      for (i = 0; i < 23; i++) begin
        @(negedge clk);
        in_data  <= b[i];
        in_valid <= 1'b1;
        @(posedge clk);
        while (!in_ready) @(posedge clk);
      end
      @(negedge clk);
      in_valid <= 1'b0;
    end
  endtask

  // Continuous stream: hold valid across bytes without gaps
  task automatic stream_frame(input logic [7:0] b [0:22]);
    int i;
    begin
      for (i = 0; i < 23; i++) begin
        @(negedge clk);
        in_data  <= b[i];
        in_valid <= 1'b1;
        @(posedge clk);
        while (!in_ready) @(posedge clk);
      end
    end
  endtask

  localparam int MAX_SAMPLES = 16384;
  int latencies [0:MAX_SAMPLES-1];
  int n_samples;
  int sync_cycle;
  int cycle_count;
  bit awaiting;
  bit clear_stats;

  always_ff @(posedge clk) begin
    if (rst || clear_stats) begin
      cycle_count <= 0;
      awaiting    <= 0;
      n_samples   <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (sync_accept) begin
        sync_cycle <= cycle_count;
        awaiting   <= 1;
      end
      if (event_valid && !fifo_full && awaiting) begin
        if (n_samples < MAX_SAMPLES) begin
          latencies[n_samples] <= cycle_count - sync_cycle;
          n_samples <= n_samples + 1;
        end
        awaiting <= 0;
      end
    end
  end

  int got_ok, got_crc, got_gap, got_resync, errors;

  always_ff @(posedge clk) begin
    if (rst) begin
      got_ok <= 0; got_crc <= 0; got_gap <= 0; got_resync <= 0;
    end else if (!fifo_empty) begin
      unique case (fifo_rdata[127:120])
        EVT_OK:      got_ok <= got_ok + 1;
        EVT_CRC_ERR: got_crc <= got_crc + 1;
        EVT_GAP:     got_gap <= got_gap + 1;
        EVT_RESYNC:  got_resync <= got_resync + 1;
        default: ;
      endcase
    end
  end

  function automatic int percentile(input int pct);
    int tmp [0:MAX_SAMPLES-1];
    int i, j, key, idx;
    begin
      for (i = 0; i < n_samples; i++) tmp[i] = latencies[i];
      for (i = 1; i < n_samples; i++) begin
        key = tmp[i];
        j = i - 1;
        while (j >= 0 && tmp[j] > key) begin
          tmp[j+1] = tmp[j];
          j--;
        end
        tmp[j+1] = key;
      end
      idx = (n_samples * pct) / 100;
      if (idx >= n_samples) idx = n_samples - 1;
      if (idx < 0) idx = 0;
      return tmp[idx];
    end
  endfunction

  initial begin
    logic [7:0] fr [0:22];
    int k, p50, p99, N;
    real thruput;
    errors = 0;
    clear_stats = 0;

    in_valid = 0;
    in_data  = 0;
    rst = 1;
    repeat (5) @(posedge clk);
    rst = 0;
    @(posedge clk);

    // Test 1: single good frame
    build_frame(MSG_TYPE_TRADE, 16'h0001, 32'h10, 32'h64, 32'h5, 16'hA11, 8'h01, 1'b0, fr);
    $display("Frame0 CRC bytes: %02h %02h", fr[21], fr[22]);
    send_frame(fr);
    begin
      int guard;
      guard = 0;
      while ((got_ok + got_crc + got_gap + got_resync) < 1 && guard < 200) begin
        @(posedge clk);
        guard++;
      end
      $display("Test1 after %0d clks: ok=%0d crc=%0d gap=%0d resync=%0d state=%0d ev=%0b busy=%0b",
               guard, got_ok, got_crc, got_gap, got_resync, state_o, event_valid, busy);
    end
    if (got_ok < 1) begin $error("Test1: expected OK"); errors++; end
    else $display("PASS Test1 single good frame");

    // Test 2: bad CRC + garbage + good (resync)
    build_frame(MSG_TYPE_TRADE, 16'h0002, 32'h11, 32'h65, 32'h6, 16'hA11, 8'h01, 1'b1, fr);
    send_frame(fr);
    send_byte(8'h00);
    send_byte(8'hFF);
    build_frame(MSG_TYPE_QUOTE, 16'h0003, 32'h12, 32'h66, 32'h7, 16'hA12, 8'h02, 1'b0, fr);
    send_frame(fr);
    begin
      int guard;
      guard = 0;
      while (got_crc < 1 && guard < 200) begin @(posedge clk); guard++; end
    end
    if (got_crc < 1) begin $error("Test2: expected CRC_ERR"); errors++; end
    else $display("PASS Test2 bad CRC + resync (crc=%0d resync=%0d ok=%0d)", got_crc, got_resync, got_ok);

    // Test 3: gap
    build_frame(MSG_TYPE_TRADE, 16'h0004, 32'h13, 32'h67, 32'h8, 16'hA11, 8'h01, 1'b0, fr);
    send_frame(fr);
    build_frame(MSG_TYPE_TRADE, 16'h0007, 32'h14, 32'h68, 32'h9, 16'hA11, 8'h01, 1'b0, fr);
    send_frame(fr);
    begin
      int guard;
      guard = 0;
      while (got_gap < 1 && guard < 200) begin @(posedge clk); guard++; end
    end
    if (got_gap < 1) begin $error("Test3: expected GAP"); errors++; end
    else $display("PASS Test3 gap-detect (gap=%0d)", got_gap);

    // Test 4: continuous corpus
    clear_stats = 1;
    @(posedge clk);
    clear_stats = 0;
    @(posedge clk);
    N = 2048;
    $display("Streaming %0d contiguous 23B frames @ 100 MHz model...", N);
    for (k = 0; k < N; k++) begin
      build_frame(MSG_TYPE_TRADE, 16'(k + 100), 32'(k), 32'(1000+k),
                  32'(10+k), 16'hBEEF, 8'hAA, 1'b0, fr);
      stream_frame(fr);
    end
    in_valid = 1'b0;
    repeat (80) @(posedge clk);

    p50 = percentile(50);
    p99 = percentile(99);
    thruput = 100e6 / real'(p50);
    $display("BENCH: samples=%0d  p50=%0d cyc  p99=%0d cyc  thruput~%.2f Mmsg/s  latency_p50~%0d ns",
             n_samples, p50, p99, thruput/1e6, p50 * 10);

    if (p50 > 27) begin $error("p50=%0d exceeds <=27", p50); errors++; end
    if (p99 > 30) begin $error("p99=%0d exceeds <=30", p99); errors++; end
    if (n_samples < 1000) begin $error("too few samples %0d", n_samples); errors++; end

    if (errors == 0) $display("parser_tb: ALL PASS");
    else             $display("parser_tb: %0d FAILURES", errors);
    $finish;
  end

  initial begin
    #80_000_000;
    $error("TIMEOUT");
    $finish;
  end

endmodule
