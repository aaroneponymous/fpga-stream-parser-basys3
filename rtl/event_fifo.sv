// event_fifo.sv - synchronous 128-bit event FIFO (distributed RAM)
module event_fifo #(
    parameter int DEPTH = 32,
    parameter int AW    = $clog2(DEPTH)
) (
    input  logic         clk,
    input  logic         rst,
    // write
    input  logic         wr_en,
    input  logic [127:0] wr_data,
    output logic         full,
    // read
    input  logic         rd_en,
    output logic [127:0] rd_data,
    output logic         empty,
    output logic [AW:0]  count
);

  logic [127:0] mem [0:DEPTH-1];
  logic [AW-1:0] wr_ptr, rd_ptr;
  logic [AW:0]   cnt;

  assign full  = (cnt == DEPTH[AW:0]);
  assign empty = (cnt == '0);
  assign count = cnt;
  assign rd_data = mem[rd_ptr];

  always_ff @(posedge clk) begin
    if (rst) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      cnt    <= '0;
    end else begin
      case ({wr_en && !full, rd_en && !empty})
        2'b10: begin
          mem[wr_ptr] <= wr_data;
          wr_ptr      <= wr_ptr + 1'b1;
          cnt         <= cnt + 1'b1;
        end
        2'b01: begin
          rd_ptr <= rd_ptr + 1'b1;
          cnt    <= cnt - 1'b1;
        end
        2'b11: begin
          mem[wr_ptr] <= wr_data;
          wr_ptr      <= wr_ptr + 1'b1;
          rd_ptr      <= rd_ptr + 1'b1;
          // cnt unchanged
        end
        default: ;
      endcase
    end
  end

endmodule
