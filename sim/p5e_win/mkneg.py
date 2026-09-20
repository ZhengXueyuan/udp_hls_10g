# mkneg.py -- P5e negative control: rebuild the PRE-opener RTL (P5d-D2 state) in a
# COPY of rtl/ and show sim\p5e_win\tb_p5e_win.v FAILs the same gate (same convention
# as sim\p5d_d1\mkneg.py: rtl\ is read-only, copy before touching anything).
# The four holes reproduce the pre-P5e behaviour exactly:
#   op_beat    -> 0        : no 0-payload opener (frame first beat = first payload word)
#   ev guard   -> frm_wait : old restart condition (no seg_sent==0 term)
#   drop_pw    -> 0        : W3 delivers the in-presentation word (no drop)
#   ev_restart -> 0        : no collision priority (W3 always wins)
# Usage: python mkneg.py <neg_name>     (neg_name = prior)
import io
import os
import shutil
import sys

NEG = sys.argv[1] if len(sys.argv) > 1 else 'prior'
ROOT = 'D:/repo/ECO/udp_hls_10g'
NEGD = os.path.join(ROOT, 'sim', 'p5e_win', 'neg', NEG)
RTLD = os.path.join(NEGD, 'rtl')
B = chr(92)


def read(p, enc='utf-8'):
    with io.open(p, 'r', encoding=enc, errors='replace', newline='') as fh:
        return fh.read()


def write(p, s, enc='utf-8'):
    with io.open(p, 'w', encoding=enc, newline='') as fh:
        fh.write(s)


def copybin(a, b):
    with open(a, 'rb') as fh:
        d = fh.read()
    with open(b, 'wb') as fh:
        fh.write(d)


# ---- 1. copy rtl/ + the bat + the TB (paths repointed at the local copy) ----
if os.path.isdir(NEGD):
    shutil.rmtree(NEGD)
os.makedirs(RTLD)
for f in os.listdir(os.path.join(ROOT, 'rtl')):
    if f.endswith('.v'):
        copybin(os.path.join(ROOT, 'rtl', f), os.path.join(RTLD, f))
for f in ('run_tb_p5e_win.bat', 'tb_p5e_win.v'):
    copybin(os.path.join(ROOT, 'sim', 'p5e_win', f), os.path.join(NEGD, f))
s = read(os.path.join(ROOT, 'sim', 'p5e_win', 'run_tb_p5e_win.bat'), 'ascii')
s = s.replace('set RTL=' + ROOT.replace('/', B) + B + 'rtl',
              'set RTL=' + NEGD.replace('/', B) + B + 'rtl')
s = s.replace('set T5=' + ROOT.replace('/', B) + B + 'sim' + B + 'p5e_win',
              'set T5=' + NEGD.replace('/', B))
assert NEGD.replace('/', B) + B + 'rtl' in s and 'set T5=' + NEGD.replace('/', B) in s
write(os.path.join(NEGD, 'run_tb_p5e_win.bat'), s, 'ascii')

# ---- 2. the four single-line holes (exact anchors, no other edits) ----
p = os.path.join(RTLD, 'app_pattern.v')
s = read(p)
holes = [
    # opener removed = op_pend never set (op_beat stays 0, op_sent stays 0,
    # frm_inflight degenerates to the pre-P5e seg_sent != 0)
    ("                    op_pend  <= 1'b1;   // 新会话首帧同样以 opener 起",
     "                    op_pend  <= 1'b0;   // NEG: no opener"),
    ("                        op_pend <= 1'b1; op_sent <= 1'b0;",
     "                        op_pend <= 1'b0; op_sent <= 1'b0;   // NEG: no opener"),
    ("                op_pend  <= 1'b1; op_sent <= 1'b0;   // P5e: 同样以 opener 起帧",
     "                op_pend  <= 1'b0; op_sent <= 1'b0;   // NEG: no opener"),
    ("                if (!active || ((ev_slot == act_id) &&\n"
     "                                (frm_wait || (seg_sent == 12'd0)))) begin",
     "                if (!active || ((ev_slot == act_id) && frm_wait)) begin   // NEG: old guard"),
    ("    wire        drop_pw    = closing && pw_valid && (seg_sent == 12'd0);",
     "    wire        drop_pw    = 1'b0;   // NEG: no drop of the in-presentation word"),
    ("    wire        ev_restart = ev_up && (!active || ((ev_slot == act_id) &&\n"
     "                             (frm_wait || (seg_sent == 12'd0))));",
     "    wire        ev_restart = 1'b0;   // NEG: W3 always wins (pre-P5e)"),
]
for old, new in holes:
    assert old in s, 'anchor missing: ' + old[:60]
    s = s.replace(old, new, 1)
write(p, s)
print('%s: 4 holes punched in a copy of rtl/ (opener + guard + drop + collision priority removed)' % NEG)
