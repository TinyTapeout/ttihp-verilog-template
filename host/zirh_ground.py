#!/usr/bin/env python3
# =============================================================================
# ZIRH - ground station: telemetry stream decoder
#
#   python3 host/zirh_ground.py --port /dev/ttyUSB0            live capture
#   python3 host/zirh_ground.py --file capture.bin             offline decode
#   python3 host/zirh_ground.py --selftest                     no hardware
#
# Decodes the 10-byte telemetry frames the chip emits unprompted:
#
#   0  0x5A 'Z'    1  0x52 'R'
#   2  STATUS      {seq[3:0], armed, infra, mode[1:0]}
#   3-4 PLAIN  5-6 RAW  7-8 ESCAPE   (16-bit big-endian)
#   9  XOR of bytes 0..8
#
# The line also carries echo bytes between frames, so the decoder treats the
# input as an untrusted byte stream: it hunts for the sync pair, validates
# the checksum before accepting a frame, and resynchronizes by advancing one
# byte on any mismatch. Bytes that never validate are reported as non-frame
# traffic (echo or line noise).
#
# Per frame it reports counter values and deltas; it flags sequence gaps
# (dropped frames), checksum failures, infra events and counter drops
# (a counter going backwards without CLEAR means instrument trouble).
# Optional CSV log for beam-campaign records.
#
# Requires: Python 3.8+. pyserial only for --port mode.
# =============================================================================

import argparse
import sys
import time

SYNC0, SYNC1 = 0x5A, 0x52
FRAME_LEN = 10
MODES = {0: "zeros", 1: "ones", 2: "checker", 3: "checker"}


class Frame:
    __slots__ = ("seq", "armed", "infra", "mode", "plain", "raw", "escape")

    def __init__(self, buf):
        status = buf[2]
        self.seq = (status >> 4) & 0xF
        self.armed = (status >> 3) & 1
        self.infra = (status >> 2) & 1
        self.mode = status & 3
        self.plain = (buf[3] << 8) | buf[4]
        self.raw = (buf[5] << 8) | buf[6]
        self.escape = (buf[7] << 8) | buf[8]


def checksum_ok(buf):
    chk = 0
    for b in buf[:9]:
        chk ^= b
    return chk == buf[9]


class Decoder:
    """Feed bytes in, get (event, payload) tuples out.

    Events: ("frame", Frame), ("skip", byte)  - byte that is not part of any
    valid frame (echo traffic or noise), ("chk_fail", bytes) - sync pair with
    a bad checksum (counted, first byte re-emitted as skip during resync).
    """

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data):
        self.buf.extend(data)
        out = []
        while True:
            # drop leading bytes that cannot start a frame
            while self.buf and self.buf[0] != SYNC0:
                out.append(("skip", self.buf.pop(0)))
            if len(self.buf) >= 2 and self.buf[1] != SYNC1:
                out.append(("skip", self.buf.pop(0)))
                continue
            if len(self.buf) < FRAME_LEN:
                return out
            cand = bytes(self.buf[:FRAME_LEN])
            if checksum_ok(cand):
                out.append(("frame", Frame(cand)))
                del self.buf[:FRAME_LEN]
            else:
                out.append(("chk_fail", cand))
                out.append(("skip", self.buf.pop(0)))  # resync one byte on


