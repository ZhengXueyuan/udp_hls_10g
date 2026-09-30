#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_wide.py -- 把 8 字节/拍 (P7B_10G) 分支拼进 rtl/app_udp_pattern.v.

设计原则 (本工程铁律: 默认构建逐位不变):
  * 所有新增逻辑都在 `ifdef P7B_10G 内; 被改动的既有语句一律写成
        `ifdef P7B_10G
        <新写法>
        `else
        <原语句, 逐字照抄>
        `endif
    ⇒ **默认定义集下预处理结果与改动前逐字节相同** (本脚本自动证明并断言)。
  * 只有 P7B_10G 一个宏; 未定义时 = 今天的 RTL (P5/P6a/P6b/P6e/K7 全部构建)。

用法:  python apply_wide.py            # 从 .orig 重新拼 (幂等)
       python apply_wide.py --check    # 只做等价证明, 不写文件
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
TGT = os.path.join(ROOT, "rtl", "app_udp_pattern.v")
ORIG = os.path.join(HERE, "app_udp_pattern.v.orig")
FUNCS = os.path.join(HERE, "wide_funcs.v.txt")

NL = "\r\n"          # 目标文件在工作树里是 CRLF (git 索引是 LF; autocrlf=true)


def rd(p):
    return io.open(p, encoding="utf-8", newline="").read()


def block(lines):
    return NL.join(lines)


def sub1(s, old, new, tag):
    n = s.count(old)
    assert n == 1, "[ANCHOR %s] expected 1 hit, got %d" % (tag, n)
    return s.replace(old, new)


# ===========================================================================
# 1. 函数块 (xs_next8 / xs_word8) —— 插在 xs_next 之后 (用"左对齐"注释行作锚点)
# ===========================================================================
A_FUNC = "    // 左对齐: stg 低 n 字节 → 高 n 字节 (显式 case, 坑 5: 禁变移位量)"

# ===========================================================================
# 2. TX: 8 路线网 (插在 push_any 之后) + T_FRM 满字推送分支 + frm_close
# ===========================================================================
A_TXW = "    wire        nul_push = (txs == T_FRM) && nul_pend && !txf_full;"
TXW = block([
    "`ifdef P7B_10G",
    "    // =====================================================================",
    "    // 8 字节/拍 TX (P7B_10G): 剩余 >= 8 字节时**一拍推一个满字**; 剩 < 8 的",
    "    // **尾字**自动落到下面的逐字节路径 ⇒ 非 8 倍数载荷结构性正确 (含 PLEN_MAX",
    "    // 冻结 + 0xA5 填充, 与逐字节路径同款)。",
    "    // 逐字节恒等: gen_word 的 lane k = (M^k·s)[31:24] = 序列第 k 个字节;",
    "    //   tx_lfsr_8 = M^8·s = 推进 8 步 ⇒ 与「每拍 1 字节」序列**同一个流**。",
    "    // =====================================================================",
    "    wire [63:0] tx_lfsr_8 = xs_next8(tx_lfsr);              // 状态推进 8 步",
    "    wire [63:0] gen_word  = pay_ok ? xs_word8(tx_lfsr)      // 8 个字节 (lane0 在前)",
    "                                  : 64'hA5A5A5A5A5A5A5A5;",
    "    // 满字快路径: gen_ok 已含 (T_FRM && !txf_full && !nul_pend && 未发完)",
    "    wire        wide_ok   = gen_ok && (left >= 12'd8);",
    "`endif",
])

A_FRM = "                    if (nul_push) begin"
FRM = block([
    "`ifdef P7B_10G",
    "                    if (wide_ok) begin",
    "                        // 一拍推 8 字节 (need 恒 8; last_b = (left == 8) 即本帧末字)",
    "                        txf_wr        <= 1'b1;",
    "                        txf_in        <= {last_b, 8'hFF, gen_word};",
    "                        seg_sent      <= seg_sent + 12'd8;",
    "                        stat_tx_bytes <= stat_tx_bytes + 32'd8;",
    "                        remain        <= rem_n;",
    "                        bcnt          <= 4'd0;",
    "                        stg           <= 64'd0;",
    "                        if (pay_ok) tx_lfsr <= tx_lfsr_8;   // 超长帧冻结 (同逐字节)",
    "                    end else",
    "`endif",
])

