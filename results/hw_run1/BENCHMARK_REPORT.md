# FPGA Streaming Parser - Hardware Benchmark Report

Run directory: `results/hw_run1`  
Host time of run: 2026-11-12T12:47:49-0500  
Generated from the raw files by `scripts/make_report.py`.

Labels: **[HW]** read from the physical board; **[SIM]** xsim; **[STA]** post-route static timing; **[DER]** arithmetic on labelled values.

## 1. Build and device

| Item | Value |
|---|---|
| Source commit at build time | `98652aae71b6ce7d43035543427e1e900c12a920` (clean tree: True) |
| Vivado | 2025.2 |
| Part | xc7a35tcpg236-1 |
| Top | `top_bench` |
| Build ID (in bitstream generic and monitor register 0x00) | `6AF5FA19` |
| Bitstream SHA-256 | `91115ee316b75737f271fe6f1d9130da1f94c7e4408507f6949f3d67d798c684` |
| Probes (.ltx) SHA-256 | `4a55a369c0514eed765a4f043fcd6f5e06f70fd1c9462bd9f0586c9abc09dea7` |
| Clock constraint | `sys_clk_pin`, period 10.0 ns (100 MHz), from `parser.srcs/constrs_1/imports/ddca/Basys-3-Master.xdc` |
| [STA] Post-route | WNS 0.348 ns, TNS 0.0 ns, WHS 0.032 ns, THS 0.0 ns; all constraints met: True |
| [HW] JTAG target | `localhost:3121/xilinx_tcf/Digilent/210183BF796BA` at 15 MHz |
| [HW] Device | xc7a35t, IDCODE `0362D093` |
| [HW] Bitstream header part | `7a35tcpg236` |
| [HW] DONE pin after programming | 1 |
| [HW] Monitor ID register read back | `B0E100016AF5FA19` (matches build ID: True) |

## 2. Test input

- **Corpus A** (`mem/frames.mem`, original): 4096 bytes = 8 garbage bytes + 160 x 23-byte frames (2 with bad CRC, 2 sequence jumps) + 408 zero pad bytes, replayed at 1 byte/cycle, looping.
- **Corpus B** (`mem/frames_b2b.mem`, `scripts/gen_b2b.py`): 178 valid 23-byte frames back to back, 4094 bytes, no padding. Sequence restarts each loop, so one GAP event per loop is expected.
- `mem/frames.mem` SHA-256 `ded8f82ac91c26fa84dfc504e6d28b33a2b57f5503e15e7135a3d2858d2766e8`
- `mem/frames_b2b.mem` SHA-256 `11919300bfdfbf964349387bb759949711d7f818fce37e3d539c08ae23cf1fb2`
- **Drain throttle**: `drain_div=0` is the original always-drain FIFO; `drain_div=31` reads the FIFO at most once every 32 cycles to force backpressure.

## 3. Clock check [HW]

Free-running cycle counter read twice over JTAG, 10.008 s apart by host clock: 1,000,790,461 cycles.  
[DER] Estimated clock = 100.0009 MHz. JTAG round-trip timing limits this to roughly +/-0.1%; it confirms the board runs at ~100 MHz, not the exact oscillator ppm.

## 4. Results per test

Latency definitions (all in clock cycles of the 100 MHz design clock):
- **lat1**: SYNC0 byte accepted by the parser -> parser event handshake (`event_valid && event_ready`).
- **lat2**: SYNC0 byte accepted -> the event leaves the 32-entry event FIFO.
- Messages are matched through timestamp queues, so each event is paired with its own frame even when several are in flight (only possible in the FIFO, under backpressure).
- The original `perf_counters` measures from the registered `sync_accept` pulse, one cycle after the SYNC0 handshake, so it reports lat1 - 1.

