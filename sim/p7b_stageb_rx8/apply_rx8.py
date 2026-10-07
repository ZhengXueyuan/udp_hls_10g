#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_rx8.py -- Stage B / R1: 给 rtl/app_pattern.v 加 **RX 8 路并行** (包在既有宏
`P7B_10G` 内), 并证明「未定义该宏 ⇒ 与改动前源码逐字节相同」(机器证明, 不是声称).

手法 (与 UDP 轮 _proj_10g/notes/p7b_rate8/apply_wide.py 同款):
  - 三处锚点, 每处断言**命中恰 1 次**;
  - 所有新行都写在 `ifdef P7B_10G ... `else <原语句逐字> `endif 里 ⇒ 未定义时预处理器
    原样吐回原语句 (极简预处理器只认 ifdef/ifndef/else/endif, 见 pp()).

基线: app_pattern.v.orig (= git HEAD e9a4d23 的 rtl/app_pattern.v, sha256 b6a9fa0e…)。
输出: rtl/app_pattern.v (覆盖), 另把函数块写到 wide_funcs_from_udp.v.txt 供比对。

用法: python apply_rx8.py [--check]      (--check = 只跑证明不写文件)
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ORIG = os.path.join(HERE, "app_pattern.v.orig")
TGT = os.path.join(ROOT, "rtl", "app_pattern.v")
UDP = os.path.join(ROOT, "rtl", "app_udp_pattern.v")
GEN = os.path.join(HERE, "wide_funcs.v.txt")          # gen_mat8.py 的输出
FUNCS_DUMP = os.path.join(HERE, "wide_funcs_from_udp.v.txt")


def rd(p):
    return io.open(p, encoding="utf-8", newline="").read()


def pp(src, defs):
    """极简预处理器: 只认 `ifdef/`ifndef/`else/`endif (与 apply_wide.py 逐字同款)."""
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


def extract_funcs(path):
    """从 app_udp_pattern.v (板级已验的 8 路实现) 抽出两个函数, 逐字搬用."""
    s = rd(path).split("\n")
    i0 = [k for k, l in enumerate(s) if "function [63:0] xs_next8" in l][0]
    i1 = [k for k, l in enumerate(s) if k > i0 and "function [63:0] xs_word8" in l][0]
    i2 = [k for k, l in enumerate(s) if k > i1 and "endfunction" in l][0]
    return "\n".join(l.rstrip() for l in s[i0:i2 + 1]) + "\n"


# =========================== 三处锚点 ===========================
# 锚点 1: xs_next 的 endfunction 之后插入 8 路函数块
A1 = """            xs_next = t;
        end
    endfunction
"""

# 锚点 2: rx_tready 定义之后插入宽路径的组合网
A2_TAIL = "    assign rx_tready = (rxs == 2'd0);\n"

# 锚点 3: RX 取值分支里, 在 `if (pop8(rx_tkeep) == 4'd0)` 之前接一条宽分支
A3 = "                    if (pop8(rx_tkeep) == 4'd0) begin\n"

NEW_FUNCS_HEAD = "`ifdef P7B_10G\n" + """    // ==================================================================
    // 8 路展开 (P7B_10G): xorshift64 转移矩阵 M 的幂 —— **常量 XOR 网**, 不是级联
    // ==================================================================
    // 本段与 rtl/app_udp_pattern.v 的同名函数**逐字节相同** (板级已验的 8 路实现),
    // 由 _proj_10g/notes/p7b_rate8/gen_mat8.py 生成 (勿手改), 该脚本含三条自校验
    // (M^8 vs 8 次 xs_next / 字节行 vs 逐步 / 1000 字节全序列 vs 逐字节)。
    // RX 侧的两个消费者: rx_exp_word = xs_word8(rx_lfsr) (本字 8 个期望字节) 与
    // rx_lfsr_8 = xs_next8(rx_lfsr) (期望序列推进 8 步)。
"""

NEW_RX_WIRES = """`ifdef P7B_10G
    // =====================================================================
    // RX 8 路并行 (P7B_10G): 满字 (pop8(tkeep)==8) **一拍比完 8 lane**。
    //   - 逐位等价: 期望字 = xs_word8(rx_lfsr), 与逐字节路径**同一组映射**
    //     (M^k·s 的字节行); 状态推进 xs_next8 = M^8 与 8 次 xs_next 同值。
    //   - 1 拍/字: 宽路径**保持 rxs==0** (不进比较态) ⇒ rx_tready 恒 1 ⇒ 背靠背。
    //     原路径 = 1(取值) + 8(逐字节) = 9 拍/满字 ⇒ 这就是被吸收的那级气泡。
    //   - 非满字 (尾字/0 长字) 结构性回落串行路径 (无第二套尾字实现) ⇒ 非 8 倍数载荷正确。
    //   - `rx_tready` 的定义**一字未动** (`rxs==0` 收字) ⇒ 上游/AXIS 合同零改动。
    //   - 计数口径与串行路径**逐字节同款** (stat_rx_bytes / stat_mismatch 都是"每字节")。
    //   - rw_* 照旧锁存 (回落路径用), 只是宽拍上不再进入 rxs==1。
    //   - ⚠️ `!ev_up`: 每连接复位 (ev_up) 与"本拍有字"撞车时, 宽路径必须**让位**,
    //     否则它写的 rx_lfsr <= rx_lfsr_8 (推进 8 步) 会把 ev_up 的 `rx_lfsr <= SEED`
    //     盖掉 —— 而逐字节路径在该拍**不写** rx_lfsr (只写 rxs<=1), 复位照常生效
    //     ⇒ 两条路径在那个角落会分叉。让位后两边逐位同行为 (本拍退回串行:
    //     rxs<=1 + 下一拍起按 SEED 序列逐字节比), 代价 = 每个连接起点 1 个字慢一拍。
    // =====================================================================
    wire [63:0] rx_exp_word = xs_word8(rx_lfsr);      // 本字 8 个期望字节
    wire [63:0] rx_lfsr_8   = xs_next8(rx_lfsr);      // 期望序列推进 8 步
    wire [3:0]  rx_kn       = pop8(rx_tkeep);
    wire        rx_wide     = (rxs == 2'd0) && rx_tvalid && (rx_kn == 4'd8) && !ev_up;
    wire [7:0]  rx_bad_v;                             // 逐 lane 失配
    assign rx_bad_v[0] = (rx_tdata[63:56] !== rx_exp_word[63:56]);
    assign rx_bad_v[1] = (rx_tdata[55:48] !== rx_exp_word[55:48]);
    assign rx_bad_v[2] = (rx_tdata[47:40] !== rx_exp_word[47:40]);
    assign rx_bad_v[3] = (rx_tdata[39:32] !== rx_exp_word[39:32]);
    assign rx_bad_v[4] = (rx_tdata[31:24] !== rx_exp_word[31:24]);
    assign rx_bad_v[5] = (rx_tdata[23:16] !== rx_exp_word[23:16]);
    assign rx_bad_v[6] = (rx_tdata[15:8]  !== rx_exp_word[15:8]);
    assign rx_bad_v[7] = (rx_tdata[7:0]   !== rx_exp_word[7:0]);
    wire [3:0]  rx_bad_n = pop8(rx_bad_v);            // 本拍失配字节数 (0..8)
`endif
"""

# 锚点 3 的替换: 原 `if (pop8==0)` 之前加宽分支; `else` 关键字整条包在 ifdef 内
A3_NEW = """`ifdef P7B_10G
                    if (rx_wide) begin
                        // 满字: 一拍比完 8 lane (rxs 保持 0 ⇒ 下一拍立刻收下一个字)。
                        // 与串行路径同口径: 每字节记一次 (失配按 lane 数量记)。
                        stat_mismatch <= stat_mismatch + {28'b0, rx_bad_n};
                        stat_rx_bytes <= stat_rx_bytes + 32'd8;
                        rx_lfsr       <= rx_lfsr_8;
                    end else if (pop8(rx_tkeep) == 4'd0) begin
`else
                    if (pop8(rx_tkeep) == 4'd0) begin
`endif
"""


def build(old, funcs):
    """三处锚点, 每处命中恰 1 次."""
    n1 = old.count(A1)
    assert n1 == 1, "anchor1 (xs_next endfunction) hits=%d" % n1
    n2 = old.count(A2_TAIL)
    assert n2 == 1, "anchor2 (rx_tready) hits=%d" % n2
    n3 = old.count(A3)
    assert n3 == 1, "anchor3 (pop8(tkeep)==0) hits=%d" % n3

    new = old.replace(A1, A1 + NEW_FUNCS_HEAD + funcs + "`endif\n", 1)
    new = new.replace(A2_TAIL, A2_TAIL + NEW_RX_WIRES, 1)
    new = new.replace(A3, A3_NEW, 1)
    return new


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    check_only = "--check" in sys.argv

    old = rd(ORIG)
    funcs = extract_funcs(UDP)
    io.open(FUNCS_DUMP, "w", encoding="utf-8", newline="").write(funcs)

    # 顺带: 生成器 (gen_mat8.py) 的输出必须与「从板级已验的 UDP 版抽出的函数」
    # 归一化后逐行相同 (双向印证; 尾部空格/行尾不计).
    if os.path.exists(GEN):
        g = [l.rstrip() for l in rd(GEN).split("\n")]
        j0 = [k for k, l in enumerate(g) if "function [63:0] xs_next8" in l][0]
        j2 = [k for k, l in enumerate(g) if k > j0 and "endfunction" in l
              and k > ([k for k, l in enumerate(g) if "function [63:0] xs_word8" in l][0])][0]
        gblk = [l.rstrip() for l in g[j0:j2 + 1]]
        ublk = [l.rstrip() for l in funcs.split("\n")]
        # 抽出的 funcs 末尾有一个空行 (join 产物), 归一化掉再比
        while ublk and ublk[-1] == "":
            ublk.pop()
        while gblk and gblk[-1] == "":
            gblk.pop()
        same = (gblk == ublk)
        print("GEN-CHECK (gen_mat8.py 输出 vs UDP 版函数块): %s (%d lines)"
              % ("IDENTICAL" if same else "*** DIFFER ***", len(ublk)))
        assert same, "gen_mat8.py 输出与 UDP 版函数块不一致 -> abort"

    new = build(old, funcs)

    # ---- 证明 1: 默认构建 (无 P7B_10G) 预处理后与改动前**逐字节相同** ----
    a = pp(old, set())
    b = pp(new, set())
    same = (a == b)
    print("PP-EQUIV default (no P7B_10G): %s  (old %d bytes / new %d bytes)"
          % ("IDENTICAL" if same else "*** DIFFER ***", len(a), len(b)))
    if not same:
        import difflib
        print("\n".join(list(difflib.unified_diff(a.split("\n"), b.split("\n"),
                                                  n=3, lineterm=""))[:60]))
        assert False, "default-build source NOT identical -> abort"

    # ---- 证明 2: P7B_10G 下语法上只增不减 ----
    c = pp(new, {"P7B_10G"})
    print("PP with P7B_10G: %d lines (default %d lines) => +%d lines"
          % (len(c.split("\n")), len(b.split("\n")),
             len(c.split("\n")) - len(b.split("\n"))))

    if check_only:
        print("CHECK-ONLY: 未写文件")
        return 0
    io.open(TGT, "w", encoding="utf-8", newline="").write(new)
    print("wrote %s (%d bytes)" % (TGT, len(new.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
