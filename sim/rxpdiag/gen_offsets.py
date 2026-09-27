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

# ---------------------------------------------------------------------------
# v4 TPL block: APPENDED after the v3 block (before CR/LF).  Must stay
# byte-identical in rtl/app_status_uart.v.
# ---------------------------------------------------------------------------
TPL_V4 = [
    " CN=xxxx RD=xxxx NC=xxxx NP=xxxx WF=xxxx RL=xxxx WC=xxxx",
    " NE=xxxx NR=xxxx MR=xxxx EN=x EO=x",
    " QA=xxxxxx QB=xxxxxx QC=xxxxxx QD=xxxxxx",
    " QE=xxxxxx QF=xxxxxx QG=xxxxxx QH=xxxxxx",
]
FIELDS_V4 = [
    ("CN", 4), ("RD", 4), ("NC", 4), ("NP", 4), ("WF", 4), ("RL", 4),
    ("WC", 4),
    ("NE", 4), ("NR", 4), ("MR", 4), ("EN", 1), ("EO", 1),
    ("QA", 6), ("QB", 6), ("QC", 6), ("QD", 6),
    ("QE", 6), ("QF", 6), ("QG", 6), ("QH", 6),
]
# published v4 offsets: key -> (value_start, value_end)  (ISSUE ... section 17.2)
PUB_V4 = {
    "CN": (639, 643), "RD": (647, 651), "NC": (655, 659), "NP": (663, 667),
    "WF": (671, 675), "RL": (679, 683), "WC": (687, 691),
    "NE": (695, 699), "NR": (703, 707), "MR": (711, 715),
    "EN": (719, 720), "EO": (724, 725),
    "QA": (729, 735), "QB": (739, 745), "QC": (749, 755), "QD": (759, 765),
    "QE": (769, 775), "QF": (779, 785), "QG": (789, 795), "QH": (799, 805),
}
PUB_V4_CR, PUB_V4_LF, PUB_V4_LINE = 805, 806, 807

# ---------------------------------------------------------------------------
# v5 TPL block: APPENDED after the v4 block (before CR/LF).  Must stay
# byte-identical in rtl/app_status_uart.v.
# ---------------------------------------------------------------------------
TPL_V5 = [
    " DV=xxxxxxxx DG=xx DE=xx DO=xxxx DM=xxxxxxxx VZ=x",
    " PS=xxxxxxxx NM=xxxxxxxx IC=xxxxxxxx DC=xxxxxxxx SB=xxxxxxxx",
]
FIELDS_V5 = [
    ("DV", 8), ("DG", 2), ("DE", 2), ("DO", 4), ("DM", 8), ("VZ", 1),
    ("PS", 8), ("NM", 8), ("IC", 8), ("DC", 8), ("SB", 8),
]
# published v5 offsets (ISSUE ... section 19); this IS the calibration record
PUB_V5 = {
    "DV": (809, 817), "DG": (821, 823), "DE": (827, 829), "DO": (833, 837),
    "DM": (841, 849), "VZ": (853, 854),
    "PS": (858, 866), "NM": (870, 878), "IC": (882, 890), "DC": (894, 902),
    "SB": (906, 914),
}
PUB_V5_CR, PUB_V5_LF, PUB_V5_LINE = 914, 915, 916

# ---------------------------------------------------------------------------
# v6 TPL block: APPENDED after the v5 block (before CR/LF).  Must stay
# byte-identical in rtl/app_status_uart.v.
# ---------------------------------------------------------------------------
TPL_V6 = [
    " CV=xxxxxxxx CG=xx CE=xx CO=xxxx CM=xxxxxxxx CZ=x CS=xx",
]
FIELDS_V6 = [
    ("CV", 8), ("CG", 2), ("CE", 2), ("CO", 4), ("CM", 8), ("CZ", 1), ("CS", 2),
]
# published v6 offsets (ISSUE ... section 18.13); this IS the calibration record
PUB_V6 = {
    "CV": (918, 926), "CG": (930, 932), "CE": (936, 938), "CO": (942, 946),
    "CM": (950, 958), "CZ": (962, 963), "CS": (967, 969),
}
PUB_V6_CR, PUB_V6_LF, PUB_V6_LINE = 969, 970, 971

