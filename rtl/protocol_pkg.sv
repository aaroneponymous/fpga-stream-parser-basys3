// protocol_pkg.sv - FAST-inspired fixed-field wire format + 128-bit event packing
package protocol_pkg;

  // Sync / frame constants (big-endian wire order)
  localparam logic [7:0] SYNC0       = 8'hFA;
  localparam logic [7:0] SYNC1       = 8'h53;  // 'S'
  localparam int         FRAME_BYTES = 23;
  localparam int         PAYLOAD_LEN = 18;      // LEN for 23B total (bytes after LEN)
  localparam int         HDR_BYTES   = 3;       // SYNC0, SYNC1, LEN
  localparam int         CRC_BYTES   = 2;
  localparam int         CRC_COVER   = 21;      // bytes [0..20] covered by CRC

  // Byte offsets
  localparam int OFF_SYNC0     = 0;
  localparam int OFF_SYNC1     = 1;
  localparam int OFF_LEN       = 2;
  localparam int OFF_MSG_TYPE  = 3;
  localparam int OFF_SEQ       = 4;   // u16
  localparam int OFF_TIMESTAMP = 6;   // u32
  localparam int OFF_PRICE     = 10;  // i32
  localparam int OFF_QTY       = 14;  // u32
  localparam int OFF_INSTR_ID  = 18;  // u16
  localparam int OFF_FLAGS     = 20;  // u8
  localparam int OFF_CRC       = 21;  // u16

  // CRC16-CCITT (poly 0x1021, init 0xFFFF, no final XOR)
  localparam logic [15:0] CRC16_POLY = 16'h1021;
  localparam logic [15:0] CRC16_INIT = 16'hFFFF;

  // Event status codes → event[127:120]
  typedef enum logic [7:0] {
    EVT_OK      = 8'h00,
    EVT_CRC_ERR = 8'h01,
    EVT_GAP     = 8'h02,
    EVT_RESYNC  = 8'h03
  } event_status_e;

  // 128-bit packed event:
  //   [127:120] status
  //   [119:112] msg_type
  //   [111:96]  seq
  //   [95:64]   timestamp
  //   [63:32]   price
  //   [31:16]   qty[31:16]
  //   [15:0]    instr_id
  // flags are available on parser last_flags output (8 bits do not fit cleanly
  // with full qty+instr; qty low 16 omitted in the packed word per plan note).
  function automatic logic [127:0] pack_event(
      input logic [7:0]  status,
      input logic [7:0]  msg_type,
      input logic [15:0] seq,
      input logic [31:0] timestamp,
      input logic [31:0] price,
      input logic [31:0] qty,
      input logic [15:0] instr_id
  );
    pack_event = {status, msg_type, seq, timestamp, price, qty[31:16], instr_id};
  endfunction

  function automatic logic [7:0]  evt_status   (input logic [127:0] e); return e[127:120]; endfunction
  function automatic logic [7:0]  evt_msg_type (input logic [127:0] e); return e[119:112]; endfunction
  function automatic logic [15:0] evt_seq      (input logic [127:0] e); return e[111:96];  endfunction
  function automatic logic [31:0] evt_timestamp(input logic [127:0] e); return e[95:64];   endfunction
  function automatic logic [31:0] evt_price    (input logic [127:0] e); return e[63:32];   endfunction
  function automatic logic [15:0] evt_qty_hi   (input logic [127:0] e); return e[31:16];   endfunction
  function automatic logic [15:0] evt_instr_id (input logic [127:0] e); return e[15:0];    endfunction

endpackage
