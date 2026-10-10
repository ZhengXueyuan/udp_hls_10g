# -*- coding: utf-8 -*-
"""同族普查 v2 (只读): wrapper_p4.v 纯别名方向判定 + 浮空网清单。
修 v1 的模块头解析 (函数式参数 #(...)) 与行号映射 (注释替换保长度)。"""
import os, re, glob, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
ROOT = r'D:\repo\XCKU5PMini\udp_hls_10g'
WRAP = os.path.join(ROOT, 'board', 'wrapper_p4.v')
raw = open(WRAP, 'r', encoding='utf-8', errors='replace').read()

def blank_comments(t):
    """把注释替换成等长空白 (换行保留) => 偏移与 raw 一一对应"""
    out = list(t)
    for m in re.finditer(r'/\*', t):
        pass
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

text = blank_comments(raw)

def skip_paren(t, k):
    """t[k]=='(' -> 返回匹配 ')' 的下标"""
    depth = 0
    while k < len(t):
        if t[k] == '(':
            depth += 1
        elif t[k] == ')':
            depth -= 1
            if depth == 0:
                return k
        k += 1
    return len(t) - 1

def line_of(off):
    return raw.count('\n', 0, off) + 1

# ---------------- 端口方向表 ----------------
pat_port = re.compile(r'\b(input|output|inout)\b\s*'
                      r'(?:wire|reg|signed|unsigned|logic)?\s*'
                      r'((?:\[[^\]]*\]\s*)*)'
                      r'([A-Za-z_]\w*(?:\s*,\s*(?!(?:input|output|inout|wire|reg|signed|unsigned|logic)\b)[A-Za-z_]\w*)*)')

def collect_ports(t):
    out = {}
    for m in re.finditer(r'\bmodule\s+([A-Za-z_]\w*)', t):
        name = m.group(1)
        k = m.end()
        while k < len(t) and t[k].isspace():
            k += 1
        if k < len(t) and t[k] == '#':
            p = t.find('(', k)
            if p < 0:
                continue
            k = skip_paren(t, p) + 1
            while k < len(t) and t[k].isspace():
                k += 1
        if k >= len(t) or t[k] != '(':
            continue
        e = skip_paren(t, k)
        hdr = t[k:e + 1]
        endm = t.find('endmodule', e)
        body = t[e:endm if endm > 0 else len(t)]
        d = out.setdefault(name, {})
        for pm in pat_port.finditer(hdr + '\n' + body):
            dr = pm.group(1)
            for nm in [x.strip() for x in pm.group(3).split(',')]:
                if nm and nm not in d:
                    d[nm] = dr
    return out

srcfiles = sorted(glob.glob(os.path.join(ROOT, 'rtl', '*.v'))) + \
           sorted(glob.glob(os.path.join(ROOT, 'board', '*.v'))) + \
           sorted(glob.glob(os.path.join(ROOT, 'hls', 'slowstack_prj', 'solution1', 'syn', 'verilog', '*.v')))
portmap = {}
for f in srcfiles:
    t = blank_comments(open(f, 'r', encoding='utf-8', errors='replace').read())
    for k, v in collect_ports(t).items():
        portmap.setdefault(k, {}).update({a: b for a, b in v.items() if a not in portmap.get(k, {})})
print('# 端口方向表: %d 模块 / %d 源文件' % (len(portmap), len(srcfiles)))
# --- 自校验 (解析器可信度) ---
CHECKS = [('tx_arb', 'm_axis_tvalid', 'output'), ('tx_arb', 'm_axis_tready', 'input'),
          ('tx_arb', 's_fast_tready', 'output'),
          ('mac_tx_64', 's_axis_tready', 'output'), ('mac_tx_64', 's_axis_tvalid', 'input'),
          ('tcp_tx_frame', 'm_axis_tready', 'input'), ('tcp_tx_frame', 'm_axis_tvalid', 'output'),
          ('app_ctrl', 'dbg_c0_state', 'output'), ('app_ctrl', 'rst_req', 'output'),
          ('app_pattern', 'm_tready', 'input'), ('app_pattern', 'stat_tx_bytes', 'output'),
          ('axis_pipe', 's_ready', 'output'), ('axis_pipe', 'm_valid', 'output'),
          ('fifo_sync', 'full', 'output'), ('clk_gen_p6b', 'clk_dp', 'output'),
          ('fifo_async', 'full', 'output'), ('tcb', 'rb_state', 'output'),
          ('app_udp_pattern', 'm_tvalid', 'output')]
