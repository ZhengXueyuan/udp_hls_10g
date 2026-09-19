#!/usr/bin/env python
"""board_snapshot.py -- read the board's UART snapshot and reconcile counters.

The board emits one status line every ~5 s on COM9 (9600-8N1).  It carries the
MAC/TCP counter set that lets us attribute traffic to layers:

    MW   = mac_rx_64 output word count (8 B/word, FCS stripped).
           The zero-noise check: MW must advance by exactly the number of words
           the synthetic peer put on the wire (peer reports "TX wire words").
    TRU  = truncated-frame counter
    DROPS= a/b/c/d drop counters (queue / classify / ... )
    TW TF TI = TCP TX words / frames / ...
    PASS, RXTR, SC/SD/SF/SP/SV = fast/slow path counters
    W / WC / WL = latch + window registers (non-zero W => an RTO rollback fired)
    HR   = HLS reset flag

Usage:
  python board_snapshot.py                       print one parsed snapshot
  python board_snapshot.py --port COM9
  python board_snapshot.py --reconcile -- <cmd> [args...]
        read snapshot A, run <cmd>, read snapshot B, print per-field deltas
        (use --expect-words N to also check the MW delta against N)

Notes:
  Two consecutive snapshots are always read so the returned line is fresh --
  the serial driver buffer frequently still holds the previous period's line.
"""
import re
import subprocess
import sys
import time

try:
    import serial
except ImportError:
    serial = None

PORT = "COM9"
BAUD = 9600

# Fields whose value is a single hex/decimal number
NUMERIC = ["NX", "UA", "WN", "WS", "ST", "W", "I", "E", "TXST", "RXST", "ACC",
           "EMV", "EST", "PF", "TV", "PV", "SV", "PLEN", "TW", "TF", "TI",
           "PW", "PR", "PFL", "PEM", "PLN", "RXPL", "RXPC", "RXT", "PASS",
           "RXTR", "MW", "RW", "WC", "WL", "SC", "SD", "SF", "SP", "SV",
           "HR", "TRU"]
# Fields with a/b/... compound values
COMPOUND = ["CW", "DROPS"]

WATCH = ["MW", "TRU", "DROPS", "TW", "TF", "TI", "PASS", "RXTR",
         "W", "WC", "WL", "SC", "SD", "SF", "SP", "SV", "HR"]


def read_line(port=PORT, timeout=25.0, want_two=True):
    """Return the most recent COMPLETE snapshot line as str.

    Counts complete *lines*, not distinct MW values -- an idle board emits the
    same MW every period, so waiting for MW to change would hang forever.
    want_two=True waits for a second period, guaranteeing the line we return is
    fresh rather than a leftover sitting in the driver buffer."""
    if serial is None:
        raise RuntimeError("pyserial not available")
    sp = serial.Serial(port, BAUD, timeout=3.0)
    try:
        buf = b""
        t0 = time.time()
        while time.time() - t0 < timeout:
            chunk = sp.read(1024)
            if chunk:
                buf += chunk
                # [:-1] drops the trailing partial line still being received
                lines = [l for l in buf.split(b"\r\n")[:-1] if b"MW=" in l]
                if len(lines) >= (2 if want_two else 1):
                    return lines[-1].decode("latin-1")
    finally:
        sp.close()
    raise RuntimeError("UART read timeout (no complete snapshot)")


def parse(line):
    """-> (values: dict, raw: dict of untouched tokens)"""
    vals = {}
    raw = {}
    for tok in line.split():
        if "=" not in tok:
            continue
        k, v = tok.split("=", 1)
        raw[k] = v
        if k in COMPOUND:
            parts = v.split("/")
            for i, p in enumerate(parts):
                if re.fullmatch(r"[0-9A-Fa-f]+", p):
                    vals["%s[%d]" % (k, i)] = int(p, 16)
        elif re.fullmatch(r"[0-9A-Fa-f]+", v):
            vals[k] = int(v, 16)
    return vals, raw


def snapshot_cmd(port):
    line = read_line(port)
    vals, raw = parse(line)
    print(line)
    print()
    for k in WATCH:
        if k in raw:
            print("  %-6s = %s" % (k, raw[k]))
    return 0


def reconcile_cmd(port, cmd, expect_words):
    a_line = read_line(port)
    a, _ = parse(a_line)
    print("[A] MW=%08X TRU=%08X DROPS=%s W=%s" %
          (a.get("MW", 0), a.get("TRU", 0),
           a.get("DROPS[0]", 0), a.get("W", 0)))
    sys.stdout.flush()

    t0 = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True)
    dt = time.time() - t0
    sys.stdout.write(p.stdout)
    sys.stdout.write(p.stderr)
    print("[cmd] exit=%d wall=%.2fs" % (p.returncode, dt))

    if expect_words is None:
        m = re.search(r"TX wire words:\s*(\d+)", p.stdout)
        if m:
            expect_words = int(m.group(1))
            print("[cmd] auto-detected peer TX wire words = %d" % expect_words)

    b_line = read_line(port)
    b, _ = parse(b_line)
    print("[B] MW=%08X TRU=%08X DROPS=%s W=%s" %
          (b.get("MW", 0), b.get("TRU", 0),
           b.get("DROPS[0]", 0), b.get("W", 0)))

    print()
    print("=== delta (B - A) ===")
    keys = sorted(set(list(a.keys()) + list(b.keys())))
    for k in keys:
        d = b.get(k, 0) - a.get(k, 0)
        if d == 0:
            continue
        mark = "  <<<" if k in WATCH else ""
        print("  %-9s %12d%s" % (k, d, mark))

    mw_delta = b.get("MW", 0) - a.get("MW", 0) if "MW" in a and "MW" in b else None
    # a snapshot may straddle the transfer: the board emits every ~5 s, so the
    # window [A,B] is >= the transfer.  Stray frames landing in the window would
    # inflate MW -- that is exactly what the check is for.
    print()
    print("MW delta = %s words" % mw_delta)
    if expect_words is not None and mw_delta is not None:
        print("peer TX wire words = %d" % expect_words)
        diff = mw_delta - expect_words
        print("difference = %+d words (%.1f frames of %.0f words)" %
              (diff, diff / 190.0, 190.0))
        if diff == 0:
            print("VERDICT: EXACT MATCH -- zero stray RX traffic, zero lost words")
        elif diff > 0:
            print("VERDICT: board RX exceeded peer TX by %d words -- stray frames "
                  "inside the UART window (other host traffic) or board-side "
                  "duplication" % diff)
        else:
            print("VERDICT: board RX short by %d words -- frames lost between NIC "
                  "and board MAC, or board drops" % (-diff))
    return 0


def main():
    port = PORT
    args = sys.argv[1:]
    if "--port" in args:
        port = args[args.index("--port") + 1]
    if "--reconcile" in args:
        rest = args[args.index("--reconcile") + 1:]
        if rest and rest[0] == "--":
            rest = rest[1:]
        expect = None
        if "--expect-words" in rest:
            i = rest.index("--expect-words")
            expect = int(rest[i + 1])
            rest = rest[:i] + rest[i + 2:]
        if not rest:
            print("need a command after --reconcile --")
            return 2
        return reconcile_cmd(port, rest, expect)
    return snapshot_cmd(port)


if __name__ == "__main__":
    sys.exit(main())
