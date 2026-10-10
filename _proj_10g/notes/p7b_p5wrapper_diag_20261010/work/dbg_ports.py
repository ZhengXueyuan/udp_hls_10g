# -*- coding: utf-8 -*-
import re, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

def blank_comments(t):
    out = list(t)
    i = 0
    while i < len(t):
        if t.startswith('/*', i):
            j = t.find('*/', i + 2)
            j = len(t) - 2 if j < 0 else j
            for k in range(i, min(j + 2, len(t))):
                if out[k] != '\n':
                    out[k] = ' '
            i = j + 2
        elif t.startswith('//', i):
            j = t.find('\n', i)
            j = len(t) if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        else:
            i += 1
    return ''.join(out)

def skip_paren(t, k):
    d = 0
    while k < len(t):
        if t[k] == '(':
            d += 1
        elif t[k] == ')':
            d -= 1
            if d == 0:
                return k
        k += 1
    return len(t) - 1

pat_port = re.compile(r'\b(input|output|inout)\b\s*'
                      r'(?:wire|reg|signed|unsigned|logic)?\s*'
                      r'((?:\[[^\]]*\]\s*)*)'
                      r'([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)')

for f in [r'D:\repo\XCKU5PMini\udp_hls_10g\rtl\tx_arb.v']:
    t = blank_comments(open(f, encoding='utf-8', errors='replace').read())
    for m in re.finditer(r'\bmodule\s+([A-Za-z_]\w*)', t):
        name = m.group(1)
        k = m.end()
        while k < len(t) and t[k].isspace():
            k += 1
        if k < len(t) and t[k] == '#':
            p = t.find('(', k)
            k = skip_paren(t, p) + 1
            while k < len(t) and t[k].isspace():
                k += 1
        e = skip_paren(t, k)
        hdr = t[k:e + 1]
        print('MODULE', name, 'hdr_len', len(hdr))
        print(repr(hdr))
        d = {}
        for pm in pat_port.finditer(hdr):
            dr, br, names = pm.group(1), pm.group(2), pm.group(3)
            for nm in [x.strip() for x in names.split(',')]:
                if nm and nm not in d:
                    d[nm] = dr
        print('PARSED', d)