class Session:
    """Tracks continuity across frames and renders report lines."""

    def __init__(self, csv=None):
        self.prev = None
        self.frames = 0
        self.gaps = 0
        self.chk_fails = 0
        self.skipped = 0
        self.csv = csv
        if csv:
            csv.write("time,seq,armed,infra,mode,plain,raw,escape,"
                      "d_plain,d_raw,d_escape,gap\n")

    def _delta(self, now, before):
        d = now - before
        return d if d >= 0 else None  # negative without CLEAR: suspicious

    def handle(self, event, payload, quiet_skips=True):
        lines = []
        if event == "skip":
            self.skipped += 1
            if not quiet_skips:
                lines.append(f"  echo/noise byte: {payload:#04x}")
        elif event == "chk_fail":
            self.chk_fails += 1
            lines.append("! checksum FAIL: " + payload.hex(" "))
        elif event == "frame":
            f = payload
            self.frames += 1
            gap = 0
            d = ("-", "-", "-")
            if self.prev is not None:
                gap = (f.seq - self.prev.seq - 1) % 16
                if gap:
                    self.gaps += gap
                dp = self._delta(f.plain, self.prev.plain)
                dr = self._delta(f.raw, self.prev.raw)
                de = self._delta(f.escape, self.prev.escape)
                d = tuple("RESET?" if x is None else f"+{x}" for x in (dp, dr, de))
            flags = "".join([
                "A" if f.armed else "-",
                "I" if f.infra else "-",
            ])
            lines.append(
                f"seq={f.seq:2d} [{flags}] mode={MODES[f.mode]:7s} "
                f"PLAIN={f.plain:5d} ({d[0]:>6s})  "
                f"RAW={f.raw:5d} ({d[1]:>6s})  "
                f"ESCAPE={f.escape:5d} ({d[2]:>6s})"
                + (f"  ! {gap} frame(s) LOST" if gap else ""))
            if self.csv:
                self.csv.write(
                    f"{time.time():.3f},{f.seq},{f.armed},{f.infra},"
                    f"{MODES[f.mode]},{f.plain},{f.raw},{f.escape},"
                    f"{d[0]},{d[1]},{d[2]},{gap}\n")
            self.prev = f
        return lines

    def summary(self):
        return (f"frames={self.frames}  lost={self.gaps}  "
                f"checksum_fails={self.chk_fails}  other_bytes={self.skipped}")


def make_frame(seq, plain, raw, escape, armed=1, infra=0, mode=0, corrupt=False):
    status = ((seq & 0xF) << 4) | (armed << 3) | (infra << 2) | mode
    buf = bytearray([SYNC0, SYNC1, status,
                     plain >> 8, plain & 0xFF,
                     raw >> 8, raw & 0xFF,
                     escape >> 8, escape & 0xFF])
    chk = 0
    for b in buf:
        chk ^= b
    buf.append(chk ^ (0x01 if corrupt else 0x00))
    return bytes(buf)


def selftest():
    """Decoder must survive a hostile stream: echo bytes (including fake sync
    bytes), a corrupted frame, dropped frames, split feeds."""
    stream = (
        b"hello"                                   # echo traffic
        + make_frame(1, 0, 0, 0)
        + bytes([0x5A])                            # lone fake sync byte
        + make_frame(2, 3, 1, 0)
        + make_frame(3, 3, 1, 0, corrupt=True)     # checksum failure
        + bytes([0x5A, 0x52])                      # sync pair, then nothing valid
        + b"x"
        + make_frame(6, 4, 1, 0, infra=1)          # seq jump: 2 lost (3 bad, 4-5 missing)
    )

    sess = Session()
    dec = Decoder()
    # feed one byte at a time: reassembly across arbitrary boundaries
    for i in range(len(stream)):
        for ev, pl in dec.feed(stream[i:i + 1]):
            for line in sess.handle(ev, pl):
                print(line)

    assert sess.frames == 3, f"expected 3 valid frames, got {sess.frames}"
    assert sess.chk_fails >= 1, "corrupted frame must be flagged"
    assert sess.prev.plain == 4 and sess.prev.infra == 1
    assert sess.gaps > 0, "seq discontinuity must be counted"
    print("selftest:", sess.summary())
    print("selftest PASS")


def main():
    ap = argparse.ArgumentParser(description="ZIRH telemetry decoder")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--port", help="serial port, e.g. /dev/ttyUSB0")
    src.add_argument("--file", help="decode a raw capture file")
    src.add_argument("--selftest", action="store_true")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--csv", help="append machine-readable log to this file")
    ap.add_argument("--show-echo", action="store_true",
                    help="print non-frame bytes as well")
    args = ap.parse_args()

    if args.selftest:
        selftest()
        return

    csv = open(args.csv, "a") if args.csv else None
    sess = Session(csv=csv)
    dec = Decoder()

    def pump(chunk):
        for ev, pl in dec.feed(chunk):
            for line in sess.handle(ev, pl, quiet_skips=not args.show_echo):
                print(line, flush=True)

    try:
        if args.file:
            with open(args.file, "rb") as f:
                pump(f.read())
        else:
            import serial  # pyserial, only needed for live mode
            with serial.Serial(args.port, args.baud, timeout=0.2) as sp:
                print(f"listening on {args.port} @ {args.baud} 8N1 "
                      "(ctrl-C to stop)")
                while True:
                    pump(sp.read(256))
    except KeyboardInterrupt:
        pass
    finally:
        print(sess.summary())
        if csv:
            csv.close()


if __name__ == "__main__":
    main()
