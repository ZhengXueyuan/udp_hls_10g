# -*- coding: utf-8 -*-
"""同族普查: wrapper_p4.v 的 纯别名方向判定 + 无驱动网普查 (只读)。
判据 = "无驱动 / 方向写反的别名网"。方向判定追到被例化模块的端口表 (input/output)。
输出两张表: (A) 纯 assign 别名逐条判定; (B) 全 wrapper 浮空网 (无真驱动) 清单。
"""
import os, re, glob, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

ROOT = r'D:\repo\XCKU5PMini\udp_hls_10g'
WRAP = os.path.join(ROOT, 'board', 'wrapper_p4.v')

def strip_comments(t):
    t = re.sub(r'/\*.*?\*/', ' ', t, flags=re.S)
    # 行注释: 去掉 // 之后 (但别吃掉字符串; 本工程 RTL 无字符串)
    t = re.sub(r'//[^\n]*', '', t)
    return t

# ---------------- 1. 模块端口方向表 ----------------
pat_mod = re.compile(r'\bmodule\s+(\w+)\s*(#\s*\([^)]*\))?\s*\(', re.S)
pat_port = re.compile(r'\b(input|output|inout)\b\s*'
                      r'(?:wire|reg|signed|unsigned|logic)?\s*'
                      r'((?:\[[^\]]*\]\s*)*)'
                      r'([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)')

def collect_ports(text):
    """module name -> {port: dir}"""
    out = {}
    for m in pat_mod.finditer(text):
        name = m.group(1)
        # 头部 port list 结束处: 找匹配的 ')'
        i = m.end() - 1
        depth = 0
        j = i
        while j < len(text):
            if text[j] == '(' : depth += 1
            elif text[j] == ')':
                depth -= 1
                if depth == 0: break
            j += 1
        body = text[j: text.find('endmodule', j)]
        # 头 + 体内 ANSI/非 ANSI 声明都收 (端口只声明一次)
        hdr = text[m.end(): j+1]
        d = {}
        for pm in pat_port.finditer(hdr + '\n' + body):
            dr = pm.group(1)
            names = [x.strip() for x in pm.group(3).split(',')]
            for n in names:
                if n and n not in d:
                    d[n] = dr
        out[name] = d
    return out

srcfiles = sorted(glob.glob(os.path.join(ROOT, 'rtl', '*.v'))) + \
           sorted(glob.glob(os.path.join(ROOT, 'board', '*.v'))) + \
           sorted(glob.glob(os.path.join(ROOT, 'hls', 'slowstack_prj', 'solution1', 'syn', 'verilog', '*.v')))
portmap = {}
for f in srcfiles:
    try:
        t = strip_comments(open(f, 'r', encoding='utf-8', errors='replace').read())
    except Exception:
        continue
    for k, v in collect_ports(t).items():
        if k in portmap:            # 同名模块重复 (HLS vs rtl) -> 合并 (方向应一致)
            portmap[k].update(v)
        else:
            portmap[k] = dict(v)
print('# 端口方向表: %d 个模块 (来自 %d 个源文件)' % (len(portmap), len(srcfiles)))
if 'wrapper_p4' in portmap:
    print('# wrapper_p4 端口表 %d 条' % len(portmap['wrapper_p4']))

raw = open(WRAP, 'r', encoding='utf-8', errors='replace').read()
text = strip_comments(raw)

# ---------------- 2. ifdef 求值 (两配置) ----------------
CONFIGS = {
    'A_default_appmode': {'APP_MODE'},                    # 本门实际配置 (p5_wrapper 门)
    'G_appmode_dp156':   {'APP_MODE', 'DP_156MHZ'},       # 板那一支 (DP 轴)
}
def active_lines(text, macros):
    """返回 {行起始偏移: True/False} —— 用逐行扫描 ifdef/ifndef/else/endif"""
    act = {}
    stack = []
    off = 0
    for line in text.split('\n'):
        s = line.strip()
        cur = all(x[0] for x in stack)
        act[off] = cur
        if s.startswith('`ifdef'):
            mac = s.split()[1] if len(s.split()) > 1 else ''
            stack.append((mac in macros, True))
        elif s.startswith('`ifndef'):
            mac = s.split()[1] if len(s.split()) > 1 else ''
            stack.append((mac not in macros, True))
        elif s.startswith('`elsif'):
            if stack:
                taken, _ = stack.pop()
                mac = s.split()[1] if len(s.split()) > 1 else ''
                stack.append(((mac in macros), taken))
        elif s.startswith('`else'):
            if stack:
                taken, first = stack.pop()
                stack.append(((not taken) if first else False, False))
        elif s.startswith('`endif'):
            if stack: stack.pop()
        off += len(line) + 1
    return act

# ---------------- 3. 例化 -> 端口连接 (net) ----------------
inst_re = re.compile(r'(?m)^[ \t]*(\w+)\s*(#\s*\([^;]*?\))?\s*(\w+)\s*\(')
conn_re = re.compile(r'\.(\w+)\s*\(\s*([^()]*?)\s*\)')

def find_insts(text, act):
    out = []          # (module, inst, {port: net}, offset)
    for m in inst_re.finditer(text):
        mod = m.group(1)
        if mod not in portmap or mod in ('module',):
            continue
        if not act.get(m.start() - (m.start() - text.rfind('\n', 0, m.start()) - 1), True):
            # 该行是否 active
            line_start = text.rfind('\n', 0, m.start()) + 1
            if not act.get(line_start, True):
                continue
        i = m.end() - 1
        depth = 0
        j = i
        while j < len(text):
            if text[j] == '(': depth += 1
            elif text[j] == ')':
                depth -= 1
                if depth == 0: break
            j += 1
        body = text[i:j+1]
        conns = {}
        for cm in conn_re.finditer(body):
            conns[cm.group(1)] = cm.group(2).strip()
        if conns:
            out.append((mod, m.group(3), conns, m.start()))
    return out

