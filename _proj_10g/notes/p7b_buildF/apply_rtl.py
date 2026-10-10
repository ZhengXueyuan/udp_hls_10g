#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P7B 构建 F (2026-10-10) —— RTL + wrapper 的**逐处**改动.

  范围 (派单 = `_proj_10g/notes/P7B_L_INSTRUMENT_DESIGN.md` §2/§5.2):
   ① W67 = `tcp_tx_frame.stat_winstall_cap`  (板帽侧等窗拍数, 纯观测)
   ② W68 = `tcp_rx.stat_ack_adv`             (推进 snd_una 的 ACK 次数, 纯观测)
   ③ W69 = `tcp_tx_frame.o_win_at_winstall`  (等窗拍操作点锁存, 纯观测)
   ④ 快照 67 → 70 字 (`SNAP_NW_P6E` / `SNAP_P7BDP_NW` 27→30 / 三处接线 / 装配)
   ⑤ BID `0x19 → 0x1A`
   ⑥ 纯注释订正 (B8 债: 帽值注释 0xBFFE → 现役 0xF000 的"订正说明")

  形状照 `_proj_10g/notes/p7b_buildE/apply_rtl.py` + `apply_readside.py`:
  每条改动**声明期望命中数** (不足/超出 ⇒ 硬失败, 不是"静默没打上");
  行尾用**文件自身的风格** (逐文件测: tcp_tx_frame/wrapper/tcp_rx = CRLF; tcb/retx_ram = LF)。
  `--check`: 只匹配, 不落盘。
"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))

EDITS = []


def E(rel, old, new, n=1):
    EDITS.append((rel, old, new, n))


# ===========================================================================
# ① rtl/tcp_tx_frame.v —— W67 + W69 (端口 / OVL 分支 / 默认分支 / 复位)
# ===========================================================================
F = "rtl/tcp_tx_frame.v"

# ---- 端口 (两个新 output, 插在 stat_winstall 之后 / 调试探针之前) ----
E(F,
  "    output reg  [31:0] stat_winstall,\n"
  "    // ---- P4b-7-P6 调试探针 (纯 assign 线束输出, 不动任何逻辑) ----\n",
  "    output reg  [31:0] stat_winstall,\n"
  "    // ---- ⭐ P7B 构建 F: 窗口门停顿的「哪一侧在咬」分裂计数器 (W67; 纯观测) ---------\n"
  "    //   语义 (逐字定义 —— **哪一拍算**): 第 T 拍 +1 ⟺ 第 T 拍 `stat_winstall_ev`\n"
  "    //   成立 **且** `win_wnd_eff >= RING_CAP`。\n"
  "    //     · `win_wnd_eff` = `tcb.win_wnd_eff` = **同一个注册样本**里的\n"
  "    //       `min(snd_wnd, WIN_CAP)` (与 `win_open`/`win_inflight` 同沿、同 `win_id`、\n"
  "    //       同拍 —— tcb.v:144-148 的单个 always 块) ⇒ 本判据与产生 `wnd_open=0` 的\n"
  "    //       那个比较**同源同拍**, 不是另采一份 (所以「哪一侧在咬」与「等窗」严格配对)。\n"
  "    //   ⇒ 结构性蕴含: `stat_winstall_cap_ev ⇒ stat_winstall_ev`\n"
  "    //     ⇒ **`ΔW67 ≤ ΔW66` 逐窗恒真** (反了就是实现错 —— 这是一条免费的牙)。\n"
  "    //   ⇒ 对端侧 (对端通告窗在咬) 的拍数 = `ΔW66 − ΔW67` —— 本设计**不做**第二个\n"
  "    //     计数器 (`P7B_L_INSTRUMENT_DESIGN.md` §2.2 裁定②)。\n"
  "    //   ⚠️ 并列档归属 (必须写清): `win_wnd_eff == RING_CAP` 判为**板帽侧** (与\n"
  "    //      `tcb.v:143` 的 `snd_wnd < WIN_CAP` 同一个比较同向) ⇒ 对端**恰好**给到\n"
  "    //      WIN_CAP 时会被算成板帽侧; 结构性偏置**至多一个 16 位档**, 不影响判定。\n"
  "    //   ⚠️ 纯观测: 唯一消费者是本计数器 CE; 不驱动任何功能逻辑, 不改任何门的判据。\n"
  "    //   ⚠️ 32 位自然回卷 (156.25 MHz ⇒ 27.487 s) ⇒ 差值判据必须 mod 2^32 且记原始值。\n"
  "    output reg  [31:0] stat_winstall_cap,\n"
  "    // ---- ⭐ P7B 构建 F: 等窗拍的操作点锁存 (W69; 纯观测) --------------------------\n"
  "    //   语义 (逐字定义): 在第 T 拍, 若 `stat_winstall_ev` 成立, 则\n"
  "    //   `o_win_at_winstall <= {win_inflight, win_wnd_eff}` (**同沿同源样本**, 与那次\n"
  "    //   阻塞判据用的是同一份寄存器样本); 否则**保持**。\n"
  "    //   ⇒ 它是「**最近一次因窗口而没开成帧**那一刻的 (在飞, 有效窗)」;\n"
  "    //     高 16 位 = `win_inflight`, 低 16 位 = `win_wnd_eff`。\n"
  "    //   ⚠️ **读法边界 (必须遵守)**: 本字是**锁存字** —— 只在同窗 `ΔW66 > 0` 时才\n"
  "    //      属于本窗; `ΔW66 == 0` ⇒ 它是**上一次**留下的陈旧值, **不许读**\n"
  "    //      (与 W57 `retx_hi` 的「只在 retx_active=1 时有效」同款口径)。\n"
  "    //   ⚠️ 纯观测: 只多 `stat_winstall_ev` 的 32 个 CE 扇出, 不碰功能路径。\n"
  "    output reg  [31:0] o_win_at_winstall,\n"
  "    // ---- P4b-7-P6 调试探针 (纯 assign 线束输出, 不动任何逻辑) ----\n", 1)

