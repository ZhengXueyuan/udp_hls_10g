# apply_c.py -- P7B-BIZ 追加 C: slow_{rx,tx}_adp.stat_fifo_ovf 接进快照窗口 (+2 字)
#   W59 = slow_tx_adp.stat_fifo_ovf   (u_wf 拒写; 修好后结构性恒 0 ⇒ 写门回归的板级守卫)
#   W60 = slow_rx_adp.stat_fifo_ovf   (o_ovf 拒写; 同上)
#   两个都**已经是模块输出端口** ⇒ 只动 wrapper (不碰别人的 owner 文件)。
#   ⇒ 窗口 59 -> 61 字; 未实现地址 0x10C -> 0x114
import io, sys

def sub(p, pairs, label=""):
    s = io.open(p, encoding='utf-8', newline='').read()
    for a, b in pairs:
        if a not in s:
            sys.exit("MISS[%s] %s: %s" % (label, p, a[:70]))
        s = s.replace(a, b)
    io.open(p, 'w', encoding='utf-8', newline='').write(s)
    print("ok", p)

W = 'board/wrapper_p4.v'
sub(W, [
 # 1) wire 声明 (与邻居同处: srx_stat_commit/... 那一带)
 ("    wire [31:0] srx_stat_commit, srx_stat_drop;",
  "    wire [31:0] srx_stat_commit, srx_stat_drop;\n"
  "    // P7B-BIZ 追加 C: 两个同族\"本拍空间门\"缺陷的**板级守卫计数器**\n"
  "    //   (slow_adp 的两个 `.wr()` 原先没把空间门预 AND ⇒ 拒写事件**结构性不可见**;\n"
  "    //    修好后它们恒 0, 但一旦写门将来回归本拍 `full`, 它们会立刻响 ⇒ 必须有板级读数,\n"
  "    //    否则\"修好了\"这件事只有仿真背书 —— 本工程已因\"自检在板级结构性为 0\"吃过一次亏)\n"
  "    wire [31:0] srx_stat_fifo_ovf, stx_stat_fifo_ovf;"),
 ("    wire [31:0] stx_stat_frames, stx_stat_purge;",
  "    wire [31:0] stx_stat_frames, stx_stat_purge;\n"
  "    wire [31:0] stx_stat_fifo_ovf_w_check;   // (占位: 见慢路径例化处的接线)"),
 # 2) 两处例化连线
 ("        .stat_commit    (srx_stat_commit),\n        .stat_drop      (srx_stat_drop),",
  "        .stat_commit    (srx_stat_commit),\n        .stat_drop      (srx_stat_drop),\n"
  "        .stat_fifo_ovf  (srx_stat_fifo_ovf),   // P7B-BIZ → W60"),
 ("        .stat_frames    (stx_stat_frames),\n        .stat_purge     (stx_stat_purge)",
  "        .stat_frames    (stx_stat_frames),\n        .stat_purge     (stx_stat_purge),\n"
  "        .stat_fifo_ovf  (stx_stat_fifo_ovf)    // P7B-BIZ → W59"),
 # 3) 总字数 59 -> 61
 ("    // 字宽 59 (P7B-BIZ, 2026-09-30): 51 → 59 (**W51..W58**, 8 个新字)。\n"
  "    //   ⚠️ 后两个 (W57/W58) 是**追加 B**: 重传**会话**的定性观测量 (不是计数, 是状态)。",
  "    // 字宽 61 (P7B-BIZ, 2026-09-30): 51 → 61 (**W51..W60**, 10 个新字)。\n"
  "    //   ⚠️ W57/W58 = **追加 B** (重传**会话**的定性观测量, 不是计数是状态);\n"
  "    //   ⚠️ W59/W60 = **追加 C** (slow_tx_adp / slow_rx_adp 的 `stat_fifo_ovf`,\n"
  "    //      两个同族\"本拍空间门\"缺陷修好后的**板级守卫**), 源都已是模块输出端口。"),
 ("    //   ⚠️ **预算复算** (本轮的 59): 59 ≤ 119 ✓; 未实现地址 = 0x20+4*59 = **0x10C** ✓\n"
  "    //     (字 67, 真正未实现); `{snap_idx,5'b0}` 最大 = (59-1)<<5 = 1856 < 4096 ✓",
  "    //   ⚠️ **预算复算** (本轮的 61): 61 ≤ 119 ✓; 未实现地址 = 0x20+4*61 = **0x114** ✓\n"
  "    //     (字 69, 真正未实现); `{snap_idx,5'b0}` 最大 = (61-1)<<5 = 1920 < 4096 ✓"),
 ("    localparam SNAP_NW_P6E = 59;        // 总字数 W0..W58 (未实现地址 = 0x10C = word 67)",
  "    localparam SNAP_NW_P6E = 61;        // 总字数 W0..W60 (未实现地址 = 0x114 = word 69)"),
 ("    localparam SNAP_P7BDP_NW = 20;      // W39/W40, W45..W50 + **W51..W58 (P7B-BIZ)** (b 域 = dp_clk)",
  "    localparam SNAP_P7BDP_NW = 22;      // W39/W40, W45..W50 + **W51..W60 (P7B-BIZ)** (b 域 = dp_clk)"),
 # 4) 两个新字的源 (追加 C: 在 dom 域 = ? -> slow_adp 在 dp_clk? 见下注释)
 ("    wire [31:0] biz_w58 = {31'd0, tx_retx_active};     // 槽 19: 重传会话进行中 (1 位)",
  "    wire [31:0] biz_w58 = {31'd0, tx_retx_active};     // 槽 19: 重传会话进行中 (1 位)\n"
  "    // ---- 追加 C: 慢路径两个适配器的拒写计数 (源 = 模块输出端口, 已在 dp 域) ----------\n"
  "    //   ⚠️ 口径: 两个都是\"**本拍空间门**没预 AND ⇒ 拒写事件不可见\"那一族缺陷的守卫;\n"
  "    //      修复后应**恒 0**, 非 0 = 又出现了静默丢失 (与 W35/W56 同族)。\n"
  "    wire [31:0] biz_w59 = stx_stat_fifo_ovf;           // 槽 20: slow_tx_adp u_wf 拒写\n"
  "    wire [31:0] biz_w60 = srx_stat_fifo_ovf;           // 槽 21: slow_rx_adp o_ovf 拒写"),
 # 5) 两条显式 assign
 ("    assign p7bdp_din[19*32 +: 32] = biz_w58;   // 槽 19 → W58 tcp_tx_frame.o_retx_active",
  "    assign p7bdp_din[19*32 +: 32] = biz_w58;   // 槽 19 → W58 tcp_tx_frame.o_retx_active\n"
  "    assign p7bdp_din[20*32 +: 32] = biz_w59;   // 槽 20 → W59 slow_tx_adp.stat_fifo_ovf\n"
  "    assign p7bdp_din[21*32 +: 32] = biz_w60;   // 槽 21 → W60 slow_rx_adp.stat_fifo_ovf"),
 # 6) 装配两条 (MSB 端)
 ("    wire [SNAP_NW_P6E*32-1:0] snap_dout_all = {\n        p7bdp_dout[19*32 +: 32],   // W58 tcp_tx_frame.o_retx_active (会话进行中, 1 位)",
  "    wire [SNAP_NW_P6E*32-1:0] snap_dout_all = {\n"
  "        p7bdp_dout[21*32 +: 32],   // W60 slow_rx_adp.stat_fifo_ovf (rx 适配器拒写; 恒 0)\n"
  "        p7bdp_dout[20*32 +: 32],   // W59 slow_tx_adp.stat_fifo_ovf (tx 适配器拒写; 恒 0)\n"
  "        p7bdp_dout[19*32 +: 32],   // W58 tcp_tx_frame.o_retx_active (会话进行中, 1 位)"),
 ("    // ---- 59 字装配 (**逐项写出**: 每项的槽号在注释里, 不依赖\"从右往左\"的记忆) ----",
  "    // ---- 61 字装配 (**逐项写出**: 每项的槽号在注释里, 不依赖\"从右往左\"的记忆) ----"),
 ("    //   ⚠️ 非 P7B 构建里三条新束的 din 全是常量 ⇒ 后 23 个字读回恒 0 (预期, 不是缺陷);",
  "    //   ⚠️ 非 P7B 构建里三条新束的 din 全是常量 ⇒ 后 25 个字读回恒 0 (预期, 不是缺陷);"),
 ("    //      (P7B-BIZ 在 u_snap_p7bdp 里续加 8 个业务字 W51..W58, 见下 `biz_w5x` 处)",
  "    //      (P7B-BIZ 在 u_snap_p7bdp 里续加 10 个业务字 W51..W60, 见下 `biz_w5x` 处)"),
 ("    //   u_snap_p7bdp : clk_b = dp_clk                   NW=20 → W39/W40, W45..W50, **W51..W58**",
  "    //   u_snap_p7bdp : clk_b = dp_clk                   NW=22 → W39/W40, W45..W50, **W51..W60**"),
 ("    // ---- P7B-BIZ: dp 束的 槽 12..19 = 快照字 W51..W58 --------------------------",
  "    // ---- P7B-BIZ: dp 束的 槽 12..21 = 快照字 W51..W60 --------------------------"),
 ("    //   P7B-BIZ 新增 槽 12..19 (W51..W58): 源 = 上面那 8 条 `biz_w5x` (全是 dp 域寄存器输出)。",
  "    //   P7B-BIZ 新增 槽 12..21 (W51..W60): 源 = 上面那 10 条 `biz_w5x` (全是 dp 域寄存器输出)。"),
 ("    // ---- P7B-BIZ: 槽 12..19 (**逐槽显式 assign**, 不并进上面的 generate) ----------",
  "    // ---- P7B-BIZ: 槽 12..21 (**逐槽显式 assign**, 不并进上面的 generate) ----------"),
 ("                                        //    8 = **P7B-BIZ**: 59 字 (W51-W58, 业务观测面 + 重传会话定性)",
  "                                        //    8 = **P7B-BIZ**: 61 字 (W51-W60: 业务观测面 + 重传会话定性 +\n"
  "                                        //        慢路径两个拒写守卫)"),
 ("        .SNAP_NW    (SNAP_NW_P6E)       // 59 = 14+22 (snap_seq) + 3+20+4 (P7b 三束, BIZ 加 8)",
  "        .SNAP_NW    (SNAP_NW_P6E)       // 61 = 14+22 (snap_seq) + 3+22+4 (P7b 三束, BIZ 加 10)"),
 ("        //   · din   = `snap_dout_all` (59 字, axi 域装配, 见采集段)",
  "        //   · din   = `snap_dout_all` (61 字, axi 域装配, 见采集段)"),
], "wrapper")

