#!/usr/bin/env python
# -*- coding: ascii -*-
"""gen_offsets.py -- programmatic character-offset derivation for the
app_status_uart diagnostic status line (RXP_DIAG v1 / v2 / v3).

WHY THIS EXISTS
  The status line is a concatenation of TPL literals plus a per-character
  override mux keyed on `ci`.  Every field offset is therefore a *computed*
  quantity, and hand-counting them has burned this project before.  This script
  concatenates the literals **in declaration order** (the same order the RTL
  uses) and reports the [start, end) window of every `KEY=` field, plus the
  CR/LF and the total line length.

SELF-CHECK
  It first reproduces the *published* v2 offsets (GW 384, EW 404, OZ 424,
  OL 436, OM 448, OH 460, CR 468, LF 469, LINE_LEN 470) and fails loudly if
  they do not match.  Only then does it report the v3 block.

ASCII-only on purpose (Windows console / GBK + bat rules).
"""
import sys

# ---------------------------------------------------------------------------
# v1+v2 TPL: the *published* 470-char line, literals in declaration order.
# (copy verbatim from rtl/app_status_uart.v; CR/LF are two 1-byte literals)
# ---------------------------------------------------------------------------
TPL_V2 = [
    "P5B1 ST=x NX=xxxxxxxx UA=xxxxxxxx RW=xxxx RN=xxxxxxxx ",
    "RX=xxxxxxxx TX=xxxxxxxx TF=xxxx MM=xxxx OC=xxxxx EV=xxxx ",
    "DP=xxxx RY=xxxx EC=xx DL=xxxx FI=xxxx RS=xxxx",
    " AK=xxxx AD=xxxx TS=x WQ=xxxx WM=xxxx WU=xxxx PO=xxxxx PX=xxxx",
    " URB=xxxxxxxx UMM=xxxxxxxx URF=xxxx UOV=xxxx UPC=xxxx UPA=xxxx",
    " UTB=xxxxxxxx UTF=xxxx",
    " II=xxxxxxxx GG=xx EE=xx PP=xx BA=xxxxxxxx BB=xxxxxxxx BC=xxxxxxxx DD=xxxxxxxx",
    " GW=xxxxxxxxxxxxxxxx EW=xxxxxxxxxxxxxxxx",
    " OZ=xxxxxxxx OL=xxxxxxxx OM=xxxxxxxx OH=xxxxxxxx",
    "\r\n",
]

# ---------------------------------------------------------------------------
# v3 TPL block: APPENDED at the end (before CR/LF).  Must stay byte-identical
# in rtl/app_status_uart.v.
# ---------------------------------------------------------------------------
TPL_V3 = [
    " SW=xxxxxxxxxxxxxxxx SF=xxx SM=x",
    " FR=xxx FW=xxx FO=xxx FH=xxx FS=x FN=xxxx",
    " PR=xxx PW=xxx PH=xxx",
    " LR=xxx LW=xxx LO=xxx LH=xxx",
    " RC=xxxx VC=xxxx",
    " VX=xxx VS=xxx VR=xxx VN=xxxx",
]

# field key -> hex width (characters of the value)
FIELDS_V2 = [
    ("ST", 1), ("NX", 8), ("UA", 8), ("RW", 4), ("RN", 8), ("RX", 8),
    ("TX", 8), ("TF", 4), ("MM", 4), ("OC", 5), ("EV", 4), ("DP", 4),
    ("RY", 4), ("EC", 2), ("DL", 4), ("FI", 4), ("RS", 4),
    ("AK", 4), ("AD", 4), ("TS", 1), ("WQ", 4), ("WM", 4), ("WU", 4),
    ("PO", 5), ("PX", 4),
    ("URB", 8), ("UMM", 8), ("URF", 4), ("UOV", 4), ("UPC", 4),
    ("UPA", 4), ("UTB", 8), ("UTF", 4),
    ("II", 8), ("GG", 2), ("EE", 2), ("PP", 2),
    ("BA", 8), ("BB", 8), ("BC", 8), ("DD", 8),
    ("GW", 16), ("EW", 16),
    ("OZ", 8), ("OL", 8), ("OM", 8), ("OH", 8),
]
FIELDS_V3 = [
    ("SW", 16), ("SF", 3), ("SM", 1),
    ("FR", 3), ("FW", 3), ("FO", 3), ("FH", 3), ("FS", 1), ("FN", 4),
    ("PR", 3), ("PW", 3), ("PH", 3),
    ("LR", 3), ("LW", 3), ("LO", 3), ("LH", 3),
    ("RC", 4), ("VC", 4),
    ("VX", 3), ("VS", 3), ("VR", 3), ("VN", 4),
]
# published v2 offsets: key -> (value_start, value_end)
PUB_V2 = {
    "GW": (384, 400), "EW": (404, 420), "OZ": (424, 432), "OL": (436, 444),
    "OM": (448, 456), "OH": (460, 468),
}
PUB_CR, PUB_LF, PUB_LINE = 468, 469, 470


def _regex_keymap(line):
    """Emulate the board reader's parse: re.findall(r"([A-Z]{2})=([0-9A-Fx]+)")
    -> last match wins.  Used to show which *keys* the reader will actually see
    (the TPL has a known shadowing pair: 'UTF=' is also read as key 'TF')."""
    import re
    km = {}
    for m in re.finditer(r"([A-Z]{2})=([0-9A-Fx]+)", line):
        km.setdefault(m.group(1), []).append(m.start(2))
    return km


