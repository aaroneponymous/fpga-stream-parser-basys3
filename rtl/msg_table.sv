// msg_table.sv - ROM: MSG_TYPE → field layout / expected LEN
module msg_table (
    input  logic [7:0]           msg_type,
    output parser_pkg::msg_desc_t desc
);

  import parser_pkg::*;
  import protocol_pkg::*;

  always_comb begin
    desc = '0;
    unique case (msg_type)
      MSG_TYPE_TRADE: begin
        desc.valid        = 1'b1;
        desc.expect_len   = 8'(PAYLOAD_LEN);
        desc.field_enable = FE_ALL;
      end
      MSG_TYPE_QUOTE: begin
        desc.valid        = 1'b1;
        desc.expect_len   = 8'(PAYLOAD_LEN);
        desc.field_enable = FE_ALL;
      end
      MSG_TYPE_HB: begin
        desc.valid        = 1'b1;
        desc.expect_len   = 8'(PAYLOAD_LEN);
        desc.field_enable = FE_SEQ | FE_TS | FE_FLAGS;
      end
      default: begin
        desc.valid        = 1'b0;
        desc.expect_len   = 8'(PAYLOAD_LEN);
        desc.field_enable = FE_ALL;
      end
    endcase
  end

endmodule