A = '_proj_pcie/rtl/axi_regs.v'
sub(A, [
 ("//   0x24 RO  SNAP_W1    ... 一直到 **0x108 SNAP_W58** (共 **59 字**; 演进 8→16→24→32→36→51→57→59)。",
  "//   0x24 RO  SNAP_W1    ... 一直到 **0x110 SNAP_W60** (共 **61 字**; 演进 8→16→24→32→36→51→57→59→61)。"),
 ("//                           W58 **tcp_tx_frame.o_retx_active** (重传会话进行中; 低 1 位)",
  "//                           W58 **tcp_tx_frame.o_retx_active** (重传会话进行中; 低 1 位)\n"
  "//                           W59 **slow_tx_adp.stat_fifo_ovf** (u_wf 拒写; 守卫, 恒 0)\n"
  "//                           W60 **slow_rx_adp.stat_fifo_ovf** (o_ovf 拒写; 守卫, 恒 0)"),
 ("//                         未实现地址 = **0x10C** (word 67) ⇒ 读回 0xffffffff。",
  "//                         未实现地址 = **0x114** (word 69) ⇒ 读回 0xffffffff。"),
 ("//             窗口上限从 56 字抬到 **119 字** (字 8..126); 现役 = 59 字, 未实现 = 0x10C;",
  "//             窗口上限从 56 字抬到 **119 字** (字 8..126); 现役 = 61 字, 未实现 = 0x114;"),
 ("    //   ★ **P7B-BIZ (2026-09-30) 收口: NW 51 → 59** (W51..W58 八个业务字)。",
  "    //   ★ **P7B-BIZ (2026-09-30) 收口: NW 51 → 61** (W51..W60 十个业务字)。"),
], "axi_regs")