A_CLOSE = "    wire        frm_close = push_now ? last_b : nul_push;"
CLOSE = block([
    "`ifdef P7B_10G",
    "    wire        frm_close = (push_now || wide_ok) ? last_b : nul_push;",
    "`else",
    "    wire        frm_close = push_now ? last_b : nul_push;",
    "`endif",
])

# ===========================================================================
# 3. RX: rx_tready (原位加守卫) + 8 路块 (插在 rx_ld 之后)
# ===========================================================================
A_RTR = "    assign rx_tready = !nx_v;"
RTR = block([
    "`ifdef P7B_10G",
    "    // 宽路径的 rx_tready 定义在下面的 8 路块里 (要用到 cmp_ld_w)",
    "`else",
    "    assign rx_tready = !nx_v;",
    "`endif",
])

A_RXL = "    wire       rx_ld   = rx_tvalid && rx_tready;               // 前瞻装载"
RXL = block([
    "`ifdef P7B_10G",
    "    // =====================================================================",
    "    // 8 字节/拍 RX 校验 (P7B_10G): 满字**一拍比完**; 非满字(尾字/0 长帧)仍走",
    "    // 上面的逐字节路径 ⇒ 非 8 倍数帧结构性正确。",
    "    // 期望序列与 TX 侧**同一组映射** (xs_word8) ⇒ 两侧同源, 不会各自近似。",
    "    // =====================================================================",
    "`ifdef RXP_DIAG",
    "    // 诊断构建 (RXP_DIAG) 的 v1-v4 仪器全是**逐字节量** (ds_idx 活计数器 /",
    "    // 帧内偏移桶 / 事件 FIFO), 与满字并行比对不兼容 ⇒ 该组合下宽 RX 关闭",
    "    // (退回逐字节: 正确但慢)。⚠️ 目前没有任何构建同时开这两个宏。",
    "    wire        wide_cmp = 1'b0;",
    "    wire [63:0] rx_lfsr_8   = 64'd0;   // 哑声明 (下方 always 里的分支恒假, 不进网表)",
    "    wire [3:0]  rx_bad_n    = 4'd0;",
    "    assign rx_tready = !nx_v;",
    "`else",
    "    wire [63:0] rx_exp_word = xs_word8(rx_lfsr);      // 本字 8 个期望字节",
    "    wire [63:0] rx_lfsr_8   = xs_next8(rx_lfsr);      // 期望序列推进 8 步",
    "    // 只在「满字 && 在本字首字节」时成立; 一旦非满字, 结构性退回逐字节路径",
    "    wire        wide_cmp    = cmp_busy && (cmp_n == 4'd8) && (cmp_i == 4'd0);",
    "    wire [7:0]  rx_bad_v;                             // 逐 lane 失配 (i_en=0 恒 0)",
    "    assign rx_bad_v[0] = i_en && (cmp_d[63:56] !== rx_exp_word[63:56]);",
    "    assign rx_bad_v[1] = i_en && (cmp_d[55:48] !== rx_exp_word[55:48]);",
    "    assign rx_bad_v[2] = i_en && (cmp_d[47:40] !== rx_exp_word[47:40]);",
    "    assign rx_bad_v[3] = i_en && (cmp_d[39:32] !== rx_exp_word[39:32]);",
    "    assign rx_bad_v[4] = i_en && (cmp_d[31:24] !== rx_exp_word[31:24]);",
    "    assign rx_bad_v[5] = i_en && (cmp_d[23:16] !== rx_exp_word[23:16]);",
    "    assign rx_bad_v[6] = i_en && (cmp_d[15:8]  !== rx_exp_word[15:8]);",
    "    assign rx_bad_v[7] = i_en && (cmp_d[7:0]   !== rx_exp_word[7:0]);",
    "    wire [3:0]  rx_bad_n = pop8(rx_bad_v);            // 本拍失配字节数 (0..8)",
    "    // cmp 寄存器的装载条件 (语义与 diag 段那条 cmp_ld 相同, 但不引 cmp_end 线:",
    "    // 本块在它之前 —— 坑 22: xvlog 先声明后用)",
    "    wire        cmp_ld_w = nx_v && (!cmp_busy || (cmp_n == 4'd0) ||",
    "                                    (cmp_i + 4'd1 >= cmp_n) || wide_cmp);",
    "    // 宽路径 1 字/拍: 前瞻字被**消费的同拍**必须能再收一个字, 否则每字 2 拍",
    "    // (只到 4 字节/拍)。串行路径下它只是把手递提前 1 拍 (nx 寄存器同拍被",
    "    // 读走+写新 ⇒ 无覆盖, 无丢字), 逻辑等价。",
    "    assign rx_tready = !nx_v || cmp_ld_w;",
    "`endif",
    "`endif",
])