# ---- OVL 分支: 谓词 (紧跟 stat_winstall_ev) ----
E(F,
  "                                   !fifo_full && !bank_rdy[rx_bank] &&\n"
  "                                   !tx_blk_sid && !wnd_open;\n",
  "                                   !fifo_full && !bank_rdy[rx_bank] &&\n"
  "                                   !tx_blk_sid && !wnd_open;\n"
  "    // ⭐ 构建 F (W67): 窗口门的「哪一侧在咬」—— 与上面那条**同源同拍**的第二投影。\n"
  "    //   判据与 `tcb.v:143` 的 `snd_wnd < WIN_CAP` **同型式** (不相等 ⟺ 生效帽 == 板帽):\n"
  "    //     `win_cap_bind` = `win_wnd_eff >= RING_CAP`; 真 ⇒ 咬住的是**板的帽**,\n"
  "    //     假 ⇒ 咬住的是**对端通告窗**。\n"
  "    //   ⚠️ `RING_CAP` 与 `tcb.WIN_CAP` 的结构性同源 = wrapper 的单一 localparam\n"
  "    //     `WIN_CAP_5` (`board/wrapper_p4.v:227`) ⇒ `:1971` `.WIN_CAP(WIN_CAP_5)` 与\n"
  "    //     `:2135` `.RING_CAP(WIN_CAP_5)` 由同一个值下发, **不会分叉**。\n"
  "    //   ⚠️ 比较器输入是**寄存器** (tcb 的注册输出) ⇒ 不引入新的组合长链;\n"
  "    //     本线只喂 `stat_winstall_cap_ev` (唯一消费者 = 计数器 CE)。\n"
  "    wire        win_cap_bind         = (win_wnd_eff >= RING_CAP);\n"
  "    wire        stat_winstall_cap_ev = stat_winstall_ev && win_cap_bind;\n", 1)

# ---- OVL 分支: 复位 ----
E(F,
  "            stat_winstall <= 32'd0;   // P7B 构建 E: 窗口门停顿计数\n"
  "            fin_sent_r <= 16'h0; rst_sent_r <= 16'h0; fin_retx_pend <= 16'h0;\n",
  "            stat_winstall <= 32'd0;   // P7B 构建 E: 窗口门停顿计数\n"
  "            stat_winstall_cap <= 32'd0;     // P7B 构建 F: 板帽侧等窗拍数 (W67)\n"
  "            o_win_at_winstall <= 32'd0;      // P7B 构建 F: 等窗拍操作点锁存 (W69)\n"
  "            fin_sent_r <= 16'h0; rst_sent_r <= 16'h0; fin_retx_pend <= 16'h0;\n", 1)

# ---- OVL 分支: 计数 + 锁存 ----
E(F,
  "            if (stat_winstall_ev) stat_winstall <= stat_winstall + 32'd1;\n"
  "            svc_id_r <= retx_req ? retx_id : prio_lo(rto_pend);\n",
  "            if (stat_winstall_ev) stat_winstall <= stat_winstall + 32'd1;\n"
  "            // ⭐ 构建 F: W67 (板帽侧那一份) + W69 (操作点锁存; 语义/读法见端口注)\n"
  "            if (stat_winstall_cap_ev) stat_winstall_cap <= stat_winstall_cap + 32'd1;\n"
  "            if (stat_winstall_ev) o_win_at_winstall <= {win_inflight, win_wnd_eff};\n"
  "            svc_id_r <= retx_req ? retx_id : prio_lo(rto_pend);\n", 1)

# ---- 默认 (非 OVL) 分支: 谓词 ----
E(F,
  "                                   !flush_pend && !pay_full && !tx_blk_sid && !wnd_open;\n",
  "                                   !flush_pend && !pay_full && !tx_blk_sid && !wnd_open;\n"
  "    // ⭐ 构建 F (W67): 与 OVL 分支**逐字同款**的分裂判据 (语义权威在 OVL 分支处)\n"
  "    wire        win_cap_bind         = (win_wnd_eff >= RING_CAP);\n"
  "    wire        stat_winstall_cap_ev = stat_winstall_ev && win_cap_bind;\n", 1)

