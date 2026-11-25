# Hardware benchmark

Measures throughput and latency of the parser on the Basys 3 itself. The parser, CRC, FIFO, replay and
`perf_counters` modules are the same ones used by `top_basys3`; the benchmark only adds a passive monitor, debug
cores and host scripts.

## Design

| File | Purpose |
|---|---|
| `rtl/bench/bench_monitor.sv` | Passive monitor. Counts over an exact cycle window and matches each event to its own frame start with timestamp queues. Measures lat1 (SYNC0 accepted -> parser event handshake) and lat2 (SYNC0 accepted -> event leaves the FIFO): min/avg/max, 64-bin histograms, stalls, backpressure, and drop checks by conservation. |
| `rtl/bench/bench_system.sv` | The `top_basys3` replay -> parser -> FIFO -> perf_counters wiring plus the monitor. Adds an optional back-to-back corpus and an optional FIFO drain throttle; both are off at their default values. |
| `rtl/bench/top_bench.sv` | Board top. Same pins, switches, LEDs and 7-seg as `top_basys3`, plus a VIO (host control and register readout) and an ILA (raw capture). |
| `tb/bench_tb.sv` | Checks cycle-for-cycle equivalence with `top_basys3`, checks the monitor against an independent scoreboard, and prints reference registers. |
| `scripts/gen_b2b.py` | Generates corpus B (178 back-to-back frames, 4094 bytes). |
| `scripts/build_bench.tcl` | Non-project build. Fails if timing is not met. Writes `build/impl/build_info.json` (commit, build ID, timing, SHA-256 of the bitstream and probes). |
| `scripts/hw_bench.tcl` | Verifies the bitstream and device, programs the board, checks DONE and the monitor build ID, runs all tests, and writes raw results. |
| `scripts/make_report.py` | Derives every figure from the raw files and writes `BENCHMARK_REPORT.md` and `summary.json`. |

## Reproduce

Requirements: Vivado 2025.2 at `~/tools/amd/2025.2/2025.2/Vivado/bin` (or set `VIVADO_BIN`), and the Basys 3
connected over its USB-JTAG port and powered on.

```sh
# 1. Simulation (about 10 s). Must print "bench_tb: ALL PASS".
./scripts/run_bench_sim.sh

# 2. Build (a few minutes). Must print "BUILD OK".
mkdir -p build && (cd build && vivado -mode batch -nojournal -log build_vivado.log -source ../scripts/build_bench.tcl)

# 3. Program the board, run every test and write the report (about 2 minutes).
./scripts/run_hw_bench.sh my_run
#    -> results/my_run/BENCHMARK_REPORT.md, summary.json, raw/, vivado_hw.log
```

`run_hw_bench.sh` stops with `HWBENCH FAIL: ...` if any of these checks fails:
- the bitstream SHA-256 doesn't match `build_info.json`, or the build came from a dirty tree;
- the bitstream header part isn't the build part;
- there isn't exactly one JTAG target and one device;
- the device isn't an `xc7a35t` with IDCODE `x362D093`;
- DONE isn't 1 after programming;
- the VIO and ILA cores aren't both found;
- the monitor's build-ID register doesn't match the bitstream that was built.

Programming loads volatile configuration memory only; the SPI flash is not written.

## Tests

| Test | Corpus | FIFO drain | Window | Purpose |
|---|---|---|---|---|
| clock_check | - | - | about 10 s host time | Free-running cycle counter against host time. |
| A_cold, B_cold | A, B | every cycle | 1,000,000 cycles from reset | Deterministic; must match simulation register for register. |
| A_drain31_cold | A | 1 in 32 cycles | 1,000,000 cycles | Backpressure from reset. |
| A_1s x5, B_1s x5 | A, B | every cycle | 100,000,000 cycles (1 s) | Sustained throughput and latency. |
| A_drain31_1s x3 | A | 1 in 32 cycles | 1 s | Sustained backpressure; checks for drops. |
| A_10s | A | every cycle | 1,000,000,000 cycles (10 s) | Long run. |
| ila_A, ila_B, ila_A_drain31 | A, B, A | as above | 2048 samples | Raw per-cycle captures. |

Corpus A is `mem/frames.mem` (8 garbage bytes, 160 frames including 2 bad-CRC frames and 2 sequence jumps, 408 pad
bytes). Corpus B is `mem/frames_b2b.mem` (178 valid frames back to back; the sequence restarts each loop, so one GAP
per loop is expected).

## Results

Run `results/hw_run1` (bitstream SHA-256 `91115ee3...`, build ID `6AF5FA19`):

- Corpus A: 3.62 M msg/s (27.6 cycles per message, from its padding and garbage bytes).
- Corpus B: exactly 4,000,000 messages per 1 s window, 25 cycles per frame.
- lat1 24 cycles and lat2 25 cycles for every message without backpressure.
- With the FIFO drained once every 32 cycles: 3.125 M msg/s, 0 dropped, 0 matching errors.
- Both deterministic cold windows identical to simulation for every counter and histogram bin.
- Clock measured at 100.001 MHz against host time (about +/-0.1%).

The `git_commit` recorded in that run's `build_info.json` refers to the history the build was made from, which
predates this repository. The bitstream itself is in `results/hw_run1/build/` and is identified by its SHA-256.

## Manual inspection in the Vivado GUI

1. Hardware Manager, Open Target -> Auto Connect, program the device with `build/impl/top_bench.bit` and
   `build/impl/top_bench.ltx`.
2. In the VIO window (hex values), set `ctrl = 06` (start + loop) and `window_len = 05F5E100` (100,000,000 cycles),
   then `ctrl = 0E` to arm a window.
3. Set `sel` to a register address and read `rdata` (`rsel` echoes the address). Register map in
   `bench_monitor.sv`, for example `07` events, `12`/`13` lat1 min/max, `14`/`15` lat1 sum/count.
4. The ILA window shows the same handshakes; trigger on `dbg_ev_fire == 1`.
5. With every VIO output at 0, the switches and 7-seg behave as in `top_basys3`.
