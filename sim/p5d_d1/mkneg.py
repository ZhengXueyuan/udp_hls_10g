# mkneg.py -- P5d-D1 negative controls: break the RTL in a COPY and show the
# gate FAILs (same convention as sim/p5c_t4/mkneg.py: rtl/ is read-only, so
# copy it to a temp dir before touching anything).
# Usage: python mkneg.py <neg_name>   neg_name = neg_rst | neg_st
#   neg_rst : remove the rst_req term from tx_blk  -> D1b (abort window) must FAIL
#   neg_st  : force the ESTAB term to constant 1   -> D2  (residual window) must FAIL
import io
import os
import shutil
import sys

NEG = sys.argv[1]
ROOT = 'D:/repo/ECO/udp_hls_10g'
NEGD = os.path.join(ROOT, 'sim', 'p5d_d1neg', NEG)
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
for f in ('run_tb_p5d_d1.bat', 'tb_p5d_d1.v'):
    copybin(os.path.join(ROOT, 'sim', 'p5d_d1', f), os.path.join(NEGD, f))
s = read(os.path.join(ROOT, 'sim', 'p5d_d1', 'run_tb_p5d_d1.bat'), 'ascii')
s = s.replace('set RTL=' + ROOT.replace('/', B) + B + 'rtl',
              'set RTL=' + NEGD.replace('/', B) + B + 'rtl')
s = s.replace('set T5=' + ROOT.replace('/', B) + B + 'sim' + B + 'p5d_d1',
              'set T5=' + NEGD.replace('/', B))
assert NEGD.replace('/', B) + B + 'rtl' in s and 'set T5=' + NEGD.replace('/', B) in s
write(os.path.join(NEGD, 'run_tb_p5d_d1.bat'), s, 'ascii')

# ---- 2. the single-line hole ----
p = os.path.join(RTLD, 'tcp_tx_frame.v')
s = read(p)
if NEG == 'neg_rst':
    old = "wire [15:0] tx_blk = fin_req | fin_sent_r | rst_sent_r | rst_req;"
    new = "wire [15:0] tx_blk = fin_req | fin_sent_r | rst_sent_r;"
elif NEG == 'neg_st':
    old = "    wire        st_ok    = (rb_state == 4'd1);"
    new = "    wire        st_ok    = 1'b1;"
else:
    raise SystemExit('unknown neg: %s' % NEG)
assert old in s, 'anchor missing: ' + old
write(p, s.replace(old, new, 1))
print('%s: hole punched (%s -> %s)' % (NEG, old.strip(), new.strip()))
