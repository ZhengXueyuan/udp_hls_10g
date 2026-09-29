# -*- coding: utf-8 -*-
"""
mutate_rxcls.py —— 变异测试: 把 rx_classify_v2 改坏, 看单元门是否报警 (判据有没有牙)

用法 (从 git bash, 仓根):
    /c/Users/zhxue/anaconda3/python.exe _proj_10g/p7b_rxcls/scripts/mutate_rxcls.py

做法:
  1. 把 _proj_10g/p7b_rxcls/rtl/rx_classify_v2.v 拷到 sim/_mut_rtl/
  2. 对副本施加**一处**变异 (文本替换)
  3. 用 P7B_RXCLS_RTL=<副本目录> 跑 sim/run_tb_rxcls_v2.bat
  4. 「抓住」= 门退出非 0; 「漏掉」= 门仍 PASS (必须如实登记)
原始 RTL 一个字节都不动; 只写 sim/_mut_rtl/ 与 sim/_mut_logs/。

关键变异 (判据判别力):
  M1 「FILL 期不输出」形态复活 (决策窗内禁止发射) —— 吞吐判据必须 FAIL
  M2 F4 形态静默丢字 (空间门用寄存器化 full) —— 内容对拍 + ovf 自检必须 FAIL
  M3 分类语义回归 (tlast 优先级被 w5 flags 覆盖) —— 保真对拍必须 FAIL
  M4 路由队列每拍出队 (帧末才该出队) —— 保真/吞吐必须 FAIL
  M5/M6 等价变异 —— **期望漏掉** (如实登记)
"""
import io
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))          # p7b_rxcls/scripts
PROJ = os.path.dirname(HERE)                               # p7b_rxcls
RTL = os.path.join(PROJ, "rtl")
SIM = os.path.join(PROJ, "sim")
WORK = os.path.join(SIM, "_mut_rtl")
LOGS = os.path.join(SIM, "_mut_logs")
BAT = os.path.join(SIM, "run_tb_rxcls_v2.bat")

# 变异体里要插入的多行块 (保持 Verilog 合法: 模块项顺序任意)
# M1 = 把 v1 的核心缺陷 (每帧 6 拍通道空转) 搬回 v2: 每发完一帧就"空 6 拍"才允许发射。
#      计时器**按拍递减** (不是按接受字数), 所以不会死锁 ⇒ 稳态应回到 v1 的 N/(N+6)。
M1_BLOCK = """    reg blank_m1; reg [3:0] bc_m1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin blank_m1 <= 1'b0; bc_m1 <= 4'd0; end
        else begin
            if (w_wr && s_axis_tlast) begin blank_m1 <= 1'b1; bc_m1 <= 4'd6; end
            else if (bc_m1 > 4'd0) begin
                bc_m1 <= bc_m1 - 4'd1;
                if (bc_m1 == 4'd1) blank_m1 <= 1'b0;
            end
        end
    end
    wire          rd_ok       = !w_empty && !rq_empty && !blank_m1;"""

M2_BLOCK = """    reg w_full_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) w_full_r <= 1'b0; else w_full_r <= w_full;
    end
    assign s_axis_tready = !w_full_r;"""

