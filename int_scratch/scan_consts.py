# 独立审查: 扫 rtl/*.v + board/*.v 里所有"像时间常数"的数字字面量, 标出哪些带 DP_156MHZ 守卫
import io, os, re, sys, glob
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# 哪些模块在 P6b 里搬到 dp_clk (156.25MHz): 从 wrapper 的例化 .clk(dp_clk) 抽
wrap = io.open('board/wrapper_p4.v', encoding='utf-8', errors='replace').read().split('\n')
inst_clk = {}
cur = None
for l in wrap:
    m = re.match(r'^\s*(\w+)\s+(\w+)\s*\(', l)
    if m and m.group(1) not in ('if', 'else', 'begin', 'always', 'case', 'for', 'assign'):
        cur = m.group(2)
        inst_clk.setdefault(cur, None)
    if cur:
        m2 = re.search(r'\.clk\s*\(\s*(\w+)\s*\)', l)
        if m2:
            inst_clk[cur] = m2.group(1)
        if re.match(r'^\s*\);', l):
            cur = None

num = re.compile(r"\b\d[\d_]{4,}\b")
rows = []
for f in sorted(glob.glob('rtl/*.v')) + ['board/uart_dbg.v']:
    src = io.open(f, encoding='utf-8', errors='replace').read().split('\n')
    depth = 0
    for i, l in enumerate(src):
        if '`ifdef DP_156MHZ' in l:
            depth += 1
        if '`endif' in l and depth > 0:
            depth -= 1
        for m in num.finditer(l):
            v = int(m.group(0).replace('_', ''))
            if v < 10000:
                continue
            rows.append((f, i + 1, m.group(0), depth > 0, l.strip()[:80]))
print('%-26s %-6s %-14s %-10s %s' % ('file', 'line', 'value', 'DP_156MHZ?', 'text'))
for r in rows:
    print('%-26s %-6d %-14s %-10s %s' % (r[0], r[1], r[2], 'YES' if r[3] else '**NO**', r[4]))
print()
print('=== wrapper 里各例化的 clk 域 ===')
for k, v in sorted(inst_clk.items()):
    print('  %-22s %s' % (k, v))