| Test | Window cycles | Events [HW] | Msg/s at 100 MHz [DER] | Cycles/msg (steady) [DER] | lat1 min/avg/max (p50, p99) [HW] | lat2 min/avg/max (p50, p99) [HW] | OK/CRC/GAP/RESYNC [HW] | Dropped [DER] | Queue errors [HW] |
|---|---|---|---|---|---|---|---|---|---|
| A_10s_t1 | 1,000,000,000 | 36,231,889 | 3.6232 M | 27.600 | 24/24.000/24 (24, 24) | 25/25.000/25 (25, 25) | 34873195/452898/905796/0 | 0 parser, 0 FIFO | 0 |
| A_1s_t1 | 100,000,000 | 3,623,187 | 3.6232 M | 27.600 | 24/24.000/24 (24, 24) | 25/25.000/25 (25, 25) | 3487317/45290/90580/0 | 0 parser, 0 FIFO | 0 |
| A_1s_t2 | 100,000,000 | 3,623,192 | 3.6232 M | 27.600 | 24/24.000/24 (24, 24) | 25/25.000/25 (25, 25) | 3487322/45290/90580/0 | 0 parser, 0 FIFO | 0 |
| A_1s_t3 | 100,000,000 | 3,623,188 | 3.6232 M | 27.600 | 24/24.000/24 (24, 24) | 25/25.000/25 (25, 25) | 3487318/45290/90580/0 | 0 parser, 0 FIFO | 0 |
| A_1s_t4 | 100,000,000 | 3,623,187 | 3.6232 M | 27.600 | 24/24.000/24 (24, 24) | 25/25.000/25 (25, 25) | 3487317/45290/90580/0 | 0 parser, 0 FIFO | 0 |
| A_1s_t5 | 100,000,000 | 3,623,187 | 3.6232 M | 27.600 | 24/24.000/24 (24, 24) | 25/25.000/25 (25, 25) | 3487317/45290/90580/0 | 0 parser, 0 FIFO | 0 |
| A_cold | 1,000,000 | 36,239 | 3.6239 M | 27.594 | 24/24.000/24 (24, 24) | 25/25.000/25 (25, 25) | 34878/454/907/0 | 0 parser, 0 FIFO | 0 |
| A_drain31_1s_t1 | 100,000,000 | 3,125,000 | 3.1250 M | 32.000 | 24/28.400/31 (31, 31) | 638/975.438/1054 (>= 63, >= 63) | 3007814/39062/78124/0 | 0 parser, 0 FIFO | 0 |
| A_drain31_1s_t2 | 100,000,000 | 3,124,988 | 3.1250 M | 32.000 | 24/28.400/31 (31, 31) | 638/975.439/1054 (>= 63, >= 63) | 3007801/39062/78125/0 | 0 parser, 0 FIFO | 0 |
| A_drain31_1s_t3 | 100,000,000 | 3,124,991 | 3.1250 M | 32.000 | 24/28.400/31 (31, 31) | 638/975.439/1054 (>= 63, >= 63) | 3007801/39064/78126/0 | 0 parser, 0 FIFO | 0 |
| A_drain31_cold | 1,000,000 | 31,281 | 3.1281 M | 31.968 | 24/28.374/31 (31, 31) | 45/973.231/1054 (>= 63, >= 63) | 30106/392/783/0 | 0 parser, 0 FIFO | 0 |
| B_1s_t1 | 100,000,000 | 4,000,000 | 4.0000 M | 25.000 | 24/24.000/24 (24, 24) | 25/25.000/25 (25, 25) | 3977528/0/22472/0 | 0 parser, 0 FIFO | 0 |
| B_1s_t2 | 100,000,000 | 4,000,000 | 4.0000 M | 25.000 | 24/24.000/24 (24, 24) | 25/25.000/25 (25, 25) | 3977528/0/22472/0 | 0 parser, 0 FIFO | 0 |
| B_1s_t3 | 100,000,000 | 4,000,000 | 4.0000 M | 25.000 | 24/24.000/24 (24, 24) | 25/25.000/25 (25, 25) | 3977528/0/22472/0 | 0 parser, 0 FIFO | 0 |
| B_1s_t4 | 100,000,000 | 4,000,000 | 4.0000 M | 25.000 | 24/24.000/24 (24, 24) | 25/25.000/25 (25, 25) | 3977528/0/22472/0 | 0 parser, 0 FIFO | 0 |
| B_1s_t5 | 100,000,000 | 4,000,000 | 4.0000 M | 25.000 | 24/24.000/24 (24, 24) | 25/25.000/25 (25, 25) | 3977528/0/22472/0 | 0 parser, 0 FIFO | 0 |
| B_cold | 1,000,000 | 39,999 | 3.9999 M | 25.000 | 24/24.000/24 (24, 24) | 25/25.000/25 (25, 25) | 39775/0/224/0 | 0 parser, 0 FIFO | 0 |

