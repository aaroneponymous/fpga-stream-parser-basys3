// bram_replay.sv - stream corpus bytes from BRAM at 1 B/cycle
module bram_replay #(
    parameter int MEM_DEPTH = 4096,
    parameter int AW        = $clog2(MEM_DEPTH),
    parameter     INIT_FILE = ""
) (
    input  logic          clk,
    input  logic          rst,
    input  logic          start,
    input  logic          loop_en,
    input  logic          out_ready,
    output logic          out_valid,
    output logic [7:0]    out_data,
    output logic          done,
    output logic [AW-1:0] addr_o
);

  logic [7:0]    mem [0:MEM_DEPTH-1];
  logic [AW-1:0] addr;
  logic          running;
  logic          start_d;

  initial begin
    integer i;
    for (i = 0; i < MEM_DEPTH; i++) mem[i] = 8'h00;
    if (INIT_FILE != "")
      $readmemh(INIT_FILE, mem);
  end

  assign addr_o = addr;

  wire fire = running && (!out_valid || out_ready);

  always_ff @(posedge clk) begin
    if (rst) begin
      addr      <= '0;
      running   <= 1'b0;
      out_valid <= 1'b0;
      out_data  <= '0;
      done      <= 1'b0;
      start_d   <= 1'b0;
    end else begin
      start_d <= start;
      done    <= 1'b0;

      // Rising edge of start arms replay
      if (start && !start_d) begin
        running   <= 1'b1;
        addr      <= '0;
        out_valid <= 1'b0;
      end else if (!start) begin
        running   <= 1'b0;
        out_valid <= 1'b0;
        addr      <= '0;
      end else if (fire) begin
        out_data  <= mem[addr];
        out_valid <= 1'b1;
        if (addr == AW'(MEM_DEPTH - 1)) begin
          if (loop_en) begin
            addr <= '0;
          end else begin
            running <= 1'b0;
            done    <= 1'b1;
            // last beat remains until taken; clear valid after accept
          end
        end else begin
          addr <= addr + 1'b1;
        end
      end else if (!running && out_valid && out_ready) begin
        out_valid <= 1'b0;
      end
    end
  end

endmodule
