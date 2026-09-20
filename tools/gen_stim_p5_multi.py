#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""gen_stim_p5_multi.py — P5d D5 **多连接并发门** (tb/tb_p5_multi.v) 脚本 + 判据

用法:
  python gen_stim_p5_multi.py <simdir> <case>          # 生成 multi_cmds.memh
  python gen_stim_p5_multi.py <simdir> <case> check    # 校验 resp_p5_multi.memh

case: main / neg_wq / neg_mgn / neg_mgn0 / known_idle_fifo

本门回答三个问题 (P5d 的三条修法各一条) + 三个负向对照 + 一个"长只写后首读"正向守卫:
  D4 分池: app 在建连**之前**写 app_ctrl 0x0C = WIN_POOL/N ⇒ 三条连接各拿
     WIN_POOL/N, Σwinq == WIN_POOL (由构造); 池不空 (conn0 不拿满池)。
     neg_wq = 写回 0xC000 (旧默认) ⇒ 判据 ① 必须 FAIL (conn0 拿满, conn1/2 得 0)。
  H-fix 动态接受裕度: 裕度 = min(4096, 10550/N) 且 >= 3328。
     neg_mgn  = 裕度强制 4096 (旧常量, N=3 时 N*M > 10550) ⇒ 判据 ④ 必须 FAIL。
     neg_mgn0 = 裕度强制 0 ⇒ 判据 ⑦ (漂移: 窗塌陷期顺序段被拒 + 对端回卷) 必须 FAIL。
  D5 门本身: 3 连接并发大流量 (慢消费者顶 frame_fifo) + 两连接并发 close。
  known_idle_fifo: **曾**被判为 frame_fifo "预存缺陷"的形态 (从复位起停消费 ⇒ 首读
     发生在长时间只写之后)。P5d 复核 (sim/p5d_multi/p5dmech 的 MEMMON 桩) 证伪:
     成因是 TB 脚本 `22: sink_rate = sa;` 的**阻塞赋值**在时钟沿同一步改 readiness
     (坑 3), 读侧恒等 dout(N) === mem[rptr(N)] 只在那一拍被破坏; 改成分级非阻塞后
     同一 RTL 下 miss 8 -> 0。本 case 保留为**正向守卫**: 该形态必须逐字节精确,
     失配即 FAIL (旧记录 "必须复现" 已作废)。

判据 (逐条落在 resp_p5_multi.memh 的 MUL* 行上):
  ① 分池: 每连接 winq == WIN_POOL/N (所有快照) + wq_cap_r 回读 == WIN_POOL/N
  ② 池守恒: **逐拍** Σwinq + pool == WIN_POOL (MULINV pool_bad == 0)
  ③ 物理零丢帧: mac_rx_64.stat_drop == 0 (MULMDROP)
  ④ 物理界 (契约式, TL 的 H-fix 公式, 稳态): MULINV phys_bad == 0
     (Σwinq + N*margin + Δ + U + SEG_MAX <= 65536; 另有接受界推导式 real_bad)
  ⑤ 并发 close: conn1/conn2 各恰 1 FIN, conn0 0 FIN, 无 RST, FIN 的 dst/src MAC 正确
  ⑥ 无 WAIT 超时 (MULTO 一条不许有) + MULDONE tmo=0
  ⑦ 漂移判据 (H-fix 的**目的**): tcp_rx stat_drop_seq == 0 且对端回卷 rewind == 0
  ⑧ 数据完整性: sink 每 tid 字节流**严格逐字节**连续 (miss == 0) + tkeep/空字合法
     + 字节守恒 (Σ 板侧 rcv_nxt 推进 == Σ sink 消费 + occ)
     (旧版允许 "<= 8B/每个 stall->resume 边沿" 的宽容界已撤销: 那 8B 是 TB 激励
      竞争 (坑 3) 造成的假故障, 修正后本判据 = 严格 0 失配)
  ⑨ C12 静态镜像: wrapper 的 acc_margin_of 表项 == TB 的镜像表项, 且对 N=1..3
     满足 N*margin <= 10550 与 margin >= 3328 (从**源码**解析, 独立于行为)
