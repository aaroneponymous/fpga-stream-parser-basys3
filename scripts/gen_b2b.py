#!/usr/bin/env python3
"""Generate the back-to-back benchmark corpus (corpus B).

178 valid 23-byte frames with consecutive sequence numbers and no garbage or
padding: 178 x 23 = 4094 bytes, which is the replay depth used for corpus B
(bram_replay MEM_DEPTH=4094), so the looping stream never contains idle bytes.
When the replay wraps, the sequence restarts at 1, so the first frame of every
loop after the first is reported as GAP. That is expected and counted.

Frames are built with gen_frames.build_frame, the same encoder as corpus A.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_frames import build_frame  # noqa: E402

N_FRAMES = 178
DEPTH = N_FRAMES * 23  # 4094


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", type=Path, default=Path("mem/frames_b2b.mem"))
    args = ap.parse_args()

    blob = bytearray()
    for i in range(N_FRAMES):
        blob += build_frame(
            msg_type=1 if (i % 2 == 0) else 2,
            seq=1 + i,
            timestamp=2_000_000 + i,
            price=20000 + i,
            qty=200 + (i % 50),
            instr_id=0xB10 + (i % 7),
            flags=0x01,
        )
    assert len(blob) == DEPTH
    args.o.parent.mkdir(parents=True, exist_ok=True)
    with args.o.open("w") as f:
        for b in blob:
            f.write(f"{b:02X}\n")
    print(f"Wrote {args.o} ({len(blob)} bytes, {N_FRAMES} frames, depth {DEPTH})")


if __name__ == "__main__":
    main()
