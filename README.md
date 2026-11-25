# FPGA Streaming Parser (Basys 3)

A streaming RTL parser for a fixed-field binary protocol (sync + length, CRC16-CCITT, resync, sequence-gap detection),
written in SystemVerilog for the Digilent Basys 3 (Artix-7 XC7A35T). Frames are replayed from BRAM at one byte per
clock at 100 MHz, and each frame is emitted as a packed 128-bit event through a FIFO.

## Results on the board

Measured on a Basys 3 at 100 MHz with the BRAM replay source (`results/hw_run1/BENCHMARK_REPORT.md`):

| | |
|---|---|
| Back-to-back 23-byte frames | 4.00 M msg/s (25 cycles per frame) |
| Original corpus (`mem/frames.mem`, includes padding and corrupt frames) | 3.62 M msg/s |
| Latency, SYNC0 byte accepted to event handshake | 24 cycles (240 ns), every message |
| Latency, SYNC0 byte accepted to event leaving the FIFO | 25 cycles (250 ns) |
| FIFO drained once every 32 cycles | 3.125 M msg/s, 0 messages dropped |

Post-route timing at 100 MHz: WNS +3.898 ns for `top_basys3`, and +0.348 ns for the instrumented `top_bench` (its
critical path is in the measurement logic; parser paths keep +2.588 ns).

How the measurements are taken and how to repeat them: [HW_BENCHMARK.md](HW_BENCHMARK.md).

## Layout

| Path | Contents |
|---|---|
| `rtl/` | Parser (`parser_core`, `crc16_ccitt`, `msg_table`, packages), `bram_replay`, `event_fifo`, `perf_counters`, `top_basys3` |
| `rtl/bench/` | Hardware benchmark: `bench_monitor`, `bench_system`, `top_bench` (VIO + ILA) |
| `tb/` | `parser_tb`, `crc16_tb`, `replay_tb`, `bench_tb` |
| `mem/` | Replay corpora: `frames.mem` and the back-to-back `frames_b2b.mem` |
| `scripts/` | Corpus generators, xsim runners, Vivado build, programming and report scripts |
| `parser.xpr`, `parser.srcs/` | Vivado project and the Basys 3 constraints |
| `results/` | Benchmark simulation log and hardware runs |
| `docs/` | Protocol, FSM and circuit diagrams |

## Quick start

```bash
export PATH=~/tools/amd/2025.2/2025.2/Vivado/bin:$PATH

# Generate the corpora
python3 scripts/gen_frames.py -n 160 -o mem/frames.mem
python3 scripts/gen_b2b.py -o mem/frames_b2b.mem

# Parser functional + performance bench, and the unit / replay benches (xsim)
./scripts/run_xsim_parser.sh
./scripts/run_xsim_unit.sh

# Vivado project: add sources, implement top_basys3 and check timing
vivado -mode batch -source scripts/setup_project.tcl
vivado -mode batch -source scripts/impl_timing.tcl
```

## Board controls (`top_basys3`)

| Control | Function |
|---------|----------|
| `btnC`  | Reset |
| `sw[0]` | Start BRAM replay (level; rising edge arms) |
| `sw[1]` | Loop corpus continuously |
| `sw[2]` | 7-seg shows messages per second / 1024, in hex (decimal point on) |
| `sw[3]` | 7-seg shows the last latency in cycles, in hex (`0017` = 23) |
| default | 7-seg shows total messages / 1024, in hex; freezes when `sw[0]` is off |
| LEDs    | busy, sync, event, FIFO, errors, state |

At about 4 M msg/s a raw 16-bit count wraps every ~15 ms, so the display shows scaled values. The display latency
counts from the registered `sync_accept` pulse, one cycle after the SYNC0 byte is accepted.

## Docs

- [docs/protocol.md](docs/protocol.md): frame format, CRC and status codes
- [docs/fsm.md](docs/fsm.md): parser state machine
- [docs/circuits.md](docs/circuits.md): module hierarchy and datapath diagrams