# ---- 默认分支: 复位 ----
E(F,
  "            stat_winstall <= 32'd0;   // P7B 构建 E: 窗口门停顿计数\n"
  "            for (ri = 0; ri < 16; ri = ri + 1) begin\n",
  "            stat_winstall <= 32'd0;   // P7B 构建 E: 窗口门停顿计数\n"
  "            stat_winstall_cap <= 32'd0;     // P7B 构建 F: 板帽侧等窗拍数 (W67)\n"
  "            o_win_at_winstall <= 32'd0;      // P7B 构建 F: 等窗拍操作点锁存 (W69)\n"
  "            for (ri = 0; ri < 16; ri = ri + 1) begin\n", 1)

# ---- 默认分支: 计数 + 锁存 ----
E(F,
  "            // ⭐ 构建 E: 窗口门停顿计数 (与 OVL 分支同款; 纯观测)\n"
  "            if (stat_winstall_ev) stat_winstall <= stat_winstall + 32'd1;\n",
  "            // ⭐ 构建 E: 窗口门停顿计数 (与 OVL 分支同款; 纯观测)\n"
  "            if (stat_winstall_ev) stat_winstall <= stat_winstall + 32'd1;\n"
  "            // ⭐ 构建 F: W67 (板帽侧那一份) + W69 (操作点锁存)\n"
  "            if (stat_winstall_cap_ev) stat_winstall_cap <= stat_winstall_cap + 32'd1;\n"
  "            if (stat_winstall_ev) o_win_at_winstall <= {win_inflight, win_wnd_eff};\n", 1)

# ===========================================================================
# ② rtl/tcp_tx_frame.v —— **纯注释**订正 (B8 债: 0xBFFE → 现役 0xF000)
# ===========================================================================
E(F,
  "    // P4c: 门控帽 0x2FFE -> 0xBFFE (窗口 12KB -> 48KB-2; tcb win 读口内亦硬编码\n"
  "    // 同值, 两处必须一致)。\n",
  "    // P4c: 门控帽 0x2FFE -> 0xBFFE (窗口 12KB -> 48KB-2; tcb win 读口内亦硬编码\n"
  "    // 同值, 两处必须一致)。\n"
  "    // ⛔ 2026-10-10 (构建 F, B8 债订正): **上面两行是 P4c 时代的历史值, 不是现役值** ——\n"
  "    //   现役帽 = **`0xF000` (61440 B; P7B-LONGSEND 轮抬帽)**, 单一真值源 = wrapper 的\n"
  "    //   localparam `WIN_CAP_5` (`board/wrapper_p4.v:227`), 由它同时下发 `tcb.WIN_CAP`\n"
  "    //   (`:1971`) 与本模块 `RING_CAP` (`:2135`) ⇒ **两处(三处)结构性同值, 不分叉**。\n"
  "    //   ⚠️ 下面 `RING_CAP` 的**参数默认值 `0xBFFE` 只是给不传参例化 (各单元 TB) 用的\n"
  "    //   历史默认值** —— 它不是板上现役值, 也不是行为契约 (改它 = 改行为, 本轮不动)。\n"
  "    //   ⚠️ 本注释块内所有**由帽值派生的数字** (如 53244 / 48KB) 仍是按 0xBFFE 写的\n"
  "    //   历史在案值, 现役帽 (0xF000) 下的对应量**本轮未重算** (如实登记, 不猜)。\n", 1)

E(F,
  "    // (帽 0xBFFE << 64K, 无 16 位化边角)。\n",
  "    // (帽 0xBFFE << 64K, 无 16 位化边角; ⚠️ 现役帽 = 0xF000, 见上面 B8 订正块)。\n", 1)

E(F,
  "    // RING_CAP 帽 (0xBFFE) 钳位后的对端通告窗, 比较在 tcb win 读口内完成\n",
  "    // RING_CAP 帽钳位后的对端通告窗 (**该值现役 = 0xF000**; `0xBFFE` = 历史默认值,\n"
  "    // 见本模块参数处的 B8 订正块), 比较在 tcb win 读口内完成\n", 1)

E(F,
  "    // 为终点, 不是最差路径)。1 拍陈旧性分析 (RING_CAP 0xBFFE, 最坏误开 ≤\n",
  "    // 为终点, 不是最差路径)。1 拍陈旧性分析 (RING_CAP **现役 0xF000** / 历史默认\n"
  "    // 0xBFFE, 最坏误开 ≤\n", 1)

