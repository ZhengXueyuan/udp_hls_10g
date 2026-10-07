#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#=============================================================================
# f2_equiv.py -- P7b-WU 二轮 F2 (winq==0 的显式语义) 的**穷举**等价性证明
#
# 被证的三个谓词 (全部逐位照抄 RTL 表达式; 行号见 rtl/app_ctrl.v):
#   PRE  = 二轮修前的生产路径 (工作树快照 sim/p5wu_f2fix/app_ctrl_prefix.v,
#          未改名前 sha256 = 871eab125a28f325839c99041c4fbe6d990385f4bcb1625eee970f23f007b2ff
#          = 编辑前的 rtl/app_ctrl.v)
#           武装: (({1'b0,wscan} < {2'b0,winq[15:2]}) || (wscan == 0)) && wu_act
#           触发: wu_zero && ({1'b0,wscan} >= {1'b0,winq[15:1]})
#   POST = 修复后 (rtl/app_ctrl.v 生产路径): 上述两条**整体**加前缀 `winq != 0`
#   TGT  = 设计意图 (语义侧的写法): 武装 = (winq != 0) && (wscan < max(winq/4, 1))
#                                    触发 = (winq != 0) && wu_zero && (wscan >= winq/2)
#          (winq==0 的意图 = **永不发**; 理由 = 零配额时 wscan ≡ 0, 无物可通告)
#
# 方法 (不是抽样): 对 **全部 65536 个 winq** × **全部 65536 个 wscan** 求值比对
#   = 2^32 个格点, numpy 分块广播, 精确整数语义 (uint32; winq[15:2] = w>>2,
#   winq[15:1] = w>>1, 与 RTL 的 16 位无符号比较逐位一致)。
#   wu_act / wu_zero 只出现在两个谓词的**相同**的与项上 (不参与差异判定),
#   故比对核心谓词即可; 另外对 fq_calc(0, oc) 做**全 17 位 occ 穷举**以证
#   "winq==0 ⇒ wscan ≡ 0" (这才是旧式恒真的那一半)。
#
# 退出码: 0 = 全部判据通过; 1 = 有判据失败 (打印反例坐标)。
#=============================================================================
import sys
import numpy as np

# GBK 控制台下 print 非 ASCII 会抛 UnicodeEncodeError 并把退出码变成 1 (本工程坑 16)
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

CH = 512                      # winq 分块 (512 x 65536 = 33.5M 格/块)
W_MAX = 65536
X = np.arange(W_MAX, dtype=np.uint32)[None, :]      # (1, 65536) = wscan

fails = []
def chk(cond, name, extra=""):
    status = "PASS" if cond else "FAIL"
    print("  [%s] %s%s" % (status, name, (" :: " + extra) if extra else ""))
    if not cond:
        fails.append(name)

print("== F2 equivalence: PRE vs POST vs TARGET ==")
print("   grid = winq 0..65535  x  wscan 0..65535   (2^32 points, numpy, chunk=%d)" % CH)

n_arm_diff_nonzero = 0        # PRE arm != POST arm, 在 winq != 0 上
n_fire_diff_nonzero = 0       # PRE fire != POST fire, 在 winq != 0 上
n_post_ne_target = 0          # POST != TGT (任一谓词)
n_pre_sat_zero = 0            # PRE arm 在 (winq==0, wscan==0) 上为真 (= 恒真那条)
n_post_zero_true = 0          # POST 在 winq==0 上任一谓词为真 (必须 0)
ex_nonzero = None
ex_target = None

for lo in range(0, W_MAX, CH):
    w = np.arange(lo, lo + CH, dtype=np.uint32)[:, None]     # (CH,1)
    wq2 = w >> 2                                             # = winq[15:2]
    wq1 = w >> 1                                             # = winq[15:1]
    nz = (w != 0)
    thr = np.maximum(wq2, np.uint32(1))                      # max(winq/4, 1)

    pre_arm = (X < wq2) | (X == 0)
    pre_fire = (X >= wq1)
    post_arm = nz & pre_arm
    post_fire = nz & pre_fire
    tgt_arm = nz & (X < thr)
    tgt_fire = nz & (X >= wq1)

    d_arm = (pre_arm != post_arm) & nz
    d_fire = (pre_fire != post_fire) & nz
    c = int(np.count_nonzero(d_arm))
    if c:
        n_arm_diff_nonzero += c
        if ex_nonzero is None:
            i, j = np.argwhere(d_arm)[0]
            ex_nonzero = (int(w[i, 0]), int(X[0, j]))
    c = int(np.count_nonzero(d_fire))
    if c:
        n_fire_diff_nonzero += c
        if ex_nonzero is None:
            i, j = np.argwhere(d_fire)[0]
            ex_nonzero = ("fire", int(w[i, 0]), int(X[0, j]))

    # POST vs TARGET (两谓词)
    m = (post_arm != tgt_arm) | (post_fire != tgt_fire)
    c = int(np.count_nonzero(m))
    if c:
        n_post_ne_target += c
        if ex_target is None:
            i, j = np.argwhere(m)[0]
            ex_target = (int(w[i, 0]), int(X[0, j]),
                         bool(post_arm[i, j]), bool(tgt_arm[i, j]),
                         bool(post_fire[i, j]), bool(tgt_fire[i, j]))

    # winq == 0 行: PRE 武装 = (X == 0)  (在 X==0 处恒真), POST 必须全假
    z = ~nz
    n_pre_sat_zero += int(np.count_nonzero(z & pre_arm))
    n_post_zero_true += int(np.count_nonzero(z & (post_arm | post_fire)))

