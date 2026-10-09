#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P7B 构建 E —— RTL/顶层改动 (显式清单; 每条断言命中数, 不做任何通配替换).
   ① rtl/tcp_tx_frame.v : 新增 `stat_winstall` (帧器侧**窗口门**停顿计数器; 两个分支同一语义)
   ② rtl/app_pattern.v  : A3 修复 —— 被吞的 ev_up 变成**待补事件** (up_pend_r)
   ③ board/wrapper_p4.v : 快照 66 → 67 字 (W66 = stat_winstall) + BUILD_ID_V 0x18 → 0x19
   行尾: 插入行用**文件自身的**行尾风格 (CRLF 文件插 CRLF; LF 文件插 LF).
   用法: python apply_rtl.py [--check]   (--check = 只报命中数, 不写盘)
"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def rd(p):
    b = open(p, "rb").read()
    return b, (b"\r\n" if b.count(b"\r\n") else b"\n")


EDITS = []


def E(rel, old, new, n=1):
    EDITS.append((rel, old, new, n))


# ===========================================================================
# ① rtl/tcp_tx_frame.v
# ===========================================================================
# ---- A1: 端口声明 (放在 stat_tlast_in 之后, 紧跟其后的 P4b-7-P6 调试探针注释之前) ----
E("rtl/tcp_tx_frame.v",
  "    output reg  [31:0] stat_tlast_in,\n"
  "    // ---- P4b-7-P6 调试探针",
  "    output reg  [31:0] stat_tlast_in,\n"
  "    // ---- ⭐ P7B 构建 E: 帧器侧**窗口门**停顿计数器 (纯观测) ---------------------\n"
  "    //   语义 (哪一拍算) = 帧器**站在数据帧启动点**、呈交口**确实有字**、启动门的\n"
  "    //   **其余每一项都开**、而**唯一关着的门是 `wnd_open`** ⇒ 等价表述:\n"
  "    //   \"把 `wnd_open` 换成 1, 这一拍就正好是 `start_data` 拍\"。\n"
  "    //   逐拍定义 / 不算的边界 / 与 app 侧 W64 的关系 = OVL 分支 `stat_winstall_ev`\n"
  "    //   处那段注释 (**两个分支同一语义, 那一段是唯一权威**)。\n"
  "    //   ⚠️ 纯观测: 不驱动任何功能逻辑, 不改任何门的判据 (默认构建数据行为逐位不变)。\n"
  "    //   ⚠️ 32 位自然回卷 (156.25 MHz ⇒ 27.487 s) ⇒ 差值判据必须 mod 2^32 且记原始值。\n"
  "    output reg  [31:0] stat_winstall,\n"
  "    // ---- P4b-7-P6 调试探针", 1)

