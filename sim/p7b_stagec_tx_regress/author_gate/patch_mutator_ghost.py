#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""patch_mutator_ghost.py -- 给 mk_mut_tx.py 加 P7B-RETXHI-GHOST 的三条变异 (M-3/M-4/M-5)
   并重对齐 mut_s0b 的陈旧锚点 (旧锚点在 RETXHI-GHOST 刀之后 0 命中).
   ⚠️ 每处声明命中数; 任一不符 => 不落盘 (fail-closed).
   ⚠️ 锚点里的 `\\n` 是**源文件里字面出现的两字符序列** (python 字符串字面量的换行转义),
      所以这里一律用 raw string 写."""
import os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
MK = os.path.join(HERE, "mk_mut_tx.py")

t = open(MK, encoding="utf-8").read()
bad = 0

# ---------- (1) mut_s0b 锚点重对齐 ----------
old = r'''add("mut_s0b", [(
    "    assign upd_val = svc_rewind ? rb_snd_una :\n"
    "                     seq_r + (is_data_r ? {20'b0, plen_r} : 32'd1);",
    "    assign upd_val = svc_rewind ? rb_snd_una :\n"
    "                     seq_r + (is_data_r ? 32'd0 : 32'd1);",
    1)], "默认分支: 数据推进写不推进 (S0 灵敏度证明用)")
'''
new = r'''add("mut_s0b", [(
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
'''
n = t.count(old)
print("%s%-22s hits=%d (declared 1)" % ("OK " if n == 1 else "!! ", "s0b re-anchor", n))
if n != 1:
    bad += 1
else:
    t = t.replace(old, new)

# ---------- (2) 追加 M-3 / M-4 / M-5 ----------
ADD = r'''

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
#   0xF000_0000 (模拟上一会话的高水位漏进新会话 = 设计件 E3-6 的危险方向)。
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
     "                whi_r[cfg_up_id]         <= 32'hF000_0000;   // M-5: 注入陈旧高水位\n"
     "                rst_sent_r[cfg_up_id]    <= 1'b0;\n"
     "                fin_retx_pend[cfg_up_id] <= 1'b0;\n"
     "                epoch[cfg_up_id]        <= 4'd0;",
     1),
], "M-5 拆钳位 + 注入陈旧 whi => e_ringhi 命中")
'''
if "mut_ghost_m3" in t:
    print("OK  M-3/M-4/M-5 already present (skip)")
else:
    t = t.rstrip() + "\n" + ADD
    print("OK  M-3/M-4/M-5 appended")

if bad:
    print("*** %d 处不符 => 不落盘 ***" % bad)
    sys.exit(1)
open(MK, "w", encoding="utf-8", newline="\n").write(t)
print("WROTE mk_mut_tx.py")
