# -*- coding: utf-8 -*-
"""
mutate_gate.py —— 变异测试: 把 RTL 改坏, 看单元门是否报警 (判据有没有牙)

用法 (从 git bash):
    /c/Users/zhxue/anaconda3/python.exe _proj_10g/p7b_mac/scripts/mutate_gate.py

做法:
  1. 把 _proj_10g/p7b_mac/rtl/*.v 拷到 sim/_mut_rtl/
  2. 对副本施加一处变异 (文本替换)
  3. 用 P7B_RTL=<副本目录> 跑 run_tb_mac_10g.bat
  4. 「抓住」= 门退出 1; 「漏掉」= 门仍 PASS (必须如实登记)
原始 RTL 一个字节都不动。

⚠️ 纪律: 本脚本只写 sim/_mut_rtl/ (临时目录), 不改 rtl/ 下任何文件。
"""
import io
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))          # p7b_mac/scripts
PROJ = os.path.dirname(HERE)                               # p7b_mac
RTL = os.path.join(PROJ, "rtl")
SIM = os.path.join(PROJ, "sim")
WORK = os.path.join(SIM, "_mut_rtl")
LOGS = os.path.join(SIM, "_mut_logs")          # 每变异的 xsim 日志留档 (证据链)
BAT = os.path.join(SIM, "run_tb_mac_10g.bat")