# ---- A2: OVL 分支的判据线 (紧跟 start_data 定义) ----
E("rtl/tcp_tx_frame.v",
  "    wire        start_data = (rx_state == RX_IDLE) && recv_first && !ack_pend_r &&\n"
  "                             !svc && !ring_eval && !scan_now && !rx_flush &&\n"
  "                             s_axis_tvalid && !fifo_full && !bank_rdy[rx_bank] &&\n"
  "                             wnd_open && !tx_blk_sid;\n",
  "    wire        start_data = (rx_state == RX_IDLE) && recv_first && !ack_pend_r &&\n"
  "                             !svc && !ring_eval && !scan_now && !rx_flush &&\n"
  "                             s_axis_tvalid && !fifo_full && !bank_rdy[rx_bank] &&\n"
  "                             wnd_open && !tx_blk_sid;\n"
  "\n"
  "    // ================= ⭐ P7B 构建 E: 帧器侧窗口门停顿计数器 =================\n"
  "    //   (W66; 默认分支 `else` 侧有**逐字同款**的一份, 语义以此处为权威)\n"
  "    //\n"
  "    //   【语义定义 —— 哪一拍算】同时满足这四组:\n"
  "    //     ① `rx_state == RX_IDLE && recv_first`\n"
  "    //        = 帧器**站在数据帧启动点**: 本帧一拍都还没吞 (recv_first 在吞下首拍\n"
  "    //          的那一刻才落 0) ⇒ \"想开一个新数据帧\"的那个点。\n"
  "    //     ② `s_axis_tvalid`\n"
  "    //        = 呈交口**确实有字** (不是空等) ⇒ \"想开\"是真的有货要开。\n"
  "    //     ③ 启动门的**其余每一项都开**: `!ack_pend_r && !svc && !ring_eval &&\n"
  "    //        !scan_now && !rx_flush && !fifo_full && !bank_rdy[rx_bank] && !tx_blk_sid`\n"
  "    //        (逐项 = `start_data` 里除 wnd_open 之外的全部合取项)。\n"
  "    //     ④ `!wnd_open` = **唯一**关着的门是窗口门 (tcb 注册输出: 32 位回绕正确的\n"
  "    //        在飞差 vs 帽 `min(snd_wnd, RING_CAP)`; 门本体在 tcb.v:142-148)。\n"
  "    //\n"
  "    //   等价表述 (判据只用它解释, 不用它实现): `stat_winstall_ev ⟺ (以 wnd_open:=\n"
  "    //   1'b1 代入 start_data) && !wnd_open` ⇒ 计数 = 帧器**因窗口而没能开帧**的拍数。\n"
  "    //\n"
  "    //   【哪一拍不算 —— 逐条边界 (每一条都是刻意的排除, 混进来就失去判别力)】\n"
  "    //     · 帧内拍 (recv_first==0 / rx_state!=RX_IDLE): 不算 —— 帧已经开着,\n"
  "    //       \"开新帧\"这个语义不适用 (帧内续传的门在 S_RECV 子句, 不含 wnd_open);\n"
  "    //     · `s_axis_tvalid==0`: 不算 —— 那是\"没得开\"不是\"想开被挡\"\n"
  "    //       (帧器真闲着的拍归 W65 线占空 / W63 app 侧 frm_wait 那一侧读);\n"
  "    //     · 被**别的**门挡着 (ACK 优先 ack_pend_r/svc · 轮扫 scan_now · 重放 ring_eval\n"
  "    //       · 冲洗 rx_flush · 载荷 FIFO 满 fifo_full · 本 bank 还在被 TX 引擎发\n"
  "    //       bank_rdy[rx_bank] · FIN/RST fence / 非 ESTAB / r6 的\"对端首个 ACK 未到\"\n"
  "    //       合成项 tx_blk_sid) ⇒ **一律不算**。本字只量窗口这一格 —— W64 里\"帧器忙\n"
  "    //       别的事\"的那部分要**减掉本字之后**才归它 (见下面与 W64 的关系)。\n"
  "    //     · 复位拍: rx_state=RX_IDLE/recv_first=1 但 tvalid=0 ⇒ 结构性不算。\n"
  "    //\n"
  "    //   【与 app 侧 W64 (`app_pattern.stat_bp_cyc`) 的关系】\n"
  "    //     W64 的口径 = `pw_valid && !m_tready && !closing && !bad_frm` (app 有字压在\n"
  "    //     自己的呈交口上、帧器经 axis_pipe 不收) —— 它把\"等窗口\"和\"帧器忙别的\"\n"
  "    //     **混在一起**, 分不出是哪一种 (这正是本字要补的那一格)。\n"
  "    //     方向: **W64 是该停顿在 app 观测点上的投影, 本字是它在帧器启动点上的投影**。\n"
  "    //     帧器算的那一拍 ⇒ 呈交口有字 ⇒ 1 深 axis_pipe 满 ⇒ pipe.s_ready\n"
  "    //     (= app 的 m_tready) = 帧器端 s_axis_tready, 而本拍 s_axis_tready == 0\n"
  "    //     (④ 的 !wnd_open 正是 S_IDLE 子句里那一项) ⇒ app 侧 `!m_tready` 成立。\n"
  "    //     ⚠️ 严格成立的式子 = `ΔW64 ≥ ΔW66 − ΔH` (同一窗): ΔH = app 侧\"呈交口上\n"
  "    //     没有字\"的拍 (字刚被 pipe 锁存的那 1 拍 / 逐字节装配拍 / opener 交接拍 /\n"
  "    //     W3 收尾拍) —— 那些拍 app 侧 W64 结构性不计 (它要求 pw_valid=1), 而帧器\n"
  "    //     侧本字照计 (pipe 里有字)。**ΔH 是有界的少数拍** (每字 ≤1 拍, 每帧边界\n"
  "    //     ~1-2 拍; 且 `P7B_10G` 的 A2/整字路把装配拍压成 0), 因此**长窗下**\n"
  "    //     ΔW64 ⊇ ΔW66 逐拍成立到 ΔH 之内; 读法 = 同窗比 ΔW66 与 ΔW64:\n"
  "    //       ΔW66 ≈ ΔW64 ⇒ 帧器停顿基本**全是等窗** (window-limited);\n"
  "    //       ΔW66 ≪ ΔW64 ⇒ 其余部分 = 帧器**忙别的门** (ACK 优先/轮扫/重放/FIFO/\n"
  "    //                     bank fence), 那部分归 W63/W64 与 FSM 观测。\n"
  "    //     ⚠️ **登记过的盲区 (不许当已证)**: ΔH 本身**没有独立计数器** ⇒ 上述\n"
  "    //     \"ΔW66 ≪ ΔW64\" 只能给\"不是等窗\"的**方向**, 不能把差额逐拍归因到具体那一个门\n"
  "    //     (要那个得再补\"帧器在启动点被非窗门挡住\"的计数器 —— 本轮不做)。\n"
  "    wire        stat_winstall_ev = (rx_state == RX_IDLE) && recv_first &&\n"
  "                                   s_axis_tvalid && !ack_pend_r && !svc &&\n"
  "                                   !ring_eval && !scan_now && !rx_flush &&\n"
  "                                   !fifo_full && !bank_rdy[rx_bank] &&\n"
  "                                   !tx_blk_sid && !wnd_open;\n", 1)

