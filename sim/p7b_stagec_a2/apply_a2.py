#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_a2.py -- Stage C / A2: 给 rtl/app_pattern.v 的 **TX 侧**加 "1 拍/字"
(包在既有宏 `P7B_10G` 内), 并机器证明「未定义该宏 ⇒ 与改动前源码逐字节相同」。

手法 (与 Stage B 的 apply_rx8.py / UDP 轮的 apply_wide.py 同款):
  - 五处锚点, 每处断言**命中恰 1 次**;
  - 所有新行都写在 `ifdef P7B_10G ... `else <原语句逐字> `endif` 里 ⇒ 未定义时预处理
    器原样吐回原语句 (极简预处理器只认 ifdef/ifndef/else/endif, 见 pp()).

设计要点 (与本目录 notes / P7B_STAGEC_A2.md 的"与设计件的偏差"一节逐条对应):
  * **前瞻只用于"预取下一个字"**, 不参与任何判据:
      - 收尾 (`need == 4'd0`) 与装载 (`asm_full`) 仍用**非前瞻** need/seg_sent/remain
        ⇒ 帧边界决策与默认构建**同拍采样** (tx_ok/remain/frm_idx 的采样点不动);
      - 只有"整字预取"分支 (a2_ldw) 用 need_a/sent_a, 且它在 (need==0) 之后、
        (bcnt<need_a) 之前 ⇒ 尾字结构性回落原逐字节路径。
  * **帧拆除拍让位** (a2_hold = ev_down 将置 closing | ev_up 换流): 这些拍上默认
    构建因 !pw_valid 而不装配, 预取必须让位, 否则收尾帧多 8 字节载荷 / 新会话
    opener 被残余字挡住。
  * 同拍"消费 + 预取" ⇒ 装载赢 pw_valid (Verilog 后者胜; 显式写在消费块之后)。

基线: app_pattern.v.pre_a2 (= 本改动前的 rtl/app_pattern.v, 含 Stage B 的 RX 8 路)
输出: rtl/app_pattern.v (覆盖)