# ---------------- 4. assign 解析 ----------------
assign_re = re.compile(r'(?m)^[ \t]*assign\s+([A-Za-z_]\w*)\s*=\s*([^;]+);')

def analyze(cfg_name, macros):
    act = active_lines(text, macros)
    insts = find_insts(text, act)
    # net -> [ (inst, port, dir) ]
    ndrv = {}
    for mod, inst, conns, off in insts:
        pm = portmap.get(mod, {})
        for port, net in conns.items():
            if not re.fullmatch(r'[A-Za-z_]\w*', net):
                continue
            d = pm.get(port, '?')
            if d == 'output':
                ndrv.setdefault(net, []).append('%s.%s(out)' % (inst, port))
    aliases = []
    for m in assign_re.finditer(text):
        line_start = text.rfind('\n', 0, m.start()) + 1
        if not act.get(line_start, True):
            continue
        lhs, rhs = m.group(1), m.group(2).strip()
        if re.fullmatch(r'[A-Za-z_]\w*', rhs):
            aliases.append((lhs, rhs, raw[:m.start()].count('\n') + 1))
    # 浮空传播 (fixpoint): 一个 assign 的 LHS "有驱动" 但其值 = RHS 的浮空性
    float_assign = set()      # rhs 浮空的 assign 的下标
    changed = True
    while changed:
        changed = False
        for idx, (lhs, rhs, ln) in enumerate(aliases):
            if idx in float_assign:
                continue
            rhs_has_port_driver = rhs in ndrv
            rhs_from_alias = any((l == rhs and i not in float_assign) for i, (l, r, _) in enumerate(aliases))
            if not rhs_has_port_driver and not rhs_from_alias:
                float_assign.add(idx)
                changed = True
    print('\n===== 配置 %s : macros=%s =====' % (cfg_name, sorted(macros)))
    print('# 例化 %d 个; 被例化模块 output 驱动网 %d 个; 纯别名 assign %d 条' %
          (len(insts), len(ndrv), len(aliases)))
    print('%-28s %-28s %-6s %-34s %-34s %s' % ('LHS(X)', 'RHS(Y)', '行号', 'X 的驱动者', 'Y 的驱动者', '判定'))
    nrev = nok = nund = nconf = 0
    for lhs, rhs, ln in aliases:
        dup = ndrv.get(lhs, [])
        dwn = ndrv.get(rhs, [])
        if dup and not dwn:
            verdict = '反向(多驱动+悬空)'; nrev += 1
        elif dwn and not dup:
            verdict = '正确'; nok += 1
        elif dup and dwn:
            verdict = '两端都有端口驱动(多驱动冲突?)'; nconf += 1
        else:
            verdict = '两端都无端口驱动(悬空)'; nund += 1
        print('%-28s %-28s %-6d %-34s %-34s %s' % (lhs, rhs, ln, ','.join(dup) or '-', ','.join(dwn) or '-', verdict))
    print('# 小计: 正确 %d / 反向(多驱动+悬空) %d / 多驱动冲突 %d / 两端悬空 %d' % (nok, nrev, nconf, nund))
    # ---------------- 浮空网清单 ----------------
    # 所有出现在 instance 连接里的网 (排除常数/literal) + 所有 alias 的 LHS/RHS
    allnets = set()
    for mod, inst, conns, off in insts:
        for port, net in conns.items():
            if re.fullmatch(r'[A-Za-z_]\w*', net):
                allnets.add(net)
    for lhs, rhs, _ in aliases:
        allnets.add(lhs); allnets.add(rhs)
    # 非别名 assign 的 LHS + rhs 引用
    expr_drv = {}
    for m in assign_re.finditer(text):
        line_start = text.rfind('\n', 0, m.start()) + 1
        if not act.get(line_start, True):
            continue
        lhs, rhs = m.group(1), m.group(2).strip()
        if re.fullmatch(r'[A-Za-z_]\w*', rhs):
            continue
        expr_drv.setdefault(lhs, set(re.findall(r'[A-Za-z_]\w*', rhs)))
    alias_lhs = {l for l, r, _ in aliases}
    fl = set()
    for n in sorted(allnets):
        if n in ndrv:          continue
        if n in alias_lhs:     continue
        if n in expr_drv:      continue
        fl.add(n)
    print('# 浮空网 (无端口驱动 / 无 assign, 但出现在连接或别名里): %d 条' % len(fl))
    for n in sorted(fl):
        users = []
        for mod, inst, conns, off in insts:
            for port, net in conns.items():
                if net == n:
                    users.append('%s.%s(%s)' % (inst, port, portmap.get(mod, {}).get(port, '?')))
        print('   FLOAT %-24s 消费者=%s' % (n, ','.join(users) or '-'))
    # 二阶: 由浮空网推导出来的信号 (X 传播风险)
    prop = []
    for lhs, refs in expr_drv.items():
        bad = refs & (fl | set(x for x in alias_lhs if any(l == x and i in float_assign for i, (l, r, _) in enumerate(aliases))))
        if bad:
            prop.append((lhs, sorted(bad)))
    print('# 二阶 (RHS 引用了浮空网的 assign): %d 条' % len(prop))
    for lhs, bad in prop:
        print('   PROP %-24s <- %s' % (lhs, ','.join(bad)))
    return len(aliases), nok, nrev, nconf, nund, len(fl)

for cfg, mac in CONFIGS.items():
    analyze(cfg, mac)