# ===========================================================================
# ③ rtl/tcb.v —— 纯注释订正 (B8 债)
# ===========================================================================
E("rtl/tcb.v",
  "    // P5: 窗口门控帽提为参数 (原先硬编码 16'hBFFE)。必须与\n"
  "    // tcp_tx_frame.RING_CAP 同值 (P4c 起两处同值 0xBFFE; wrapper 显式传参,\n"
  "    // 避免日后分叉)。默认值 = 历史硬编码值, 行为不变。\n",
  "    // P5: 窗口门控帽提为参数 (原先硬编码 16'hBFFE)。必须与\n"
  "    // tcp_tx_frame.RING_CAP 同值 (P4c 起两处同值 0xBFFE; wrapper 显式传参,\n"
  "    // 避免日后分叉)。默认值 = 历史硬编码值, 行为不变。\n"
  "    // ⛔ 2026-10-10 (构建 F, B8 债订正): 上面那句「两处同值 **0xBFFE**」是 **P4c 时代的\n"
  "    //   历史值** —— **现役帽 = `0xF000` (61440 B; P7B-LONGSEND 轮抬帽)**, 单一真值源 =\n"
  "    //   `board/wrapper_p4.v:227` 的 `WIN_CAP_5`, 由它同时下发本模块 (`.WIN_CAP(WIN_CAP_5)`,\n"
  "    //   `wrapper_p4.v:1971`) 与 `tcp_tx_frame` (`.RING_CAP(WIN_CAP_5)`, `wrapper_p4.v:2135`)\n"
  "    //   ⇒ **三处同值由构造保证, 不会分叉**。下面 `WIN_CAP` 的**参数默认值 `0xBFFE` 只是\n"
  "    //   给不传参例化 (各单元 TB) 用的历史默认值**, 不是板上现役值 (改它 = 改行为)。\n", 1)

E("rtl/tcb.v",
  "    // P4c: 门控帽 0x2FFE -> 0xBFFE (窗口 12KB -> 48KB-2; 与 tcp_tx_frame\n"
  "    // RING_CAP 硬编码同值, 两处必须一致)。结构性安全界同步放宽: ring 物理\n"
  "    // 容量 65536 字节/conn (retx_ram 13 位 ring 字 idx), 最坏在飞 =\n"
  "    // (0xBFFE-1) + plen_max 4095 = 53244 < 65536 — 硬 ring 界仍成立。\n",
  "    // P4c: 门控帽 0x2FFE -> 0xBFFE (窗口 12KB -> 48KB-2; 与 tcp_tx_frame\n"
  "    // RING_CAP 硬编码同值, 两处必须一致)。结构性安全界同步放宽: ring 物理\n"
  "    // 容量 65536 字节/conn (retx_ram 13 位 ring 字 idx), 最坏在飞 =\n"
  "    // (0xBFFE-1) + plen_max 4095 = 53244 < 65536 — 硬 ring 界仍成立。\n"
  "    // ⛔ 2026-10-10 (构建 F, B8 债订正): 本行(`0xBFFE`/53244)与上一行(`0xBFFE`)都是\n"
  "    //   **P4c 历史值** —— 现役帽 = **`0xF000`** (单一真值源 = wrapper 的 `WIN_CAP_5`,\n"
  "    //   见本模块参数处的 B8 订正块); 现役帽下的最坏在飞**本轮未重算** (如实登记)。\n", 1)

# ===========================================================================
# ④ rtl/retx_ram.v —— 纯注释订正 (B8 债)
# ===========================================================================
E("rtl/retx_ram.v",
  "// (RING_CAP 0xBFFE - 1) + plen_max 4095 = 53244 字节, 且 2^16 使回绕 = 掩码\n",
  "// (RING_CAP 0xBFFE - 1) + plen_max 4095 = 53244 字节, 且 2^16 使回绕 = 掩码\n"
  "// ⛔ 2026-10-10 (构建 F, B8 债订正): `0xBFFE`/53244 是 **P4c 历史值** —— 现役帽 =\n"
  "//   **`0xF000` (61440 B)**, 单一真值源 = `board/wrapper_p4.v:227` 的 `WIN_CAP_5`\n"
  "//   (它同时下发 tcb 与 tcp_tx_frame) ⇒ 下面 64KB 容量的结论**方向不变**, 但现役帽\n"
  "//   下的最坏在飞**本轮未重算** (如实登记, 不猜); 「48KB」同属历史值。\n", 1)

# ===========================================================================
# ⑤ rtl/tcp_rx.v —— W68 (端口 / 计数器 / 复位)
# ===========================================================================
R = "rtl/tcp_rx.v"