Formulas: Msg/s = events x 100e6 / window cycles. Cycles/msg (steady) = (cycle of last event - cycle of first event) / (events - 1). Dropped (parser) = committed frames + in-flight at start - events - in-flight at end. Dropped (FIFO) = events + queued at start - FIFO reads - queued at end.

### Backpressure and stalls [HW]

| Test | Bytes accepted | Replay stalled by parser (cycles) | Source idle (cycles) | Parser output blocked (cycles) | FIFO full (cycles) | Max FIFO occupancy | Original perf_counters last_latency (live) |
|---|---|---|---|---|---|---|---|
| A_10s_t1 | 927,536,222 | 72,463,778 | 0 | 0 | 0 | 1 | 23 |
| A_1s_t1 | 92,753,626 | 7,246,374 | 0 | 0 | 0 | 1 | 23 |
| A_1s_t2 | 92,753,616 | 7,246,384 | 0 | 0 | 0 | 1 | 23 |
| A_1s_t3 | 92,753,624 | 7,246,376 | 0 | 0 | 0 | 1 | 23 |
| A_1s_t4 | 92,753,626 | 7,246,374 | 0 | 0 | 0 | 1 | 23 |
| A_1s_t5 | 92,753,626 | 7,246,374 | 0 | 0 | 0 | 1 | 23 |
| A_cold | 927,521 | 72,478 | 1 | 0 | 0 | 1 | 23 |
| A_drain31_1s_t1 | 79,999,896 | 20,000,104 | 0 | 13,750,104 | 62,519,971 | 32 | 30 |
| A_drain31_1s_t2 | 80,000,039 | 19,999,961 | 0 | 13,749,985 | 62,519,456 | 32 | 30 |
| A_drain31_1s_t3 | 80,000,110 | 19,999,890 | 0 | 13,749,908 | 62,519,126 | 32 | 30 |
| A_drain31_cold | 800,599 | 199,400 | 1 | 136,838 | 622,299 | 32 | 23 |
| B_1s_t1 | 92,000,000 | 8,000,000 | 0 | 0 | 0 | 1 | 23 |
| B_1s_t2 | 92,000,000 | 8,000,000 | 0 | 0 | 0 | 1 | 23 |
| B_1s_t3 | 92,000,000 | 8,000,000 | 0 | 0 | 0 | 1 | 23 |
| B_1s_t4 | 92,000,000 | 8,000,000 | 0 | 0 | 0 | 1 | 23 |
| B_1s_t5 | 92,000,000 | 8,000,000 | 0 | 0 | 0 | 1 | 23 |
| B_cold | 920,000 | 79,999 | 1 | 0 | 0 | 1 | 23 |

### Latency histograms [HW]

