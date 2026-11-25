# FAST-inspired Fixed-Field Protocol

Streaming parser target for Basys 3 / Artix-7. This is **not** full OpenFAST
(no presence maps or stop-bit varints). It is a fixed-field wire format with
sync+len, CRC16, resync, and sequence gap-detect.

## Frame format (23 bytes, big-endian)

| Offset | Size | Field        | Notes                                      |
|-------:|-----:|--------------|--------------------------------------------|
| 0      | 1    | SYNC0        | `0xFA`                                     |
| 1      | 1    | SYNC1        | `0x53` (`'S'`)                             |
| 2      | 1    | LEN          | Payload bytes after LEN; `18` for 23B frame|
| 3      | 1    | MSG_TYPE     | Table key (`0x01` trade, `0x02` quote, …)  |
| 4      | 2    | SEQ          | u16 sequence (gap-detect)                  |
| 6      | 4    | TIMESTAMP    | u32                                        |
| 10     | 4    | PRICE        | i32                                        |
| 14     | 4    | QTY          | u32                                        |
| 18     | 2    | INSTR_ID     | u16                                        |
| 20     | 1    | FLAGS        | u8                                         |
| 21     | 2    | CRC16-CCITT  | Poly `0x1021`, init `0xFFFF`, bytes `[0..20]` |

Total = 23 bytes. Variable `LEN` is accepted for resync robustness; the
performance corpus uses fixed 23B frames (`LEN=18`).

## CRC16-CCITT

- Polynomial: `0x1021`
- Initial value: `0xFFFF`
- No reflected bits, no final XOR
- Covers bytes `[0]` through `[20]` (everything except the CRC itself)
- Wire order: CRC high byte at offset 21, low byte at 22

## 128-bit packed event

Emitted via FIFO on each completed parse attempt:

| Bits     | Field                         |
|---------:|-------------------------------|
| 127:120  | status (`OK`/`CRC_ERR`/`GAP`/`RESYNC`) |
| 119:112  | msg_type                      |
| 111:96   | seq                           |
| 95:64    | timestamp                     |
| 63:32    | price                         |
| 31:16    | qty[31:16]                    |
| 15:0     | instr_id                      |

`flags` and qty low 16 bits are retained in parser sideband registers for
debug/LEDs.

### Status codes

| Code | Name     | Meaning                          |
|-----:|----------|----------------------------------|
| 0x00 | OK       | CRC match, sequence contiguous   |
| 0x01 | CRC_ERR  | CRC mismatch                     |
| 0x02 | GAP      | `SEQ != last_seq + 1` (CRC OK)   |
| 0x03 | RESYNC   | Recovered after hunt/bad sync    |

## Design targets (set before measurement; BRAM replay @ 100 MHz, 1 B/cycle)

- 23B frames, continuous stream
- ~26 cycles/msg p50 / ~28 p99
- ~3.6–3.8M msg/s
- ~260–280 ns latency (sync accept → `event_valid`)

Measured on the board: 25 cycles per back-to-back frame (4.00 M msg/s), 3.62 M msg/s on `mem/frames.mem`, and
24 cycles (240 ns) from SYNC0 accepted to the event handshake. See [HW_BENCHMARK.md](../HW_BENCHMARK.md).