sub('_proj_pcie/p7b_gate4_accept.sh', [
 ("# p7b_gate4_accept.sh — **P7b 闸 4 板级验收** (板侧 59 字 + NIC 侧网关判据)",
  "# p7b_gate4_accept.sh — **P7b 闸 4 板级验收** (板侧 61 字 + NIC 侧网关判据)"),
 ("#   ① 闸 4 的几何是 **59 字** (0x20..0x108, 未实现 = **0x10C**) —— P7B-BIZ 从 51 字扩来",
  "#   ① 闸 4 的几何是 **61 字** (0x20..0x110, 未实现 = **0x114**) —— P7B-BIZ 从 51 字扩来"),
 ("#         `W58` = `tcp_tx_frame.o_retx_active` (重传会话进行中, 低 1 位)",
  "#         `W58` = `tcp_tx_frame.o_retx_active` (重传会话进行中, 低 1 位)\n"
  "#         `W59` = `slow_tx_adp.stat_fifo_ovf`  (u_wf 拒写; 恒 0 = 无静默丢失)\n"
  "#         `W60` = `slow_rx_adp.stat_fifo_ovf`  (o_ovf 拒写; 恒 0 = 无静默丢失)"),
 ("#   开关: G4_BIT=<位流路径> · EXPECT_BID=0x... · SNAP_WORDS=59 · G4_IFACE=enp1s0f1np1\n"
  "#         ⚠️ P7B-BIZ 起窗口 = **59 字** (RTL `board/wrapper_p4.v` 的 `SNAP_NW_P6E`);",
  "#   开关: G4_BIT=<位流路径> · EXPECT_BID=0x... · SNAP_WORDS=61 · G4_IFACE=enp1s0f1np1\n"
  "#         ⚠️ P7B-BIZ 起窗口 = **61 字** (RTL `board/wrapper_p4.v` 的 `SNAP_NW_P6E`);"),
 ("SNAP_WORDS=${SNAP_WORDS:-59}\nUNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 59 ⇒ 0x10C (51 ⇒ 0xEC)",
  "SNAP_WORDS=${SNAP_WORDS:-61}\nUNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 61 ⇒ 0x114 (51 ⇒ 0xEC)"),
 ("#   · P7B_10G 构建 (默认几何 59 字 / BID=7): 前端域 = PCS 的 CDR **恢复钟**",
  "#   · P7B_10G 构建 (默认几何 61 字 / BID=7): 前端域 = PCS 的 CDR **恢复钟**"),
], "accept")