- **A_10s_t1** lat1 {24: 36,231,889}; lat2 {25: 36,231,888}
- **A_1s_t1** lat1 {24: 3,623,187}; lat2 {25: 3,623,187}
- **A_1s_t2** lat1 {24: 3,623,192}; lat2 {25: 3,623,192}
- **A_1s_t3** lat1 {24: 3,623,188}; lat2 {25: 3,623,188}
- **A_1s_t4** lat1 {24: 3,623,187}; lat2 {25: 3,623,187}
- **A_1s_t5** lat1 {24: 3,623,187}; lat2 {25: 3,623,187}
- **A_cold** lat1 {24: 36,239}; lat2 {25: 36,238}
- **A_drain31_1s_t1** lat1 {24: 1,152,329, 28: 19,531, 31: 1,953,140}; lat2 {>=63: 3,125,000}
- **A_drain31_1s_t2** lat1 {24: 1,152,334, 28: 19,531, 31: 1,953,123}; lat2 {>=63: 3,125,000}
- **A_drain31_1s_t3** lat1 {24: 1,152,348, 28: 19,531, 31: 1,953,112}; lat2 {>=63: 3,125,000}
- **A_drain31_cold** lat1 {24: 11,649, 28: 195, 30: 1, 31: 19,436}; lat2 {45: 1, 52: 1, 59: 1, >=63: 31,246}
- **B_1s_t1** lat1 {24: 4,000,000}; lat2 {25: 4,000,000}
- **B_1s_t2** lat1 {24: 4,000,000}; lat2 {25: 4,000,000}
- **B_1s_t3** lat1 {24: 4,000,000}; lat2 {25: 4,000,000}
- **B_1s_t4** lat1 {24: 4,000,000}; lat2 {25: 4,000,000}
- **B_1s_t5** lat1 {24: 4,000,000}; lat2 {25: 4,000,000}
- **B_cold** lat1 {24: 39,999}; lat2 {25: 39,999}

## 5. Hardware vs simulation (deterministic 1,000,000-cycle cold windows)

Both start from reset with the replay start and the window arm in the same clock cycle, so the board and the simulation should produce identical counters and histograms.

- **A_cold**: all 28 counters and both histograms identical between [HW] and [SIM].
- **B_cold**: all 28 counters and both histograms identical between [HW] and [SIM].

## 6. ILA captures [HW]

2048 consecutive cycles per capture; per-message latencies recomputed from the raw samples by this script, independently of the monitor.

| Capture | Contiguous | Events | lat1 (min/avg/max) | lat2 (min/avg/max) | Event interval cycles (min/avg/max) | FIFO-full samples |
|---|---|---|---|---|---|---|
| ila_A | True | 82 | 24/24.000/24 | 25/25.000/25 | 25/25.000/25 | 0 |
| ila_A_drain31 | True | 69 | 24/28.588/31 | not computable: FIFO backlog predates the capture | 25/29.588/32 | 1458 |
| ila_B | True | 82 | 24/24.000/24 | 25/25.000/25 | 25/25.000/25 | 0 |

## 7. Verdict on the previously reported figures

- **100 MHz clock**: constrained at 10.000 ns and met post-route [STA]; board clock measured at 100.001 MHz [HW/DER].
- **3.6-3.8 M msg/s**: [HW] corpus A (original replay data) sustained 3.6232-3.6232 M msg/s over 5 x 1 s windows (inside the 3.6-3.8 range); corpus B (back-to-back frames, parser-limited) 4.0000-4.0000 M msg/s. [DER] corpus A cycles per message = 27.600; corpus B = 25.000.
- **260-280 ns latency**: [HW] lat1 values observed [24] cycles = [240.0] ns; lat2 values [25] cycles = [250.0] ns, without backpressure. No observed latency falls in 260-280 ns, so the figure is not supported by the hardware. [HW] the original perf_counters last_latency register read [23] cycles (it starts one cycle after the SYNC0 handshake).
- **Conditions**: these figures hold for this design fed from on-chip BRAM at 1 byte per cycle with the event FIFO drained every cycle. The corpus A rate depends on its padding and garbage bytes (it is not a property of the parser alone); the parser's own limit is corpus B's rate. No network or external I/O is involved.

## 8. Raw evidence

All files under `raw/`: `session.json` (device and identity checks), `clock_check.json`, one JSON per test window with every monitor register as read over JTAG, and `ila_*.csv` / `ila_*.ila` captures (the .ila files open in the Vivado hardware manager). `vivado_hw.log` is the full Tcl session log.