# ---- A3: OVL 复位 ----
E("rtl/tcp_tx_frame.v",
  "            retx_ovf_p     <= 1'b0;\n"
  "            stat_retx <= 0;\n",
  "            retx_ovf_p     <= 1'b0;\n"
  "            stat_retx <= 0;\n"
  "            stat_winstall <= 32'd0;   // P7B 构建 E: 窗口门停顿计数\n", 1)

# ---- A4: OVL 递增 (放在 stat_retx_wrap 事件计数之后) ----
E("rtl/tcp_tx_frame.v",
  "            if (retx_ovf && retx_active && !retx_ovf_p)\n"
  "                stat_retx_wrap <= stat_retx_wrap + 32'd1;\n",
  "            if (retx_ovf && retx_active && !retx_ovf_p)\n"
  "                stat_retx_wrap <= stat_retx_wrap + 32'd1;\n"
  "            // ⭐ 构建 E: 帧器侧窗口门停顿计数 (语义见 stat_winstall_ev 处的权威注释)\n"
  "            //   口径与其它 stat_* 同族: **按当拍寄存器态**计数 (拍数, 不是事件数)。\n"
  "            if (stat_winstall_ev) stat_winstall <= stat_winstall + 32'd1;\n", 1)

# ---- A5: 默认分支的判据线 (与 OVL 分支逐条同款; 该分支的数据帧启动点 = state==S_IDLE) ----
E("rtl/tcp_tx_frame.v",
  "    wire        start_data = (state == S_IDLE) && !ack_pend_r && !svc && !ring_eval &&\n"
  "                             !scan_now && !flush_pend && s_axis_tvalid && !pay_full &&\n"
  "                             wnd_open && !tx_blk_sid;\n",
  "    wire        start_data = (state == S_IDLE) && !ack_pend_r && !svc && !ring_eval &&\n"
  "                             !scan_now && !flush_pend && s_axis_tvalid && !pay_full &&\n"
  "                             wnd_open && !tx_blk_sid;\n"
  "    // ⭐ 构建 E (默认/串行分支): 与 OVL 分支**逐条同款**的窗口门停顿判据 ——\n"
  "    //   \"数据帧启动点\" 在本分支 = `state == S_IDLE` (串行 FSM 没有 recv_first;\n"
  "    //   S_IDLE 即\"本帧一拍都还没吞\"), 其余八项逐字相同 (flush_pend↔rx_flush,\n"
  "    //   pay_full↔fifo_full, 其余同名) ⇒ 两个分支的**语义完全相同**。\n"
  "    //   完整语义/边界/与 W64 的关系 = OVL 分支 `stat_winstall_ev` 处那段注释 (权威)。\n"
  "    wire        stat_winstall_ev = (state == S_IDLE) && s_axis_tvalid &&\n"
  "                                   !ack_pend_r && !svc && !ring_eval && !scan_now &&\n"
  "                                   !flush_pend && !pay_full && !tx_blk_sid && !wnd_open;\n", 1)