def value_window(line, key, width):
    """[start, end) of the hex value of the field written literally as ' KEY='
    (every field in the TPL is space-separated, so this is unambiguous even when
    a *different*, longer field would parse to the same 2-letter key -- e.g.
    ' UTF=' also parses as key 'TF' by the board reader's rule)."""
    pat = " " + key + "="
    idx = []
    i = line.find(pat)
    while i >= 0:
        idx.append(i)
        i = line.find(pat, i + 1)
    if len(idx) != 1:
        raise SystemExit("FATAL: literal ' %s=' appears %d times (must be 1)"
                         % (key, len(idx)))
    s = idx[0] + len(pat)
    e = s + width
    # the window must be all 'x' placeholders in the template
    if line[s:e] != "x" * width:
        raise SystemExit("FATAL: key %s window %d..%d is %r, not %d 'x'"
                         % (key, s, e, line[s:e], width))
    return (s, e)


def report(title, line, fields):
    print("== %s ==" % title)
    print("LINE_LEN = %d" % len(line))
    print("CR = %d   LF = %d" % (len(line) - 2, len(line) - 1))
    for key, w in fields:
        s, e = value_window(line, key, w)
        print("  %-4s width=%2d  chars [%3d..%4d)  value_chars [%3d..%4d)"
              % (key, w, s - len(key) - 1, s - len(key) - 1 + len(key) + 1 + w,
                 s, e))
    print("")


def main():
    v2 = "".join(TPL_V2)
    # --- self-check against the published v2 layout ---
    bad = 0
    for key, (a, b) in sorted(PUB_V2.items()):
        s, e = value_window(v2, key, b - a)
        if (s, e) != (a, b):
            print("SELFCHECK FAIL: %s at %d..%d, published %d..%d"
                  % (key, s, e, a, b))
            bad += 1
    if len(v2) != PUB_LINE or v2[-2:] != "\r\n":
        print("SELFCHECK FAIL: LINE_LEN %d (published %d), tail %r"
              % (len(v2), PUB_LINE, v2[-2:]))
        bad += 1
    if (len(v2) - 2, len(v2) - 1) != (PUB_CR, PUB_LF):
        print("SELFCHECK FAIL: CR/LF at %d/%d, published %d/%d"
              % (len(v2) - 2, len(v2) - 1, PUB_CR, PUB_LF))
        bad += 1
    if bad:
        raise SystemExit("FATAL: published v2 offsets not reproduced -> DO NOT "
                         "trust the v3 numbers either")
    print("SELFCHECK OK: published v2 offsets reproduced "
          "(GW 384, EW 404, OZ 424, OL 436, OM 448, OH 460, CR 468, LF 469, "
          "LINE_LEN 470)\n")

    report("v2 (470 chars, unchanged)", v2, FIELDS_V2)

    # --- v3 line: v3 literals inserted before the CR/LF ---
    v3_body = "".join(TPL_V3)
    line3 = v2[:-2] + v3_body + "\r\n"
    report("v3 (v2 prefix byte-identical + appended block)", line3, FIELDS_V3)

    # --- invariants the RTL decoder relies on ---
    n_v2 = len(v2)
    s_first = value_window(line3, FIELDS_V3[0][0], FIELDS_V3[0][1])[0]
    print("v3 first field value starts at %d (v2 body ends at %d, i.e. the "
          "char before CR is %d)" % (s_first, n_v2 - 2, n_v2 - 3))
    assert line3[:n_v2 - 2] == v2[:-2], "prefix changed!"
    print("PREFIX CHECK OK: first %d chars byte-identical to v2" % (n_v2 - 2))
    # ci is a 10-bit register / TPL index -> LINE_LEN must be <= 1023
    assert len(line3) <= 1023, "LINE_LEN %d exceeds the 10-bit ci window" % len(line3)
    print("LINE LIMIT OK: LINE_LEN %d <= 1023 (10-bit ci)" % len(line3))
    # hex digit count of every v3 window must fit the field width
    for key, w in FIELDS_V3:
        value_window(line3, key, w)
    print("WINDOW CHECK OK: all v3 fields have exactly %d 'x' placeholders"
          % len(FIELDS_V3))

    # --- shadowing check: what the BOARD READER (regex, last match wins) sees ---
    km3 = _regex_keymap(line3)
    shadow = 0
    for key, w in FIELDS_V3:
        s, e = value_window(line3, key, w)
        occ = km3.get(key, [])
        if len(occ) != 1 or occ[0] != s:
            print("SHADOW: key %s: literal at %d but reader sees regex hits at %s"
                  % (key, s, occ))
            shadow += 1
    print("KEY SHADOW CHECK: %d of %d v3 keys read unambiguously (%s)"
          % (len(FIELDS_V3) - shadow, len(FIELDS_V3),
             "OK" if shadow == 0 else "COLLISION"))
    # pre-existing, documented collision in the v2 prefix (do not "fix": it is
    # the reader's own rule and every published offset depends on it)
    coll = {k: v for k, v in km3.items() if len(v) > 1}
    print("NOTE pre-existing multi-hit keys in the line (reader: last wins): %s"
          % sorted(coll.keys()))
    print("\nRTL must use: localparam LINE_LEN = 10'd%d;" % len(line3))
    print("RTL decoder windows (ci >= X && ci < Y):")
    for key, w in FIELDS_V3:
        s, e = value_window(line3, key, w)
        print("  %-3s : ci >= 10'd%d && ci < 10'd%d   (pc-offset in hexd)"
              % (key, s, e))


if __name__ == "__main__":
    main()