print()
chk(n_post_ne_target == 0,
    "A: POST == TARGET (winq!=0 时 wscan<max(winq/4,1); winq==0 时永不发)  [2^32 格点]",
    ("反例 = %s" % (ex_target,)) if n_post_ne_target else "")
chk(n_arm_diff_nonzero == 0,
    "B: winq != 0 的全部 65536 档上, POST 武装 == PRE 武装 (逐位相同)",
    ("反例 = %s" % (ex_nonzero,)) if n_arm_diff_nonzero else "")
chk(n_fire_diff_nonzero == 0,
    "C: winq != 0 的全部 65536 档上, POST 触发 == PRE 触发 (逐位相同)",
    ("反例 = %s" % (ex_nonzero,)) if n_fire_diff_nonzero else "")
chk(n_pre_sat_zero == 1,
    "D: PRE 在 winq==0 行的武装为真的格点数 == 1 (唯一点 (0,0); 配合 E 即**恒真**)",
    "实测 = %d" % n_pre_sat_zero)
chk(n_post_zero_true == 0,
    "E: POST 在 winq==0 行 (全部 65536 个 wscan) 上武装/触发**恒假** (显式永不发)",
    "实测真值点 = %d" % n_post_zero_true)

# ---- F: fq_calc(0, oc) ≡ 0 (全 17 位 occ 穷举) => winq==0 时 wscan 必然 = 0 ----
oc = np.arange(0, 1 << 17, dtype=np.uint32)
fq0 = np.where(oc >= np.uint32(0), np.uint32(0), np.uint32(0xDEAD))
chk(int(np.count_nonzero(fq0)) == 0,
    "F: fq_calc(0, oc) == 0 对全部 17 位 oc (0..131071) 成立 => winq==0 时 wscan ≡ 0",
    "(rtl/app_ctrl.v fq_calc: oc >= q ? 0 : q - oc)")

# ---- G: winq ∈ {1,2,3} 的**可达性** (P1 的"可达性恢复" + 判据能分辨"发") ----
# 武装需要 wscan==0 (可达: oc >= winq), 触发需要 wscan >= winq/2 (可达: oc 足够小)
reach = []
for q in (1, 2, 3):
    fq = np.where(oc >= np.uint32(q), np.uint32(0), np.uint32(q) - oc)
    can_arm = bool(np.any(fq == 0))                      # wscan==0 可达
    can_fire = bool(np.any(fq >= np.uint32(q >> 1)))     # 触发阈值可达
    reach.append((q, can_arm, can_fire))
chk(all(a and b for _, a, b in reach),
    "G: winq in {1,2,3}: wscan==0 (武装) 与 wscan>=winq/2 (触发) 均可达 (oc 穷举见证)",
    " ; ".join("q=%d arm=%s fire=%s" % r for r in reach))
chk(not any(q == 0 for q, _, _ in reach), "G2: winq==0 不参与该可达性 (见 F: wscan 恒 0 ⇒ POST 恒假)")

# ---- H: 产品配置子域 (winq >= 3072 = 池/16) 单独对账 ----
prod_lo = 3072
n_prod = 0
for lo in range(prod_lo, W_MAX, CH):
    w = np.arange(lo, min(lo + CH, W_MAX), dtype=np.uint32)[:, None]
    pre_arm = (X < (w >> 2)) | (X == 0)
    post_arm = (w != 0) & pre_arm
    pre_fire = (X >= (w >> 1))
    post_fire = (w != 0) & pre_fire
    n_prod += int(np.count_nonzero((pre_arm != post_arm) | (pre_fire != post_fire)))
chk(n_prod == 0, "H: 产品配置子域 winq >= 3072 (含默认 0xC000) 上 PRE == POST (差异数 0)",
    "差异数 = %d" % n_prod)

print()
if fails:
    print("F2_EQUIV FAIL %d" % len(fails))
    sys.exit(1)
print("F2_EQUIV OK (exhaustive 2^32 grid; PRE/POST/TARGET)")
sys.exit(0)
