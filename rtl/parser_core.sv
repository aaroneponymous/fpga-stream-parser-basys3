// parser_core.sv - streaming table-driven fixed-field parser
// 1 B/cycle: hunt → sync1 → hdr → payload → crc → emit
// CRC updates live every accepted header/payload byte; gap-detect on SEQ
module parser_core (
    input  logic         clk,
    input  logic         rst,
    input  logic         in_valid,
    input  logic [7:0]   in_data,
    output logic         in_ready,
    output logic         event_valid,
    output logic [127:0] event_data,
    input  logic         event_ready,
    output logic [7:0]   last_flags,
    output logic [2:0]   state_o,
    output logic         sync_accept,
    output logic         busy
);

  import protocol_pkg::*;
  import parser_pkg::*;

  parser_state_e state;

  logic [7:0]  msg_type_r, flags_r, len_target, pay_cnt;
  logic [15:0] seq_r, instr_r, crc_rx, last_seq;
  logic [31:0] ts_r, price_r, qty_r;
  logic        have_seq, gap_flag, saw_resync, crc_byte_idx;
  logic        crc_init, crc_valid;
  logic [15:0] crc_val;
  msg_desc_t   desc;

  wire take = in_valid && in_ready;
  wire crc_match = (crc_val == crc_rx);

  // Stall byte pipe only while waiting for FIFO to accept the event
  assign in_ready     = (state != ST_EMIT);
  assign busy         = (state != ST_HUNT);
  assign state_o      = state;
  assign last_flags   = flags_r;

  msg_table u_table (
      .msg_type(msg_type_r),
      .desc(desc)
  );

  crc16_ccitt u_crc (
      .clk  (clk),
      .rst  (rst),
      .init (crc_init),
      .valid(crc_valid),
      .data (in_data),
      .crc  (crc_val)
  );

  // CRC controls (combinational)
  always_comb begin
    crc_init  = 1'b0;
    crc_valid = 1'b0;
    if (take) begin
      unique case (state)
        ST_HUNT: begin
          if (in_data == SYNC0) begin
            crc_init  = 1'b1;
            crc_valid = 1'b1;
          end
        end
        ST_SYNC1: begin
          if (in_data == SYNC1) begin
            crc_valid = 1'b1;
          end else if (in_data == SYNC0) begin
            crc_init  = 1'b1;
            crc_valid = 1'b1;
          end
        end
        ST_HDR, ST_PAYLOAD: crc_valid = 1'b1;
        ST_RESYNC: begin
          if (in_data == SYNC0) begin
            crc_init  = 1'b1;
            crc_valid = 1'b1;
          end
        end
        default: ;
      endcase
    end
  end

  // Status for current EMIT
  logic [7:0] emit_status;
  always_comb begin
    if (!crc_match)       emit_status = EVT_CRC_ERR;
    else if (gap_flag)    emit_status = EVT_GAP;
    else if (saw_resync)  emit_status = EVT_RESYNC;
    else                  emit_status = EVT_OK;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state        <= ST_HUNT;
      msg_type_r   <= '0;
      flags_r      <= '0;
      len_target   <= 8'(PAYLOAD_LEN);
      pay_cnt      <= '0;
      seq_r        <= '0;
      instr_r      <= '0;
      crc_rx       <= '0;
      last_seq     <= '0;
      ts_r         <= '0;
      price_r      <= '0;
      qty_r        <= '0;
      have_seq     <= 1'b0;
      gap_flag     <= 1'b0;
      saw_resync   <= 1'b0;
      crc_byte_idx <= 1'b0;
      event_valid  <= 1'b0;
      event_data   <= '0;
      sync_accept  <= 1'b0;
    end else begin
      sync_accept <= 1'b0;

      // Hold event_valid until accepted (need 1-cycle present before ready can retire)
      if (state == ST_EMIT) begin
        event_data <= pack_event(emit_status, msg_type_r, seq_r, ts_r,
                                  price_r, qty_r, instr_r);
        if (!event_valid) begin
          // First cycle in EMIT: present the event
          event_valid <= 1'b1;
        end else if (event_ready) begin
          // Handshake complete
          event_valid <= 1'b0;
          if (crc_match) begin
            last_seq <= seq_r;
            have_seq <= 1'b1;
          end
          saw_resync <= 1'b0;
          if (!crc_match)
            state <= ST_RESYNC;
          else
            state <= ST_HUNT;
        end
      end else if (take) begin
        unique case (state)
          ST_HUNT: begin
            if (in_data == SYNC0) begin
              sync_accept  <= 1'b1;
              pay_cnt      <= '0;
              crc_byte_idx <= 1'b0;
              gap_flag     <= 1'b0;
              seq_r        <= '0;
              ts_r         <= '0;
              price_r      <= '0;
              qty_r        <= '0;
              instr_r      <= '0;
              flags_r      <= '0;
              state        <= ST_SYNC1;
            end
          end

          ST_SYNC1: begin
            if (in_data == SYNC1) begin
              state <= ST_HDR;
            end else if (in_data == SYNC0) begin
              sync_accept  <= 1'b1;
              pay_cnt      <= '0;
              crc_byte_idx <= 1'b0;
              gap_flag     <= 1'b0;
              state        <= ST_SYNC1;
            end else begin
              state <= ST_HUNT;
            end
          end

          ST_HDR: begin
            // LEN byte
            len_target <= in_data;
            pay_cnt    <= '0;
            if (in_data == 8'd0)
              state <= ST_CRC;
            else
              state <= ST_PAYLOAD;
          end

          ST_PAYLOAD: begin
            unique case (pay_cnt)
              8'd0:  msg_type_r      <= in_data;
              8'd1:  seq_r[15:8]     <= in_data;
              8'd2:  seq_r[7:0]      <= in_data;
              8'd3:  ts_r[31:24]     <= in_data;
              8'd4:  ts_r[23:16]     <= in_data;
              8'd5:  ts_r[15:8]      <= in_data;
              8'd6:  ts_r[7:0]       <= in_data;
              8'd7:  price_r[31:24]  <= in_data;
              8'd8:  price_r[23:16]  <= in_data;
              8'd9:  price_r[15:8]   <= in_data;
              8'd10: price_r[7:0]    <= in_data;
              8'd11: qty_r[31:24]    <= in_data;
              8'd12: qty_r[23:16]    <= in_data;
              8'd13: qty_r[15:8]     <= in_data;
              8'd14: qty_r[7:0]      <= in_data;
              8'd15: instr_r[15:8]   <= in_data;
              8'd16: instr_r[7:0]    <= in_data;
              8'd17: flags_r         <= in_data;
              default: ;
            endcase

            // Gap-detect when SEQ low byte arrives
            if (pay_cnt == 8'd2) begin
              if (have_seq && ({seq_r[15:8], in_data} != (last_seq + 16'd1)))
                gap_flag <= 1'b1;
              else
                gap_flag <= 1'b0;
            end

            if (pay_cnt + 8'd1 == len_target) begin
              crc_byte_idx <= 1'b0;
              state        <= ST_CRC;
            end
            pay_cnt <= pay_cnt + 8'd1;
          end

          ST_CRC: begin
            if (!crc_byte_idx) begin
              crc_rx[15:8] <= in_data;
              crc_byte_idx <= 1'b1;
            end else begin
              crc_rx[7:0] <= in_data;
              state       <= ST_EMIT;
            end
          end

          ST_RESYNC: begin
            if (in_data == SYNC0) begin
              sync_accept  <= 1'b1;
              saw_resync   <= 1'b1;
              pay_cnt      <= '0;
              crc_byte_idx <= 1'b0;
              gap_flag     <= 1'b0;
              seq_r        <= '0;
              ts_r         <= '0;
              price_r      <= '0;
              qty_r        <= '0;
              instr_r      <= '0;
              flags_r      <= '0;
              state        <= ST_SYNC1;
            end
          end

          default: state <= ST_HUNT;
        endcase
      end
    end
  end

endmodule