E(R,
  "    output reg  [31:0] stat_ack,           // ACK 请求数\n"
  "    output reg  [31:0] stat_bytes,         // 接受且 FCS 好的载荷字节\n",
  "    output reg  [31:0] stat_ack,           // ACK 请求数\n"
  "    // ---- ⭐ P7B 构建 F: 「推进 snd_una 的 ACK」事件计数器 (W68; 纯观测) ------------\n"
  "    //   语义 (逐字定义 —— **哪一拍算**): 第 T 拍 +1 ⟺ 第 T 拍\n"
  "    //     `fend && s_axis_tcrs && ack_adv_l && !fend_trunc`\n"
  "    //   (谓词与 :551 那条**逐字同款** —— 那里用它清 `in_retx/dup_cnt`; 本字只**计数**。\n"
  "    //   ⚠️ 刻意**不改成共用一根线**: 那会动到功能路径上的表达式, 违反本轮「纯观测」口径;\n"
  "    //   两处若将来分叉, 以 :551 的功能语义为准 —— 本字的口径定义在上面的表达式里)。\n"
  "    //   ⇒ 口径 = **事件数** (不是拍数): 每次 = 「对端发来一个把**该连接** `snd_una`\n"
  "    //     往前推的 ACK」。\n"
  "    //   ⚠️ 与既有 `stat_ack` (:579, = **本板要回**的 ACK 数) **完全不是一回事**, 读表别混。\n"
  "    //   · `fend` 拍是本帧唯一的收尾拍 ⇒ 每帧至多 +1, 不会重复计;\n"
  "    //   · `ack_ok` 已把「ACK 必须落在 [snd_una, ack_hi]」做掉 (:300) ⇒ 乱序/陈旧 ACK\n"
  "    //     不会误计;\n"
  "    //   · `conn_id_l` 是**该帧的连接** (不随 rb_id 复用而漂) ⇒ 天然不分槽。\n"
  "    //   ⚠️ 已知边角 (如实登记; `P7B_L_INSTRUMENT_DESIGN.md` §2.3 边角 4): `ack_adv_l` 用\n"
  "    //     的是 w5 拍采样的 `ra_snd_una`, 而 TCB 落地要到 drain 的 `drn==2` 拍 ⇒ 若**另一条**\n"
  "    //     ACK 的 drain 恰在 w5→fend (1-2 拍) 内推进了同一连接的 snd_una, 本帧会被**多计\n"
  "    //     一次** (分母略大 ⇒ `L` 略小)。**发生率未量** —— 要精确时用设计件 §2.3 的变体\n"
  "    //     `E_ack'` (tcb 写口比较版)。\n"
  "    //   ⚠️ 纯观测: 谓词全是既有寄存器 + 本计数器不回喂任何功能逻辑。\n"
  "    //   ⚠️ 32 位自然回卷 (156.25 MHz ⇒ 27.487 s) ⇒ 差值判据必须 mod 2^32 且记原始值。\n"
  "    output reg  [31:0] stat_ack_adv,\n"
  "    output reg  [31:0] stat_bytes,         // 接受且 FCS 好的载荷字节\n", 1)

E(R,
  "            stat_drop_crc <= 0; stat_drop_seq <= 0; stat_ack <= 0; stat_bytes <= 0;\n",
  "            stat_drop_crc <= 0; stat_drop_seq <= 0; stat_ack <= 0; stat_bytes <= 0;\n"
  "            stat_ack_adv <= 32'd0;   // P7B 构建 F: 推进 snd_una 的 ACK 数 (W68)\n", 1)

E(R,
  "            if (accept) words_in <= words_in + 32'd1;\n"
  "            if (ack_req) stat_ack <= stat_ack + 1;\n",
  "            if (accept) words_in <= words_in + 32'd1;\n"
  "            if (ack_req) stat_ack <= stat_ack + 1;\n"
  "            // ⭐ 构建 F (W68): 推进 ACK 事件计数 (逐字定义见端口注; 纯观测)\n"
  "            if (ack_adv_ev) stat_ack_adv <= stat_ack_adv + 32'd1;\n", 1)

# 谓词线: 声明在与 :551 同层的作用域 (模块级), 放在 `fend_trunc` 之后
E(R,
  "    assign fend   = fend_w6 || fend_w6t || fend_w6a || fend_pay || fend_pad || fend_trunc;\n",
  "    assign fend   = fend_w6 || fend_w6t || fend_w6a || fend_pay || fend_pad || fend_trunc;\n"
  "    // ⭐ 构建 F (W68) 的判据线 (纯观测; 与 :551 那条功能判据**逐字同款**, 见端口注).\n"
  "    //   ⚠️ 不复用 :551 的表达式 = 不动功能路径 (本轮硬口径); 两处的**语义**由端口注钉死。\n"
  "    wire        ack_adv_ev = fend && s_axis_tcrs && ack_adv_l && !fend_trunc;\n", 1)

# ===========================================================================
# ⑥ board/wrapper_p4.v —— 源线声明 / 例化接线 / 扩窗 67→70 / BID
# ===========================================================================
W = "board/wrapper_p4.v"

E(W,
  "    wire [31:0] tx_stat_winstall;\n",
  "    wire [31:0] tx_stat_winstall;\n"
  "    // ⭐ 构建 F: 两个新仪器线的声明 —— 与 W66 同款, 放在 `ifdef APP_MODE` **之外**\n"
  "    //   (tcp_tx_frame 的例化在所有构建里都发生; 只在分支里声明会让默认构建退化成\n"
  "    //   隐式 1 位网 ⇒ 静默截断, 工程坑 24)。\n"
  "    wire [31:0] tx_stat_winstall_cap;   // 槽 27 → W67 (板帽侧等窗拍数)\n"
  "    wire [31:0] tx_win_at_winstall;     // 槽 29 → W69 (等窗拍操作点锁存)\n", 1)