# (名字, 文件, 原文, 变异后, 预期)  预期: "caught" = 门应报 FAIL
MUTS = [
    ("M1 TX 字节序镜像变直通", "mac_tx_10g.v",
     "bswap64[i*8 +: 8] = d[(7-i)*8 +: 8];",
     "bswap64[i*8 +: 8] = d[i*8 +: 8];", "caught"),
    ("M1b RX 字节序镜像变直通", "mac_rx_10g.v",
     "3'd0: align8 = {w[7:0],   w[15:8],  w[23:16], w[31:24],\n                                w[39:32], w[47:40], w[55:48], w[63:56]};",
     "3'd0: align8 = {w[63:56], w[55:48], w[47:40], w[39:32],\n                                w[31:24], w[23:16], w[15:8],  w[7:0]};", "caught"),
    ("M2 CRC 残留魔数换成大端魔数", "mac_rx_10g.v",
     "localparam [31:0] ETH_CRC_RESIDUE = 32'hDEBB20E3;",
     "localparam [31:0] ETH_CRC_RESIDUE = 32'hC704DD7B;", "caught"),
    ("M3 F4 空间门退回寄存器 full", "mac_rx_10g.v",
     "wire        push_ok       = !fifo_full_next;",
     "wire        push_ok       = !fifo_full;", "caught"),
    ("M4 RX FCS 剥离关闭", "mac_rx_10g.v",
     "wire [3:0] drop_b = b_last ? ((b_k > 4) ? 4'd4 : b_k)",
     "wire [3:0] drop_b = 4'd0; wire [3:0] drop_b_unused = b_last ? ((b_k > 4) ? 4'd4 : b_k)", "caught"),
    ("M5 RX 起始 lane 不锁存 (复现已修缺陷)", "mac_rx_10g.v",
     "wire [2:0] lo      = in_first ? first_lo : 3'd0;",
     "wire [2:0] lo      = in_first ? s_lo : 3'd0;", "caught"),
    ("M6 TX IFG 从 12 降到 4", "mac_tx_10g.v",
     "localparam [4:0]  ETH_IFG_IDLE  = 5'd12;",
     "localparam [4:0]  ETH_IFG_IDLE  = 5'd4;", "caught"),
    ("M7 TX F-2 冲刷被拆掉 (中止后直接回 IDLE)", "mac_tx_10g.v",
     "S_ABORT: begin\n                    state <= S_FLUSH; flush_cnt <= 4'd0; flush_tl <= 1'b0;\n                end",
     "S_ABORT: begin\n                    state <= S_IDLE; flush_cnt <= 4'd0; flush_tl <= 1'b0;\n                end", "caught"),
    # ⭐ M7b = M7 + **计数器伪装**: 照样发幽灵帧, 只是报告说"冲刷过了"。
    #    这是 GATEFIX D1 的判别力试金石: 旧判据 (只判 stat_flush_done/words) 对它
    #    **229 checks / 0 fail / PASS**; 新判据 = 基于线上内容的逐帧幽灵检测 ⇒ 必须 FAIL。
    ("M7b TX 幽灵帧 + 计数器伪装 (D1 试金石)", "mac_tx_10g.v",
     "S_ABORT: begin\n                    state <= S_FLUSH; flush_cnt <= 4'd0; flush_tl <= 1'b0;\n                end",
     "S_ABORT: begin\n                    state <= S_IDLE; flush_cnt <= 4'd0; flush_tl <= 1'b0;\n"
     "                    stat_flush_done <= stat_flush_done + 32'd1;\n"
     "                    stat_flush_words <= stat_flush_words + 32'd1;\n                end", "caught"),
    ("M8 (等价变异) hi>=8 写成 hi>7 —— 逻辑等价, 期望**漏掉**", "mac_rx_10g.v",
     "wire [7:0] hi_mask = (hi >= 4'd8) ? 8'h00 : (8'hFF << hi);",
     "wire [7:0] hi_mask = (hi > 4'd7)  ? 8'h00 : (8'hFF << hi);", "not_caught"),
    ("M9 (等价变异) /T/ lane 判定改用 >= 4'd8 的等价写法", "mac_rx_10g.v",
     "wire       t_v  = (t_lane_lo != 4'd8);",
     "wire       t_v  = (t_lane_lo < 4'd8);", "not_caught"),
    # GATEFIX D3: 给"不卡死"给一个**能取到的失败模态** (原判据 rx_dbg_state !== 2'bx 恒真)。
    # 拆掉帧闭合条件 ⇒ FSM 永停在"收帧"态 ⇒ 看门狗与"回到 IDLE"两条判据必须响。
    ("M10 RX 帧闭合条件拆掉 (FSM 永停在收帧态)", "mac_rx_10g.v",
     "if (t_v) in_active <= 1'b0;      // 帧闭合",
     "if (1'b0) in_active <= 1'b0;      // 帧闭合 (M10: 闭合条件被拆掉)", "caught"),
    # ===================================================================
    # 2026-09-30: DEFECT #1 (mac_tx_10g 补 pad 帧的 FCS **不含 pad**) 的修复配套。
    #   判据结构也一并改了 (同源 oracle → 独立 oracle + TX→RX 自洽回放), 所以这一族
    #   变异是给**新判据**验牙用的。
    #   ⚠️ M11a 是"逐字复现修复前语义"的那一个: CRC 输入换回"只有内容" (keep=cw_keep /
    #      d=cw_data / en 不含 S_TAIL0) ⇒ S_TAIL0 里 CRC 寄存器冻结 ⇒ p0_fcs 退化成
    #      lw_fcs ⇒ 与 HEAD 版行为逐位相同。实证: 直接拿 HEAD 的 mac_tx_10g.v 跑同一门
    #      = 337 checks / 17 fail, 与本变异应报同一条 FAIL 集 (sim/_mut_logs/PRECOND_*)。
    # ===================================================================
    ("M11a DEFECT #1 复现: pad 不进 CRC (整块回退)", "mac_tx_10g.v",
     "    wire [7:0]  crc_keep = (state == S_TAIL0)\n"
     "                           ? ((p0_rst != 6'd0) ? 8'hFF : (8'hFF << (5'd8 - p0_use)))\n"
     "                           : (cw_last ? (8'hFF << (5'd8 - lw_ts)) : cw_keep);\n"
     "    wire [63:0] crc_d    = (state == S_TAIL0) ? 64'd0 : (cw_data & cmask64(cw_len));\n"
     "    wire        crc_en   = (state == S_DATA)  ? (cw_len != 4'd0)\n"
     "                         : (state == S_TAIL0) ? 1'b1 : 1'b0;",
     "    wire [7:0]  crc_keep = cw_keep;\n"
     "    wire [63:0] crc_d    = cw_data;\n"
     "    wire        crc_en   = (state == S_DATA) && (cw_len != 4'd0);", "caught"),
    ("M11b pad 只从末内容字的 CRC 里去掉", "mac_tx_10g.v",
     "                           : (cw_last ? (8'hFF << (5'd8 - lw_ts)) : cw_keep);",
     "                           : cw_keep;", "caught"),
    ("M11c pad 只从 S_TAIL0 续字的 CRC 里去掉", "mac_tx_10g.v",
     "    wire        crc_en   = (state == S_DATA)  ? (cw_len != 4'd0)\n"
     "                         : (state == S_TAIL0) ? 1'b1 : 1'b0;",
     "    wire        crc_en   = (state == S_DATA) && (cw_len != 4'd0);", "caught"),
    # 等价变异: S_TAIL0 里 p0_use = min(m_pad_left, 8) 且 m_dhere 恒 0 ⇒ p0_use == 8
    #   与 p0_rst != 0 只在 m_pad_left == 8 处不同, 而那里两种写法都取 8'hFF ⇒ 全等价。
    ("M11d (等价变异) 纯 pad 判定 p0_rst!=0 写成 p0_use==8", "mac_tx_10g.v",
     "                           ? ((p0_rst != 6'd0) ? 8'hFF : (8'hFF << (5'd8 - p0_use)))",
     "                           ? ((p0_use == 5'd8) ? 8'hFF : (8'hFF << (5'd8 - p0_use)))",
     "not_caught"),
    # ===================================================================
    # 2026-09-30: P7B_LANEFIX (/S/@lane4 的 4 字节重对齐) 的新逻辑验牙。
    #   判据 = 组 4 新增的 SOP 满对齐 / 内容逐字节 / 线上长度三族 (见 tb_mac_10g.v 组 4)。
    # ===================================================================
    ("M12 重对齐关闭 (lane4 回到修前 0xF0 首字)", "mac_rx_10g.v",
     "wire        ra_hold  = a_first && (first_lo == 3'd4) && !frag_now;  // 扣住那一拍",
     "wire        ra_hold  = 1'b0;  // M12: 重对齐被关掉", "caught"),
    ("M13 冲字拆掉 (lane4 末字余字节不再交付)", "mac_rx_10g.v",
     "                ra_v     <= (!t_v) || (hi > 4'd4);",
     "                ra_v     <= (!t_v);", "caught"),
    ("M14 合并字低半字节序颠倒", "mac_rx_10g.v",
     ": ra_merge ? {ra_d, ld[7:0], ld[15:8], ld[23:16], ld[31:24]}",
     ": ra_merge ? {ra_d, ld[31:24], ld[23:16], ld[15:8], ld[7:0]}", "caught"),
    # 等价变异 (2026-09-30 实测订正 —— 原期望写成 caught, 门判 missed, 分析后**门是对的**):
    #   raw 窗与归一化窗是**同一字节流的不同分字**, 而 CRC 只按"字节流顺序 + keep"推进 ⇒
    #   两者残差逐位相同 (raw: [4,hi') 然后每字 [0,8)...; 归一化: 半字+低半滚动)。
    #   这同时也是对"归一化没有改变字节流"的一条独立佐证。
    ("M15 (等价变异) CRC 挂点从 A'(归一化) 退回 raw A", "mac_rx_10g.v",
     "        .en(ap_v),                  // 帧数据字才参与\n        .d(ap_data), .keep(ap_keep),",
     "        .en(a_v),                  // 帧数据字才参与\n        .d(a_data), .keep(a_keep),", "not_caught"),
    ("M16 线上长度退回用 ap_k (重复计数)", "mac_rx_10g.v",
     "wire [15:0] len_now = b_last ? f_len : (f_len + {12'd0, (a_v ? a_k : 4'd0)});",
     "wire [15:0] len_now = b_last ? f_len : (f_len + {12'd0, a_k_l});", "caught"),
    # 等价变异: 帧未完时 ra_car4 恒 4 (hi=8) ⇒ `t_v ? ra_car4 : 4` 与 `ra_car4` 逐位相同;
    #   帧在本字结束且 hi<=4 时 ra_v<=0 ⇒ ra_k 不再被读 ⇒ 取值无差别。
    ("M17 (等价变异) 半字字节数写成 t_v ? ra_car4 : 4", "mac_rx_10g.v",
     "                ra_k     <= ra_car4[2:0];",
     "                ra_k     <= t_v ? ra_car4[2:0] : 3'd4;", "not_caught"),
]