# (名字, 原文, 变异后, 预期)  预期: "caught" = 门应报 FAIL
MUTS = [
    ("M1 FILL-without-output modality restored (read blanked in decision window)",
     "    wire          rd_ok       = !w_empty && !rq_empty;",
     M1_BLOCK, "caught"),
    ("M2 F4-style silent word loss (registered full as space gate)",
     "    assign s_axis_tready = !w_full;",
     M2_BLOCK, "caught"),
    ("M3 tlast priority lost (w5 flags override tlast)",
     "    wire       dec_w2 = (widx == 4'd2) && !s_axis_tlast && !cur_is_tcp; // 非 TCP: 定案 SLOW\n"
     "    wire       dec_w5 = (widx == 4'd5) && !s_axis_tlast;                // TCP: 看 w5 flags",
     "    wire       dec_w2 = (widx == 4'd2) && !cur_is_tcp; // 非 TCP: 定案 SLOW\n"
     "    wire       dec_w5 = (widx == 4'd5);                // TCP: 看 w5 flags", "caught"),
    ("M4 route queue popped every word (should pop at frame end)",
     "    wire          rq_pop      = w_rd && w_dout[3];       // 本帧末字发出那一拍",
     "    wire          rq_pop      = w_rd;                    // M4: 每拍出队", "caught"),
    ("M5 (equivalent) widx == 4'd2 written as widx == 2",
     "    wire       dec_w2 = (widx == 4'd2) && !s_axis_tlast && !cur_is_tcp;",
     "    wire       dec_w2 = (widx == 2) && !s_axis_tlast && !cur_is_tcp;", "not_caught"),
    ("M6 (equivalent) cur_tcp_ctl inlined into dec_val",
     "    wire       dec_val  = dec_w5 ? (cur_tcp_ctl ? RT_SLOW : RT_FAST) : RT_SLOW;",
     "    wire       dec_val  = dec_w5 ? ((|s_axis_tdata[2:0]) ? RT_SLOW : RT_FAST) : RT_SLOW;",
     "not_caught"),
    # M7: 实验中发现的一条**真等价**变异 (M3 只改 dec_w2 那一半时主门仍 PASS ⇒ 追因所得):
    #   dec_w2 只在 !is_tcp 时成立, 而非 TCP 帧无论走 tlast 规则还是走 w2 规则都得 SLOW
    #   ⇒ 去掉 dec_w2 的 !s_axis_tlast 对**任何**激励都无影响。可作为判据边界的反证。
    ("M7 (equivalent, found by experiment) dec_w2 loses !tlast: non-TCP is SLOW either way",
     "    wire       dec_w2 = (widx == 4'd2) && !s_axis_tlast && !cur_is_tcp;",
     "    wire       dec_w2 = (widx == 4'd2) && !cur_is_tcp;", "not_caught"),
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
    env["P7B_RXCLS_RTL"] = WORK
    p = subprocess.run(["cmd", "/c", BAT], cwd=SIM, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = p.stdout.decode("utf-8", "replace")
    if tag:
        if not os.path.isdir(LOGS):
            os.makedirs(LOGS)
        src = os.path.join(SIM, "xsim_rxcls.log")
        if os.path.isfile(src):
            shutil.copy(src, os.path.join(LOGS, tag + ".log"))
    return p.returncode, out


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    print("=== P7B rx_classify_v2 单元门 变异测试 ===")
    results = []
    copy_rtl()
    rc0, out0 = run_gate("00_clean")
    done = [l for l in out0.splitlines() if "done:" in l]
    print("  [%s] 正例 (干净件副本)                    rc=%d  %s" %
          ("OK " if rc0 == 0 else "!! ", rc0, done[-1].strip() if done else ""))
    if rc0 != 0:
        print("  !! 正例未 PASS ⇒ 后面的变异结果无意义, 终止")
        for f in [l.strip() for l in out0.splitlines() if "[FAIL]" in l][:10]:
            print("         %s" % f)
        return 1
    for idx, (name, old, new, expect) in enumerate(MUTS):
        copy_rtl()
        path = os.path.join(WORK, "rx_classify_v2.v")
        s = io.open(path, encoding="utf-8").read()
        if old not in s:
            print("  [SKIP] %-52s (锚点未命中)" % name)
            results.append((name, expect, "anchor_miss"))
            continue
        io.open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))
        tag = "%02d_%s" % (idx, name.split()[0])
        rc, out = run_gate(tag)
        caught = (rc != 0)
        ok = (caught == (expect == "caught"))
        fails = [l.strip() for l in out.splitlines() if "[FAIL]" in l]
        meas = [l.strip() for l in out.splitlines() if "[meas]" in l]
        print("  [%s] %-52s expect=%-11s rc=%d  nFAIL=%d" %
              ("OK " if ok else "!! ", name, expect, rc, len(fails)))
        for f in fails[:4]:
            print("         %s" % f)
        for m in meas[:2]:
            print("         %s" % m)
        results.append((name, expect, "caught" if caught else "missed"))

    copy_rtl()
    print("\n---- 汇总 ----")
    bad = 0
    for name, expect, got in results:
        want = "caught" if expect == "caught" else "missed"
        if got != want:
            bad += 1
        print("  %s  %-54s expect=%-7s got=%s" %
              ("OK" if got == want else "!!", name, want, got))
    print("\nMUT_VERDICT = %s (非等价变异漏掉 %d 条)" %
          ("PASS" if bad == 0 else "FAIL", bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