E(W,
  "    wire [31:0] rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,\n"
  "                rx_stat_seq, rx_stat_ack, rx_stat_bytes_tcp;\n",
  "    wire [31:0] rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,\n"
  "                rx_stat_seq, rx_stat_ack, rx_stat_bytes_tcp;\n"
  "    // ⭐ 构建 F: W68 = `tcp_rx.stat_ack_adv` (推进 snd_una 的 ACK 次数; dp 域寄存器输出)\n"
  "    //   ⚠️ `tcp_rx` 的例化在 `ifdef APP_MODE` **之外** (与 tx_stat_winstall 同款) ⇒ 不包守卫。\n"
  "    wire [31:0] rx_stat_ack_adv;\n", 1)

E(W,
  "        .stat_winstall  (tx_stat_winstall),   // 构建 E: W66 的源 (窗口门停顿)\n",
  "        .stat_winstall  (tx_stat_winstall),   // 构建 E: W66 的源 (窗口门停顿)\n"
  "        .stat_winstall_cap (tx_stat_winstall_cap), // 构建 F: W67 的源 (板帽侧那一份)\n"
  "        .o_win_at_winstall (tx_win_at_winstall),   // 构建 F: W69 的源 (操作点锁存)\n", 1)

E(W,
  "        .stat_ack           (rx_stat_ack),\n",
  "        .stat_ack           (rx_stat_ack),\n"
  "        .stat_ack_adv       (rx_stat_ack_adv),   // 构建 F: W68 的源 (推进 ACK 事件数)\n", 1)

# ---- 扩窗: 总字数 67 → 70 ----
E(W,
  "    localparam SNAP_NW_P6E = 67;        // 总字数 W0..W66 (未实现地址 = 0x12C = word 75)\n",
  "    // ⭐ P7B 构建 F (2026-10-10): 67 → **70** (三个**纯观测**仪器同批: W67 = 帧器侧窗口门的\n"
  "    //   **板帽侧**那一份 / W68 = `tcp_rx` 的**推进 ACK 事件数** (L 的分母) / W69 = 等窗拍的\n"
  "    //   **操作点锁存**)。动机/语义逐字 = `_proj_10g/notes/P7B_L_INSTRUMENT_DESIGN.md` §2\n"
  "    //   (派单 = 「把 L 拆开」: 现状 `L = (W/1518)(P−193)` 全靠换算 ⇒ 本批把它变成\n"
  "    //   **两个板内计数器之比** `L = ΔW66/ΔW68`)。\n"
  "    //   预算复算: 70 ≤ 119 (7 位译码上限) ✓; 未实现地址 = 0x20+4*70 = **0x138** (word 78,\n"
  "    //   真正未实现); `{snap_idx,5'b0}` 最大 = (70-1)<<5 = 2208 < 4096 ⇒ `axi_regs.snap_base`\n"
  "    //   仍是 [11:0] (**不动**); `snap_idx = r_word[6:0]-8` 最大 69 ⇒ 7 位 ✓ (回绕红线 ≥0x200)。\n"
  "    //   ⚠️ 三个新字**全部进 p7bdp 束** (SNAP_P7BDP_NW 27 → 30): W67/W69 的源在\n"
  "    //   `tcp_tx_frame`、W68 的源在 `tcp_rx` —— **都在 `dp_clk` 域**, 且都是**寄存器输出**\n"
  "    //   (`stat_winstall_cap` / `o_win_at_winstall` / `stat_ack_adv` 都是 reg)\n"
  "    //   ⇒ 满足 snap_cdc 的前提 (\"b 域寄存器输出, 只在 clk_b 沿变化\")。\n"
  "    localparam SNAP_NW_P6E = 70;        // 总字数 W0..W69 (未实现地址 = 0x138 = word 78)\n", 1)

E(W,
  "    localparam SNAP_P7BDP_NW = 27;      // W39/W40, W45..W50 + W51..W60 (BIZ) + W61/W62 (WU)\n"
  "                                        //   + **W63/W64 (P7B-GAP9-TX 的两个停滞计数器)**\n"
  "                                        //   + **W66 (构建 E: tcp_tx_frame.stat_winstall)** (b 域 = dp_clk)\n",
  "    localparam SNAP_P7BDP_NW = 30;      // W39/W40, W45..W50 + W51..W60 (BIZ) + W61/W62 (WU)\n"
  "                                        //   + **W63/W64 (P7B-GAP9-TX 的两个停滞计数器)**\n"
  "                                        //   + **W66 (构建 E: tcp_tx_frame.stat_winstall)**\n"
  "                                        //   + **W67/W68/W69 (构建 F: 三个纯观测仪器 —— 板帽侧\n"
  "                                        //     等窗拍数 / 推进 ACK 事件数 / 等窗拍操作点锁存)** (b 域 = dp_clk)\n", 1)

E(W,
  "    wire [SNAP_P7BDP_NW*32-1:0] p7bdp_dout;  // [0..26] → 槽 0..26 (BIZ 12→16; WU 16→24; GAP9-TX 24→26; 构建 E 26→27)\n",
  "    wire [SNAP_P7BDP_NW*32-1:0] p7bdp_dout;  // [0..29] → 槽 0..29 (BIZ 12→16; WU 16→24; GAP9-TX 24→26; 构建 E 26→27; 构建 F 27→30)\n", 1)