sub('_proj_pcie/p6e_snap_check.sh', [
 ("#        W0..W58 (0x20..0x108), 重复项结构性不可能再出现。",
  "#        W0..W60 (0x20..0x110), 重复项结构性不可能再出现。"),
 ('#     ② "未实现地址" 0xB0 → 0xEC (51 字) → **0x10C** (P7B-BIZ 59 字; = 0x20 + 4*59)。',
  '#     ② "未实现地址" 0xB0 → 0xEC (51 字) → **0x114** (P7B-BIZ 61 字; = 0x20 + 4*61)。'),
 ("#              ⚠️ P7B-BIZ 起窗口 = **59 字** (RTL 当前值) ⇒ 读 51 字位流要显式覆盖 SNAP_WORDS=51",
  "#              ⚠️ P7B-BIZ 起窗口 = **61 字** (RTL 当前值) ⇒ 读 51 字位流要显式覆盖 SNAP_WORDS=51"),
 ("#    59 = **P7B-BIZ** (`wrapper_p4.v` 的 `SNAP_NW_P6E = 59`; 0x20..0x108, 未实现 0x10C);",
  "#    61 = **P7B-BIZ** (`wrapper_p4.v` 的 `SNAP_NW_P6E = 61`; 0x20..0x110, 未实现 0x114);"),
 ("SNAP_WORDS=${SNAP_WORDS:-59}\nUNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 59 ⇒ 0x10C (51 ⇒ 0xEC)",
  "SNAP_WORDS=${SNAP_WORDS:-61}\nUNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 61 ⇒ 0x114 (51 ⇒ 0xEC)"),
 ("#    (**59 字**把 0x20..0x108 全占了 = word 8..66 ⇒ 第一个空地址 = word 67 = 0x10C;",
  "#    (**61 字**把 0x20..0x110 全占了 = word 8..68 ⇒ 第一个空地址 = word 69 = 0x114;"),
 ("#   · **P7B_10G 构建** (本脚本默认几何 59 字 / EXPECT_BID=7): 前端域 = PCS 的 CDR **恢复钟**",
  "#   · **P7B_10G 构建** (本脚本默认几何 61 字 / EXPECT_BID=7): 前端域 = PCS 的 CDR **恢复钟**"),
 (' "tx_retx_active      (重传/回卷重放会话**进行中**; 低 1 位)" )',
  ' "tx_retx_active      (重传/回卷重放会话**进行中**; 低 1 位)"\n'
  ' # ---- P7B-BIZ 追加 C: 慢路径两个适配器的拒写守卫 (恒 0) ----\n'
  ' "stx_stat_fifo_ovf  (slow_tx_adp u_wf 拒写; 恒 0 = 无静默丢失)"\n'
  ' "srx_stat_fifo_ovf  (slow_rx_adp o_ovf 拒写; 恒 0 = 无静默丢失)" )'),
], "snap_check")

