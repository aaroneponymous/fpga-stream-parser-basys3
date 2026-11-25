#!/usr/bin/env python3
"""Build BENCHMARK_REPORT.md and summary.json from a hardware run directory.

Usage: scripts/make_report.py results/<run> [--build build/impl] [--sim results/sim/bench_tb.log]

Every number in the report is labelled by where it comes from:
  [HW]   read from the physical board (monitor registers or ILA capture)
  [SIM]  from the xsim run of bench_tb
  [STA]  from the post-route static timing report
  [DER]  arithmetic on the above (the formula is shown)
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import statistics
from pathlib import Path

NOMINAL_HZ = 100e6
CYCLE_NS = 10.0

REG = {
    "id": 0x00, "uptime": 0x01, "win": 0x02, "wlen": 0x03, "bytes": 0x04, "cand": 0x05,
    "commit": 0x06, "events": 0x07, "ok": 0x08, "crc": 0x09, "gap": 0x0A, "resync": 0x0B,
    "fifo_rd": 0x0C, "in_stall": 0x0D, "src_idle": 0x0E, "out_bp": 0x0F, "fifo_full": 0x10,
    "fifo_max": 0x11, "l1_min": 0x12, "l1_max": 0x13, "l1_sum": 0x14, "l1_n": 0x15,
    "l2_min": 0x16, "l2_max": 0x17, "l2_sum": 0x18, "l2_n": 0x19, "occ": 0x1A, "qerr": 0x1B,
    "first_ev": 0x1C, "last_ev": 0x1D, "orig": 0x1E, "cfg": 0x1F,
}
# registers that must match simulation exactly for a deterministic cold window
COMPARE = [k for k in REG if k not in ("id", "uptime", "orig")]


def regs_of(raw: dict) -> dict[int, int]:
    return {int(k, 16): int(v, 16) for k, v in raw.items()}


def decode(r: dict[int, int]) -> dict:
    d = {k: r.get(a, 0) for k, a in REG.items()}
    occ, qe = d["occ"], d["qerr"]
    d["q1_start"], d["q1_end"] = (occ >> 24) & 0xFF, (occ >> 16) & 0xFF
    d["q2_start"], d["q2_end"] = (occ >> 8) & 0xFF, occ & 0xFF
    d["q1_ovf"], d["q1_unf"] = (qe >> 48) & 0xFFFF, (qe >> 32) & 0xFFFF
    d["q2_ovf"], d["q2_unf"] = (qe >> 16) & 0xFFFF, qe & 0xFFFF
    d["orig_msg_count"], d["orig_last_latency"] = d["orig"] & 0xFFFFFFFF, (d["orig"] >> 32) & 0xFFFF
    d["hist1"] = {b: r.get(0x40 + b, 0) for b in range(64) if r.get(0x40 + b, 0)}
    d["hist2"] = {b: r.get(0x80 + b, 0) for b in range(64) if r.get(0x80 + b, 0)}
    return d


def pct(hist: dict[int, int], p: float) -> str:
    n = sum(hist.values())
    if not n:
        return "-"
    need, acc = p * n, 0
    for b in sorted(hist):
        acc += hist[b]
        if acc >= need:
            return f">= {b}" if b == 63 else str(b)
    return "-"


def metrics(d: dict) -> dict:
    w, ev = d["win"], d["events"]
    m = {
        "window_cycles": w,
        "events": ev,
        "msgs_per_s_at_100MHz": ev * NOMINAL_HZ / w if w else 0,
        "cycles_per_msg_window": w / ev if ev else None,
        "steady_cycles_per_msg": (d["last_ev"] - d["first_ev"]) / (ev - 1) if ev > 1 else None,
        "lat1": {"min": d["l1_min"], "avg": d["l1_sum"] / d["l1_n"] if d["l1_n"] else None,
                 "max": d["l1_max"], "n": d["l1_n"], "p50": pct(d["hist1"], .5), "p99": pct(d["hist1"], .99)},
        "lat2": {"min": d["l2_min"], "avg": d["l2_sum"] / d["l2_n"] if d["l2_n"] else None,
                 "max": d["l2_max"], "n": d["l2_n"], "p50": pct(d["hist2"], .5), "p99": pct(d["hist2"], .99)},
        "dropped_parser": d["commit"] + d["q1_start"] - d["events"] - d["q1_end"],
        "dropped_fifo": d["events"] + d["q2_start"] - d["fifo_rd"] - d["q2_end"],
        "queue_errors": d["q1_ovf"] + d["q1_unf"] + d["q2_ovf"] + d["q2_unf"],
    }
    return m


def parse_sim(path: Path) -> dict[str, dict[int, int]]:
    out: dict[str, dict[int, int]] = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        mm = re.match(r"REG (\S+) ([0-9a-f]{2}) ([0-9a-f]{16})", line)
        if mm:
            out.setdefault(mm[1], {})[int(mm[2], 16)] = int(mm[3], 16)
    return out


def parse_timing(path: Path) -> dict:
    t = path.read_text()
    mm = re.search(r"WNS\(ns\)\s+TNS\(ns\).*?\n\s*-+.*?\n\s*(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s+(-?[\d.]+)\s+(-?[\d.]+)", t, re.S)
    res = {"all_met": "All user specified timing constraints are met." in t}
    if mm:
        res.update(wns=float(mm[1]), tns=float(mm[2]), whs=float(mm[5]), ths=float(mm[6]))
    return res


def ila_analyse(path: Path) -> dict:
    rows = list(csv.reader(path.open()))
    head, radix = rows[0], rows[1]
    data = rows[2:]

    def col(prefix):
        for i, h in enumerate(head):
            if h.split("[")[0] == prefix:
                return i
        raise KeyError(prefix)

    def val(row, i):
        s = row[i].strip()
        r = radix[i].upper()
        if "HEX" in r:
            return int(s, 16)
        if "BIN" in r:
            return int(s, 2)
        return int(s)

    ci = {n: col(n) for n in ("dbg_take", "dbg_byte", "parser_state", "dbg_ev_fire", "dbg_ev_status",
                             "dbg_ev_seq", "dbg_fifo_rd", "stamp", "dbg_byte_valid", "fifo_full")}
    samples = [{n: val(r, i) for n, i in ci.items()} for r in data]
    stamps = [s["stamp"] for s in samples]
    contiguous = all((b - a) & 0xFFFFFFFF == 1 for a, b in zip(stamps, stamps[1:]))

    cand = None
    q1: list[int] = []
    q2: list[int] = []
    lat1, lat2, gaps, seqs = [], [], [], []
    last_ev = None
    for s in samples:
        t = s["stamp"]
        st = s["parser_state"]
        if s["dbg_take"] and s["dbg_byte"] == 0xFA and st in (0, 1, 6):
            cand = t
        if s["dbg_take"] and st == 1 and s["dbg_byte"] == 0x53 and cand is not None:
            q1.append(cand)
        if s["dbg_ev_fire"]:
            seqs.append((s["dbg_ev_seq"], s["dbg_ev_status"]))
            if last_ev is not None:
                gaps.append(t - last_ev)
            last_ev = t
            if q1:
                ts = q1.pop(0)
                lat1.append(t - ts)
                q2.append(ts)
            else:
                q2.append(None)
        if s["dbg_fifo_rd"] and q2:
            ts = q2.pop(0)
            if ts is not None:
                lat2.append(t - ts)

    def summ(xs):
        if not xs:
            return None
        xs = sorted(xs)
        return {"n": len(xs), "min": xs[0], "max": xs[-1], "avg": sum(xs) / len(xs), "values": sorted(set(xs))[:20]}

    # FIFO reads can only be paired with frame starts seen in this capture if the
    # FIFO held no events from before the capture (no backpressure in the window).
    backlog = any(sm["fifo_full"] for sm in samples)
    return {"samples": len(samples), "contiguous": contiguous, "first_stamp": stamps[0] if stamps else None,
            "events": len(seqs), "lat1": summ(lat1), "lat2": None if backlog else summ(lat2),
            "lat2_note": "not computable: FIFO backlog predates the capture" if backlog else "", "interval": summ(gaps),
            "first_events": seqs[:12],
            "fifo_full_samples": sum(s["fifo_full"] for s in samples)}


def fmt(x, nd=4):
    if x is None:
        return "-"
    if isinstance(x, float):
        return f"{x:,.{nd}f}"
    return f"{x:,}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--build", default="build/impl")
    ap.add_argument("--sim", default="results/sim/bench_tb.log")
    a = ap.parse_args()
    run, build, raw = Path(a.run), Path(a.build), Path(a.run) / "raw"

    info = json.loads((build / "build_info.json").read_text())
    session = json.loads((raw / "session.json").read_text())
    timing = parse_timing(build / "timing_summary_routed.rpt")
    sim = parse_sim(Path(a.sim))
    tests = {}
    for p in sorted(raw.glob("*.json")):
        if p.name in ("session.json", "clock_check.json"):
            continue
        j = json.loads(p.read_text())
        d = decode(regs_of(j["regs"]))
        tests[j["test"]] = {"config": j["config"], "decoded": d, "metrics": metrics(d),
                            "host_window_s": (j.get("host_done_seen_us", 0) - j.get("host_arm_us", 0)) / 1e6}

    cc = json.loads((raw / "clock_check.json").read_text())
    d_cyc = int(cc["uptime1_hex"], 16) - int(cc["uptime0_hex"], 16)
    d_s = (cc["host1_us"] - cc["host0_us"]) / 1e6
    f_est = d_cyc / d_s

    ila = {p.stem: ila_analyse(p) for p in sorted(raw.glob("ila_*.csv"))}

    # deterministic comparisons against simulation
    comps = {}
    for hw_name, sim_name in (("A_cold", "A_cold"), ("B_cold", "B_cold")):
        if hw_name in tests and sim_name in sim:
            hw_r = regs_of(json.loads((raw / f"{hw_name}.json").read_text())["regs"])
            sm = sim[sim_name]
            diffs = []
            for k in COMPARE:
                adr = REG[k]
                if adr == 0x1F:
                    continue
                if hw_r.get(adr, 0) != sm.get(adr, 0):
                    diffs.append((k, hw_r.get(adr, 0), sm.get(adr, 0)))
            for b in range(0x40, 0xC0):
                if hw_r.get(b, 0) != sm.get(b, 0):
                    diffs.append((f"hist{1 if b < 0x80 else 2}[{b & 63}]", hw_r.get(b, 0), sm.get(b, 0)))
            comps[hw_name] = diffs

    L = []
    w = L.append
    w("# FPGA Streaming Parser - Hardware Benchmark Report\n")
    w(f"Run directory: `{run}`  ")
    w(f"Host time of run: {session['host_time']}  ")
    w("Generated from the raw files by `scripts/make_report.py`.\n")
    w("Labels: **[HW]** read from the physical board; **[SIM]** xsim; **[STA]** post-route static timing; "
      "**[DER]** arithmetic on labelled values.\n")

    w("## 1. Build and device\n")
    w("| Item | Value |\n|---|---|")
    w(f"| Source commit at build time | `{info['git_commit']}` (clean tree: {not info['git_dirty']}) |")
    w(f"| Vivado | {info['vivado']} |")
    w(f"| Part | {info['part']} |")
    w(f"| Top | `{info['top']}` |")
    w(f"| Build ID (in bitstream generic and monitor register 0x00) | `{info['build_id']}` |")
    w(f"| Bitstream SHA-256 | `{info['bitstream_sha256']}` |")
    w(f"| Probes (.ltx) SHA-256 | `{info['probes_sha256']}` |")
    w(f"| Clock constraint | `{info['clock']['name']}`, period {info['clock']['period_ns']} ns (100 MHz), from `parser.srcs/constrs_1/imports/ddca/Basys-3-Master.xdc` |")
    w(f"| [STA] Post-route | WNS {timing.get('wns')} ns, TNS {timing.get('tns')} ns, WHS {timing.get('whs')} ns, THS {timing.get('ths')} ns; all constraints met: {timing['all_met']} |")
    w(f"| [HW] JTAG target | `{session['target']}` at {session['jtag_hz']/1e6:.0f} MHz |")
    w(f"| [HW] Device | {session['device']}, IDCODE `{session['idcode']}` |")
    w(f"| [HW] Bitstream header part | `{session['bit_header_part']}` |")
    w(f"| [HW] DONE pin after programming | {session['done_pin']} |")
    w(f"| [HW] Monitor ID register read back | `{session['monitor_id']}` (matches build ID: {session['monitor_id'].endswith(info['build_id'])}) |\n")

    w("## 2. Test input\n")
    w("- **Corpus A** (`mem/frames.mem`, original): 4096 bytes = 8 garbage bytes + 160 x 23-byte frames "
      "(2 with bad CRC, 2 sequence jumps) + 408 zero pad bytes, replayed at 1 byte/cycle, looping.")
    w("- **Corpus B** (`mem/frames_b2b.mem`, `scripts/gen_b2b.py`): 178 valid 23-byte frames back to back, "
      "4094 bytes, no padding. Sequence restarts each loop, so one GAP event per loop is expected.")
    sha = {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in ("mem/frames.mem", "mem/frames_b2b.mem") if Path(p).exists()}
    for p, h in sha.items():
        w(f"- `{p}` SHA-256 `{h}`")
    w("- **Drain throttle**: `drain_div=0` is the original always-drain FIFO; `drain_div=31` reads the FIFO at most once every 32 cycles to force backpressure.\n")

    w("## 3. Clock check [HW]\n")
    w(f"Free-running cycle counter read twice over JTAG, {d_s:.3f} s apart by host clock: {d_cyc:,} cycles.  ")
    w(f"[DER] Estimated clock = {f_est/1e6:.4f} MHz. JTAG round-trip timing limits this to roughly +/-0.1%; "
      "it confirms the board runs at ~100 MHz, not the exact oscillator ppm.\n")

    w("## 4. Results per test\n")
    w("Latency definitions (all in clock cycles of the 100 MHz design clock):")
    w("- **lat1**: SYNC0 byte accepted by the parser -> parser event handshake (`event_valid && event_ready`).")
    w("- **lat2**: SYNC0 byte accepted -> the event leaves the 32-entry event FIFO.")
    w("- Messages are matched through timestamp queues, so each event is paired with its own frame even when several are in flight (only possible in the FIFO, under backpressure).")
    w("- The original `perf_counters` measures from the registered `sync_accept` pulse, one cycle after the SYNC0 handshake, so it reports lat1 - 1.\n")
    w("| Test | Window cycles | Events [HW] | Msg/s at 100 MHz [DER] | Cycles/msg (steady) [DER] | lat1 min/avg/max (p50, p99) [HW] | lat2 min/avg/max (p50, p99) [HW] | OK/CRC/GAP/RESYNC [HW] | Dropped [DER] | Queue errors [HW] |")
    w("|---|---|---|---|---|---|---|---|---|---|")
    for name, t in tests.items():
        d, m = t["decoded"], t["metrics"]
        l1, l2 = m["lat1"], m["lat2"]
        w(f"| {name} | {fmt(m['window_cycles'])} | {fmt(m['events'])} | {fmt(m['msgs_per_s_at_100MHz']/1e6)} M | "
          f"{fmt(m['steady_cycles_per_msg'], 3)} | {l1['min']}/{fmt(l1['avg'], 3)}/{l1['max']} ({l1['p50']}, {l1['p99']}) | "
          f"{l2['min']}/{fmt(l2['avg'], 3)}/{l2['max']} ({l2['p50']}, {l2['p99']}) | "
          f"{d['ok']}/{d['crc']}/{d['gap']}/{d['resync']} | {m['dropped_parser']} parser, {m['dropped_fifo']} FIFO | {m['queue_errors']} |")
    w("")
    w("Formulas: Msg/s = events x 100e6 / window cycles. Cycles/msg (steady) = (cycle of last event - cycle of first event) / (events - 1). "
      "Dropped (parser) = committed frames + in-flight at start - events - in-flight at end. Dropped (FIFO) = events + queued at start - FIFO reads - queued at end.\n")

    w("### Backpressure and stalls [HW]\n")
    w("| Test | Bytes accepted | Replay stalled by parser (cycles) | Source idle (cycles) | Parser output blocked (cycles) | FIFO full (cycles) | Max FIFO occupancy | Original perf_counters last_latency (live) |")
    w("|---|---|---|---|---|---|---|---|")
    for name, t in tests.items():
        d = t["decoded"]
        w(f"| {name} | {fmt(d['bytes'])} | {fmt(d['in_stall'])} | {fmt(d['src_idle'])} | {fmt(d['out_bp'])} | {fmt(d['fifo_full'])} | {d['fifo_max']} | {d['orig_last_latency']} |")
    w("")

    w("### Latency histograms [HW]\n")
    for name, t in tests.items():
        d = t["decoded"]
        h1 = ", ".join(f"{b}: {n:,}" for b, n in sorted(d["hist1"].items()))
        h2 = ", ".join(f"{'>=63' if b == 63 else b}: {n:,}" for b, n in sorted(d["hist2"].items()))
        w(f"- **{name}** lat1 {{{h1}}}; lat2 {{{h2}}}")
    w("")

    w("## 5. Hardware vs simulation (deterministic 1,000,000-cycle cold windows)\n")
    w("Both start from reset with the replay start and the window arm in the same clock cycle, so the board and the "
      "simulation should produce identical counters and histograms.\n")
    for name, diffs in comps.items():
        if not diffs:
            w(f"- **{name}**: all {len(COMPARE) - 1} counters and both histograms identical between [HW] and [SIM].")
        else:
            w(f"- **{name}**: {len(diffs)} differences: " + "; ".join(f"{k} hw={a} sim={b}" for k, a, b in diffs[:10]))
    w("")

    w("## 6. ILA captures [HW]\n")
    w("2048 consecutive cycles per capture; per-message latencies recomputed from the raw samples by this script, independently of the monitor.\n")
    w("| Capture | Contiguous | Events | lat1 (min/avg/max) | lat2 (min/avg/max) | Event interval cycles (min/avg/max) | FIFO-full samples |")
    w("|---|---|---|---|---|---|---|")
    for name, c in ila.items():
        def s3(x):
            return "-" if not x else f"{x['min']}/{x['avg']:.3f}/{x['max']}"
        w(f"| {name} | {c['contiguous']} | {c['events']} | {s3(c['lat1'])} | {s3(c['lat2']) if c['lat2'] else (c['lat2_note'] or '-')} | {s3(c['interval'])} | {c['fifo_full_samples']} |")
    w("")

    # verdicts
    def T(n):
        return tests.get(n, {}).get("metrics")
    a1 = [T(f"A_1s_t{k}") for k in range(1, 6) if T(f"A_1s_t{k}")]
    b1 = [T(f"B_1s_t{k}") for k in range(1, 6) if T(f"B_1s_t{k}")]
    w("## 7. Verdict on the previously reported figures\n")
    if a1 and b1:
        ra = [m["msgs_per_s_at_100MHz"] / 1e6 for m in a1]
        rb = [m["msgs_per_s_at_100MHz"] / 1e6 for m in b1]
        l1s = sorted({m["lat1"]["min"] for m in a1 + b1} | {m["lat1"]["max"] for m in a1 + b1})
        l2s = sorted({m["lat2"]["min"] for m in a1 + b1} | {m["lat2"]["max"] for m in a1 + b1})
        w(f"- **100 MHz clock**: constrained at 10.000 ns and met post-route [STA]; board clock measured at {f_est/1e6:.3f} MHz [HW/DER].")
        in_a = [x for x in ra if 3.6 <= x <= 3.8]
        w(f"- **3.6-3.8 M msg/s**: [HW] corpus A (original replay data) sustained {min(ra):.4f}-{max(ra):.4f} M msg/s over {len(ra)} x 1 s windows "
          f"({'inside' if len(in_a) == len(ra) else 'not inside'} the 3.6-3.8 range); corpus B (back-to-back frames, parser-limited) "
          f"{min(rb):.4f}-{max(rb):.4f} M msg/s. [DER] corpus A cycles per message = {statistics.mean(m['cycles_per_msg_window'] for m in a1):.3f}; "
          f"corpus B = {statistics.mean(m['cycles_per_msg_window'] for m in b1):.3f}.")
        lat_ok = any(26 <= x <= 28 for x in l1s + l2s)
        w(f"- **260-280 ns latency**: [HW] lat1 values observed {l1s} cycles = {[x * CYCLE_NS for x in l1s]} ns; lat2 values {l2s} cycles = "
          f"{[x * CYCLE_NS for x in l2s]} ns, without backpressure. "
          f"{'Some observed latencies fall in 260-280 ns.' if lat_ok else 'No observed latency falls in 260-280 ns, so the figure is not supported by the hardware.'} "
          f"[HW] the original perf_counters last_latency register read {sorted({t['decoded']['orig_last_latency'] for n, t in tests.items() if n.startswith(('A_1s', 'B_1s'))})} cycles "
          "(it starts one cycle after the SYNC0 handshake).")
        w("- **Conditions**: these figures hold for this design fed from on-chip BRAM at 1 byte per cycle with the event FIFO drained every cycle. "
          "The corpus A rate depends on its padding and garbage bytes (it is not a property of the parser alone); the parser's own limit is corpus B's rate. "
          "No network or external I/O is involved.")
    w("")
    w("## 8. Raw evidence\n")
    w("All files under `raw/`: `session.json` (device and identity checks), `clock_check.json`, one JSON per test window with every monitor register as read over JTAG, "
      "and `ila_*.csv` / `ila_*.ila` captures (the .ila files open in the Vivado hardware manager). `vivado_hw.log` is the full Tcl session log.\n")

    (run / "BENCHMARK_REPORT.md").write_text("\n".join(L))
    (run / "summary.json").write_text(json.dumps({
        "build": info, "timing": timing, "session": session, "clock_mhz": f_est / 1e6,
        "tests": {k: {"config": v["config"], "metrics": v["metrics"]} for k, v in tests.items()},
        "sim_compare": {k: [list(map(str, x)) for x in v] for k, v in comps.items()}, "ila": ila,
    }, indent=2, default=str))
    print(f"wrote {run/'BENCHMARK_REPORT.md'}")


if __name__ == "__main__":
    main()