def copy_rtl():
    if os.path.isdir(WORK):
        shutil.rmtree(WORK)
    os.makedirs(WORK)
    for fn in os.listdir(RTL):
        if fn.endswith(".v") or fn.endswith(".vh"):
            shutil.copy(os.path.join(RTL, fn), os.path.join(WORK, fn))


def run_gate(tag=""):
    env = dict(os.environ)
    env["P7B_RTL"] = WORK
    p = subprocess.run(["cmd", "/c", BAT], cwd=SIM, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = p.stdout.decode("utf-8", "replace")
    # 把本轮的 xsim 日志原样留档 (bat 每轮覆盖 xsim_m10g.log ⇒ 不留档就没有逐条证据)
    if tag:
        if not os.path.isdir(LOGS):
            os.makedirs(LOGS)
        src = os.path.join(SIM, "xsim_m10g.log")
        if os.path.isfile(src):
            shutil.copy(src, os.path.join(LOGS, tag + ".log"))
    return p.returncode, out


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    print("=== P7b MAC 单元门 变异测试 ===")
    results = []
    # 正例 (干净件副本): 必须 PASS —— 变异测试的第一条纪律
    copy_rtl()
    rc0, out0 = run_gate("00_clean")
    done = [l for l in out0.splitlines() if "done:" in l]
    print("  [%s] 正例 (干净件副本)                          rc=%d  %s" %
          ("OK " if rc0 == 0 else "!! ", rc0, done[-1].strip() if done else ""))
    if rc0 != 0:
        print("  !! 正例未 PASS ⇒ 后面的变异结果无意义, 终止")
        for f in [l.strip() for l in out0.splitlines() if "[FAIL]" in l][:10]:
            print("         %s" % f)
        return 1
    for idx, (name, fn, old, new, expect) in enumerate(MUTS):
        copy_rtl()
        path = os.path.join(WORK, fn)
        s = io.open(path, encoding="utf-8").read()
        if old not in s:
            print("  [SKIP] %-40s (锚点未命中: %s)" % (name, fn))
            results.append((name, expect, "anchor_miss"))
            continue
        io.open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))
        tag = "%02d_%s" % (idx, name.split()[0])      # 例: 07_M7b
        rc, out = run_gate(tag)
        caught = (rc != 0)
        ok = (caught == (expect == "caught"))
        # 抓到的失败判据 (最多 5 条; 完整清单见 sim/_mut_logs/<tag>.log)
        fails = [l.strip() for l in out.splitlines() if "[FAIL]" in l]
        print("  [%s] %-42s expect=%s rc=%d  nFAIL=%d" %
              ("OK " if ok else "!! ", name, expect, rc, len(fails)))
        for f in fails[:5]:
            print("         %s" % f)
        results.append((name, expect, "caught" if caught else "missed"))

    copy_rtl()
    print("\n---- 汇总 ----")
    bad = 0
    for name, expect, got in results:
        want = "caught" if expect == "caught" else "missed"
        flag = "OK" if got == want else "!!"
        if got != want:
            bad += 1
        print("  %s  %-44s expect=%-7s got=%s" % (flag, name, want, got))
    print("\nMUT_VERDICT = %s (不等价变异漏掉 %d 条)" %
          ("PASS" if bad == 0 else "FAIL", bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