# ---- A6: 默认分支复位 ----
E("rtl/tcp_tx_frame.v",
  "            svc_id_r <= 0; tick_cnt <= 0; rto_pend_any <= 0; ack_pend_r <= 0;\n"
  "            stat_retx <= 0;\n",
  "            svc_id_r <= 0; tick_cnt <= 0; rto_pend_any <= 0; ack_pend_r <= 0;\n"
  "            stat_retx <= 0;\n"
  "            stat_winstall <= 32'd0;   // P7B 构建 E: 窗口门停顿计数\n", 1)

# ---- A7: 默认分支递增 ----
E("rtl/tcp_tx_frame.v",
  "            // svc 优先编码寄存器化 (P6 时序, 见 svc_id 声明注释): 每拍刷新,\n",
  "            // ⭐ 构建 E: 窗口门停顿计数 (与 OVL 分支同款; 纯观测)\n"
  "            if (stat_winstall_ev) stat_winstall <= stat_winstall + 32'd1;\n"
  "            // svc 优先编码寄存器化 (P6 时序, 见 svc_id 声明注释): 每拍刷新,\n", 1)

# ===========================================================================
# ② rtl/app_pattern.v —— A3
# ===========================================================================
# ---- B1: ev_restart 改判据源 (= 换流真的发生), 并新增待补寄存器/判据 ----
E("rtl/app_pattern.v",
  "    wire        ev_restart = ev_up && (!active || ((ev_slot == act_id) &&\n"
  "                             (frm_wait || (seg_sent == 12'd0))));\n",
  "    // ⭐ 构建 E (A3): ev_up 的**事件源**换成 `up_ev` —— 被吞过的 ev_up 由\n"
  "    //   `up_pend_r` 补做 (见下面 ev_up 块)。判据本身 (下面 `up_ok`) **逐字未动**。\n"
  "    wire        up_ev   = ev_up || up_pend_r;\n"
  "    wire [3:0]  up_slot = ev_up ? ev_slot : up_pend_id;\n"
  "    wire        up_ok   = !active || ((up_slot == act_id) &&\n"
  "                                      (frm_wait || (seg_sent == 12'd0)));\n"
  "    wire        up_do   = up_ev && up_ok;\n"
  "    // ev_restart = \"本拍**真的**发生换流\" (旧式 = `ev_up && 判据`): 用它做\n"
  "    // ①W3 块让位 (closing && !ev_restart) ②rst_close 的撞车帧计数 ③a2_hold 的\n"
  "    // 预取抑制。改成 up_do 后这三处的语义不变 —— 补做拍上 closing 恒 0\n"
  "    // (closing ⟹ active 是块内不变量: closing 只在 active 时置位、与 active 同拍清),\n"
  "    // 且那一拍 asm_go 恒 0 ⇒ ①② 是空操作、③ 与旧行为同值。\n"
  "    wire        ev_restart = up_do;\n", 1)

# ---- B2: 待补寄存器的声明 (放在 op_pend/op_sent 之后) ----
E("rtl/app_pattern.v",
  "    reg         op_pend;       // P5e: 本帧的 0 载荷 opener 尚未呈交\n"
  "    reg         op_sent;       // P5e: 本帧 opener 已交付给 pipe (帧已\"预开\")\n",
  "    reg         op_pend;       // P5e: 本帧的 0 载荷 opener 尚未呈交\n"
  "    reg         op_sent;       // P5e: 本帧 opener 已交付给 pipe (帧已\"预开\")\n"
  "    // ---- ⭐ 构建 E (A3): 被吞的 CONN_UP 的**待补**位 ------------------------\n"
  "    //   缺陷 (tb_app_cont 的 u_rec1/u_rec2 已复现): ev_up 到达时若 app 正卡在\n"
  "    //   closing (等 pipe 交付收尾字, 而帧器 tready=0), 换流判据 `(frm_wait ||\n"
  "    //   seg_sent==0)` 为假 ⇒ 事件**被吞**; 而事件是 1 拍脉冲、app 又没有\"待处理\n"
  "    //   ev_up\"寄存器 ⇒ 收尾完直接回 idle, 新连接**静默零数据、无自愈**。\n"
  "    //   判别变量是\"ev_up 到达时是否仍卡在 closing\", **不是间隔 k** (k=40 ≤ tready\n"
  "    //   低窗 70 也照样被吞) ⇒ 修法必须是\"记住事件 + 补做\", 不能靠加延迟。\n"
  "    reg         up_pend_r;     // 有未消费的 CONN_UP (当时判据为假)\n"
  "    reg  [3:0]  up_pend_id;    // 它的槽号 (补做时用同一个槽)\n", 1)