A_RXCMT = "            // 装载 (前瞻空位才有 rx_tready ⇒ 与下面的\"消费 nx\"结构性互斥)"
RXCMT = block([
    "`ifdef P7B_10G",
    "            // ⚠️ 宽路径 (P7B_10G): rx_tready = !nx_v || cmp_ld_w ⇒ 上面那条「结构性互斥」",
    "            //    已被**有意**放宽 (否则每个字要 2 拍 = 4 字节/拍)。代价是下面三处",
    "            //    消费分支的 nx_v 必须写成 rx_ld —— 否则同拍新装进来的字被静默丢弃",
    "            //    (实测症状: 回环只收到一半字节)。",
    "`endif",
    "            // 装载 (前瞻空位才有 rx_tready ⇒ 与下面的\"消费 nx\"结构性互斥)",
])

A_CMPEND = "                end else if (cmp_end) begin"
CMPEND = block([
    "`ifdef P7B_10G",
    "                end else if (cmp_end || wide_cmp) begin",
    "`else",
    "                end else if (cmp_end) begin",
    "`endif",
])

A_LFSR = block([
    "            if (!i_en)               rx_lfsr <= SEED;",
    "            else if (cmp_hit)        rx_lfsr <= xs_next(rx_lfsr);",
])
LFSR = block([
    "`ifdef P7B_10G",
    "            if (!i_en)               rx_lfsr <= SEED;",
    "            else if (wide_cmp)       rx_lfsr <= rx_lfsr_8;",
    "            else if (cmp_hit)        rx_lfsr <= xs_next(rx_lfsr);",
    "`else",
    "            if (!i_en)               rx_lfsr <= SEED;",
    "            else if (cmp_hit)        rx_lfsr <= xs_next(rx_lfsr);",
    "`endif",
])

A_BYTES = "            if (cmp_hit)        stat_rx_bytes <= stat_rx_bytes + 32'd1;"
BYTES = block([
    "`ifdef P7B_10G",
    "            if (wide_cmp)       stat_rx_bytes <= stat_rx_bytes + 32'd8;",
    "            else if (cmp_hit)   stat_rx_bytes <= stat_rx_bytes + 32'd1;",
    "`else",
    "            if (cmp_hit)        stat_rx_bytes <= stat_rx_bytes + 32'd1;",
    "`endif",
])

A_MIS = "            if (rx_bad)         stat_mismatch <= stat_mismatch + 32'd1;"
MIS = block([
    "`ifdef P7B_10G",
    "            if (wide_cmp)       stat_mismatch <= stat_mismatch + {28'b0, rx_bad_n};",
    "            else if (rx_bad)    stat_mismatch <= stat_mismatch + 32'd1;",
    "`else",
    "            if (rx_bad)         stat_mismatch <= stat_mismatch + 32'd1;",
    "`endif",
])


def build(src, funcs):
    s = src
    # 函数块也必须包在 ifdef 内 —— 否则默认构建的源码就多出两个函数 (虽未被引用)
    fblock = NL.join(["`ifdef P7B_10G", funcs, "`endif"])
    s = sub1(s, A_FUNC, fblock + NL + A_FUNC, "FUNC")
    s = sub1(s, A_TXW, A_TXW + NL + TXW, "TXW")
    s = sub1(s, A_FRM, FRM + NL + A_FRM, "FRM")
    s = sub1(s, A_CLOSE, CLOSE, "CLOSE")
    s = sub1(s, A_RTR, RTR, "RTR")
    s = sub1(s, A_RXCMT, RXCMT, "RXCMT")
    s = sub1(s, A_RXL, A_RXL + NL + RXL, "RXL")
    s = sub1(s, A_CMPEND, CMPEND, "CMPEND")
    s = sub1(s, A_LFSR, LFSR, "LFSR")
    s = sub1(s, A_BYTES, BYTES, "BYTES")
    s = sub1(s, A_MIS, MIS, "MIS")
    s = subn(s, A_NXV1, NXV1, 2, "NXV1")     # cmp_n==0 分支 + cmp_last 分支
    s = sub1(s, A_NXV2, NXV2, "NXV2")        # 引擎空闲装载分支
    return s


