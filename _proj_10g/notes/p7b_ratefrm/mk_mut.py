# -*- coding: utf-8 -*-
"""mk_mut.py -- 生成"乒乓退化成单 bank"(= 回到收发不重叠)的变异体。

变异 = 唯一一处: RX 引擎的接受门加上"TX 侧完全空闲且无待发帧" ⇒ RX 与 TX 结构性互斥,
等价于回到默认实现的串行语义 (但保留了双 bank 结构)。用于证明**拍/帧判据有判别力**:
若不重叠, 拍/帧必须回到 ~378 而不是 191 ⇒ 判据变红。
"""
import io, os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "..", "..", "rtl", "udp_tx_frame.v")
DST = os.path.join(HERE, "mut_single_bank", "udp_tx_frame.v")

OLD = "    assign s_axis_tready = (rx_state == RX_IDLE) && !fifo_full && !bank_rdy[rx_bank];"
NEW = ("    // ==== MUTATION (仅本文件): 禁用乒乓 ⇒ RX 必须等 TX 完全空闲 ====\n"
       "    assign s_axis_tready = (rx_state == RX_IDLE) && !fifo_full && !bank_rdy[rx_bank]\n"
       "                           && (tx_state == T_IDLE) && (bank_rdy == 2'b00);")

os.makedirs(os.path.dirname(DST), exist_ok=True)
s = io.open(SRC, encoding="utf-8").read()
if OLD not in s:
    print("[MUT-FAIL] anchor not found -- rtl/udp_tx_frame.v changed?")
    sys.exit(1)
assert s.count(OLD) == 1
s = s.replace(OLD, NEW)
io.open(DST, "w", encoding="utf-8", newline="\n").write(s)
print("[MUT-OK] %s  (%d bytes, 1 处变异: RX 接受门 + 等 TX 空闲)" % (DST, len(s)))