# ---- B3: ev_up 块重构 (RX 侧副作用留在 raw ev_up; TX 换流走 up_do) ----
E("rtl/app_pattern.v",
  "            if (ev_up) begin\n"
  "                rx_lfsr <= SEED;\n"
  "                rxs     <= 2'd0;\n"
  "                // 新连接: 启动图案发送 (单会话; 其它槽的新事件忽略)\n",
  "            if (ev_up) begin\n"
  "                rx_lfsr <= SEED;\n"
  "                rxs     <= 2'd0;\n"
  "                // ⭐ 构建 E (A3): RX 侧副作用留在 **raw ev_up** (与旧式逐位相同):\n"
  "                //   图案流按**连接起点**认 (对端从 SEED 起发), 而新连接从 ev_up\n"
  "                //   那一刻就开始了 —— 补做换流只影响 TX 侧哪一帧起发, 不该把\n"
  "                //   RX 期望序列在补做拍再重置一次 (那会把 raw ev_up 之后收到的\n"
  "                //   合法上行字节误判成失配)。TX 换流本体在下面 `if (up_do)` 块。\n"
  "            end\n"
  "            if (up_do) begin\n"
  "                // 新连接: 启动图案发送 (单会话; 其它槽的新事件忽略)\n", 1)

# ---- B4: ev_up 块尾 (up_lat 与 end) —— 换流块独立出来后收口 ----
E("rtl/app_pattern.v",
  "                    wc_buf   <= 64'd0; wc_n <= 4'd0;\n"
  "                    bad_frm  <= (i_bad_frame == 16'd1);\n"
  "                end\n"
  "                up_lat <= 1'b1;\n"
  "            end\n",
  "                    wc_buf   <= 64'd0; wc_n <= 4'd0;\n"
  "                    bad_frm  <= (i_bad_frame == 16'd1);\n"
  "                end\n"
  "            end\n"
  "            if (ev_up) up_lat <= 1'b1;\n"
  "            // ---- ⭐ 构建 E (A3): 待补事件的登记 / 消费 / 撤销 ----------------\n"
  "            //   登记: ev_up 这一拍判据为假 (事件被吞) ⇒ 记住它 (槽号一起记);\n"
  "            //   消费: `up_do` 那一拍清掉 (= 上面换流块已执行);\n"
  "            //   撤销: 补做目标槽又来了一次 CONN_DOWN (新连接也关了) ⇒ 不再补\n"
  "            //         (不撤销的话会把一个已经拆掉的连接当成活的重新发流)。\n"
  "            //   ⚠️ 块序即优先级: 这三条都在换流块**之后**, 且互补 (up_do 与\n"
  "            //      \"ev_up && !up_ok\" 结构性互斥) ⇒ up_pend_r 单一写者、无覆盖。\n"
  "            if (up_do) up_pend_r <= 1'b0;\n"
  "            else if (ev_up) begin\n"
  "                up_pend_r  <= 1'b1;\n"
  "                up_pend_id <= ev_slot;\n"
  "            end\n"
  "            if (ev_down && up_pend_r && (ev_slot == up_pend_id) && !ev_up)\n"
  "                up_pend_r <= 1'b0;\n", 1)

# ---- B4b: 换流块的内层判据 —— 事件源换成 up_slot (判据本身逐字同款, 已抽到 up_ok) ----
E("rtl/app_pattern.v",
  "                if (!active || ((ev_slot == act_id) &&\n"
  "                                (frm_wait || (seg_sent == 12'd0)))) begin\n"
  "                    active   <= 1'b1;\n"
  "                    act_id   <= ev_slot;\n",
  "                // ⚠️ 构建 E (A3): 判据原文 = `!active || ((ev_slot == act_id) &&\n"
  "                //    (frm_wait || seg_sent==0))` —— **一字未改**, 只是把事件源\n"
  "                //    从 raw `ev_slot` 抽到 `up_slot` (= 补做事件时用登记的槽号),\n"
  "                //    并提到上面的 `up_ok` (同一个表达式, 单一来源)。\n"
  "                if (up_ok) begin\n"
  "                    active   <= 1'b1;\n"
  "                    act_id   <= up_slot;\n", 1)