退出码: 0 全过 (main/probe), 1 有 FAIL (负向对照**必须**为 1)
"""
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)

# ---- 与 tb/tb_p5_multi.v / wrapper_p4.v 同源的常量 ----
NCONN = 3
WIN_POOL = 0xC000
WQ_CAP = WIN_POOL // NCONN          # 0x4000 = 16384
FIFO_BYTES = 65536
DELTA = 2816
U_FRM = 1518
SEG_MAX = 1500
BUDGET_PHYS = FIFO_BYTES - WIN_POOL - DELTA - U_FRM - SEG_MAX   # 10550
MGN_MIN = 3328                      # Δ + 512 余量 (表的下界钳位)
FLOOD_PER_CONN = 24576              # 每连接注水预算 (字节)
FLOOD_TOTAL = FLOOD_PER_CONN * NCONN
# (原 NRESUME = 2 已删除: 判据 ⑧ 从 "<= 8B/边沿" 收紧为严格 0 ——
#  那 8B 是 TB 激励竞争 (阻塞写在时钟沿改 readiness) 的假故障, 见 check() ⑧ 注释)

# 每连接身份 (与 tb_p5_multi.v 的 init 块**同式**)
def conn(c):
    return dict(pip=0xC0A86401 + c, bip=0xC0A86402 + c,
                pport=0x3039 + c, mport=0x1F90 + c,
                pmac=bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66 + c]),
                iss=0x12345678 + (c << 12), pcis=0x20000000 + (c << 20))

WSCALE = 8
CFG_PEER_WND = 0xC000
PC_WND = 0x4000
WRAPPER_SRC = os.path.join(ROOT, 'board', 'wrapper_p4.v')
TB_SRC = os.path.join(ROOT, 'tb', 'tb_p5_multi.v')


# =====================================================================
# 脚本生成
# =====================================================================
class Script:
    def __init__(self, case):
        self.case = case
        self.lines = []

    def w(self, op, a=0, b=0, c=0, d=0, e=0, f=0, g=0, h=0, i=0):
        self.lines.append([op, a, b, c, d, e, f, g, h, i])

    def pc_table(self, c):
        d = conn(c)
        m = d['pmac']
        self.w(11, c, d['pport'], d['mport'], d['bip'], d['pip'],
               int.from_bytes(m[:2], 'big'), int.from_bytes(m[2:], 'big'),
               PC_WND, 1)
        self.w(17, c, d['pcis'] + 1)

    def cfg_add(self, slot, c):
        d = conn(c)
        m = d['pmac']
        self.w(18, slot, d['pcis'] + 1, d['iss'] + 1)
        self.w(4, slot, 0, WSCALE, d['pip'], d['bip'],
               (d['pport'] << 16) | d['mport'],
               int.from_bytes(m[:2], 'big'), int.from_bytes(m[2:], 'big'),
               CFG_PEER_WND)

    def text(self):
        return ''.join(' '.join(str(x) for x in ln) + '\n' for ln in self.lines)


def build(case):
    s = Script(case)
    # ---- D4: 分池必须在建连**之前**写 (窗口不可撤销) ----
    s.w(7, 0x0C, WIN_POOL if case == 'neg_wq' else WQ_CAP)
    for c in range(NCONN):
        s.pc_table(c)
    for c in range(NCONN):
        s.cfg_add(c, c)
    s.w(1, 2000)                     # 等 ev_up/init 收尾
    s.w(8, 0x0C)                     # 回读 wq_cap_r
    s.w(12)                          # 快照 A: 建连后 (winq/rcv_wnd 分池语义)

    # ---- 阶段 0: **消费者从复位起就停** (rate 复位值 = 0) ----
    # ⚠️ 这里曾有一处"将就": 先 `22 1` 让消费侧跑起来再停 —— 为的是绕开当时被
    # 归因于 frame_fifo 的"预存缺陷" (长只写后首读吐 1 重复字 + 丢 1 字)。P5d
    # 复核证伪该归因 (真因 = TB 脚本阻塞写, 坑 3; 见文件头 known_idle_fifo 说明)
    # ⇒ 绕行已撤销: 本门主动考"首读发生在长时间只写之后"这一形态 (第一条对端
    # 数据到达时 sink 一直停 ⇒ frame_fifo 先被灌满, 然后才恢复消费)。
    for c in range(NCONN):
        s.w(20, c, FLOOD_PER_CONN)
    s.w(24, 4096)                    # 至少发出 4KB (证明注水在跑)
    s.w(1, 20000)
    # ---- 阶段 1: 消费者继续停 ⇒ 三条连接把 frame_fifo 顶起来 (窗口收缩) ----
    s.w(22, 0)                       # sink 停 (显式重申; 复位值同)
    s.w(1, 200000)                   # 让它跑到窗关/停等
    s.w(12)                          # 快照 B: 顶住后的池/占用/窗

    # ---- 阶段 2: 慢排空 ⇒ 窗口重开 (wu) ⇒ 对端恢复 (闭环活性) ----
    s.w(22, 8)
    s.w(24, 16384)
    s.w(1, 100000)
    s.w(12)                          # 快照 C
    # ---- 阶段 3: 再次停 (第二个窗关) 然后快速排空 ----
    s.w(22, 0)
    s.w(1, 200000)
    s.w(22, 1)
    s.w(25, 1500000)                 # 等"静默" (预算空/在队空/已发==已接受)
    s.w(12)                          # 快照 D
    s.w(22, 1)                       # 全速排空
    s.w(23, FLOOD_TOTAL)             # 等 sink 排空 (字节守恒的另一半)
    s.w(12)                          # 快照 E: 洪水后 (关闭前)

    # ---- 阶段 4: 两连接**并发** close (判据 ⑤) ----
    # 用 CMD 写 (0x06) 而不是 app_pattern: 本门不实例化 app_pattern。
    # 两条背靠背 (间隔 ~5 拍) ⇒ 两个连接在同一个扫描轮内进入关闭流程。
    s.w(7, 0x06, (1 << 4) | 1)
    s.w(7, 0x06, (1 << 4) | 2)
    s.w(3, 2)                        # 等 2 个 FIN 上线
    s.w(1, 30000)                    # 观察窗: 不得再冒 FIN/RST (互不串扰/不重复)
    s.w(12)                          # 快照 F: 最终
    return s


def build_probe(case):
    """known_idle_fifo: **长只写后首读** 正向守卫 —— 从复位起 sink 一直停, 恢复后必须逐字节精确。

    历史: 该形态曾被判为 frame_fifo/tcp_echo 的"预存缺陷"(必错位 8B)。P5d 复核
    (sim/p5d_multi/p5dmech 的 MEMMON 桩 + A/B) 证伪: 读侧恒等 dout(N) === mem[rptr(N)]
    的破坏发生在 TB 脚本 `22: sink_rate = sa;` **阻塞写**的同一时间步 (就绪链
    eco2_tready → eco_tready → fwd_rd → rd_ok 组合变), 每个这样的边沿 1 拍; 该行改
    成分级非阻塞后同一 RTL 下 miss 8 -> 0。故本 case 的期望输出改为 **miss == 0**
    (正向守卫: 该形态永久回归)。它是 main 用例"阶段 2/3 恢复消费"的最严版本:
    整个洪水期只写不读 (FIFO 顶满), 之后才全速排空。
    """
    s = Script(case)
    s.w(7, 0x0C, WQ_CAP)
    for c in range(NCONN):
        s.pc_table(c)
    for c in range(NCONN):
        s.cfg_add(c, c)
    s.w(1, 2000)
    s.w(22, 0)                       # **从复位起就停** ⇒ 第一次读在大量只写之后
    for c in range(NCONN):
        s.w(20, c, FLOOD_PER_CONN)
    s.w(24, 4096)
    s.w(1, 200000)
    s.w(12)
    s.w(22, 1)                       # 恢复消费 (首次读在此之后) —— 必须逐字节精确
    s.w(1, 400000)
    s.w(12)
    return s


# =====================================================================
# resp 解析
# =====================================================================
def parse_resp(path):
    pools, wqs, invs, clss, peers, cfgs, tcbs, regs = [], [], [], [], [], [], {}, {}
    info = dict(pools=pools, wqs=wqs, invs=invs, clss=clss, peers=peers,
                cfgs=cfgs, tcbs=tcbs, regs=regs, to=[], cmd=[], mdrop=None,
                mac=None, rx7=None, fl=None, sink=None, done=None, tx=None,
                frm=None)
    for line in open(path, errors='replace'):
        p = line.split()
        if not p:
            continue
        k = p[0]
        if k == 'MULPOOL':
            d = dict(x.split('=') for x in p[1:])
            pools.append({a: int(b) for a, b in d.items()})
        elif k == 'MULWQ':
            d = dict(x.split('=') for x in p[2:])
            wqs.append((int(p[1]), {a: int(b) for a, b in d.items()}))
        elif k == 'MULINV':
            d = dict(x.split('=') for x in p[1:])
            invs.append({a: int(b) for a, b in d.items()})
        elif k == 'MULCLS':
            d = dict(x.split('=') for x in p[2:])
            clss.append((int(p[1]), {a: int(b) for a, b in d.items()}))
        elif k == 'MULCLSUM':
            d = dict(x.split('=') for x in p[1:])
            info['clsum'] = {a: int(b) for a, b in d.items()}
        elif k == 'MULPEER':
            d = dict(x.split('=') for x in p[2:])
            peers.append((int(p[1]), {a: int(b, 16) for a, b in d.items()}))
        elif k == 'MULCFG':
            d = dict(x.split('=') for x in p[1:])
            cfgs.append({a: int(b) for a, b in d.items()})
        elif k == 'MULTCB':
            tcbs[int(p[1])] = [int(x, 16) for x in p[2:]]
        elif k == 'MULREG':
            regs[int(p[1])] = int(p[2], 16)
        elif k == 'MULTO':
            info['to'].append(line.strip())
        elif k == 'MULCMD':
            info['cmd'].append([int(x) for x in p[1:]])
        elif k == 'MULMDROP':
            info['mdrop'] = int(p[1])
        elif k == 'MULMAC':
            info['mac'] = dict(x.split('=') for x in p[1:])
        elif k == 'MULRX7':
            info['rx7'] = {a: int(b) for a, b in
                           (x.split('=') for x in p[1:])}
        elif k == 'MULFL':
            info['fl'] = {a: int(b) for a, b in (x.split('=') for x in p[1:])}
        elif k == 'MULSINK':
            info['sink'] = {a: int(b) for a, b in (x.split('=') for x in p[1:])}
        elif k == 'MULTX':
            info['tx'] = {a: int(b) for a, b in (x.split('=') for x in p[1:])}
        elif k == 'MULFRM':
            info['frm'] = {a: int(b) for a, b in (x.split('=') for x in p[1:])}
        elif k == 'MULSTAT':
            info['atx'] = {a: int(b) for a, b in (x.split('=') for x in p[1:])}
        elif k == 'MULDONE':
            info['done'] = {a: int(b) for a, b in (x.split('=') for x in p[1:])}
        elif line.startswith('P5MUL DONE'):
            info['logdone'] = line.strip()
    return info


# =====================================================================
# 源码解析 (C12 镜像 + 物理预算)
# =====================================================================
def parse_margin_table(path, fn_name='acc_margin_of'):
    """从源码里抽出 acc_margin_of 的 (条件, 值) 表项 (顺序文本扫描)。

    返回 [(kind, arg, value)]: kind = 'le' (n<=arg) / 'eq' (n==arg) / 'ge'(else)。
    解析失败返回 None ⇒ 判据必须报错 (不允许静默跳过)。
    """
    try:
        txt = open(path, errors='replace').read()
    except OSError:
        return None
    m = re.search(r'function\s*\[15:0\]\s*%s\b(.*?)endfunction' % fn_name,
                  txt, re.S)
    if not m:
        return None
    body = m.group(1)
    # 值字面量: 16'd4096 (十进制) / 16'h1F90 (十六进制) 都要认
    VAL = r'=\s*16.([dh])([0-9A-Fa-f]+)'
    out = []
    for line in body.splitlines():
        if line.strip().startswith('//'):
            continue
        mm = re.search(r'n\s*<=\s*(?:\d+)?(?:.\s*d)?(\d+).*?' + VAL, line)
        if mm:
            out.append(('le', int(mm.group(1)), int(mm.group(3),
                        16 if mm.group(2) == 'h' else 10)))
            continue
        mm = re.search(r'n\s*==\s*(?:\d+)?(?:.\s*d)?(\d+).*?' + VAL, line)
        if mm:
            out.append(('eq', int(mm.group(1)), int(mm.group(3),
                        16 if mm.group(2) == 'h' else 10)))
            continue
        mm = re.search(r'else\s+%s\s*' % fn_name + VAL, line)
        if mm:
            out.append(('ge', 0, int(mm.group(2),
                        16 if mm.group(1) == 'h' else 10)))
    return out if out else None


def table_eval(tbl, n):
    """按表求 N=n 的裕度 (与 RTL/TB 的 if/else 链同语义)。"""
    for kind, arg, val in tbl:
        if kind == 'le' and n <= arg:
            return val
        if kind == 'eq' and n == arg:
            return val
        if kind == 'ge':
            return val
    return None


# =====================================================================
# 判据
# =====================================================================
class Ck:
    def __init__(self):
        self.fails = []
        self.n = 0

    def ok(self, cond, what):
        self.n += 1
        if not cond:
            self.fails.append(what)
            print('FAIL %s' % what)
        return cond

    def eq(self, got, want, what):
        return self.ok(got == want, '%s: got %s want %s' % (what, got, want))

    def le(self, got, want, what):
        return self.ok(got <= want, '%s: got %s > %s' % (what, got, want))


def check_probe(info):
    """known_idle_fifo 守卫: 长只写后首读必须**逐字节精确** (旧 "必须复现" 已作废)。

    附带字节守恒 (Σ rcv_nxt 推进 == Σ sink 消费 + occ): 该形态下 sink 常来不及读完,
    守恒式仍必须成立 (occ 吸收差额)。
    """
    ck = Ck()
    sk = info['sink']
    mm = sk['miss'] if sk else -1
    ck.eq(mm, 0,
          'PROBE: 长只写后首读必须逐字节精确 (miss==0) —— 非 0 即 TB 激励竞争复现 '
          '(先查 tb_p5_multi.v 是否有新的阻塞写命令) 或读侧真缺陷')
    ck.eq(sk['kaerr'] if sk else -1, 0, 'PROBE: tkeep 合法性')
    ck.eq(sk['evfrm'] if sk else -1, 0, 'PROBE: 空字计数')
    acc = 0
    for c in range(NCONN):
        t = info['tcbs'].get(c)
        if not t:
            ck.ok(False, 'PROBE: 缺 conn%d 的 MULTCB 行' % c)
            continue
        acc += (t[0] - (conn(c)['pcis'] + 1)) & 0xFFFFFFFF
    occ = info['pools'][-1]['occ'] if info['pools'] else -1
    sink_sum = (sk['bytes0'] + sk['bytes1'] + sk['bytes2']) if sk else 0
    ck.eq(sink_sum + occ, acc, 'PROBE: 字节守恒 Σ已接受 == Σ已消费 + occ')
    print('  [probe] 失配字节=%d kaerr=%s evfrm=%s sink=%d occ=%d accepted=%d'
          % (mm, sk['kaerr'] if sk else '?', sk['evfrm'] if sk else '?',
             sink_sum, occ, acc))
    return ck


def check(info, case):
    ck = Ck()
    print('== P5d multi check: case=%s ==' % case)
    N = NCONN
    pools = info['pools']
    if not pools:
        ck.ok(False, 'resp 缺 MULPOOL 行 (快照缺失 — 判据不允许静默跳过)')
        return ck

    # ---- ⑨ 静态镜像 + 物理预算 (源码级, 独立于行为) ----
    wtbl = parse_margin_table(WRAPPER_SRC)
    ttbl = parse_margin_table(TB_SRC)
    if wtbl is None:
        ck.ok(False, '无法从 %s 解析 acc_margin_of 表 (不允许静默跳过)' % WRAPPER_SRC)
    if ttbl is None:
        ck.ok(False, '无法从 %s 解析 acc_margin_of 表 (不允许静默跳过)' % TB_SRC)
    if wtbl and ttbl:
        # wrapper 的**行为表** = TB 的镜像表 (TB 的 ifdef 负向分支名字不同, 只在
        # main 情形比对; 负向情形由行为判据负责)
        wvals = [v for _, _, v in wtbl]
        tvals = [v for _, _, v in ttbl]
        if case == 'main':
            ck.eq(wvals, tvals, 'C12: TB 裕度镜像 == wrapper 表 (逐项)')
            for n in range(1, N + 1):
                v = table_eval(wtbl, n)
                ck.ok(v is not None, 'wrapper 表对 N=%d 未给出值' % n)
                if v is not None:
                    ck.ok(n * v <= BUDGET_PHYS,
                          'wrapper 表 N=%d: %d*%d=%d > 物理预算 %d'
                          % (n, n, v, n * v, BUDGET_PHYS))
                    ck.ok(v >= MGN_MIN,
                          'wrapper 表 N=%d 的值 %d < 下界 %d (漂移覆盖不住)'
                          % (n, v, MGN_MIN))
        print('  裕度表: wrapper=%s TB=%s (N=1..%d -> %s)'
              % (wvals, tvals, N, [table_eval(wtbl, n) for n in range(1, 4)]))

    # ---- ⑨b 仿真里的实际裕度 == 表 (确认门按表跑) ----
    cfg = info['cfgs'][-1] if info['cfgs'] else None
    if cfg is None:
        ck.ok(False, 'resp 缺 MULCFG 行')
    else:
        n_est = max(1, cfg['n_estab'])
        if case == 'main':
            exp = table_eval(wtbl, n_est) if wtbl else None
            ck.eq(cfg['acc_margin'], exp,
                  'MULCFG acc_margin == 表(N=%d)' % n_est)
        print('  MULCFG acc_margin=%d n_estab=%d wq_cap=0x%04x'
              % (cfg['acc_margin'], cfg['n_estab'], cfg['wq_cap']))

    # ---- ① 分池 (D4) ----
    wq_final = [(c, d) for c, d in info['wqs']]
    want_cap = WQ_CAP if case != 'neg_wq' else WIN_POOL
    cap_lbl = 'WIN_POOL/N=0x%04x' % WQ_CAP if case != 'neg_wq' else               'WIN_POOL/N=0x%04x (neg_wq 被写成 0xC000 ⇒ 本条必须 FAIL)' % WQ_CAP
    for c, d in wq_final:
        ck.ok(d['winq'] == want_cap,
              '① 连接 %d winq=0x%04x != %s' % (c, d['winq'], cap_lbl))
        ck.le(d['rcv_wnd'], max(d['winq'], 0),
              '① 连接 %d 通告窗 %d > 配额 %d' % (c, d['rcv_wnd'], d['winq']))
    # ①b wq_cap_r 寄存器回读 (写进去的值必须读回同一个)
    want_reg = WQ_CAP if case != 'neg_wq' else WIN_POOL
    ck.eq(info['regs'].get(0x0C, -1), want_reg,
          '① wq_cap_r (0x0C) 回读 == 写入值')
    for i, d in enumerate(info['invs']):
        pass
    print('  ① 分池: %s' % [(c, d['winq'], d['rcv_wnd']) for c, d in wq_final])

    # ---- ② 池守恒 (逐拍) ----
    for i, d in enumerate(pools):
        ck.eq(d['pool'] + d['sum_winq'], WIN_POOL,
              '② 快照%d 池守恒 pool+Σwinq' % i)
    for i, d in enumerate(info['invs']):
        ck.eq(d['pool_bad'], 0, '② 快照%d 逐拍池守恒违反次数' % i)
    # ---- ①b 分池上限 (逐拍) ----
    for i, d in enumerate(info['invs']):
        ck.eq(d['cap_bad'], 0, '① 快照%d 逐拍分池上限违反次数' % i)

    # ---- ③ 物理零丢帧 ----
    ck.eq(info['mdrop'], 0, '③ mac_rx_64.stat_drop (物理丢帧数)')
    print('  ③ mac_drop=%d occ_max=%d mac_frames=%s'
          % (info['mdrop'], pools[-1]['occ_max'],
             info['mac'].get('frames') if info['mac'] else '?'))

    # ---- ④ 物理界 ----
    for i, d in enumerate(info['invs']):
        ck.eq(d['phys_bad'], 0,
              '④ 快照%d 契约物理界 (Σwinq+N*M+Δ+U+SEG) 违反次数' % i)
        ck.eq(d['real_bad'], 0,
              '④ 快照%d 接受界物理界 (occ+Σ当前窗+N*M+U+SEG) 违反次数' % i)
    print('  ④ 契约界峰值=%d 物理界峰值=%d (FIFO=%d, occ_max=%d)'
          % (info['invs'][-1]['real_max'], info['invs'][-1]['real_max'],
             FIFO_BYTES, pools[-1]['occ_max']))
    print('  [注] "occ+Σ通告窗=%d" 的瞬时值不能当判据: 通告窗是 TCB 寄存器值, 滞后'
          '占用 <=1 个扫描轮 (256 拍) ⇒ occ 与未收回的旧窗会同时计入 (双重计数)。'
          '判据用的是接受界推导 (见 tb_p5_multi.v 的 inv_phys 注释)。'
          % (pools[-1]['occ'] + pools[-1]['sum_wnd']))
    for i, d in enumerate(pools):
        n_est = max(d['n_estab'], 0)
        mgn = cfg['acc_margin'] if cfg else 0
        # 快照点的裕度按快照的 ESTAB 数复算 (裕度是 ESTAB 数的函数)
        mgn_s = table_eval(wtbl, n_est) if wtbl else mgn
        # 契约式 (TL 的 H-fix 公式): Σwinq + N*margin + Δ + U + SEG_MAX <= FIFO
        tot = (d['sum_winq'] + n_est * mgn_s + DELTA + U_FRM + SEG_MAX)
        ck.le(tot, FIFO_BYTES,
              '④ 快照%d 契约界复算 Σwinq=%d N=%d M=%d -> %d'
              % (i, d['sum_winq'], n_est, mgn_s, tot))
    # 建连瞬态的违反 = 只报告 (判据语义见 tb_p5_multi.v 的 inv_phys_viol 注释)
    tr = [d['phys_tran'] for d in info['invs']]
    if tr and tr[-1] != 0:
        print('  [注] 建连瞬态物理界违反 %d 拍 (裕度尚未随 ESTAB 数收敛; 非判据)' % tr[-1])

    # ---- ⑤ 并发 close ----
    cls = dict(info['clss'])
    if len(cls) < NCONN:
        ck.ok(False, '⑤ resp 缺 MULCLS 行 (判据不允许静默跳过)')
    else:
        ck.eq(cls[1]['fin'], 1, '⑤ conn1 恰 1 FIN')
        ck.eq(cls[2]['fin'], 1, '⑤ conn2 恰 1 FIN')
        ck.eq(cls[0]['fin'], 0, '⑤ conn0 (未关闭) 的 FIN 数')
        for c in range(NCONN):
            ck.eq(cls[c]['rst'], 0, '⑤ conn%d 不得有 RST' % c)
            ck.eq(cls[c]['rst_sent'], 0, '⑤ conn%d rst_sent 标志' % c)
        ck.eq(cls[1]['fin_sent'], 1, '⑤ conn1 fast path fin_sent')
        ck.eq(cls[2]['fin_sent'], 1, '⑤ conn2 fast path fin_sent')
        cs = info.get('clsum', {})
        ck.eq(cs.get('fin_macbad', 1), 0, '⑤ FIN 帧 dst MAC 串扰数')
        ck.eq(cs.get('fin_smacbad', 1), 0, '⑤ FIN 帧 src MAC 错数')
        print('  ⑤ close: %s' % [(c, cls[c]['fin'], cls[c]['rst']) for c in range(NCONN)])

    # ---- ⑥ 无超时 ----
    ck.eq(len(info['to']), 0, '⑥ WAIT 超时行数 (%s)' % (info['to'][:3],))
    ck.ok(info.get('done') is not None and info['done'].get('tmo') == 0,
          '⑥ MULDONE tmo=0 (got %s)' % (info.get('done'),))

    # ---- ⑦ 漂移判据 (H-fix 的目的) ----
    rx7 = info['rx7']
    fl = info['fl']
    if rx7 is None or fl is None:
        ck.ok(False, '⑦ resp 缺 MULRX7/MULFL 行')
    else:
        ck.eq(rx7['seq'], 0, '⑦ tcp_rx stat_drop_seq (窗塌陷拒收的顺序/重复段)')
        ck.eq(fl['rewind'], 0, '⑦ 对端 go-back-N 回卷重传次数')
        ck.eq(fl['tx_bytes'], FLOOD_TOTAL, '⑦ 注水总量 == 预算 (全发完)')
        ck.eq(rx7['nonmatch'], 0, '⑦ tcp_rx 头/状态/标志等拒收 (非窗口类)')
        ck.eq(rx7['ipcsum'], 0, '⑦ IP 校验和错帧数')
        ck.eq(rx7['crc'], 0, '⑦ FCS 错帧数')
        print('  ⑦ drift: seq=%d rewind=%d tx_bytes=%d pass=%d ack=%d'
              % (rx7['seq'], fl['rewind'], fl['tx_bytes'], rx7['pass'], rx7['ack']))

    # ---- ⑧ 数据完整性 ----
    sk = info['sink']
    if sk is None:
        ck.ok(False, '⑧ resp 缺 MULSINK 行')
    else:
        # ⑧ sink 字节流连续性 —— **严格逐字节** (miss == 0)。
        # 旧版此处曾放宽为 "<= 8B/每个 stall->resume 边沿", 理由是当时判定的
        # frame_fifo/tcp_echo "预存缺陷" (长只写后续读吐 1 重复字 + 丢 1 字)。
        # P5d 复核已证伪该归因: 那是 TB 脚本 `22: sink_rate = sa;` 阻塞写在时钟沿
        # 同一步改 readiness 造成的 (工程坑 3; 见 tb_p5_multi.v 的分级落地节 +
        # sim/p5d_multi/p5dmech 的 MEMMON 桩), RTL 读侧恒等 dout(N) === mem[rptr(N)]
        # 无缺陷。⇒ 宽容界撤销: 任何非 0 失配 = FAIL (TB 竞争复现 或 真缺陷)。
        ck.eq(sk['miss'], 0,
              '⑧ sink 逐 tid 字节流不连续字节数 (严格 0; 非 0 = TB 竞争复现或读侧缺陷)')
        ck.eq(sk['kaerr'], 0, '⑧ sink tkeep 非法次数')
        ck.eq(sk['evfrm'], 0, '⑧ sink 空字次数')
    # 守恒: Σ(rcv_nxt 推进) == Σ(sink 消费) + occ
    acc = 0
    for c in range(NCONN):
        t = info['tcbs'].get(c)
        if not t:
            ck.ok(False, '⑧ 缺 conn%d 的 MULTCB 行' % c)
            continue
        acc += (t[0] - (conn(c)['pcis'] + 1)) & 0xFFFFFFFF
    sink_sum = (sk['bytes0'] + sk['bytes1'] + sk['bytes2']) if sk else 0
    occ = pools[-1]['occ']
    ck.eq(sink_sum + occ, acc, '⑧ 字节守恒 Σ已接受 == Σ已消费 + occ')
    print('  ⑧ 完整性: sink=%d occ=%d accepted=%d miss=%d' % (sink_sum, occ, acc, sk['miss'] if sk else -1))

    # ---- 负向对照: 判据必须响 ----
    if case == 'neg_wq':
        ck.ok(any(d['winq'] != WQ_CAP for _, d in wq_final),
              'NEG: 反向对照必须让 ① FAIL (无连接拿满池) — 门有鉴别力')
        print('  [neg_wq] 期望 ① FAIL: winq=%s' % [(c, d['winq']) for c, d in wq_final])
    if case == 'neg_mgn':
        ck.ok(any(d['phys_bad'] != 0 for d in info['invs']),
              'NEG: 裕度 4096@N=3 必须让 ④ FAIL (物理界超 1738B)')
        print('  [neg_mgn] phys_bad=%s occ_max=%d'
              % ([d['phys_bad'] for d in info['invs']], pools[-1]['occ_max']))
    if case == 'neg_mgn0':
        fired = (rx7 is not None and rx7['seq'] != 0) or \
                (fl is not None and fl['rewind'] != 0)
        ck.ok(fired, 'NEG: 裕度 0 必须让 ⑦ FAIL (顺序段被窗塌陷拒收/回卷重传)')
        print('  [neg_mgn0] 期望 ⑦ FAIL: seq=%s rewind=%s'
              % (rx7['seq'] if rx7 else '?', fl['rewind'] if fl else '?'))

    print('== P5d multi: %d checks, %d FAIL ==' % (ck.n, len(ck.fails)))
    for f in ck.fails[:10]:
        print('   - %s' % f)
    return ck


# =====================================================================
def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    simdir, case = sys.argv[1], sys.argv[2]
    if case not in ('main', 'neg_wq', 'neg_mgn', 'neg_mgn0', 'known_idle_fifo'):
        print('unknown case %s' % case)
        return 2
    if len(sys.argv) > 3 and sys.argv[3] == 'check':
        info = parse_resp(os.path.join(simdir, 'resp_p5_multi.memh'))
        ck = check_probe(info) if case == 'known_idle_fifo' else check(info, case)
        return 0 if not ck.fails else 1
    sc = build_probe(case) if case == 'known_idle_fifo' else build(case)
    with open(os.path.join(simdir, 'multi_cmds.memh'), 'w') as fh:
        fh.write(sc.text())
    print('multi_cmds.memh written (%s)' % case)
    return 0


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
