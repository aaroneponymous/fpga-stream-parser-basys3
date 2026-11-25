// perf_counters.sv - message / error / latency stats for bench + board display
module perf_counters (
    input  logic        clk,
    input  logic        rst,
    input  logic        sync_accept,   // latency start
    input  logic        event_valid,
    input  logic        event_ready,
    input  logic [7:0]  event_status,  // from event_data[127:120]
    output logic [31:0] msg_count,
    output logic [31:0] crc_err_count,
    output logic [31:0] gap_count,
    output logic [31:0] cycle_sum,     // sum of latencies for avg
    output logic [15:0] last_latency,
    output logic [15:0] max_latency
);

  import protocol_pkg::*;

  logic        pending;
  logic [15:0] timer;
  wire         evt_fire = event_valid && event_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      msg_count     <= '0;
      crc_err_count <= '0;
      gap_count     <= '0;
      cycle_sum     <= '0;
      last_latency  <= '0;
      max_latency   <= '0;
      pending       <= 1'b0;
      timer         <= '0;
    end else begin
      if (sync_accept) begin
        pending <= 1'b1;
        timer   <= 16'd1;  // count this cycle as 1
      end else if (pending) begin
        timer <= timer + 16'd1;
      end

      if (evt_fire) begin
        msg_count <= msg_count + 32'd1;
        pending   <= 1'b0;
        last_latency <= pending ? timer : last_latency;
        cycle_sum    <= pending ? (cycle_sum + {16'd0, timer}) : cycle_sum;
        if (pending && timer > max_latency)
          max_latency <= timer;

        unique case (event_status)
          EVT_CRC_ERR: crc_err_count <= crc_err_count + 32'd1;
          EVT_GAP:     gap_count     <= gap_count + 32'd1;
          default: ;
        endcase
      end
    end
  end

endmodule
