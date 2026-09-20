# -*- coding: utf-8 -*-
"""静态自检: udp_split.v 内每个 wire 必须有驱动源 (inline '=', assign, 或例化输出)。
悬空 wire = z 是 P5e-T1 实测抓到的真 bug 之一 (pb_occ 未 assign)。"""
import io, re

src = io.open(r'rtl/udp_split.v', encoding='utf-8').read()
body = src[src.index('module udp_split #('):]

inline = set()   # wire x = ...;
pure = []        # wire x;
for m in re.finditer(r'^\s*wire\s*(\[[^\]]*\])?\s*([^;]+);', body, re.M):
    for part in m.group(2).split(','):
        part = part.strip()
        if '=' in part:
            nm = part.split('=')[0].strip()
            inline.add(nm)
        elif part:
            pure.append(part)

assigns = set(m.group(1) for m in re.finditer(r'\bassign\s+([A-Za-z_]\w*)', body))
conn = set(m.group(1) for m in re.finditer(r'\.\w+\s*\(\s*([A-Za-z_]\w*)\s*\)', body))

missing = [n for n in sorted(set(pure)) if n not in assigns and n not in conn]
print('pure wire decls :', len(set(pure)))
print('inline-assigned :', len(inline))
print('undriven wires  :', missing if missing else 'NONE')