# ===========================================================================
# 4. RX 引擎: "同拍消费 nx + 装载新字" 的 nx_v 冲突 (宽路径必需)
#    rx_tready = !nx_v || cmp_ld_w 打开后, 原来那句 "装载 (前瞻空位才有 rx_tready
#    ⇒ 与消费 nx 结构性互斥)" 不再成立: 同一拍既把 nx 搬进 cmp、又把 rx_tdata 装进
#    nx。若照旧写 nx_v <= 0, 新装进来的字就**被静默丢弃** (实测: 回环只收到一半字节)。
#    ⇒ 三处消费分支改成 nx_v <= rx_ld (rx_ld=0 时等价于原 nx_v <= 0)。
# ===========================================================================
A_NXV1 = "                        nx_v  <= 1'b0;"
NXV1 = block([
    "`ifdef P7B_10G",
    "                        nx_v  <= rx_ld;    // 同拍消费+装载: 新字必须留下",
    "`else",
    "                        nx_v  <= 1'b0;",
    "`endif",
])
A_NXV2 = "                cmp_busy <= 1'b1; nx_v <= 1'b0;"
NXV2 = block([
    "`ifdef P7B_10G",
    "                cmp_busy <= 1'b1; nx_v <= rx_ld;   // 同拍消费+装载: 新字必须留下",
    "`else",
    "                cmp_busy <= 1'b1; nx_v <= 1'b0;",
    "`endif",
])


def subn(s, old, new, n, tag):
    got = s.count(old)
    assert got == n, "[ANCHOR %s] expected %d hits, got %d" % (tag, n, got)
    return s.replace(old, new)


# ===========================================================================
# 极简 Verilog 预处理器 (只支持 ifdef/ifndef/else/endif; 本改动只用这四个)
# ===========================================================================
def pp(src, defs):
    out, st = [], []          # st: [(taken, any_taken)]
    for ln in src.split("\n"):
        t = ln.lstrip()
        if t.startswith("`ifdef ") or t.startswith("`ifndef "):
            inv = t.startswith("`ifndef ")
            name = t.split()[1]
            v = (name in defs) != inv
            st.append([v, v])
            continue
        if t.startswith("`else"):
            assert st, "`else without ifdef"
            st[-1][0] = not st[-1][1]          # taken = 之前没有任何分支被取过
            st[-1][1] = st[-1][1] or st[-1][0]
            continue
        if t.startswith("`endif"):
            assert st, "`endif without ifdef"
            st.pop()
            continue
        if all(f[0] for f in st):
            out.append(ln)
    assert not st, "unbalanced ifdef"
    return "\n".join(out)


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    check_only = "--check" in sys.argv
    old = rd(ORIG)
    funcs = rd(FUNCS).rstrip("\r\n")
    new = build(old, funcs)

    # ---- 证明 1: 默认定义集 (无 P7B_10G) 预处理后逐字节相同 ----
    a = pp(old, set())
    b = pp(new, set())
    same = (a == b)
    print("PP-EQUIV default (no P7B_10G): %s  (old %d bytes / new %d bytes)"
          % ("IDENTICAL" if same else "*** DIFFER ***", len(a), len(b)))
    if not same:
        import difflib
        d = list(difflib.unified_diff(a.split("\n"), b.split("\n"), n=3,
                                      lineterm=""))[:60]
        print("\n".join(d))
        assert False, "default-build source NOT identical -> abort"

    # ---- 证明 2: P7B_10G 下语法上只多不少 ----
    c = pp(new, {"P7B_10G"})
    print("PP with P7B_10G: %d lines (default %d lines) => +%d lines"
          % (len(c.split("\n")), len(b.split("\n")),
             len(c.split("\n")) - len(b.split("\n"))))
    # 宏平衡粗检: 每个 `ifdef 都有 `endif (上面 pp 已断言), 且默认集下无残留反引号指令
    for bad in ("`ifdef", "`ifndef", "`else", "`endif"):
        assert bad not in b, "preprocessed default source still has %s" % bad

    if check_only:
        return
    io.open(TGT, "w", encoding="utf-8", newline="").write(new)
    print("wrote %s (%d lines, %d bytes)" % (TGT, new.count("\n") + 1,
                                             len(new.encode("utf-8"))))


if __name__ == "__main__":
    sys.exit(main())