# ---- B5: 复位 (无条件清待补位) ----
E("rtl/app_pattern.v",
  "            frm_wait <= 1'b0; op_pend <= 1'b0; op_sent <= 1'b0;\n",
  "            frm_wait <= 1'b0; op_pend <= 1'b0; op_sent <= 1'b0;\n"
  "            up_pend_r <= 1'b0; up_pend_id <= 4'd0;   // 构建 E (A3)\n", 1)

# ---- B6: 换流块里的\"已消费\"路径 —— 换流发生时要清待补位 (幂等; 上面已写) ----
E("rtl/app_pattern.v",
  "                    //   \"换了流\" (ev_down→closing→idle 那条路不清, 但那条路之后\n"
  "                    //   唯有 ev_up 能让 app 再发, 而 ev_up 一定会清; 见 §wb 论证)。\n"
  "                    wc_buf   <= 64'd0; wc_n <= 4'd0;\n",
  "                    //   \"换了流\" (ev_down→closing→idle 那条路不清, 但那条路之后\n"
  "                    //   唯有 ev_up 能让 app 再发, 而 ev_up 一定会清; 见 §wb 论证)。\n"
  "                    //   ⚠️ 构建 E (A3): 这条\"新会话必清 carry\"的理由**依赖 ev_up 一定\n"
  "                    //   会被消费** —— 而被吞的 ev_up 现在由 up_pend_r 补做 ⇒ 该前提\n"
  "                    //   从\"脉冲不丢\"变成\"事件不丢\"(更强), 论证仍成立。\n"
  "                    wc_buf   <= 64'd0; wc_n <= 4'd0;\n", 1)

# ===========================================================================
# ③ board/wrapper_p4.v
# ===========================================================================
# ---- C1: 总字数 66 → 67 + 注释 ----
E("board/wrapper_p4.v",
  "    localparam SNAP_NW_P6E = 66;        // 总字数 W0..W65 (未实现地址 = 0x128 = word 74)",
  "    // ⭐ P7B 构建 E (2026-10-10): 66 → **67** (W66 = `tcp_tx_frame.stat_winstall`, 帧器侧\n"
  "    //   的**窗口门**停顿计数器)。动机 = 构建 D 的三跑已经用 W64/W65 把\"帽子是帧器不收字\"\n"
  "    //   钉住, 但 W64 的语义边界是\"它在帧器**内部等窗口**时同样会涨\" ⇒ 没有帧器侧计数器,\n"
  "    //   \"帧器在等窗\"与\"帧器在忙别的门\"**分不开**。本字就是补那一格 (语义 = 本文件下方\n"
  "    //   `biz_w66` 的接线段 + `rtl/tcp_tx_frame.v` 的 stat_winstall_ev 权威注释)。\n"
  "    //   预算复算: 67 ≤ 119 (7 位译码上限) ✓; 未实现地址 = 0x20+4*67 = **0x12C** (word 75,\n"
  "    //   真正未实现); `{snap_idx,5'b0}` 最大 = (67-1)<<5 = 2112 < 4096 ⇒ `axi_regs.snap_base`\n"
  "    //   仍是 [11:0] (**不动**); `snap_idx = r_word[6:0]-8` 最大 66 ⇒ 7 位 ✓ (回绕红线 ≥0x200)。\n"
  "    //   ⚠️ 本字进的是 **p7bdp 束** (SNAP_P7BDP_NW 26 → 27): `tcp_tx_frame` 与\n"
  "    //   `app_pattern` 同在 `dp_clk` 域 ⇒ 与 W51..W64 同束同域 (snap_cdc 的前提\n"
  "    //   \"b 域寄存器输出\" 满足: `stat_winstall` 是 tcp_tx_frame 里的寄存器)。\n"
  "    localparam SNAP_NW_P6E = 67;        // 总字数 W0..W66 (未实现地址 = 0x12C = word 75)", 1)