E(W,
  "    wire [31:0] biz_w66 = tx_stat_winstall; // 槽 26 → W66 窗口门停顿 (构建 E)\n",
  "    wire [31:0] biz_w66 = tx_stat_winstall; // 槽 26 → W66 窗口门停顿 (构建 E)\n"
  "    // ⭐ 构建 F (2026-10-10): 三个纯观测仪器 —— 与 W55/W66 同款: 它们的源在两个模块的\n"
  "    //   **例化在 `ifdef APP_MODE` 之外** 的位置 (tcp_tx_frame / tcp_rx) ⇒ **任何构建里都存在**\n"
  "    //   ⇒ 不包守卫兜常量 (包了反而白丢真值)。\n"
  "    //   语义逐字定义 = `rtl/tcp_tx_frame.v` 的两个新端口注 + `rtl/tcp_rx.v` 的 `stat_ack_adv` 注。\n"
  "    //   ⚠️ 全 32 位计数器 ⇒ 差值判据必须 mod 2^32 且记原始值 (全局 #55)。\n"
  "    wire [31:0] biz_w67 = tx_stat_winstall_cap; // 槽 27 → W67 板帽侧等窗拍数 (构建 F)\n"
  "    wire [31:0] biz_w68 = rx_stat_ack_adv;      // 槽 28 → W68 推进 snd_una 的 ACK 次数 (构建 F)\n"
  "    wire [31:0] biz_w69 = tx_win_at_winstall;   // 槽 29 → W69 等窗拍 {在飞, 有效窗} 锁存 (构建 F)\n", 1)

E(W,
  "    assign p7bdp_din[26*32 +: 32] = biz_w66;   // 槽 26 → W66 tcp_tx_frame.stat_winstall (构建 E)\n",
  "    assign p7bdp_din[26*32 +: 32] = biz_w66;   // 槽 26 → W66 tcp_tx_frame.stat_winstall (构建 E)\n"
  "    assign p7bdp_din[27*32 +: 32] = biz_w67;   // 槽 27 → W67 tcp_tx_frame.stat_winstall_cap (构建 F)\n"
  "    assign p7bdp_din[28*32 +: 32] = biz_w68;   // 槽 28 → W68 tcp_rx.stat_ack_adv (构建 F)\n"
  "    assign p7bdp_din[29*32 +: 32] = biz_w69;   // 槽 29 → W69 tcp_tx_frame.o_win_at_winstall (构建 F)\n", 1)

E(W,
  "    // ---- 67 字装配 (**逐项写出**: 每项的槽号在注释里, 不依赖\"从右往左\"的记忆) ----\n"
  "    //   ⭐ 构建 E: 新增 W66 落在**最上面** (= MSB 端); 旧 66 项逐项未动。\n",
  "    // ---- 70 字装配 (**逐项写出**: 每项的槽号在注释里, 不依赖\"从右往左\"的记忆) ----\n"
  "    //   ⭐ 构建 F: 新增 W67/W68/W69 落在**最上面** (= MSB 端); 旧 67 项逐项未动。\n"
  "    //   ⭐ 构建 E: 新增 W66 落在**最上面** (= MSB 端); 旧 66 项逐项未动。\n", 1)

E(W,
  "    wire [SNAP_NW_P6E*32-1:0] snap_dout_all = {\n"
  "        p7bdp_dout[26*32 +: 32],   // W66 tcp_tx_frame.stat_winstall (帧器侧窗口门停顿拍数; 构建 E)\n",
  "    wire [SNAP_NW_P6E*32-1:0] snap_dout_all = {\n"
  "        p7bdp_dout[29*32 +: 32],   // W69 tcp_tx_frame.o_win_at_winstall (等窗拍 {在飞, 有效窗} 锁存; 构建 F)\n"
  "        p7bdp_dout[28*32 +: 32],   // W68 tcp_rx.stat_ack_adv (推进 snd_una 的 ACK 次数; 构建 F)\n"
  "        p7bdp_dout[27*32 +: 32],   // W67 tcp_tx_frame.stat_winstall_cap (板帽侧等窗拍数; 构建 F)\n"
  "        p7bdp_dout[26*32 +: 32],   // W66 tcp_tx_frame.stat_winstall (帧器侧窗口门停顿拍数; 构建 E)\n", 1)

E(W,
  "    //   ⚠️ 非 P7B 构建里三条新束的 din 全是常量 ⇒ 后 **31** 个字读回恒 0\n"
  "    //      (3 + (27-4) + 5 = 31; 预期, 不是缺陷 —— 原注写 27 是 24 槽时代的口径, 就地订正\n"
  "    //       + 构建 E 把 26→27 槽 ⇒ 30→31);\n",
  "    //   ⚠️ 非 P7B 构建里三条新束的 din 全是常量 ⇒ 后 **34** 个字读回恒 0\n"
  "    //      (3 + (30-4) + 5 = 34; 预期, 不是缺陷 —— 原注写 27 是 24 槽时代的口径, 就地订正\n"
  "    //       + 构建 E 把 26→27 槽 ⇒ 30→31 + 构建 F 把 27→30 槽 ⇒ 33→34);\n", 1)

