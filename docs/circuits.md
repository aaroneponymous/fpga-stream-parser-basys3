# Circuit Diagrams - FPGA Streaming Parser Accelerator

Basys 3 / Artix-7 · `top_basys3` · 100 MHz · 1 byte/cycle

## Hierarchy

```
top_basys3
├── bram_replay          # corpus → byte stream
├── parser_core          # streaming FSM
│   ├── crc16_ccitt      # live CRC16-CCITT
│   └── msg_table        # MSG_TYPE → layout ROM
├── event_fifo           # 128-bit × 32 events
└── perf_counters        # msg/crc/gap + latency
    (+ display mux → LED / 7-seg)
```

---

## 1. Top-level (`top_basys3`)

```mermaid
flowchart LR
  subgraph BoardIO [Basys3_IO]
    CLK[clk_100MHz]
    BTN[btnC_rst]
    SW[sw_15_0]
    LED[led_15_0]
    SEG[seg_an_dp]
  end

  subgraph Top [top_basys3]
    REPLAY[bram_replay]
    PARSER[parser_core]
    FIFO[event_fifo_128x32]
    PERF[perf_counters]
    DISP[Display_mux]
  end

  CLK --> REPLAY
  CLK --> PARSER
  CLK --> FIFO
  CLK --> PERF
  BTN --> REPLAY
  BTN --> PARSER
  BTN --> FIFO
  BTN --> PERF
  SW -->|sw0_start_sw1_loop| REPLAY
  SW -->|sw2_sw3_mode| DISP

  REPLAY -->|"byte valid/ready"| PARSER
  PARSER -->|"event 128b valid/ready"| FIFO
  PARSER -->|sync_accept_event| PERF
  FIFO -->|rd_data_status| DISP
  PERF -->|counts_latency_rate| DISP
  DISP --> LED
  DISP --> SEG
```

### Top-level data path (simplified)

```mermaid
flowchart LR
  MEM["frames.mem BRAM"] --> BR["bram_replay"]
  BR -->|"1 B/cyc"| PC["parser_core"]
  PC --> CRC["crc16_ccitt"]
  PC --> TBL["msg_table"]
  PC -->|"128-bit event"| EF["event_fifo"]
  PC --> PF["perf_counters"]
  EF --> UI["LEDs / 7-seg"]
  PF --> UI
```

---

## 2. Module-wise - `parser_core`

```mermaid
flowchart TB
  subgraph Ingress
    IV[in_valid]
    ID[in_data_7_0]
    IR[in_ready]
  end

  subgraph Core [parser_core]
    TAKE["take = valid AND ready"]
    FSM["FSM HUNT/SYNC1/HDR/PAYLOAD/CRC/EMIT/RESYNC"]
    FREGS["Field registers\nmsg_type seq ts price qty instr flags"]
    GAP["Gap detect\nSEQ vs last_seq+1"]
    PACK["pack_event → 128b"]
    CRCCTL["crc_init / crc_valid"]
  end

  subgraph Children
    CRC["crc16_ccitt"]
    TABLE["msg_table"]
  end

  subgraph Egress
    EV[event_valid]
    ED[event_data_127_0]
    ER[event_ready]
    SA[sync_accept]
  end

  IV --> TAKE
  ID --> TAKE
  ID --> FREGS
  ID --> CRCCTL
  TAKE --> FSM
  FSM --> FREGS
  FSM --> CRCCTL
  FSM --> GAP
  FREGS --> TABLE
  TABLE -->|desc| FSM
  CRCCTL --> CRC
  ID --> CRC
  CRC -->|crc_val| PACK
  FREGS --> PACK
  GAP --> PACK
  PACK --> ED
  FSM --> EV
  ER --> FSM
  FSM --> SA
  FSM --> IR
```

### FSM state diagram

```mermaid
stateDiagram-v2
  [*] --> HUNT
  HUNT --> SYNC1: SYNC0=0xFA
  SYNC1 --> HDR: SYNC1=0x53
  SYNC1 --> HUNT: mismatch
  SYNC1 --> SYNC1: overlapping SYNC0
  HDR --> PAYLOAD: capture LEN
  HDR --> CRC: LEN=0
  PAYLOAD --> PAYLOAD: shift fields
  PAYLOAD --> CRC: pay_cnt == LEN
  CRC --> CRC: CRC_HI
  CRC --> EMIT: CRC_LO
  EMIT --> HUNT: ready and CRC OK
  EMIT --> RESYNC: ready and CRC_ERR
  RESYNC --> SYNC1: SYNC0
```

