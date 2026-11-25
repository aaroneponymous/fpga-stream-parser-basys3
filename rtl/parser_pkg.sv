// parser_pkg.sv - FSM states and table-entry types for the streaming parser
package parser_pkg;

  import protocol_pkg::*;

  typedef enum logic [2:0] {
    ST_HUNT    = 3'd0,
    ST_SYNC1   = 3'd1,
    ST_HDR     = 3'd2,
    ST_PAYLOAD = 3'd3,
    ST_CRC     = 3'd4,
    ST_EMIT    = 3'd5,
    ST_RESYNC  = 3'd6
  } parser_state_e;

  // Table-driven field layout descriptor (per MSG_TYPE)
  typedef struct packed {
    logic        valid;         // known message type
    logic [7:0]  expect_len;    // expected LEN field (payload bytes after LEN)
    logic [7:0]  field_enable;  // bit0=seq,1=ts,2=price,3=qty,4=instr,5=flags
  } msg_desc_t;

  localparam logic [7:0] MSG_TYPE_TRADE = 8'h01;
  localparam logic [7:0] MSG_TYPE_QUOTE = 8'h02;
  localparam logic [7:0] MSG_TYPE_HB    = 8'h03;  // heartbeat / minimal

  localparam logic [7:0] FE_SEQ   = 8'b0000_0001;
  localparam logic [7:0] FE_TS    = 8'b0000_0010;
  localparam logic [7:0] FE_PRICE = 8'b0000_0100;
  localparam logic [7:0] FE_QTY   = 8'b0000_1000;
  localparam logic [7:0] FE_INSTR = 8'b0001_0000;
  localparam logic [7:0] FE_FLAGS = 8'b0010_0000;
  localparam logic [7:0] FE_ALL   = 8'b0011_1111;

endpackage
