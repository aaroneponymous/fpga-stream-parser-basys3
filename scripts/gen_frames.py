#!/usr/bin/env python3
"""Generate FAST-inspired 23B frames with CRC16-CCITT for BRAM replay / TB."""
from __future__ import annotations
import struct
import argparse
from pathlib import Path

SYNC0, SYNC1 = 0xFA, 0x53
POLY, INIT = 0x1021, 0xFFFF


def crc16_ccitt(data: bytes) -> int:
    c = INIT
    for byte in data:
        c ^= byte << 8
        for _ in range(8):
            if c & 0x8000:
                c = ((c << 1) & 0xFFFF) ^ POLY
            else:
                c = (c << 1) & 0xFFFF
    return c


def build_frame(
    msg_type: int,
    seq: int,
    timestamp: int,
    price: int,
    qty: int,
    instr_id: int,
    flags: int,
    corrupt_crc: bool = False,
) -> bytes:
    # LEN = 18 (bytes after LEN field)
    body = bytearray()
    body.append(SYNC0)
    body.append(SYNC1)
    body.append(18)  # LEN
    body.append(msg_type & 0xFF)
    body += struct.pack(">H", seq & 0xFFFF)
    body += struct.pack(">I", timestamp & 0xFFFFFFFF)
    body += struct.pack(">i", price)
    body += struct.pack(">I", qty & 0xFFFFFFFF)
    body += struct.pack(">H", instr_id & 0xFFFF)
    body.append(flags & 0xFF)
    assert len(body) == 21
    crc = crc16_ccitt(bytes(body))
    if corrupt_crc:
        crc ^= 0xFFFF
    body.append((crc >> 8) & 0xFF)
    body.append(crc & 0xFF)
    assert len(body) == 23
    return bytes(body)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=256, help="number of good frames")
    ap.add_argument("-o", type=Path, default=Path("mem/frames.mem"))
    ap.add_argument("--gaps", type=int, default=2, help="insert N sequence gaps")
    ap.add_argument("--bad-crc", type=int, default=2, help="insert N bad-CRC frames")
    ap.add_argument("--garbage", type=int, default=8, help="garbage bytes before stream")
    args = ap.parse_args()

    frames: list[bytes] = []
    # Leading garbage for resync demo
    garbage = bytes([(i * 17 + 3) & 0xFF for i in range(args.garbage)])
    # Avoid accidental sync in garbage
    garbage = bytes(b if b not in (SYNC0, SYNC1) else 0x00 for b in garbage)

    seq = 1
    blob = bytearray(garbage)

    bad_crc_at = set(range(10, 10 + args.bad_crc))
    gap_at = set(range(20, 20 + args.gaps))

    for i in range(args.n):
        use_seq = seq
        if i in gap_at:
            use_seq = seq + 5  # jump
            seq = use_seq
        corrupt = i in bad_crc_at
        fr = build_frame(
            msg_type=1 if (i % 2 == 0) else 2,
            seq=use_seq,
            timestamp=1_000_000 + i,
            price=10000 + i,
            qty=100 + (i % 50),
            instr_id=0xA10 + (i % 7),
            flags=0x01,
            corrupt_crc=corrupt,
        )
        blob += fr
        frames.append(fr)
        seq += 1

    args.o.parent.mkdir(parents=True, exist_ok=True)
    # Hex mem: one byte per line for $readmemh
    with args.o.open("w") as f:
        for b in blob:
            f.write(f"{b:02X}\n")
        # Pad to 4096 with zeros
        for _ in range(4096 - len(blob)):
            f.write("00\n")

    # Also write a binary + meta
    bin_path = args.o.with_suffix(".bin")
    bin_path.write_bytes(blob)
    print(f"Wrote {args.o} ({len(blob)} payload bytes, {args.n} frames)")
    print(f"First frame CRC check: {crc16_ccitt(frames[0][:21]):04X} vs wire {frames[0][21]<<8|frames[0][22]:04X}")


if __name__ == "__main__":
    main()
