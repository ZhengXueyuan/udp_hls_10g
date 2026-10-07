"""collect_matrix.py -- two-column extraction for the P4 matrix (regression agent, R1 round).

Column A: per-gate EXIT + the gatebrief tail lines out of the runner's own matrix log.
Column B: each gate's private work-dir console log (the gate's own stdout/stderr).

usage: python collect_matrix.py <work_dir> <matrix_log>
pure read-only.
"""
import io, os, re, sys

def main(work, log):
    txt = io.open(log, 'r', encoding='utf-8', errors='replace').read()
    # split into per-gate blocks
    blocks = re.split(r'^=== GATE ', txt, flags=re.M)[1:]
    print('== Column A: runner matrix log, %d gate blocks ==' % len(blocks))
    out = []
    for b in blocks:
        head = b.split('\n', 1)[0]
        name = head.split(' ')[0]
        m = re.search(r'^EXIT=(\d+)$', b, flags=re.M)
        ex = m.group(1) if m else '?'
        # gatebrief output = lines after the EXIT= line up to the '---' separator
        gb = []
        mm = re.search(r'^EXIT=\d+\n(.*?)^---$', b, flags=re.M | re.S)
        if mm:
            gb = [l for l in mm.group(1).split('\n') if l.strip()]
        out.append((name, ex, gb))
    for name, ex, gb in out:
        print('GATE %-12s EXIT=%s' % (name, ex))
        for l in gb:
            print('    A| %s' % l)
    print()
    print('== Column B: per-gate console (gate stdout) ==')
    for name, ex, gb in out:
        d = os.path.join(work, name)
        c = os.path.join(d, '_gate_console.log')
        print('---- %s (%s)' % (name, d))
        if os.path.isfile(c):
            lines = io.open(c, 'r', encoding='utf-8', errors='replace').read().split('\n')
            tail = [l for l in lines if l.strip()][-8:]
            for l in tail:
                print('    B| %s' % l)
        else:
            print('    B| (no console log)')
    # summary
    hdr = re.search(r'^gates run\s*:.*$', txt, flags=re.M)
    fails = re.search(r'^gates failed\s*:.*$', txt, flags=re.M)
    verd = re.search(r'^VERDICT:.*$', txt, flags=re.M)
    dig = re.findall(r'^DIGEST_\w+=.*$', txt, flags=re.M)
    print()
    print('== summary ==')
    for m in (hdr, fails, verd):
        if m:
            print('   ', m.group(0))
    for d in dig:
        print('   ', d)

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