# ---- C2: dp 束槽数 26 → 27 ----
E("board/wrapper_p4.v",
  "    localparam SNAP_P7BDP_NW = 26;      // W39/W40, W45..W50 + W51..W60 (BIZ) + W61/W62 (WU)\n"
  "                                        //   + **W63/W64 (P7B-GAP9-TX 的两个停滞计数器)** (b 域 = dp_clk)",
  "    localparam SNAP_P7BDP_NW = 27;      // W39/W40, W45..W50 + W51..W60 (BIZ) + W61/W62 (WU)\n"
  "                                        //   + **W63/W64 (P7B-GAP9-TX 的两个停滞计数器)**\n"
  "                                        //   + **W66 (构建 E: tcp_tx_frame.stat_winstall)** (b 域 = dp_clk)\n"
  "                                        //   ⚠️ 槽号 ↔ 字号**不连续**是刻意的 (W65 在 tx 束槽 4):\n"
  "                                        //      新字一律落窗口 MSB 端, 旧字逐项不动。", 1)

# ---- C3: p7bdp_dout / din 的槽注释 ----
E("board/wrapper_p4.v",
  "    wire [SNAP_P7BDP_NW*32-1:0] p7bdp_dout;  // [0..25] → 槽 0..25 (BIZ 12→16; WU 16→24; GAP9-TX 24→26)",
  "    wire [SNAP_P7BDP_NW*32-1:0] p7bdp_dout;  // [0..26] → 槽 0..26 (BIZ 12→16; WU 16→24; GAP9-TX 24→26; 构建 E 26→27)", 1)

# ---- C4: biz_w66 声明 (与 W55 同区, 都是\"任何构建里都存在\"的源) ----
E("board/wrapper_p4.v",
  "    wire [31:0] biz_w55 = tx_stat_retx;     // 槽 16: 重传/RTO 回卷次数 (F5b 的判决量)",
  "    wire [31:0] biz_w55 = tx_stat_retx;     // 槽 16: 重传/RTO 回卷次数 (F5b 的判决量)\n"
  "    // ⭐ 构建 E: 槽 26 → W66 = `tcp_tx_frame.stat_winstall` (帧器侧**窗口门**停顿拍数)。\n"
  "    //   口径: 拍数 (不是事件数); 语义逐字定义 = rtl/tcp_tx_frame.v 的 `stat_winstall_ev`\n"
  "    //   处那段注释 (权威) —— 一句话 = \"帧器站在数据帧启动点、呈交口有字、其余门全开、\n"
  "    //   只有窗口门关着\"的拍数。\n"
  "    //   ⚠️ 与 W55 同款: 源 (`tcp_tx_frame`) 的例化在 `ifdef APP_MODE` **之外** ⇒\n"
  "    //   **任何构建里都存在** ⇒ 不包守卫兜常量 (包了反而白丢一个真值)。\n"
  "    //   ⚠️ 32 位自然回卷 (156.25 MHz 下 27.487 s) ⇒ 差值判据 mod 2^32 且记原始值。\n"
  "    wire [31:0] biz_w66 = tx_stat_winstall; // 槽 26 → W66 窗口门停顿 (构建 E)", 1)

# ---- C5: p7bdp_din 槽 26 的显式 assign ----
E("board/wrapper_p4.v",
  "    assign p7bdp_din[25*32 +: 32] = biz_w64;   // 槽 25 → W64 app_pattern.stat_bp_cyc (P7B-GAP9-TX)",
  "    assign p7bdp_din[25*32 +: 32] = biz_w64;   // 槽 25 → W64 app_pattern.stat_bp_cyc (P7B-GAP9-TX)\n"
  "    assign p7bdp_din[26*32 +: 32] = biz_w66;   // 槽 26 → W66 tcp_tx_frame.stat_winstall (构建 E)", 1)

# ---- C6: 装配 (新项加在最上面 = MSB 端) ----
E("board/wrapper_p4.v",
  "    wire [SNAP_NW_P6E*32-1:0] snap_dout_all = {\n"
  "        txsnap_dout[4*32 +: 32],   // W65 mac_tx_10g.stat_tx_idle (S_IDLE 拍数 = 线占空; P7B-A7-LINE)",
  "    wire [SNAP_NW_P6E*32-1:0] snap_dout_all = {\n"
  "        p7bdp_dout[26*32 +: 32],   // W66 tcp_tx_frame.stat_winstall (帧器侧窗口门停顿拍数; 构建 E)\n"
  "        txsnap_dout[4*32 +: 32],   // W65 mac_tx_10g.stat_tx_idle (S_IDLE 拍数 = 线占空; P7B-A7-LINE)", 1)