# ---------------------------------------------------------------------------
# v7 TPL block: APPENDED after the v6 block (before CR/LF).  Must stay
# byte-identical in rtl/app_status_uart.v.
#   6 fields, all 16-bit values shown as 4 hex characters
#   (16-bit counters are honest: no silent truncation of a wider counter).
# ---------------------------------------------------------------------------
TPL_V7 = [
    " IV=xxxx IS=xxxx IA=xxxx IB=xxxx IW=xxxx NB=xxxx",
]
FIELDS_V7 = [
    ("IV", 4), ("IS", 4), ("IA", 4), ("IB", 4), ("IW", 4), ("NB", 4),
]
# published v7 offsets (session 2026-09-27); this IS the calibration record
PUB_V7 = {
    "IV": (973, 977), "IS": (981, 985), "IA": (989, 993), "IB": (997, 1001),
    "IW": (1005, 1009), "NB": (1013, 1017),
}
PUB_V7_CR, PUB_V7_LF, PUB_V7_LINE = 1017, 1018, 1019

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
PUB_V3 = {
    "SW": (472, 488), "SF": (492, 495), "SM": (499, 500),
    "FR": (504, 507), "FW": (511, 514), "FO": (518, 521), "FH": (525, 528),
    "FS": (532, 533), "FN": (537, 541),
    "PR": (545, 548), "PW": (552, 555), "PH": (559, 562),
    "LR": (566, 569), "LW": (573, 576), "LO": (580, 583), "LH": (587, 590),
    "RC": (594, 598), "VC": (602, 606),
    "VX": (610, 613), "VS": (617, 620), "VR": (624, 627), "VN": (631, 635),
}
PUB_V3_CR, PUB_V3_LF, PUB_V3_LINE = 635, 636, 637

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

    # --- self-check the v3 block against the PUBLISHED offsets (14.2) ---
    bad = 0
    for key, (a, b) in sorted(PUB_V3.items()):
        s, e = value_window(line3, key, b - a)
        if (s, e) != (a, b):
            print("SELFCHECK FAIL (v3): %s at %d..%d, published %d..%d"
                  % (key, s, e, a, b))
            bad += 1
    if len(line3) != PUB_V3_LINE:
        print("SELFCHECK FAIL (v3): LINE_LEN %d (published %d)"
              % (len(line3), PUB_V3_LINE))
        bad += 1
    if bad:
        raise SystemExit("FATAL: published v3 offsets not reproduced -> DO NOT "
                         "trust the v4 numbers either")
    print("\nSELFCHECK OK (v3): published offsets reproduced "
          "(SW 472 ... VN 631, CR 635, LF 636, LINE_LEN 637)\n")

    # ---------------------------------------------------------------
    # v4 line: v4 literals appended after the v3 block
    # ---------------------------------------------------------------
    v4_body = "".join(TPL_V4)
    line4 = v2[:-2] + v3_body + v4_body + "\r\n"
    report("v4 (v2+v3 prefix byte-identical + appended block)", line4, FIELDS_V4)
    assert line4[:len(line3) - 2] == line3[:-2], "prefix changed!"
    print("PREFIX CHECK OK (v4): first %d chars byte-identical to v3"
          % (len(line3) - 2))
    assert len(line4) <= 1023, "LINE_LEN %d exceeds the 10-bit ci window" % len(line4)
    print("LINE LIMIT OK (v4): LINE_LEN %d <= 1023 (10-bit ci)" % len(line4))
    for key, w in FIELDS_V4:
        value_window(line4, key, w)
    print("WINDOW CHECK OK (v4): all %d v4 fields have exactly the declared "
          "'x' placeholder count" % len(FIELDS_V4))

    km4 = _regex_keymap(line4)
    shadow = 0
    for key, w in FIELDS_V4:
        s, e = value_window(line4, key, w)
        occ = km4.get(key, [])
        if len(occ) != 1 or occ[0] != s:
            print("SHADOW: key %s: literal at %d but reader sees regex hits at %s"
                  % (key, s, occ))
            shadow += 1
    print("KEY SHADOW CHECK (v4): %d of %d v4 keys read unambiguously (%s)"
          % (len(FIELDS_V4) - shadow, len(FIELDS_V4),
             "OK" if shadow == 0 else "COLLISION"))
    if shadow:
        raise SystemExit("FATAL: a v4 key is shadowed by another key in the line")
    # the v4 keys must not steal an existing key either (reader: last match wins)
    pre = set(_regex_keymap(line3).keys())
    stolen = sorted(k for k in km4 if len(km4[k]) > len(_regex_keymap(line3).get(k, [])))
    print("NOTE v4 keys that add a NEW regex hit for an existing key: %s"
          % (sorted(set(stolen) & pre) or "none"))

    print("\nRTL must use: localparam LINE_LEN = 10'd%d;" % len(line4))
    print("RTL decoder windows (ci >= X && ci < Y) for the v4 fields:")
    rtl_win = {}
    for key, w in FIELDS_V4:
        s, e = value_window(line4, key, w)
        rtl_win[key] = (s, e)
        print("  %-3s : ci >= 10'd%d && ci < 10'd%d"
              % (key, s, e))

    # ---------------------------------------------------------------
    # self-check the v4 block against the PUBLISHED offsets (17.2)
    # ---------------------------------------------------------------
    bad = 0
    for key, (a, b) in sorted(PUB_V4.items()):
        s, e = value_window(line4, key, b - a)
        if (s, e) != (a, b):
            print("SELFCHECK FAIL (v4): %s at %d..%d, published %d..%d"
                  % (key, s, e, a, b))
            bad += 1
    if len(line4) != PUB_V4_LINE:
        print("SELFCHECK FAIL (v4): LINE_LEN %d (published %d)"
              % (len(line4), PUB_V4_LINE))
        bad += 1
    if (len(line4) - 2, len(line4) - 1) != (PUB_V4_CR, PUB_V4_LF):
        print("SELFCHECK FAIL (v4): CR/LF at %d/%d, published %d/%d"
              % (len(line4) - 2, len(line4) - 1, PUB_V4_CR, PUB_V4_LF))
        bad += 1
    if bad:
        raise SystemExit("FATAL: published v4 offsets not reproduced -> DO NOT "
                         "trust the v5 numbers either")
    print("\nSELFCHECK OK (v4): published offsets reproduced "
          "(CN 639 ... QH 799, CR 805, LF 806, LINE_LEN 807)\n")

    # ---------------------------------------------------------------
    # v5 line: v5 literals appended after the v4 block
    # ---------------------------------------------------------------
    v5_body = "".join(TPL_V5)
    line5 = v2[:-2] + v3_body + v4_body + v5_body + "\r\n"
    report("v5 (v2+v3+v4 prefix byte-identical + appended block)", line5, FIELDS_V5)
    assert line5[:len(line4) - 2] == line4[:-2], "prefix changed!"
    print("PREFIX CHECK OK (v5): first %d chars byte-identical to v4"
          % (len(line4) - 2))
    assert len(line5) <= 1023, "LINE_LEN %d exceeds the 10-bit ci window" % len(line5)
    print("LINE LIMIT OK (v5): LINE_LEN %d <= 1023 (10-bit ci)" % len(line5))
    for key, w in FIELDS_V5:
        value_window(line5, key, w)
    print("WINDOW CHECK OK (v5): all %d v5 fields have exactly the declared "
          "'x' placeholder count" % len(FIELDS_V5))

    km5 = _regex_keymap(line5)
    shadow = 0
    for key, w in FIELDS_V5:
        s, e = value_window(line5, key, w)
        occ = km5.get(key, [])
        if len(occ) != 1 or occ[0] != s:
            print("SHADOW: key %s: literal at %d but reader sees regex hits at %s"
                  % (key, s, occ))
            shadow += 1
    print("KEY SHADOW CHECK (v5): %d of %d v5 keys read unambiguously (%s)"
          % (len(FIELDS_V5) - shadow, len(FIELDS_V5),
             "OK" if shadow == 0 else "COLLISION"))
    if shadow:
        raise SystemExit("FATAL: a v5 key is shadowed by another key in the line")
    # a v5 key must not steal an existing key either (reader: last match wins)
    km4_pre = _regex_keymap(line4)
    stolen = sorted(k for k in km5
                    if k in km4_pre and len(km5[k]) > len(km4_pre[k]))
    print("NOTE v5 keys that add a NEW regex hit for an existing key: %s"
          % (stolen or "none"))
    if stolen:
        raise SystemExit("FATAL: v5 key(s) %s add regex hits -- the board reader "
                         "would overwrite an existing field" % stolen)

    print("\nRTL must use: localparam LINE_LEN = 10'd%d;" % len(line5))
    print("RTL decoder windows (ci >= X && ci < Y) for the v5 fields:")
    rtl_win = {}
    for key, w in FIELDS_V5:
        s, e = value_window(line5, key, w)
        rtl_win[key] = (s, e)
        print("  %-3s : ci >= 10'd%d && ci < 10'd%d"
              % (key, s, e))

    bad = 0
    for key, (a, b) in sorted(PUB_V5.items()):
        s, e = value_window(line5, key, b - a)
        if (s, e) != (a, b):
            print("SELFCHECK FAIL (v5): %s at %d..%d, published %d..%d"
                  % (key, s, e, a, b))
            bad += 1
    if len(line5) != PUB_V5_LINE:
        print("SELFCHECK FAIL (v5): LINE_LEN %d (published %d)"
              % (len(line5), PUB_V5_LINE))
        bad += 1
    if (len(line5) - 2, len(line5) - 1) != (PUB_V5_CR, PUB_V5_LF):
        print("SELFCHECK FAIL (v5): CR/LF at %d/%d, published %d/%d"
              % (len(line5) - 2, len(line5) - 1, PUB_V5_CR, PUB_V5_LF))
        bad += 1
    if bad:
        raise SystemExit("FATAL: published v5 offsets not reproduced")
    print("\nSELFCHECK OK (v5): published offsets reproduced "
          "(DV 809 ... SB 906, CR 914, LF 915, LINE_LEN 916)\n")

    # ---------------------------------------------------------------
    # cross-check against the RTL source itself: the v3/v4/v5 decoder lines in
    # rtl/app_status_uart.v must carry exactly these windows.
    #
    # NOTE (2026-09-27): the old version of this check matched
    # `... ) lc = hexd(...)` -- that shape disappeared when app_status_uart
    # was re-pipelined (two-stage sel_r/ch_r, see the timing fix in the RTL
    # header).  It therefore FAILED on the shipped RTL even before v5.  It now
    # parses the stage-1/stage-2 pair actually present in the RTL.
    # ---------------------------------------------------------------
    import os
    import re
    rtl = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "..", "rtl", "app_status_uart.v")
    rtl = os.path.normpath(rtl)
    # the RTL comments are UTF-8 Chinese; Windows' default (GBK) codec chokes
    src = open(rtl, "r", encoding="utf-8", errors="replace").read()
    # multi-char branches: ch_r[i] <= (ci >= A && ci < B) ? (hexd|hexq(...)) : ...
    pat = re.compile(r"\(ci >= 10'd(\d+) && ci < 10'd(\d+)\)\s*\?\s*"
                     r"\((hex[dcq])\((.*?)\)\)")
    seen = {}
    for m in pat.finditer(src):
        args = m.group(4)
        ks = re.search(r"sn_([a-z]{2})", args)
        if ks is None:
            continue
        key = ks.group(1).upper()
        bs = re.search(r"ci - 10'd(\d+)", args)
        base = int(bs.group(1)) if bs else int(m.group(1))
        seen[key] = (int(m.group(1)), int(m.group(2)), base)
    # single-char branches (EN/EO/VZ) use hexc with `ci ==`
    pat2 = re.compile(r"\(ci == 10'd(\d+)\)\s*\?\s*\((hexc)\([^)]*?sn_([a-z]{2})")
    for m in pat2.finditer(src):
        key = m.group(3).upper()
        seen.setdefault(key, (int(m.group(1)), int(m.group(1)) + 1,
                              int(m.group(1))))
    bad = 0
    for key, (s, e) in rtl_win.items():
        got = seen.get(key)
        if key in ("EN", "EO", "VZ"):
            if got is None or got[0] != s:
                print("RTL-CHECK FAIL: %s RTL window %s, computed %d" % (key, got, s))
                bad += 1
            continue
        if got is None or got[0] != s or got[1] != e or got[2] != s:
            print("RTL-CHECK FAIL: %s RTL (start,end,base)=%s, computed %d..%d"
                  % (key, got, s, e))
            bad += 1
    if bad:
        raise SystemExit("FATAL: RTL decoder windows do not match the computed "
                         "v5 offsets -> fix rtl/app_status_uart.v")
    print("RTL-CHECK OK (v5): every v5 decoder window in rtl/app_status_uart.v "
          "matches the computed offset (start/end/base)")
    # ...and the same for v3/v4 (regression: the v5 edit must not have moved them)
    for keys, name in ((FIELDS_V3, "v3"), (FIELDS_V4, "v4")):
        line_cur = line3 if name == "v3" else line4
        bad = 0
        for key, w in keys:
            s, e = value_window(line_cur, key, w)
            got = seen.get(key)
            if got is None or got[0] != s or got[2] != s:
                print("RTL-CHECK FAIL (%s): %s RTL %s, computed start %d"
                      % (name, key, got, s))
                bad += 1
        if bad:
            raise SystemExit("FATAL: %s decoder windows broken" % name)
    print("RTL-CHECK OK (v3/v4 regression): every v3/v4 decoder window still "
          "matches its published offset")

    # ---------------------------------------------------------------
    # v6 line: v6 literals appended after the v5 block
    # ---------------------------------------------------------------
    v6_body = "".join(TPL_V6)
    line6 = v2[:-2] + v3_body + v4_body + v5_body + v6_body + "\r\n"
    report("v6 (v2+v3+v4+v5 prefix byte-identical + appended block)", line6,
           FIELDS_V6)
    assert line6[:len(line5) - 2] == line5[:-2], "prefix changed!"
    print("PREFIX CHECK OK (v6): first %d chars byte-identical to v5"
          % (len(line5) - 2))
    assert len(line6) <= 1023, "LINE_LEN %d exceeds the 10-bit ci window" % len(line6)
    print("LINE LIMIT OK (v6): LINE_LEN %d <= 1023 (10-bit ci)" % len(line6))
    for key, w in FIELDS_V6:
        value_window(line6, key, w)
    print("WINDOW CHECK OK (v6): all %d v6 fields have exactly the declared "
          "'x' placeholder count" % len(FIELDS_V6))

    km6 = _regex_keymap(line6)
    shadow = 0
    for key, w in FIELDS_V6:
        s, e = value_window(line6, key, w)
        occ = km6.get(key, [])
        if len(occ) != 1 or occ[0] != s:
            print("SHADOW: key %s: literal at %d but reader sees regex hits at %s"
                  % (key, s, occ))
            shadow += 1
    print("KEY SHADOW CHECK (v6): %d of %d v6 keys read unambiguously (%s)"
          % (len(FIELDS_V6) - shadow, len(FIELDS_V6),
             "OK" if shadow == 0 else "COLLISION"))
    if shadow:
        raise SystemExit("FATAL: a v6 key is shadowed by another key in the line")
    # a v6 key must not steal an existing key either (reader: last match wins)
    km5_pre = _regex_keymap(line5)
    stolen = sorted(k for k in km6
                    if k in km5_pre and len(km6[k]) > len(km5_pre[k]))
    print("NOTE v6 keys that add a NEW regex hit for an existing key: %s"
          % (stolen or "none"))
    if stolen:
        raise SystemExit("FATAL: v6 key(s) %s add regex hits -- the board reader "
                         "would overwrite an existing field" % stolen)

    print("\nRTL must use: localparam LINE_LEN = 10'd%d;" % len(line6))
    print("RTL decoder windows (ci >= X && ci < Y) for the v6 fields:")
    rtl_win6 = {}
    for key, w in FIELDS_V6:
        s, e = value_window(line6, key, w)
        rtl_win6[key] = (s, e)
        print("  %-3s : ci >= 10'd%d && ci < 10'd%d"
              % (key, s, e))

    bad = 0
    for key, (a, b) in sorted(PUB_V6.items()):
        s, e = value_window(line6, key, b - a)
        if (s, e) != (a, b):
            print("SELFCHECK FAIL (v6): %s at %d..%d, published %d..%d"
                  % (key, s, e, a, b))
            bad += 1
    if len(line6) != PUB_V6_LINE:
        print("SELFCHECK FAIL (v6): LINE_LEN %d (published %d)"
              % (len(line6), PUB_V6_LINE))
        bad += 1
    if (len(line6) - 2, len(line6) - 1) != (PUB_V6_CR, PUB_V6_LF):
        print("SELFCHECK FAIL (v6): CR/LF at %d/%d, published %d/%d"
              % (len(line6) - 2, len(line6) - 1), PUB_V6_CR, PUB_V6_LF)
        bad += 1
    if bad:
        raise SystemExit("FATAL: published v6 offsets not reproduced")
    print("\nSELFCHECK OK (v6): published offsets reproduced "
          "(CV 918 ... CS 967, CR 969, LF 970, LINE_LEN 971)\n")

    # ...RTL cross-check for the v6 decoder windows (same parser as v5)
    bad = 0
    for key, (s, e) in rtl_win6.items():
        got = seen.get(key)
        if key == "CZ":
            if got is None or got[0] != s:
                print("RTL-CHECK FAIL (v6): CZ RTL window %s, computed %d"
                      % (got, s))
                bad += 1
            continue
        if got is None or got[0] != s or got[1] != e or got[2] != s:
            print("RTL-CHECK FAIL (v6): %s RTL (start,end,base)=%s, computed %d..%d"
                  % (key, got, s, e))
            bad += 1
    if bad:
        raise SystemExit("FATAL: RTL decoder windows do not match the computed "
                         "v6 offsets -> fix rtl/app_status_uart.v")
    print("RTL-CHECK OK (v6): every v6 decoder window in rtl/app_status_uart.v "
          "matches the computed offset (start/end/base)")
    # ...and the v5 windows must still be intact after the v6 edit
    bad = 0
    for key, w in FIELDS_V5:
        s, e = value_window(line5, key, w)
        got = seen.get(key)
        if key == "VZ":
            if got is None or got[0] != s:
                print("RTL-CHECK FAIL (v5 regression): VZ RTL %s, computed %d"
                      % (got, s))
                bad += 1
            continue
        if got is None or got[0] != s or got[2] != s:
            print("RTL-CHECK FAIL (v5 regression): %s RTL %s, computed start %d"
                  % (key, got, s))
            bad += 1
    if bad:
        raise SystemExit("FATAL: v5 decoder windows broken by the v6 edit")
    print("RTL-CHECK OK (v5 regression): every v5 decoder window still matches "
          "its published offset")

    # ---------------------------------------------------------------
    # v7 line: v7 literals appended after the v6 block
    #   RXP_DIAG v7 (2026-09-27): IP-identification sequence checker (udp_rx) +
    #   the non-UDP byte counter of the v6 checker (udp_split).
    # ---------------------------------------------------------------
    v7_body = "".join(TPL_V7)
    line7 = v2[:-2] + v3_body + v4_body + v5_body + v6_body + v7_body + "\r\n"
    report("v7 (v2+v3+v4+v5+v6 prefix byte-identical + appended block)", line7,
           FIELDS_V7)
    assert line7[:len(line6) - 2] == line6[:-2], "prefix changed!"
    print("PREFIX CHECK OK (v7): first %d chars byte-identical to v6"
          % (len(line6) - 2))
    assert len(line7) <= 1023, "LINE_LEN %d exceeds the 10-bit ci window" % len(line7)
    print("LINE LIMIT OK (v7): LINE_LEN %d <= 1023 (10-bit ci)" % len(line7))
    for key, w in FIELDS_V7:
        value_window(line7, key, w)
    print("WINDOW CHECK OK (v7): all %d v7 fields have exactly the declared "
          "'x' placeholder count" % len(FIELDS_V7))

    km7 = _regex_keymap(line7)
    shadow = 0
    for key, w in FIELDS_V7:
        s, e = value_window(line7, key, w)
        occ = km7.get(key, [])
        if len(occ) != 1 or occ[0] != s:
            print("SHADOW: key %s: literal at %d but reader sees regex hits at %s"
                  % (key, s, occ))
            shadow += 1
    print("KEY SHADOW CHECK (v7): %d of %d v7 keys read unambiguously (%s)"
          % (len(FIELDS_V7) - shadow, len(FIELDS_V7),
             "OK" if shadow == 0 else "COLLISION"))
    if shadow:
        raise SystemExit("FATAL: a v7 key is shadowed by another key in the line")
    # a v7 key must not steal an existing key either (reader: last match wins)
    km6_pre = _regex_keymap(line6)
    stolen = sorted(k for k in km7
                    if k in km6_pre and len(km7[k]) > len(km6_pre[k]))
    print("NOTE v7 keys that add a NEW regex hit for an existing key: %s"
          % (stolen or "none"))
    if stolen:
        raise SystemExit("FATAL: v7 key(s) %s add regex hits -- the board reader "
                         "would overwrite an existing field" % stolen)

    print("\nRTL must use: localparam LINE_LEN = 10'd%d;" % len(line7))
    print("RTL decoder windows (ci >= X && ci < Y) for the v7 fields:")
    rtl_win7 = {}
    for key, w in FIELDS_V7:
        s, e = value_window(line7, key, w)
        rtl_win7[key] = (s, e)
        print("  %-3s : ci >= 10'd%d && ci < 10'd%d"
              % (key, s, e))

    bad = 0
    for key, (a, b) in sorted(PUB_V7.items()):
        s, e = value_window(line7, key, b - a)
        if (s, e) != (a, b):
            print("SELFCHECK FAIL (v7): %s at %d..%d, published %d..%d"
                  % (key, s, e, a, b))
            bad += 1
    if len(line7) != PUB_V7_LINE:
        print("SELFCHECK FAIL (v7): LINE_LEN %d (published %d)"
              % (len(line7), PUB_V7_LINE))
        bad += 1
    if (len(line7) - 2, len(line7) - 1) != (PUB_V7_CR, PUB_V7_LF):
        print("SELFCHECK FAIL (v7): CR/LF at %d/%d, published %d/%d"
              % (len(line7) - 2, len(line7) - 1), PUB_V7_CR, PUB_V7_LF)
        bad += 1
    if bad:
        raise SystemExit("FATAL: published v7 offsets not reproduced")
    print("\nSELFCHECK OK (v7): published offsets reproduced "
          "(IV 973 ... NB 1013, CR 1017, LF 1018, LINE_LEN 1019)\n")

    # ...RTL cross-check for the v7 decoder windows (same parser as v5/v6)
    bad = 0
    for key, (s, e) in rtl_win7.items():
        got = seen.get(key)
        if got is None or got[0] != s or got[1] != e or got[2] != s:
            print("RTL-CHECK FAIL (v7): %s RTL (start,end,base)=%s, computed %d..%d"
                  % (key, got, s, e))
            bad += 1
    if bad:
        raise SystemExit("FATAL: RTL decoder windows do not match the computed "
                         "v7 offsets -> fix rtl/app_status_uart.v")
    print("RTL-CHECK OK (v7): every v7 decoder window in rtl/app_status_uart.v "
          "matches the computed offset (start/end/base)")
    # ...and the v6/v5/v4/v3 windows must still be intact after the v7 edit
    for keys, name, line_cur in ((FIELDS_V6, "v6", line6), (FIELDS_V5, "v5", line5),
                                 (FIELDS_V4, "v4", line4), (FIELDS_V3, "v3", line3)):
        bad = 0
        for key, w in keys:
            s, e = value_window(line_cur, key, w)
            got = seen.get(key)
            if got is None or got[0] != s or got[2] != s:
                print("RTL-CHECK FAIL (%s regression): %s RTL %s, computed start %d"
                      % (name, key, got, s))
                bad += 1
        if bad:
            raise SystemExit("FATAL: %s decoder windows broken by the v7 edit" % name)
    print("RTL-CHECK OK (v3/v4/v5/v6 regression): every earlier decoder window "
          "still matches its published offset")


if __name__ == "__main__":
    main()