E(W,
  "        .BUILD_ID_V (32'h00000019),     // ⚠️ 每次改动自增 (前置闸读这一项认位流; 构建 E = 0x19)\n",
  "        .BUILD_ID_V (32'h0000001A),     // ⚠️ 每次改动自增 (前置闸读这一项认位流; 构建 F = 0x1A)\n"
  "                                        //   26 = **P7B 构建 F** (2026-10-10): 快照 67 → **70 字**\n"
  "                                        //        (三个**纯观测**仪器: W67 = `tcp_tx_frame.stat_winstall_cap`\n"
  "                                        //         (板帽侧等窗拍数; 只需一个 16 位比较 —— `win_wnd_eff` 本来\n"
  "                                        //         就是 `min(snd_wnd, WIN_CAP)` 且已是该模块输入端口) /\n"
  "                                        //         W68 = `tcp_rx.stat_ack_adv` (推进 `snd_una` 的 ACK 事件数;\n"
  "                                        //         谓词与 `tcp_rx.v:551` 逐字同款 —— 那里已存在) /\n"
  "                                        //         W69 = `tcp_tx_frame.o_win_at_winstall` (最近一次等窗拍的\n"
  "                                        //         `{win_inflight, win_wnd_eff}` 锁存)。\n"
  "                                        //         设计件 = `_proj_10g/notes/P7B_L_INSTRUMENT_DESIGN.md` §2。\n"
  "                                        //         ⚠️ 三个字**全部纯观测**: 不接进任何功能路径、不改任何门的判据\n"
  "                                        //         (唯一的结构性新逻辑 = 一个 16 位比较 + 三处计数器 CE + 1 个\n"
  "                                        //         32 位锁存)。⚠️ W69 的读法边界 = **仅当同窗 ΔW66 > 0 时有效**。\n"
  "                                        //        RTL 改动 = ①`rtl/tcp_tx_frame.v`: 两个新 output + 两分支各一处\n"
  "                                        //         谓词/计数/锁存 + 复位 (计数块在两个 ifdef 分支里都出现 = 2 次,\n"
  "                                        //         `check_window.py` 判据 12 静态数这一项) ②`rtl/tcp_rx.v`: 一个新\n"
  "                                        //         output + 一处谓词线 + 一处计数 + 一处复位。\n"
  "                                        //        ⚠️ 未实现地址随之 0x12C → **0x138** (word 78);\n"
  "                                        //        验收脚本/取数器的 NW 与 UNIMPL_ADDR 必须跟着改\n"
  "                                        //        (`SNAP_WORDS=70 UNIMPL_ADDR=0x138 EXPECT_BID=0x1A`)。\n"
  "                                        //   ---- (以下为历史, 逐字保留) ----\n", 1)

E(W,
  "        .SNAP_NW    (SNAP_NW_P6E)       // 67 = 14+22 (snap_seq) + 3+(27-4)+5 (P7b 三束; 构建 E 26→27)\n",
  "        .SNAP_NW    (SNAP_NW_P6E)       // 70 = 14+22 (snap_seq) + 3+(30-4)+5 (P7b 三束; 构建 F 27→30)\n", 1)

E(W,
  "                                        //   ⚠️ 2026-10-10 (P7B-A7): 原 65 / 末项 4 → **5**\n",
  "                                        //   ⚠️ 2026-10-10 (构建 F): 70 = 14+22 + 3+(30-4) + 5\n"
  "                                        //      (P7B-GAP9-TX 24→26; 构建 E 26→27; 构建 F 27→30)。\n"
  "                                        //   ⚠️ 2026-10-10 (P7B-A7): 原 65 / 末项 4 → **5**\n", 1)


def rd(p):
    b = open(p, "rb").read()
    return b, (b"\r\n" if b.count(b"\r\n") else b"\n")


def main():
    check = "--check" in sys.argv[1:]
    fails = []
    for rel, old, new, n in EDITS:
        p = os.path.join(REPO, rel.replace("/", os.sep))
        b, nl = rd(p)
        old2 = old.replace("\n", nl.decode())
        new2 = new.replace("\n", nl.decode())
        s = b.decode("utf-8")
        k = s.count(old2)
        tag = "OK  " if k == n else "FAIL"
        print("%s %-24s hits=%d/%d  %s" % (tag, rel, k, n, old.split("\n")[0].strip()[:58]))
        if k != n:
            fails.append((rel, k, n, old.split("\n")[0][:80]))
            continue
        if not check:
            io.open(p, "w", encoding="utf-8", newline="").write(s.replace(old2, new2))
    print("APPLY_RTL %s (%d edits, %d fail)" % ("OK" if not fails else "FAIL", len(EDITS), len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