bad = 0
for mod, port, exp in CHECKS:
    got = portmap.get(mod, {}).get(port, '?')
    if got != exp:
        bad += 1
        print('# SELFCHECK-FAIL %s.%s = %s (期望 %s)' % (mod, port, got, exp))
print('# 自校验: %d/%d 条端口方向与源码一致' % (len(CHECKS) - bad, len(CHECKS)))

def active_lines(t, macros):
    act = {}
    stack = []
    off = 0
    for line in t.split('\n'):
        s = line.strip()
        act[off] = all(x[0] for x in stack)
        if s.startswith('`ifdef'):
            mac = s.split()[1] if len(s.split()) > 1 else ''
            stack.append((mac in macros, True))
        elif s.startswith('`ifndef'):
            mac = s.split()[1] if len(s.split()) > 1 else ''
            stack.append((mac not in macros, True))
        elif s.startswith('`else'):
            if stack:
                taken, first = stack.pop()
                stack.append(((not taken) if first else False, False))
        elif s.startswith('`endif'):
            if stack:
                stack.pop()
        off += len(line) + 1
    return act

inst_hdr = re.compile(r'(?m)^[ \t]*([A-Za-z_]\w*)\s*(#)?\s*\(?')
def find_insts(t, act):
    res = []
    for m in re.finditer(r'(?m)^[ \t]*([A-Za-z_]\w*)[ \t]*', t):
        mod = m.group(1)
        if mod not in portmap or mod == 'module':
            continue
        ls = t.rfind('\n', 0, m.start()) + 1
        if not act.get(ls, True):
            continue
        k = m.end()
        if k < len(t) and t[k] == '#':
            p = t.find('(', k)
            if p < 0:
                continue
            k = skip_paren(t, p) + 1
        while k < len(t) and t[k].isspace() and t[k] != '\n':
            k += 1
        nm = re.match(r'([A-Za-z_]\w*)\s*\(', t[k:])
        if not nm:
            if os.environ.get('DBG2'):
                print('# DBG2-REJ1 %s line=%d after_param=%r' % (mod, line_of(m.start()), t[k:k + 30]))
            continue
        inst = nm.group(1)
        p = t.find('(', k + nm.end() - 1)
        e = skip_paren(t, p)
        body = t[p:e + 1]
        conns = {}
        for cm in re.finditer(r'\.(\w+)\s*\(\s*([^()]*?)\s*\)', body):
            conns[cm.group(1)] = cm.group(2).strip()
        if conns:
            res.append((mod, inst, conns, m.start()))
        elif os.environ.get('DBG2'):
            print('# DBG2-EMPTY %s %s line=%d body0=%r' % (mod, inst, line_of(m.start()), t[p:p + 40]))
    # 去重 (同一偏移)
    seen = set()
    out = []
    for r in res:
        if r[3] in seen:
            continue
        seen.add(r[3])
        out.append(r)
    if os.environ.get('DBG'):
        for mod, inst, conns, off in out:
            print('# DBG-INST %-18s %-16s conns=%3d line=%d' % (mod, inst, len(conns), line_of(off)))
    return out

assign_re = re.compile(r'(?m)^[ \t]*assign\s+([A-Za-z_]\w*)\s*=\s*([^;]+);')