sub('_proj_pcie/p7b_gate4_selftest.sh', [
 ("#        ⚠️ 几何**由 `SNAP_WORDS` 派生** (默认 59 = P7B-BIZ; 59 ⇒ 末字 0x108 / 未实现 0x10C);",
  "#        ⚠️ 几何**由 `SNAP_WORDS` 派生** (默认 61 = P7B-BIZ; 61 ⇒ 末字 0x110 / 未实现 0x114);"),
 ("#   默认 59 = P7B-BIZ (`board/wrapper_p4.v` 的 `SNAP_NW_P6E`); 跑 51 字旧位流: SNAP_WORDS=51。",
  "#   默认 61 = P7B-BIZ (`board/wrapper_p4.v` 的 `SNAP_NW_P6E`); 跑 51 字旧位流: SNAP_WORDS=51。"),
 ("SW=${SNAP_WORDS:-59}\nLAST_A=$(printf '0X%X' $(( 0x20 + 4*(SW-1) )))   # 末字地址  (59 ⇒ 0X108)",
  "SW=${SNAP_WORDS:-61}\nLAST_A=$(printf '0X%X' $(( 0x20 + 4*(SW-1) )))   # 末字地址  (61 ⇒ 0X110)"),
 ("UNIMPL_A=$(printf '0X%X' $(( 0x20 + 4*SW )))      # 未实现地址 (59 ⇒ 0X10C)",
  "UNIMPL_A=$(printf '0X%X' $(( 0x20 + 4*SW )))      # 未实现地址 (61 ⇒ 0X114)"),
 ("  0X108) V=0;;                                        # W58 tcp_tx_frame.o_retx_active\n"
  "  0X10C) V=\\${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (59 字; 旧版 0xEC -> 0x104 -> 0x10C)",
  "  0X108) V=0;;                                        # W58 tcp_tx_frame.o_retx_active\n"
  "  0X10C) V=0;;                                        # W59 slow_tx_adp.stat_fifo_ovf\n"
  "  0X110) V=0;;                                        # W60 slow_rx_adp.stat_fifo_ovf\n"
  "  0X114) V=\\${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (61 字; 旧版 0xEC -> 0x104 -> 0x10C -> 0x114)"),
], "selftest")

