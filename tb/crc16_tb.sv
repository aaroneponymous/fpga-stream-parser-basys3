// crc16_tb.sv - directed CRC16-CCITT vectors
`timescale 1ns/1ps

module crc16_tb;

  import protocol_pkg::*;

  logic        clk, rst, init, valid;
  logic [7:0]  data;
  logic [15:0] crc;

  crc16_ccitt dut (
      .clk(clk), .rst(rst), .init(init), .valid(valid), .data(data), .crc(crc)
  );

  initial clk = 0;
  always #5 clk = ~clk;

  function automatic logic [15:0] crc_step_ref(input logic [15:0] c, input logic [7:0] d);
    logic [15:0] x;
    int b;
    begin
      x = c ^ {d, 8'h00};
      for (b = 0; b < 8; b++)
        x = x[15] ? ({x[14:0], 1'b0} ^ CRC16_POLY) : {x[14:0], 1'b0};
      return x;
    end
  endfunction

  task automatic feed(input logic [7:0] bytes [], input int n);
    int i;
    begin
      @(negedge clk);
      init  <= 1'b1;
      valid <= 1'b0;
      @(posedge clk);
      @(negedge clk);
      init <= 1'b0;
      for (i = 0; i < n; i++) begin
        valid <= 1'b1;
        data  <= bytes[i];
        @(posedge clk);
        @(negedge clk);
      end
      valid <= 1'b0;
      @(posedge clk);
    end
  endtask

  int errors;

  initial begin
    logic [7:0] b9 [0:8];
    logic [7:0] b21 [0:20];
    logic [7:0] b1 [0:0];
    logic [15:0] exp;
    int i, bi;
    errors = 0;
    rst = 1; init = 0; valid = 0; data = 0;
    repeat (4) @(posedge clk);
    rst = 0;

    // empty
    begin
      logic [7:0] empty [0:0];
      feed(empty, 0);
      if (crc !== CRC16_INIT) begin
        $error("empty: got %04h", crc); errors++;
      end else $display("PASS empty → %04h", crc);
    end

    // 0x01
    b1[0] = 8'h01;
    exp = crc_step_ref(CRC16_INIT, 8'h01);
    feed(b1, 1);
    if (crc !== exp) begin
      $error("0x01: got %04h expect %04h", crc, exp); errors++;
    end else $display("PASS 0x01 → %04h", crc);

    // 123456789
    b9[0]="1"; b9[1]="2"; b9[2]="3"; b9[3]="4"; b9[4]="5";
    b9[5]="6"; b9[6]="7"; b9[7]="8"; b9[8]="9";
    exp = CRC16_INIT;
    for (i = 0; i < 9; i++) exp = crc_step_ref(exp, b9[i]);
    feed(b9, 9);
    if (crc !== exp) begin
      $error("123456789: got %04h expect %04h", crc, exp); errors++;
    end else $display("PASS 123456789 → %04h", crc);

    // 21-byte sequence
    for (i = 0; i < 21; i++) b21[i] = 8'(i);
    exp = CRC16_INIT;
    for (i = 0; i < 21; i++) exp = crc_step_ref(exp, b21[i]);
    feed(b21, 21);
    if (crc !== exp) begin
      $error("21B: got %04h expect %04h", crc, exp); errors++;
    end else $display("PASS 21B seq → %04h", crc);

    if (errors == 0) $display("crc16_tb: ALL PASS");
    else $display("crc16_tb: %0d FAILURES", errors);
    $finish;
  end

endmodule