# ---- C6b: 装配段头注释的 \"66 字\" → 67 ----
E("board/wrapper_p4.v",
  "    // ---- 66 字装配 (**逐项写出**: 每项的槽号在注释里, 不依赖\"从右往左\"的记忆) ----",
  "    // ---- 67 字装配 (**逐项写出**: 每项的槽号在注释里, 不依赖\"从右往左\"的记忆) ----\n"
  "    //   ⭐ 构建 E: 新增 W66 落在**最上面** (= MSB 端); 旧 66 项逐项未动。", 1)

# ---- C6c: 非 P7B 构建里\"后 N 个字恒 0\"的算式 (30 → 31) ----
E("board/wrapper_p4.v",
  "    //   ⚠️ 非 P7B 构建里三条新束的 din 全是常量 ⇒ 后 **30** 个字读回恒 0\n"
  "    //      (3 + (26-4) + 5 = 30; 预期, 不是缺陷 —— 原注写 27 是 24 槽时代的口径, 就地订正);",
  "    //   ⚠️ 非 P7B 构建里三条新束的 din 全是常量 ⇒ 后 **31** 个字读回恒 0\n"
  "    //      (3 + (27-4) + 5 = 31; 预期, 不是缺陷 —— 原注写 27 是 24 槽时代的口径, 就地订正\n"
  "    //       + 构建 E 把 26→27 槽 ⇒ 30→31);", 1)

# ---- C7: BUILD_ID_V 0x18 → 0x19 ----
E("board/wrapper_p4.v",
  "        .BUILD_ID_V (32'h00000018),     // ⚠️ 每次改动自增 (前置闸读这一项认位流)",
  "        .BUILD_ID_V (32'h00000019),     // ⚠️ 每次改动自增 (前置闸读这一项认位流; 构建 E = 0x19)", 1)

# ---- C8: 例化端口接线 ----
E("board/wrapper_p4.v",
  "        .stat_retx      (tx_stat_retx),\n",
  "        .stat_retx      (tx_stat_retx),\n"
  "        .stat_winstall  (tx_stat_winstall),   // 构建 E: W66 的源 (窗口门停顿)\n", 1)

# ---- C9: 线的声明 (与 tx_stat_retx 同区, ifdef 外) ----
E("board/wrapper_p4.v",
  "    wire [31:0] tx_stat_retx;    // P4b-7: 重传回卷计数 (暂留内部 wire, LED 后议)",
  "    wire [31:0] tx_stat_retx;    // P4b-7: 重传回卷计数 (暂留内部 wire, LED 后议)\n"
  "    // 构建 E: 窗口门停顿拍数 (tcp_tx_frame; 快照 W66)。声明在 ifdef **外** ——\n"
  "    //   tcp_tx_frame 的例化在所有构建里都发生 (同 tx_stat_retx 的理由):\n"
  "    //   只在分支里声明会让默认构建退化成隐式 1 位网 ⇒ 静默截断 (工程坑 24)。\n"
  "    wire [31:0] tx_stat_winstall;", 1)

# ---- C10: .SNAP_NW 接线处的算式注释 ----
E("board/wrapper_p4.v",
  "        .SNAP_NW    (SNAP_NW_P6E)       // 66 = 14+22 (snap_seq) + 3+(26-4)+5 (P7b 三束)",
  "        .SNAP_NW    (SNAP_NW_P6E)       // 67 = 14+22 (snap_seq) + 3+(27-4)+5 (P7b 三束; 构建 E 26→27)", 1)


def main():
    check = "--check" in sys.argv[1:]
    fails = []
    for rel, old, new, n in EDITS:
        p = os.path.join(REPO, rel.replace("/", os.sep))
        b, nl = rd(p)
        if nl != b"\n":
            old2 = old.replace("\n", nl.decode())
            new2 = new.replace("\n", nl.decode())
        else:
            old2, new2 = old, new
        s = b.decode("utf-8")
        k = s.count(old2)
        tag = "OK  " if k == n else "FAIL"
        print("%s %-34s hits=%d/%d  %s" % (tag, rel, k, n, old.split("\n")[0][:52]))
        if k != n:
            fails.append((rel, k, n, old.split("\n")[0][:80]))
            continue
        if not check:
            io.open(p, "w", encoding="utf-8", newline="").write(s.replace(old2, new2))
    print("APPLY_RTL %s (%d edits, %d fail)" % ("OK" if not fails else "FAIL", len(EDITS), len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