def decls(t):
    """wrapper 自己的 wire/reg 声明 (名字集合)"""
    wires, regs = set(), set()
    for m in re.finditer(r'(?m)^[ \t]*(wire|reg)\b([^;]*);', t):
        kind = m.group(1)
        tail = m.group(2)
        tail = re.sub(r'\[[^\]]*\]', ' ', tail)
        for nm in re.findall(r'[A-Za-z_]\w*', tail):
            (wires if kind == 'wire' else regs).add(nm)
    return wires, regs

def analyze(cfg, macros):
    act = active_lines(text, macros)
    insts = find_insts(text, act)
    ndrv, ncons = {}, {}
    for mod, inst, conns, off in insts:
        pm = portmap.get(mod, {})
        for port, net in conns.items():
            if not re.fullmatch(r'[A-Za-z_]\w*', net):
                continue
            d = pm.get(port, '?')
            if d == 'output':
                ndrv.setdefault(net, []).append('%s.%s' % (inst, port))
            ncons.setdefault(net, []).append('%s.%s(%s)' % (inst, port, d))
    aliases = []
    for m in assign_re.finditer(text):
        ls = text.rfind('\n', 0, m.start()) + 1
        if not act.get(ls, True):
            continue
        lhs, rhs = m.group(1), m.group(2).strip()
        if re.fullmatch(r'[A-Za-z_]\w*', rhs):
            aliases.append((lhs, rhs, m.start()))
    expr_drv = {}
    for m in assign_re.finditer(text):
        ls = text.rfind('\n', 0, m.start()) + 1
        if not act.get(ls, True):
            continue
        lhs, rhs = m.group(1), m.group(2).strip()
        if not re.fullmatch(r'[A-Za-z_]\w*', rhs):
            expr_drv[lhs] = set(re.findall(r'[A-Za-z_]\w*', rhs))
    alias_lhs = {l for l, r, _ in aliases}
    # 浮空传播 fixpoint (纯别名图)
    badidx = set()
    ch = True
    while ch:
        ch = False
        for i, (l, r, _) in enumerate(aliases):
            if i in badidx:
                continue
            if r in ndrv:
                continue
            if any((l2 == r and j not in badidx) for j, (l2, r2, _) in enumerate(aliases)):
                continue
            badidx.add(i); ch = True
    # 输入端口: 无驱动的输入代价
    wires, regs = decls(text)
    # (a) `wire X = expr;` / `reg X = ...` 形式的**声明即驱动**
    initw = set()
    for m in re.finditer(r'(?m)^[ \t]*(?:wire|reg)\b([^;=]*?)\s*=', text):
        ls = text.rfind('\n', 0, m.start()) + 1
        if not act.get(ls, True):
            continue
        tail = re.sub(r'\[[^\]]*\]', ' ', m.group(1))
        for nm in re.findall(r'[A-Za-z_]\w*', tail):
            initw.add(nm)
    # (b) 拼接 LHS `assign {a,b,c} = rhs;` 的成员 = 被驱动
    concat_lhs = {}
    for m in re.finditer(r'(?m)^[ \t]*assign\s*\{([^}]*)\}\s*=\s*([^;]+);', text):
        ls = text.rfind('\n', 0, m.start()) + 1
        if not act.get(ls, True):
            continue
        for nm in re.findall(r'[A-Za-z_]\w*', m.group(1)):
            concat_lhs[nm] = set(re.findall(r'[A-Za-z_]\w*', m.group(2)))
    print('\n===== 配置 %s : macros=%s =====' % (cfg, sorted(macros)))
    print('# 例化 %d 个 | 端口 output 驱动网 %d | 纯别名 assign %d 条 | wrapper wire %d / reg %d' %
          (len(insts), len(ndrv), len(aliases), len(wires), len(regs)))
    nrev = nok = ncov = 0
    print('\n-- 表A: 纯别名逐条方向判定 --')
    print('%-24s %-24s %6s  %-30s %-30s %s' % ('LHS(X)', 'RHS(Y)', '行号', 'X 的端口驱动者', 'Y 的端口驱动者', '判定'))
    def isdrv(n):
        return (n in ndrv) or (n in initw) or (n in expr_drv) or (n in concat_lhs) or (n in alias_lhs) or (n in regs)
    for i, (l, r, off) in enumerate(aliases):
        dl, dr = ndrv.get(l, []), ndrv.get(r, [])
        rdrv = isdrv(r) and not (r in alias_lhs and any(l2 == r and j in badidx for j, (l2, r2, _) in enumerate(aliases)))
        extra = []
        if r in initw: extra.append('wire/reg 声明即驱动')
        if r in expr_drv: extra.append('expr assign')
        if r in concat_lhs: extra.append('concat LHS')
        if r in regs: extra.append('reg')
        if dl and not rdrv:
            v = '**反向** (X 已被端口驱动, Y 无人驱动)'; nrev += 1
        elif rdrv and not dl:
            v = '正确'; nok += 1
        elif dl and rdrv:
            v = '**多驱动** (两端都有驱动)'; nrev += 1
        elif i in badidx:
            v = '未定/浮空 (Y 的驱动不可追 => X 悬空)'; ncov += 1
        else:
            v = '未定'; ncov += 1
        xf = ' (X 悬空)' if (i in badidx and v.startswith('未定')) else ''
        print('%-24s %-24s %6d  %-30s %-30s %s%s' % (l, r, line_of(off), ','.join(dl) or (','.join(extra) if extra else '-'), ','.join(dr) or (','.join(extra) if extra else '-'), v, xf))
    print('# 表A 小计: 正确 %d | 反向/多驱动 %d | 未定 %d' % (nok, nrev, ncov))
    # --- 表B: 浮空网 (wire 类, 无端口驱动/无 assign) ---
    floatn = []
    for n in sorted(set(list(ndrv.keys()) + list(ncons.keys()) + list(alias_lhs) + list(expr_drv.keys()) + list(wires)
                        + list(initw) + list(concat_lhs) + list(regs))):
        if n in ndrv or n in alias_lhs or n in expr_drv or n in initw or n in concat_lhs:
            continue
        if n in regs:
            continue           # reg 不可能 Z (可能 X -> 见表C)
        if n in regs and n not in wires:
            continue           # reg 不可能 Z (但可能 X -> 见表C)
        floatn.append(n)
    fl = set(n for n in floatn)
    print('\n-- 表B: 浮空网 (wrapper 作用域 wire, 无端口驱动且无 assign) = %d 条 --' % len(floatn))
    for n in floatn:
        print('   FLOAT %-22s 端口连接=%-58s' % (n, ','.join(ncons.get(n, [])) or '(无端口, 仅声明)'))
    print('\n-- 表C: 二阶 (RHS 引用浮空网的 assign; 含 reg 的 X 传播源) --')
    nc = 0
    for lhs, refs in sorted(expr_drv.items()):
        b = refs & fl
        if b:
            nc += 1
            print('   PROP %-22s <- %s' % (lhs, ','.join(sorted(b))))
    print('# 表C 计 %d 条' % nc)
    return dict(n_alias=len(aliases), ok=nok, rev=nrev, und=ncov, nfloat=len(floatn), nprop=nc)

res = {}
for cfg, mac in [('A_default_appmode', {'APP_MODE'}),
                 ('G_appmode_dp156', {'APP_MODE', 'DP_156MHZ'})]:
    res[cfg] = analyze(cfg, mac)
# 交叉核对: 全文件 assign 别名条数 (不判 ifdef)
total_alias = len([1 for m in assign_re.finditer(text) if re.fullmatch(r'[A-Za-z_]\w*', m.group(2).strip())])
print('\n# 交叉核对: 全文件 (未过 ifdef) 纯别名 assign = %d 条; 配置 A 计 %d, G 计 %d + 被 ifdef 关掉的分支'
      % (total_alias, res['A_default_appmode']['n_alias'], res['G_appmode_dp156']['n_alias']))
