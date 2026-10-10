#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mk_mut_tx.py -- 从现役 rtl/tcp_tx_frame.v 生成负对照变异件 (每个 = 1 处改动).
   每个变异在源文件上做**声明过的**替换, 命中数不足/超出 ⇒ 硬失败 (不是"静默没打上").
   输出到 <本目录>/mut/*.v   (由 run_tx_ovl_gate.bat 消费)

   ------------------------------------------------------------------
   2026-10-10 工具修复 (三条, 全部有实测依据):
   (1) **换行归一化**: 本工作树因 core.autocrlf=true 是 CRLF
       (rtl/tcp_tx_frame.v 工作树 125,620 B / 2,040 CR；仓里存的是 123,580 B / 0 CR),
       而锚点里的多行串写的是裸 "\n" ⇒ 在 CRLF 文本上 0 命中 (旧版一行打在
       MUTFAIL 上并**继续跑**, 见 (3))。
       现在: 读入后把 \r\n 与单独 \r 一律归一成 \n, 锚点做同样归一化再匹配,
       输出也**一律写 LF** ⇒ 变异件与签出风格无关 (CRLF/LF 工作树产出逐字节相同,
       可对 sha256 断言), 且与 `git show HEAD:` 的存法一致。
   (2) **mut_c2 的 s2/s3 锚点重新对齐到现役源码**: RETXFIX 轮给 upd_id/upd_val
       加了第三级 `replay_jump ? ... : ...` (现役 = 三级三目), 旧锚点
       `(upd_wr_ctrl ? start_id : svc_id);` / `... : rb_snd_una);` 已不存在 ⇒
       即便归一化后仍 0 命中。新锚点逐字取自现役 `rtl/tcp_tx_frame.v:491-497`。
   (3) **落盘时机 (地雷处置) = 全成或全不落 (all-or-nothing)**:
       旧版边匹配边写盘 ⇒ 失败时留下**半套变异件**: 锚点没命中的那些变异
       被写成**未变异的源文件副本** (实测 2026-10-09 那次: mut_s0b.v / mut_c7.v /
       mut_c8.v 与源**逐字节相同**), 而多锚点的 mut_c2 **只落了一半替换**
       (sub1 替换上了, sub2/sub3 没上 ⇒ mcd_id/mcd_val 写了没人读 = 声明的改动
       只存在一半) —— 而"变异臂"这个名字会照样被人/门消费 = 哑门族。
       现在: 先在内存里把**所有**变异件做完 + 逐锚点核命中数 + 核源文件 sha256
       未变, 全部通过才一次性落盘; 任一失败 ⇒ **不落盘任何变异件**, 并把本清单
       里**已存在的**同名旧件删掉 (打印 PURGED) ⇒ 硬不变式:
       **mut/ 要么是"本清单全部变异件的完整、已核验的一份", 要么是空的**,
       绝不会出现"半套/陈旧混装"。
   ------------------------------------------------------------------
   `--dry-run` (或 `--check`): 只做匹配 + 打印逐锚点命中表, **一个字节都不写**.
   退出码: 0 = 全部锚点命中数 == 声明值; 1 = 有差异.
   `plan()` 函数被 probe_anchors.py 复用 (单一锚点表来源, 防两处漂移)。
"""
import hashlib
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SRC = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")
OUT = os.path.join(HERE, "mut")

MUTS = []   # (name, [(old, new, hits)], note)


def add(name, subs, note):
    MUTS.append((name, subs, note))


# ---- S0a: 推进写值少一帧 (OVL 分支; 与 M-C3 "推进写搬回 S_DONE" 同族) ----
add("mut_s0a", [(
    "assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + {20'b0, f_plen[rx_bank]}) :",
    "assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + 32'd0) :",
    1)], "OVL: 数据推进写不推进 (seq 复用)")

# ---- S0b: 默认 (串行) 分支同族变异: 数据段推进写不推进 ----
add("mut_s0b", [(
    "    assign upd_val = ring_restore ? retx_hi :\n"
    "                     (svc_rewind ? rb_snd_una :\n"
    "                      seq_r + (is_data_r ? {20'b0, plen_r} : 32'd1));",
    "    assign upd_val = ring_restore ? retx_hi :\n"
    "                     (svc_rewind ? rb_snd_una :\n"
    "                      seq_r + (is_data_r ? 32'd0 : 32'd1));",
    1)], "默认分支: 数据推进写不推进 (S0 灵敏度证明用)")
#   [!!] 2026-10-10 (P7B-RETXHI-GHOST 实施轮) 重新对齐: 该支 `upd_val` 多了第 1 级
#      `ring_restore ? retx_hi :` (rtl/tcp_tx_frame.v §3.3-(7)) => 旧锚点 0 命中。
#      变异语义 (数据推进写不推进) 一字未变。

# ---- M-C1: 撞写口 (upd_wr_ctrl 与 upd_wr_data 同拍) ----
add("mut_c1", [(
    "    wire        upd_wr_ctrl = start_ack && !probe_sel && (aq_syn | aq_fin | aq_rst);",
    "    wire        upd_wr_ctrl = upd_wr_data || (start_ack && !probe_sel && (aq_syn | aq_fin | aq_rst));",
    1)], "M-C1 同拍撞写口 => $onehot0 红")
#   [!!] 2026-10-10 (PERSIST 实施轮) 重新对齐: `upd_wr_ctrl` 那一行被 PERSIST 刀加了
#      `!probe_sel` 门 (rtl/tcp_tx_frame.v 的 §2.4-4 (1)) => 旧锚点 0 命中 (MUTFAIL)。
#      变异语义 (同拍撞写口) 一字未变。

# ---- M-C2: 预留写寄存 8 拍 (形 A: (wr,val,id) 三件套一起延) ----
#   s2/s3 锚点 = 2026-10-10 重新对齐 (RETXFIX 后 upd_id/upd_val 是**三级三目**,
#   第三级 = `replay_jump ? retx_id_r/retx_hi : svc_id/rb_snd_una`;
#   本变异只动第二级 ctrl 分支的取值来源, 语义与旧版声明完全一致)。
add("mut_c2", [
    ("    wire        upd_wr_ctrl = start_ack && !probe_sel && (aq_syn | aq_fin | aq_rst);",
     "    // M-C2 形 A: (wr,val,id) 三件套一起寄存 8 拍\n"
     "    reg [3:0]  mcd; reg [3:0] mcd_id; reg [31:0] mcd_val;\n"
     "    always @(posedge clk or negedge rst_n) begin\n"
     "        if (!rst_n) begin mcd <= 4'd0; mcd_id <= 4'd0; mcd_val <= 32'd0; end\n"
     "        else if (start_ack && (aq_syn | aq_fin | aq_rst)) begin\n"
     "            mcd <= 4'd8; mcd_id <= start_id; mcd_val <= rb_snd_nxt + 32'd1;\n"
     "        end else if (mcd != 4'd0) mcd <= mcd - 4'd1;\n"
     "    end\n"
     "    wire        upd_wr_ctrl = (mcd == 4'd1) && !probe_sel;", 1),
    ("    assign      upd_id  = upd_wr_data ? f_conn[rx_bank] :\n"
     "                          (upd_wr_ctrl ? start_id :",
     "    assign      upd_id  = upd_wr_data ? f_conn[rx_bank] :\n"
     "                          (upd_wr_ctrl ? mcd_id :", 1),
    ("    assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + {20'b0, f_plen[rx_bank]}) :\n"
     "                          (upd_wr_ctrl ? (rb_snd_nxt + 32'd1) :",
     "    assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + {20'b0, f_plen[rx_bank]}) :\n"
     "                          (upd_wr_ctrl ? mcd_val :", 1),
], "M-C2 预留写滞后 8 拍 => J_seq_mono / J_seq_cont 红")

# ---- M-C3: 乒乓退化单 bank (接收门再加 TX 空闲) ----
add("mut_c3", [(
    "          && !fifo_full && !bank_rdy[rx_bank];",
    "          && !fifo_full && (bank_rdy == 2'b00) && (tx_state == T_IDLE);",
    1)], "M-C3 退化单 bank => 帧周期/TX 引擎拍数红")

# ---- M-C6: 撤回卷门 (!ctrl_adv_inflight) ----
add("mut_c6", [(
    "    wire        svc_x     = svc && !ctrl_adv_inflight;    // 回卷门 (§1.4(4))",
    "    wire        svc_x     = svc;",
    1)], "M-C6 撤回卷门 => FIN 预留被当 ring 数据重放 => J_seq_cont 红")

# ---- M-C7: 撤 start_ack 的 !ctrl_slot_busy ----
add("mut_c7", [(
    "    wire        start_ack = rx_idle && !rx_flush && !ctrl_slot_busy &&\n"
    "                            ((ack_pend_r && !ackq_empty) || probe_sel);",
    "    wire        start_ack = rx_idle && !rx_flush &&\n"
    "                            ((ack_pend_r && !ackq_empty) || probe_sel);",
    1)], "M-C7 撤槽独占 => issued > transmitted => J6 红")
#   [!!] 2026-10-10 (PERSIST 实施轮) 重新对齐: `start_ack` 的**写法**变了
#      (探询支并入 + 子句次序重排, rtl §2.5-(5)) => 旧锚点 0 命中; 变异语义 (撤
#      `!ctrl_slot_busy`) 一字未变。

# ---- M-C8: 撤 start_ack 的 rx_idle ----
add("mut_c8", [(
    "    wire        start_ack = rx_idle && !rx_flush && !ctrl_slot_busy &&\n"
    "                            ((ack_pend_r && !ackq_empty) || probe_sel);",
    "    wire        start_ack = !rx_flush && !ctrl_slot_busy &&\n"
    "                            ((ack_pend_r && !ackq_empty) || probe_sel);",
    1)], "M-C8 撤 rx_idle => 控制帧在收帧期装载 (混拼)")
#   [!!] 2026-10-10 (PERSIST 实施轮) 重新对齐 (同 mut_c7 注)。

# ---- W66-1 (构建 E): 窗口门停顿计数器**永不计数** (哑观测) ----
#   判据 (tb_tcp_tx_ovl.v 的 W66 段) 逐拍复算同一个判据并要求两者**相等** ⇒
#   计数器死掉 (恒 0) 而 TB 侧照数 ⇒ 必红。两个分支各一处 (声明命中数 = 2)。
add("mut_w66_dead", [(
    "            if (stat_winstall_ev) stat_winstall <= stat_winstall + 32'd1;",
    "            // M-W66-1: 哑观测 (永不计数)",
    2)], "M-W66-1 计数器恒 0 (两分支各一处) => 判据必红")

# ---- W66-2 (构建 E): 判据**语义**错 (去掉 `!wnd_open` = 把"想开"当"被窗挡") ----
#   定向反例: 计数器会**多**数 (把 start_data 拍也算进去) ⇒ 与 TB 复算不等 ⇒ 红。
add("mut_w66_nownd", [(
    "                                   !fifo_full && !bank_rdy[rx_bank] &&\n"
    "                                   !tx_blk_sid && !wnd_open;",
    "                                   !fifo_full && !bank_rdy[rx_bank] &&\n"
    "                                   !tx_blk_sid;",
    1)], "M-W66-2 (OVL) 判据去掉 !wnd_open => 多数 start_data 拍")

# ---- M-C9: 仲裁键改回 ctrl_slot_busy (两处帧边界判定) ----
add("mut_c9", [(
    "if (ctrl_tx_pend) begin",
    "if (ctrl_slot_busy) begin",
    2)], "M-C9 仲裁键=busy => 控制帧 T_DONE 自选 => transmitted > issued => J6 红")

# ===========================================================================
# ⭐ 构建 F 的三个新仪器 (W67/W69) —— 判据在 tb/tb_tcp_tx_ovl.v 的 W67/W69 段
#   判据形状 = **双边等式** (DUT 字 == TB 侧逐拍独立复算) ⇒ 两个方向都有牙:
#     · 多数 (把对端侧也算进板帽侧) / 少数 (哑计数器/哑锁存) 都会红;
#     · 另加一条结构性牙 `W67 <= W66` (子集关系, 逐窗恒真)。
# ===========================================================================

# ---- W67-1 (构建 F): 分裂判据**去掉侧别** (板帽侧 == 全部等窗拍 = 对端侧也被算进来) ----
#   判据 (tb_tcp_tx_ovl.v 的 W67 段) 逐拍复算同一个判据并要求两者**相等** ⇒ 计数器**多**数
#   (把对端侧那份也算进板帽侧) ⇒ 必红。两个分支各一处 (声明命中数 = 2)。
#   ⚠️ 本变异在 `-d TCP_TX_OVL` (默认帽) 臂上就有牙 (W67 期望 0, 变异后 != 0)。
add("mut_w67_always", [(
    "    wire        win_cap_bind         = (win_wnd_eff >= RING_CAP);",
    "    wire        win_cap_bind         = 1'b1;   // M-W67-1: 去掉侧别 (板帽侧 := 全部)",
    2)], "M-W67-1 分裂判据去掉侧别 => 板帽侧多数 (对端侧那份被算进来)")

# ---- W67-2 (构建 F): 板帽侧计数器**永不计数** (哑观测) ----
#   ⚠️ **只在 `-d W67_CAP_SMALL` 臂上有牙** —— 默认帽 (0xBFFE) 下板帽侧结构性为 0 (在飞
#   够不到 49150) ⇒ 本变异与正例不可分 (该方向的空判据, 已在 TB 与报告里登记)。
#   两个分支各一处 (声明命中数 = 2)。
add("mut_w67_dead", [(
    "            if (stat_winstall_cap_ev) stat_winstall_cap <= stat_winstall_cap + 32'd1;",
    "            // M-W67-2: 哑观测 (板帽侧永不计数)",
    2)], "M-W67-2 板帽侧计数器恒 0 (需 W67_CAP_SMALL 臂才有靶)")

# ---- W69-1 (构建 F): 操作点锁存**永不更新** (哑观测) ----
#   判据要求 DUT 的 `o_win_at_winstall` == TB 侧复算的最近一次等窗样本 (非 0) ⇒ 恒 0 必红。
#   两个分支各一处 (声明命中数 = 2)。
add("mut_w69_dead", [(
    "            if (stat_winstall_ev) o_win_at_winstall <= {win_inflight, win_wnd_eff};",
    "            // M-W69-1: 哑观测 (锁存永不更新)",
    2)], "M-W69-1 锁存恒 0 => 与 TB 复算 (非 0) 不等")

# ---- W69-2 (构建 F): 锁存使能换成**帧启动拍** (`start_data` 而不是等窗拍) ----
#   值会变成\"最近一次**开成帧**那一拍的操作点\" (= 窗口开着的样本, `win_wnd_eff` 已回到
#   全帽) ⇒ 与\"最近一次**没开成**那一拍\"的复算值**低 16 位就不同** (1460 vs 49150 一档)
#   ⇒ 必红。**只锚 OVL 分支那一处** (默认分支没有 `start_data`; 用后随的 `svc_id_r` 行定界)。
add("mut_w69_atstart", [(
    "            if (stat_winstall_ev) o_win_at_winstall <= {win_inflight, win_wnd_eff};\n"
    "            svc_id_r <= retx_req ? retx_id : prio_lo(rto_pend);\n",
    "            if (start_data) o_win_at_winstall <= {win_inflight, win_wnd_eff};   // M-W69-2\n"
    "            svc_id_r <= retx_req ? retx_id : prio_lo(rto_pend);\n",
    1)], "M-W69-2 锁存使能换成 start_data => 操作点相位错")


# ===========================================================================
# P7B-PERSIST 变异臂 (2026-10-10 实施轮; 判据在 tb/tb_tcp_tx_ovl.v 的 ARM_PERSIST 段)
#   每个变异 = 1 处改动, 锚点逐字取自**现役** rtl/tcp_tx_frame.v。
# ===========================================================================

# ---- PS-MUT-1: 删掉武装条件里的 !fin_sent_r[scan_id] (D-5 的第五子句) ----
#   判据 (j12-FIN): E5 窗内 (conn2 的 FIN 在飞 + 窗 0 + 有在飞) 必须 0 探询。
add("mut_ps_noarmfin", [(
    "    wire        ps_arm    = PERSIST_EN && scan_now && scan_estab &&\n"
    "                            (rb_snd_wnd == 16'd0) && (rb_snd_nxt != rb_snd_una) &&\n"
    "                            !fin_sent_r[scan_id] && !rst_sent_r[scan_id];",
    "    wire        ps_arm    = PERSIST_EN && scan_now && scan_estab &&\n"
    "                            (rb_snd_wnd == 16'd0) && (rb_snd_nxt != rb_snd_una) &&\n"
    "                            !rst_sent_r[scan_id];",
    1)], "PS-MUT-1 撤 !fin_sent_r => E5 冒出探询 => j12 红")

# ---- PS-MUT-2: 删掉武装条件里的 !rst_sent_r[scan_id] (v3 #6 的 RST 角) ----
add("mut_ps_noarmrst", [(
    "    wire        ps_arm    = PERSIST_EN && scan_now && scan_estab &&\n"
    "                            (rb_snd_wnd == 16'd0) && (rb_snd_nxt != rb_snd_una) &&\n"
    "                            !fin_sent_r[scan_id] && !rst_sent_r[scan_id];",
    "    wire        ps_arm    = PERSIST_EN && scan_now && scan_estab &&\n"
    "                            (rb_snd_wnd == 16'd0) && (rb_snd_nxt != rb_snd_una) &&\n"
    "                            !fin_sent_r[scan_id];",
    1)], "PS-MUT-2 撤 !rst_sent_r => E6' 冒出探询 => j12 红")

# ---- PS-MUT-3: 探询槽上线条件里删掉 ds_guard (v3 #1 / REVIEW2 blocking #1) ----
#   判据 (j13/j14, **多连接**): E7 相撞窗内不得出现跨连接数据帧。
#   [!] 单连接 (A==B) 时自洽 => 该变异**只有多连接臂能抓** (本轮的 H2 欠账)。
add("mut_ps_nodsg", [(
    "    wire        probe_sel = ps_stage_rdy && ps_stage_estab && rx_idle && !rx_flush &&\n"
    "                            !ctrl_slot_busy && ackq_empty &&\n"
    "                            !svc && !ring_eval && !scan_now && !retx_active && ds_guard;",
    "    wire        probe_sel = ps_stage_rdy && ps_stage_estab && rx_idle && !rx_flush &&\n"
    "                            !ctrl_slot_busy && ackq_empty &&\n"
    "                            !svc && !ring_eval && !scan_now && !retx_active;",
    1)], "PS-MUT-3 撤 ds_guard => E7 相撞 => 跨连接数据帧 => j13 红")

# ===========================================================================
# ⭐ P7B-RETXHI-GHOST (2026-10-10 实施轮): 三条新变异 —— 每条给一台新仪器配牙.
#   仪器面 = tb/tb_tcp_tx_ovl.v 的 e_ghost (帧尾越过高水位) / e_ringhi (A4 不变式),
#   两者都已进 tot_red 白名单和式. 臂 = `-d TCP_TX_OVL -d ARM_PERSIST`
#   (幽灵族只在 ARM_PERSIST 刺激下出现; 见 run_ghost_arms.bat 的 M3/M4/M5).
# ===========================================================================

# ---- M-3: 环重放上界换回 `retx_hi` (退回缺陷语义) => e_ghost 必须有牙 ----
#   判据 e_ghost 的判别规则 (设计件 §5.4-②): `e_ghost > 0` ⇒ 修法没生效/被绕过。
add("mut_ghost_m3", [(
    "                    ring_hi <= ((rb_snd_nxt - whi_r[svc_id]) < 32'h8000_0000) ?\n"
    "                               whi_r[svc_id] : rb_snd_nxt;",
    "                    // M-3: 环上界 := retx_hi (退回缺陷语义)\n"
    "                    ring_hi <= (fin_sent_r[svc_id] && svc_rewind) ? fin_seq_r[svc_id] :\n"
    "                               rb_snd_nxt;",
    1)], "M-3 ring_hi := retx_hi => e_ghost 命中 (有牙)")

# ---- M-4: 撤收尾恢复写 (ring_restore = 0) => 指名判据 = e_replay_jump ----
#   只锚 OVL 支那一处 (用后随的 `rd_tap` 行定界; else 支的同名语句后面不是 rd_tap)。
add("mut_ghost_norestore", [(
    "    assign      ring_restore = ring_eval && !ring_ovf && scan_estab &&\n"
    "                               (ring_delta == 32'd0) &&\n"
    "                               (rb_snd_nxt != retx_hi) &&\n"
    "                               ((retx_hi - rb_snd_nxt) < 32'h8000_0000);\n"
    "    wire        rd_tap = ring_start || (ring_act && (beat_cnt < nbeats));\n",
    "    assign      ring_restore = 1'b0;   // M-4: 撤收尾恢复写 (指名判据 = e_replay_jump)\n"
    "    wire        rd_tap = ring_start || (ring_act && (beat_cnt < nbeats));\n",
    1)], "M-4 撤 ring_restore => e_replay_jump 命中")

# ---- M-5: 拆装载拍钳位 (裸取 whi_r) + cfg_up 注入"陈旧高水位" => e_ringhi 有牙 ----
#   两处改动 = 同一条通路 ("陈旧/异常高水位活下来"): ① 钳位删掉; ② cfg_up 清位改成注入
#   0x8000_0000 (模拟上一会话的高水位漏进新会话 = 设计件 E3-6 的危险方向)。
#   ⭐ 选值依据 (回绕几何; 实施轮实测 + 推导): A4 是**回绕安全**比较 ⟹ 注入常量必须
#      "在 snd_nxt 之前不到半圈" (即 (snd_nxt − whi) mod 2^32 ≥ 2^31) 才构成违反。
#      实测: 0xF000_0000 对 snd_nxt≈0x4EBB9 落在**半圈之外** ⇒ 不变式不破 (ringhi=0, 无牙);
#      0x8000_0000 对 0/1/3 号连接 (snd_nxt < 2^31) 均落在半圈之内 ⇒ 违反 ⇒ 必命中。
add("mut_ghost_noclamp", [
    ("                    ring_hi <= ((rb_snd_nxt - whi_r[svc_id]) < 32'h8000_0000) ?\n"
     "                               whi_r[svc_id] : rb_snd_nxt;",
     "                    ring_hi <= whi_r[svc_id];   // M-5: 拆钳位 (裸取)",
     1),
    ("                fin_sent_r[cfg_up_id]    <= 1'b0;\n"
     "                whi_r[cfg_up_id]         <= 32'd0;   // ⭐ RETXHI-GHOST: 新会话重基 ⇒ 高水位清零\n"
     "                rst_sent_r[cfg_up_id]    <= 1'b0;\n"
     "                fin_retx_pend[cfg_up_id] <= 1'b0;\n"
     "                epoch[cfg_up_id]        <= 4'd0;",
     "                fin_sent_r[cfg_up_id]    <= 1'b0;\n"
     "                whi_r[cfg_up_id]         <= 32'h8000_0000;   // M-5: 注入陈旧高水位\n"
     "                rst_sent_r[cfg_up_id]    <= 1'b0;\n"
     "                fin_retx_pend[cfg_up_id] <= 1'b0;\n"
     "                epoch[cfg_up_id]        <= 4'd0;",
     1),
], "M-5 拆钳位 + 注入陈旧 whi => e_ringhi 命中")


def norm(s):
    """换行归一化: \\r\\n / 单独 \\r 一律成 \\n (幂等)."""
    return s.replace("\r\n", "\n").replace("\r", "\n")


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def plan(src_lf):
    """只做匹配, 不落盘. 源文本必须已归一化为 LF.
    返回 [(name, subs, note, hits_list)]; hits_list[i] = 第 i 个锚点的实测命中数.
    """
    out = []
    for name, subs, note in MUTS:
        out.append((name, subs, note, [src_lf.count(norm(old)) for old, _, _ in subs]))
    return out


def render(src_lf, subs):
    """按 subs 逐条替换, 返回变异件正文 (LF). 调用前必须已核过命中数."""
    t = src_lf
    for old, new, _ in subs:
        t = t.replace(norm(old), norm(new))
    return t


def main(argv):
    dry = ("--dry-run" in argv) or ("--check" in argv)

    raw_bytes = open(SRC, "rb").read()
    src = norm(io.open(SRC, encoding="utf-8", newline="").read())
    ref = sha256_bytes(raw_bytes)
    n_crlf = raw_bytes.count(b"\r\n")
    n_cr = raw_bytes.count(b"\r") - n_crlf
    print("SRC %s  %d B  sha256 %s" % (SRC, len(raw_bytes), ref))
    if n_crlf or n_cr:
        print("NORM: %d CRLF / %d lone CR -> LF (matching + output, 与签出风格无关)"
              % (n_crlf, n_cr))

    results = plan(src)
    fails = []
    for name, subs, note, hits in results:
        want = [e for _, _, e in subs]
        if hits != want:
            for i, (h, e) in enumerate(zip(hits, want), 1):
                if h != e:
                    print("MUTFAIL %s: pattern hits=%d expect=%d" % (name, h, e))
            fails.append(name)

    if dry:
        print("%-9s %-4s %s" % ("mutant", "sub", "hits/expect"))
        for name, subs, note, hits in results:
            for i, ((_, _, e), h) in enumerate(zip(subs, hits), 1):
                print("%-9s s%-3d %d/%d %s" % (name, i, h, e, "" if h == e else "<== MISMATCH"))
            print("%-9s %s" % ("", "USABLE" if hits == [e for _, _, e in subs] else "BROKEN"))
        print("DRYRUN %s (0 bytes written)" % ("OK" if not fails else "FAIL %d" % len(fails)))
        return 0 if not fails else 1

    if fails:
        print("MUTGEN FAIL %d" % len(fails))
        purge(results)
        return 1

    # 源文件在匹配期间被改过 ⇒ 整轮作废 (与"改 RTL / 在跑回归 互斥"同一条纪律)
    now = sha256_bytes(open(SRC, "rb").read())
    if now != ref:
        print("SRC-CHANGED during generation: %s -> %s" % (ref, now))
        print("MUTGEN FAIL 1")
        purge(results)
        return 1

    texts = [(name, note, render(src, subs)) for name, subs, note, _ in results]
    os.makedirs(OUT, exist_ok=True)
    for name, note, text in texts:
        io.open(os.path.join(OUT, name + ".v"), "w", encoding="utf-8", newline="").write(text)
        print("WROTE %-10s %s" % (name, note))

    # 落盘后再核一次 (窗口内被改也作废, 保证落盘集 = 单一已核源修订)
    now = sha256_bytes(open(SRC, "rb").read())
    if now != ref:
        print("SRC-CHANGED after write: %s -> %s" % (ref, now))
        print("MUTGEN FAIL 1")
        purge(results)
        return 1

    n_subs = sum(len(subs) for _, subs, _, _ in results)
    print("ANCHORS: all %d mutants matched (%d subs, each hits==expect)"
          % (len(results), n_subs))
    print("MUTGEN OK (%d mutants)" % len(MUTS))
    return 0


def purge(results):
    """失败路径: 删掉本清单里**已存在的**同名旧件 (只删这些文件名, 不做通配删除).
    理由: mut/ 里同名旧件一定来自**另一个源修订**, 混装 = 静默陈旧证据;
    硬不变式 = mut/ 要么是"本清单的完整已核验一份", 要么是空的."""
    for name, _, _, _ in results:
        p = os.path.join(OUT, name + ".v")
        if os.path.exists(p):
            os.remove(p)
            print("PURGED stale %s" % p)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