用法: python apply_a2.py [--check]
"""
import hashlib
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ORIG = os.path.join(HERE, "app_pattern.v.pre_a2")
TGT = os.path.join(ROOT, "rtl", "app_pattern.v")


def rd(p):
    return io.open(p, encoding="utf-8", newline="").read()


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def pp(src, defs):
    """极简预处理器: 只认 `ifdef/`ifndef/`else/`endif (与 apply_rx8.py 逐字同款)."""
    out, st = [], []
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
            st[-1][0] = not st[-1][1]
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


# =========================== 五处锚点 ===========================
# 锚点 1: left/need 定义 (前瞻量插在它之后)
A1 = """    wire [11:0] left     = seg_len - seg_sent;                 // 本帧剩余字节
    wire [3:0]  need     = (left >= 12'd8) ? 4'd8 : left[3:0]; // 本字字节数
"""

# 锚点 2: asm_go (唯一放宽 + 让位线网 + 预取命中线网)
A2 = """    wire        asm_go   = active && !pw_valid && !closing && !frm_wait && !op_pend &&
                           (frm_inflight || tx_ok || (remain == 32'd0));
"""

# 锚点 3: asm_full (填充/装载口径改用前瞻 need_a)
A3 = "    wire        asm_full = asm_go && (bcnt == need) && (need != 4'd0);\n"

# 锚点 4: 逐字节填充分支 (整字预取分支插在它之前)
A4 = "                end else if (bcnt < need) begin\n"

# 锚点 5: 消费块尾 (装载赢 pw_valid 写在它之后)
A5 = """                if (!bad_frm) begin
                    remain <= (remain >= {20'b0, pw_n}) ? (remain - {20'b0, pw_n}) :
                              32'd0;
                    stat_tx_bytes <= stat_tx_bytes + {28'b0, pw_n};
                end
            end
"""

NEW_A1 = """`ifdef P7B_10G
    // =====================================================================
    // A2 (Stage C, TX 1 拍/字): **前瞻量** —— 只用于"预取下一个字"
    // =====================================================================
    //   pw_take = 本拍消费块真的会消费这个字 (与下面消费块的门逐字同款)
    //   sent_a  = 本拍结束时本帧已"呈交"的字节数 (含同拍被消费的 pw_n)
    //   left_a / need_a = **下一个要预取的字** 的剩余/字节数 (前瞻基准)
    // ⚠️ 前瞻**不进任何判据**:
    //   - 收尾 (`need == 4'd0`) 用非前瞻 need ⇒ 收尾仍落在"最后一个字被消费后的
    //     下一拍", 与默认构建**同拍**采样 tx_ok/remain/frm_idx (帧边界决策不移相);
    //   - 装载 (`asm_full`) 用 need_a, 但它只在 pw_valid==0 拍发生, 而该拍
    //     need_a ≡ need (pw_take==0 ⇒ sent_a == seg_sent) ⇒ 逐位同默认;
    //   - 只有"整字预取"分支用 need_a/sent_a (它是新增路径, 无默认对应物)。
    // =====================================================================
    wire        pw_take = pw_valid && m_tready && !closing;
    wire [11:0] sent_a  = seg_sent + (pw_take ? {8'b0, pw_n} : 12'd0);
    wire [11:0] left_a  = (sent_a >= seg_len) ? 12'd0 : (seg_len - sent_a);
    wire [3:0]  need_a  = (left_a >= 12'd8) ? 4'd8 : left_a[3:0];
`endif
"""

NEW_A2 = """`ifdef P7B_10G
    // ---- A2: 帧拆除拍让位 + 唯一放宽 ("消费拍同拍预取") ---------------------
    // a2_hold = 本拍帧正在被拆除 (ev_down 将置 closing / ev_up 换流; 判据与那两个
    //   事件块逐字同款)。这些拍上默认构建因 `!pw_valid` 而**不装配**; 预取若不让
    //   位会多产出一个字 ⇒ ①ev_down 撞 payload beat 时收尾帧会**多 8 字节载荷**
    //   (默认是 0 载荷收尾字, 线上帧长改变); ②ev_up 换流时残余字会占住呈交口,
    //   把新会话的 0 载荷 opener 挡掉 (或让它的 pw_valid 覆盖换流的撤字)。
    //   让位后这些拍与默认构建**逐位同行为** (下面的整字分支同门让位 ⇒ 回落逐字节)。
    wire        a2_hold = ev_restart || (ev_down && active && (ev_slot == act_id));
    // 唯一放宽: 允许在"消费拍"同拍预取下一个字 (默认构建此拍 asm_go==0)
    wire        asm_go  = active && (!pw_valid || (m_tready && !a2_hold)) && !closing &&
                          !frm_wait && !op_pend &&
                          (frm_inflight || tx_ok || (remain == 32'd0));
    // 整字预取分支命中 (分支条件与"装载赢 pw_valid"用的是**同一个线网**, 防写歪)
    wire        a2_ldw  = asm_go && (need_a == 4'd8) && !a2_hold;
`else
    wire        asm_go   = active && !pw_valid && !closing && !frm_wait && !op_pend &&
                           (frm_inflight || tx_ok || (remain == 32'd0));
`endif
"""

NEW_A3 = """`ifdef P7B_10G
    // 填充/装载口径: 用**前瞻 need_a**。一条实数 (推演): 尾字 (need<8) 的**第一个
    // 填充拍**落在"最后一个满字的消费拍"上, 该拍的前瞻 need_a 就是尾字长度; 若用
    // 非前瞻 need (=当字长度 8) 会在那一拍多填 1 字节 + 多推进 1 步 LFSR ⇒ 整条
    // 图案流从此偏移 1 字节。装载只可能在 pw_valid==0 拍 (asm_full ⟹ bcnt==need_a
    // >0, 而 pw_valid==1 时 bcnt 恒 0), 该拍 need_a ≡ need ⇒ 与默认逐位同款。
    wire        asm_full = asm_go && (bcnt == need_a) && (need_a != 4'd0);
`else
    wire        asm_full = asm_go && (bcnt == need) && (need != 4'd0);
`endif
"""

NEW_A4 = """`ifdef P7B_10G
                end else if (a2_ldw) begin
                    // A2: **整字 1 拍装载** —— 8 个连续字节由常量 XOR 网 (xs_word8)
                    // 一拍产出, 与逐字节路径是**同一组映射** (M^0..M^7 的字节行);
                    // LFSR 同拍推进 8 步 (xs_next8 = M^8)。只在 need_a==8 时走 ⇒
                    // 尾字 (need_a<8) 结构性回落下面的逐字节路径。
                    // pw_last 基准 = **前瞻 sent_a** (非前瞻会差一个字的偏移 ⇒ 帧
                    // 长度恰为 8 倍数时最后一个满字丢 tlast)。
                    pw_data  <= bad_frm ? 64'hA5A5A5A5A5A5A5A5 : xs_word8(tx_lfsr);
                    pw_keep  <= 8'hFF;
                    pw_n     <= 4'd8;
                    pw_last  <= ((sent_a + 12'd8) >= seg_len);
                    pw_valid <= 1'b1;
                    bcnt     <= 4'd0;
                    stg      <= 64'd0;
                    if (!bad_frm) tx_lfsr <= xs_next8(tx_lfsr);
                end else if (bcnt < need_a) begin
`else
                end else if (bcnt < need) begin
`endif
"""

NEW_A5 = """`ifdef P7B_10G
            // ---- A2: 同拍"消费 + 预取" ⇒ **装载赢 pw_valid** -------------------
            // 同一个 always 块内对同一变量多次非阻塞赋值 = 后者胜。上面消费块的
            // `pw_valid <= 1'b0` 会把**本拍刚预取的字**丢掉 (每字丢一个字 ⇒ 字节流
            // 整段错位) ⇒ 必须在它之后把 pw_valid 写回 1 (只有真装载了才写;
            // a2_ldw 已含 !a2_hold ⇒ 换流/收尾拍不复活)。
            if (a2_ldw) pw_valid <= 1'b1;
`endif
"""


def build(old):
    for i, (a, nm) in enumerate(((A1, "A1 left/need"), (A2, "A2 asm_go"),
                                 (A3, "A3 asm_full"), (A4, "A4 fill-branch"),
                                 (A5, "A5 consume-tail")), 1):
        n = old.count(a)
        assert n == 1, "anchor%d (%s) hits=%d (expect exactly 1)" % (i, nm, n)
    new = old.replace(A1, A1 + NEW_A1, 1)
    new = new.replace(A2, NEW_A2, 1)
    new = new.replace(A3, NEW_A3, 1)
    new = new.replace(A4, NEW_A4, 1)
    new = new.replace(A5, A5 + NEW_A5, 1)
    return new


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    check_only = "--check" in sys.argv

    old = rd(ORIG)
    new = build(old)
    print("BASELINE %s sha256=%s" % (os.path.basename(ORIG), sha(ORIG)))
    if os.path.exists(TGT):
        print("CURRENT  rtl/app_pattern.v sha256=%s" % sha(TGT))

    # ---- 证明 1: 默认构建 (无 P7B_10G) 预处理后与改动前**逐字节相同** ----
    a = pp(old, set())
    b = pp(new, set())
    same = (a == b)
    print("PP-EQUIV default (no P7B_10G): %s  (old %d chars / new %d chars)"
          % ("IDENTICAL" if same else "*** DIFFER ***", len(a), len(b)))
    if not same:
        import difflib
        print("\n".join(list(difflib.unified_diff(a.split("\n"), b.split("\n"),
                                                  n=3, lineterm=""))[:80]))
        assert False, "default-build source NOT identical -> abort"

    # ---- 证明 2: P7B_10G 下新路径真的在, 且只增不减 ----
    c = pp(new, {"P7B_10G"})
    for key in ("a2_ldw", "need_a", "sent_a", "pw_take", "a2_hold"):
        assert key in c, "PP with P7B_10G lacks %s" % key
    print("PP with P7B_10G: %d lines (default %d lines) => +%d lines"
          % (len(c.split("\n")), len(b.split("\n")),
             len(c.split("\n")) - len(b.split("\n"))))

    if check_only:
        print("CHECK-ONLY: 未写文件")
        return 0
    io.open(TGT, "w", encoding="utf-8", newline="").write(new)
    print("wrote %s (%d bytes, sha256=%s)"
          % (TGT, len(new.encode("utf-8")), sha(TGT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