---

## 3. Component-wise

### `crc16_ccitt`

```mermaid
flowchart LR
  DATA[data_7_0] --> STEP
  INIT[init] --> MUX
  CRCR[crc_r_15_0] --> MUX
  MUX["select INIT 0xFFFF or crc_r"] --> STEP
  VALID[valid] --> EN[enable]
  STEP["crc_step\n8× shift/xor poly 0x1021"] --> NEXT[crc_next]
  NEXT --> EN
  EN --> CRCR
  CRCR --> OUT[crc]
```

### `msg_table`

```mermaid
flowchart LR
  MT[msg_type_7_0] --> CASE{case}
  CASE -->|0x01 Trade| ALL[valid LEN=18 FE_ALL]
  CASE -->|0x02 Quote| ALL
  CASE -->|0x03 HB| HB[valid FE_SEQ|TS|FLAGS]
  CASE -->|default| UNK[valid=0 FE_ALL]
  ALL --> DESC[desc]
  HB --> DESC
  UNK --> DESC
```

### `event_fifo` (DEPTH=32)

```mermaid
flowchart LR
  WR[wr_en wr_data] --> CTRL{wr/rd}
  RD[rd_en] --> CTRL
  CTRL --> MEM["mem 128b × DEPTH"]
  CTRL --> PTRS[wr_ptr rd_ptr cnt]
  PTRS --> FL[full empty count]
  MEM --> RDATA[rd_data]
```

### `bram_replay`

```mermaid
flowchart LR
  START[start ↑] --> RUN[running]
  LOOP[loop_en] --> WRAP{addr wrap}
  RUN --> ADDR[addr]
  ADDR --> BRAM["mem 8b × 4096\nframes.mem"]
  BRAM --> OUT[out_data]
  RUN --> HS[out_valid]
  READY[out_ready] --> HS
  HS -->|fire| ADDR
  WRAP -->|!loop| DONE[done]
```

### `perf_counters`

```mermaid
flowchart LR
  SYNC[sync_accept] --> TMR[latency timer]
  TMR --> LAST[last_latency max]
  EVT[event_valid AND ready] --> CNT[msg_count++]
  EVT --> ST{status}
  ST -->|CRC_ERR| CE[crc_err_count++]
  ST -->|GAP| GP[gap_count++]
  TMR --> SUM[cycle_sum]
  EVT --> SUM
```

---

## 4. 128-bit event word

```mermaid
block-beta
  columns 7
  A["status\n8"] B["msg_type\n8"] C["seq\n16"] D["timestamp\n32"] E["price\n32"] F["qty_hi\n16"] G["instr_id\n16"]

  style A fill:#333,stroke:#888,color:#fff
  style B fill:#333,stroke:#888,color:#fff
  style C fill:#333,stroke:#888,color:#fff
  style D fill:#333,stroke:#888,color:#fff
  style E fill:#333,stroke:#888,color:#fff
  style F fill:#333,stroke:#888,color:#fff
  style G fill:#333,stroke:#888,color:#fff
```

| Bits | Field |
|------|--------|
| 127:120 | status |
| 119:112 | msg_type |
| 111:96 | seq |
| 95:64 | timestamp |
| 63:32 | price |
| 31:16 | qty[31:16] |
| 15:0 | instr_id |

---

## 5. Port summary

| Module | Key inputs | Key outputs |
|--------|------------|-------------|
| `bram_replay` | start, loop_en, out_ready | out_valid, out_data[7:0], done |
| `parser_core` | in_valid, in_data, event_ready | in_ready, event_valid, event_data, sync_accept |
| `crc16_ccitt` | init, valid, data | crc[15:0] |
| `msg_table` | msg_type | desc |
| `event_fifo` | wr_en, wr_data, rd_en | full, empty, rd_data, count |
| `perf_counters` | sync_accept, event_*, status | msg_count, crc_err, gap, latency |

Source RTL: [`rtl/`](../rtl/). Protocol: [`protocol.md`](protocol.md).