sub('_proj_pcie/p7b_biz/p7b_snap.sh', [
 ("# p7b_snap.sh -- 板侧 59 字快照窗口的取数器 (P7B-BIZ: BID=7 (合体后 8) / SNAP_NW=59)",
  "# p7b_snap.sh -- 板侧 61 字快照窗口的取数器 (P7B-BIZ: BID=7 (合体后 8) / SNAP_NW=61)"),
 ("#   bash p7b_snap.sh full TAG                # 触发一次 + 打全 59 字 (带名字)",
  "#   bash p7b_snap.sh full TAG                # 触发一次 + 打全 61 字 (带名字)"),
 ("NW=${NW:-59}\nUNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*NW )))}   # 59 ⇒ 0x10C (51 ⇒ 0xEC)",
  "NW=${NW:-61}\nUNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*NW )))}   # 61 ⇒ 0x114 (51 ⇒ 0xEC)"),
 ("#      W57 tx_retx_hi (回卷重放上界) / W58 tx_retx_active (会话进行中)",
  "#      W57 tx_retx_hi (回卷重放上界) / W58 tx_retx_active (会话进行中) /\n"
  "#      W59/W60 slow_tx_adp / slow_rx_adp 的 stat_fifo_ovf (拒写守卫, 恒 0)"),
], "p7b_snap")

sub('_proj_10g/notes/p7b_gate4_3/final_state.sh', [
 ('UNIMPL=$(rd 0x10C) gen=$(( (s >> 16) & 0xffff ))"',
  'UNIMPL=$(rd 0x114) gen=$(( (s >> 16) & 0xffff ))"'),
 ("# ⚠️ UNIMPL 地址跟窗口宽度走: **59 字 (P7B-BIZ 起) ⇒ 0x10C**; 51 字位流 ⇒ 0xEC。",
  "# ⚠️ UNIMPL 地址跟窗口宽度走: **61 字 (P7B-BIZ 起) ⇒ 0x114**; 51 字位流 ⇒ 0xEC。"),
 ('W57=$(rd 0x104) W58=$(rd 0x108)  # P7B-BIZ 八字"',
  'W57=$(rd 0x104) W58=$(rd 0x108) W59=$(rd 0x10c) W60=$(rd 0x110)  # P7B-BIZ 十字"'),
], "final_state")

sub('_proj_pcie/p6b_accept.sh', [
 ("#   **P7B-BIZ 的 59 字**占 0x20..0x108 ⇒ 未实现 = **0x10C**",
  "#   **P7B-BIZ 的 61 字**占 0x20..0x110 ⇒ 未实现 = **0x114**"),
 ("#   **P7B-BIZ 59 字 = max {58,5'b0} = 1856 ⇒ 同一个 `[11:0]` 仍够, 本轮未动这一行**。",
  "#   **P7B-BIZ 61 字 = max {60,5'b0} = 1920 ⇒ 同一个 `[11:0]` 仍够, 本轮未动这一行**。"),
], "p6b_accept")
print("ALL OK")
