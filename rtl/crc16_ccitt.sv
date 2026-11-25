// crc16_ccitt.sv - incremental CRC16-CCITT, 1 byte/cycle
// Poly 0x1021, init 0xFFFF, no reflect, no final XOR
module crc16_ccitt (
    input  logic        clk,
    input  logic        rst,
    input  logic        init,       // load init value (same cycle as first data ok if !valid)
    input  logic        valid,      // consume data this cycle
    input  logic [7:0]  data,
    output logic [15:0] crc
);

  import protocol_pkg::*;

  logic [15:0] crc_r, crc_next;

  // Combinational next-state for one byte
  function automatic logic [15:0] crc_step(input logic [15:0] c, input logic [7:0] d);
    logic [15:0] x;
    int i;
    begin
      x = c ^ {d, 8'h00};
      for (i = 0; i < 8; i++) begin
        if (x[15])
          x = {x[14:0], 1'b0} ^ CRC16_POLY;
        else
          x = {x[14:0], 1'b0};
      end
      return x;
    end
  endfunction

  assign crc_next = crc_step(crc_r, data);
  assign crc      = crc_r;

  always_ff @(posedge clk) begin
    if (rst)
      crc_r <= CRC16_INIT;
    else if (init && valid)
      crc_r <= crc_step(CRC16_INIT, data);
    else if (init)
      crc_r <= CRC16_INIT;
    else if (valid)
      crc_r <= crc_next;
  end

endmodule
