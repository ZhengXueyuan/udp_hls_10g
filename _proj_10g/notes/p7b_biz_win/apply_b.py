# apply_b.py -- P7B-BIZ 追加 B (安全部分): 把**已有的、已注册的**重传会话信号接地到快照
#   W57 = tx_retx_hi      (tcp_tx_frame 的 reg retx_hi, dp 域 ⇒ 满足 snap_cdc 前提)
#   W58 = {31'd0, tx_retx_active}  (同族的 reg retx_active, 1 位)
#   ⇒ 窗口 57 -> 59 字; 未实现地址 0x104 -> 0x10C
import io, re, sys

def sub(p, pairs, label=""):
    s = io.open(p, encoding='utf-8', newline='').read()
    for a, b in pairs:
        if a not in s:
            sys.exit("MISS[%s] %s: %s" % (label, p, a[:70]))
        s = s.replace(a, b)
    io.open(p, 'w', encoding='utf-8', newline='').write(s)
    print("ok", p)

# ---- 硬守卫 (2026-10-07 "台架修复轮" 加; 与 apply_c.py 同款, pre-state = 57) --------
# ⚠️ 本件是**历史一次性补丁生成器** (窗口 57 -> 59 那一代)。重跑它 = 把旧一代的文本
#    贴回现役 RTL/脚本 (静默回退)。实测: 今天重跑会在第一个锚点 MISS 退出, 但那是
#    **字符串巧合**而不是设计的守卫; `sub()` 又是**逐文件**落盘 ⇒ 前几个文件命中、
#    后面某个 MISS 就会留下**半改**状态。⇒ 先核 pre-state, 不符就拒绝 (exit 3), 不写。
def _guard_prestate():
    w = 'board/wrapper_p4.v'
    s = io.open(w, encoding='utf-8', newline='').read()
    m = re.search(r'localparam\s+SNAP_NW_P6E\s*=\s*(\d+)\s*;', s)
    got = int(m.group(1)) if m else -1
    if got != 57:
        sys.stderr.write(
            "GUARD_REFUSE: %s 的 SNAP_NW_P6E = %s (期望 pre-state = 57).\n"
            "  本脚本只适用于窗口 57 -> 59 那一代; 现役窗口已不是那一代\n"
            "  => 拒绝执行, 未写任何文件 (防止把旧一代文本贴回现役件).\n"
            "  如确要重跑历史件, 请在**临时 worktree** 里 checkout 对应 revision 再跑.\n"
            % (w, got))
        sys.exit(3)
_guard_prestate()

W = 'board/wrapper_p4.v'
sub(W, [
 # ---- 1) 总字数 57 -> 59 ----
 ("    // 字宽 57 (P7B-BIZ, 2026-09-30): 51 → 57 (**W51..W56**, 6 个新字)。",
  "    // 字宽 59 (P7B-BIZ, 2026-09-30): 51 → 59 (**W51..W58**, 8 个新字)。\n"
  "    //   ⚠️ 后两个 (W57/W58) 是**追加 B**: 重传**会话**的定性观测量 (不是计数, 是状态)。"),
 ("    //   ⚠️ **预算复算** (本轮的 57): 57 ≤ 119 ✓; 未实现地址 = 0x20+4*57 = **0x104** ✓\n"
  "    //     (字 65, 真正未实现); `{snap_idx,5'b0}` 最大 = (57-1)<<5 = 1792 < 4096 ✓",
  "    //   ⚠️ **预算复算** (本轮的 59): 59 ≤ 119 ✓; 未实现地址 = 0x20+4*59 = **0x10C** ✓\n"
  "    //     (字 67, 真正未实现); `{snap_idx,5'b0}` 最大 = (59-1)<<5 = 1856 < 4096 ✓"),
 ("    localparam SNAP_NW_P6E = 57;        // 总字数 W0..W56 (未实现地址 = 0x104 = word 65)",
  "    localparam SNAP_NW_P6E = 59;        // 总字数 W0..W58 (未实现地址 = 0x10C = word 67)"),
 ("    localparam SNAP_P7BDP_NW = 18;      // W39/W40, W45..W50 + **W51..W56 (P7B-BIZ)** (b 域 = dp_clk)",
  "    localparam SNAP_P7BDP_NW = 20;      // W39/W40, W45..W50 + **W51..W58 (P7B-BIZ)** (b 域 = dp_clk)"),
 # ---- 2) 两个新字的源 (只有 W57/W58, 无 APP_MODE 守卫: tcp_tx_frame 恒例化) ----
 ("    // W55 的源 `tcp_tx_frame.stat_retx` **在所有构建里都存在** (它的例化在 `ifdef APP_MODE`\n"
  "    // 之外) ⇒ 不包守卫, 免得默认构建白丢一个真值。\n"
  "    wire [31:0] biz_w55 = tx_stat_retx;     // 槽 16: 重传/RTO 回卷次数 (F5b 的判决量)",
  "    // W55 的源 `tcp_tx_frame.stat_retx` **在所有构建里都存在** (它的例化在 `ifdef APP_MODE`\n"
  "    // 之外) ⇒ 不包守卫, 免得默认构建白丢一个真值。\n"
  "    wire [31:0] biz_w55 = tx_stat_retx;     // 槽 16: 重传/RTO 回卷次数 (F5b 的判决量)\n"
  "    // ---- 追加 B (2026-09-30): 重传**会话**的定性观测 (都不新增状态) --------------\n"
  "    //   来源 = `tcp_tx_frame` 的两个**已有寄存器输出** (`o_retx_hi`/`o_retx_active`\n"
  "    //   = 本文件 `:2144-2145` 的接线), 它们是 `reg retx_hi`/`reg retx_active`\n"
  "    //   (`rtl/tcp_tx_frame.v:236,238`) 的纯 assign 引出 ⇒ **dp 域寄存器输出**\n"
  "    //   ⇒ 满足 snap_cdc 的前提 (`din_b` 只在 `clk_b` 沿变化)。**未新造任何状态**。\n"
  "    //   为什么要它们 (板级 S1 的新发现: 每条 TCP 连接多发 ~11.9 个重复 seq 整段):\n"
  "    //     W55 只能给**次数**; 这两条给**状态** —— `retx_active=1` 表示采样时刻正处在\n"
  "    //     一次回卷重放会话中, `retx_hi` 是该会话的重放上界 (= 回卷前的 snd_nxt)。\n"
  "    //     与对端 pcap 的 seq 对齐即可判: 重复段落的 seq 上沿是否落在 [snd_una, retx_hi]。\n"
  "    //   ⚠️ 口径: `retx_hi` **只在 `retx_active=1` 时有效** (会话结束它不再更新)。\n"
  "    wire [31:0] biz_w57 = tx_retx_hi;                  // 槽 18: 回卷重放上界 (会话中有效)\n"
  "    wire [31:0] biz_w58 = {31'd0, tx_retx_active};     // 槽 19: 重传会话进行中 (1 位)"),
 # ---- 3) 两条显式 assign ----
 ("    assign p7bdp_din[17*32 +: 32] = biz_w56;   // 槽 17 → W56 app_udp_pattern.stat_tx_ovf",
  "    assign p7bdp_din[17*32 +: 32] = biz_w56;   // 槽 17 → W56 app_udp_pattern.stat_tx_ovf\n"
  "    assign p7bdp_din[18*32 +: 32] = biz_w57;   // 槽 18 → W57 tcp_tx_frame.o_retx_hi\n"
  "    assign p7bdp_din[19*32 +: 32] = biz_w58;   // 槽 19 → W58 tcp_tx_frame.o_retx_active"),
 # ---- 4) 装配: 两条新项落在最上面 (MSB 端) ----
 ("    wire [SNAP_NW_P6E*32-1:0] snap_dout_all = {\n"
  "        p7bdp_dout[17*32 +: 32],   // W56 app_udp_pattern TX 字 FIFO 拒写 (padrem 类回归的守卫)",
  "    wire [SNAP_NW_P6E*32-1:0] snap_dout_all = {\n"
  "        p7bdp_dout[19*32 +: 32],   // W58 tcp_tx_frame.o_retx_active (会话进行中, 1 位)\n"
  "        p7bdp_dout[18*32 +: 32],   // W57 tcp_tx_frame.o_retx_hi (回卷重放上界; 会话中有效)\n"
  "        p7bdp_dout[17*32 +: 32],   // W56 app_udp_pattern TX 字 FIFO 拒写 (padrem 类回归的守卫)"),
 ("    // ---- 57 字装配 (**逐项写出**: 每项的槽号在注释里, 不依赖\"从右往左\"的记忆) ----",
  "    // ---- 59 字装配 (**逐项写出**: 每项的槽号在注释里, 不依赖\"从右往左\"的记忆) ----"),
 ("    //   ⚠️ 非 P7B 构建里三条新束的 din 全是常量 ⇒ 后 21 个字读回恒 0 (预期, 不是缺陷);\n"
  "    //      非 APP_MODE 构建里 W51..W54 / W56 同理 (逐字源 = 常量), 但 **W55 (retx) 仍真**。",
  "    //   ⚠️ 非 P7B 构建里三条新束的 din 全是常量 ⇒ 后 23 个字读回恒 0 (预期, 不是缺陷);\n"
  "    //      非 APP_MODE 构建里 W51..W54 / W56 同理 (逐字源 = 常量), 但 **W55/W57/W58 仍真**\n"
  "    //      (它们的源 = tcp_tx_frame, 在任何构建里都例化)。"),
 # ---- 5) 其它零散注释 ----
 ("    //      (P7B-BIZ 在 u_snap_p7bdp 里续加 6 个业务字 W51..W56, 见下 `biz_w5x` 处)",
  "    //      (P7B-BIZ 在 u_snap_p7bdp 里续加 8 个业务字 W51..W58, 见下 `biz_w5x` 处)"),
 ("    //   u_snap_p7bdp : clk_b = dp_clk                   NW=18 → W39/W40, W45..W50, **W51..W56**",
  "    //   u_snap_p7bdp : clk_b = dp_clk                   NW=20 → W39/W40, W45..W50, **W51..W58**"),
 ("    // ---- P7B-BIZ: dp 束的 槽 12..17 = 快照字 W51..W56 --------------------------",
  "    // ---- P7B-BIZ: dp 束的 槽 12..19 = 快照字 W51..W58 --------------------------"),
 ("    //   P7B-BIZ 新增 槽 12..17 (W51..W56): 源 = 上面那 6 条 `biz_w5x` (全是 dp 域寄存器输出)。",
  "    //   P7B-BIZ 新增 槽 12..19 (W51..W58): 源 = 上面那 8 条 `biz_w5x` (全是 dp 域寄存器输出)。"),
 ("    // ---- P7B-BIZ: 槽 12..17 (**逐槽显式 assign**, 不并进上面的 generate) ----------",
  "    // ---- P7B-BIZ: 槽 12..19 (**逐槽显式 assign**, 不并进上面的 generate) ----------"),
 ("                                        //    8 = **P7B-BIZ**: 57 字 (W51-W56, 业务观测面)",
  "                                        //    8 = **P7B-BIZ**: 59 字 (W51-W58, 业务观测面 + 重传会话定性)"),
 ("        .SNAP_NW    (SNAP_NW_P6E)       // 57 = 14+22 (snap_seq) + 3+18+4 (P7b 三束, BIZ 加 6)",
  "        .SNAP_NW    (SNAP_NW_P6E)       // 59 = 14+22 (snap_seq) + 3+20+4 (P7b 三束, BIZ 加 8)"),
 ("        //   · din   = `snap_dout_all` (57 字, axi 域装配, 见采集段)",
  "        //   · din   = `snap_dout_all` (59 字, axi 域装配, 见采集段)"),
 ("    //    ⑥ 三个门自己的参数 (tb_axi_regs / tb_snap_cdc / tb_p6e_pcie_*) \n",
  "    //    ⑥ 三个门自己的参数 (tb_axi_regs / tb_snap_cdc / tb_p6e_pcie_*) \n"
  "    //    (P7B-BIZ 另加两处**本工程特有的**守卫: ⑧ `_proj_10g/notes/p7b_biz_win/check_window.py`\n"
  "    //      静态核装配项数/槽号/旧字不移位 ⑨ `tb_biz_win.v` 逐字读回 — 见 P7B_BIZ_WINDOW.md)\n"),
], "wrapper")

A = '_proj_pcie/rtl/axi_regs.v'
sub(A, [
 ("//   0x24 RO  SNAP_W1    ... 一直到 **0x100 SNAP_W56** (共 **57 字**; 演进 8→16→24→32→36→51→57)。",
  "//   0x24 RO  SNAP_W1    ... 一直到 **0x108 SNAP_W58** (共 **59 字**; 演进 8→16→24→32→36→51→57→59)。"),
 ("//                           W56 **app_udp_pattern.stat_tx_ovf** (静的丢字类回归守卫)",
  "//                           W56 **app_udp_pattern.stat_tx_ovf** (静的丢字类回归守卫)\n"
  "//                           W57 **tcp_tx_frame.o_retx_hi** (回卷重放上界; 会话中有效)\n"
  "//                           W58 **tcp_tx_frame.o_retx_active** (重传会话进行中; 低 1 位)"),
 ("//                         未实现地址 = **0x104** (word 65) ⇒ 读回 0xffffffff。",
  "//                         未实现地址 = **0x10C** (word 67) ⇒ 读回 0xffffffff。"),
 ("//      ⚠️ ⭐ **2026-09-30 (P7B-BIZ) 这条红线被解除了**: 57 字需要字 64 (= 0x100) 可寻址,",
  "//      ⚠️ ⭐ **2026-09-30 (P7B-BIZ) 这条红线被解除了**: 窗口跨过 0xFF 需要字 64 (= 0x100) 可寻址,"),
 ("//           · 未实现地址的可行域从 {word 64} 扩到 {word 65..127} = 0x104..0x1FC ⇒\n"
  "//             窗口上限从 56 字抬到 **119 字** (字 8..126); 现役 = 57 字, 未实现 = 0x104;",
  "//           · 未实现地址的可行域从 {word 64} 扩到 {word 65..127} = 0x104..0x1FC ⇒\n"
  "//             窗口上限从 56 字抬到 **119 字** (字 8..126); 现役 = 59 字, 未实现 = 0x10C;"),
 ("    //   ★ **P7B-BIZ (2026-09-30) 收口: NW 51 → 57** (W51..W56 六个业务字)。",
  "    //   ★ **P7B-BIZ (2026-09-30) 收口: NW 51 → 59** (W51..W58 八个业务字)。"),
], "axi_regs")

# ---- 脚本: 57 -> 59 / 0x104 -> 0x10C ----
sub('_proj_pcie/p7b_gate4_accept.sh', [
 ("# p7b_gate4_accept.sh — **P7b 闸 4 板级验收** (板侧 57 字 + NIC 侧网关判据)",
  "# p7b_gate4_accept.sh — **P7b 闸 4 板级验收** (板侧 59 字 + NIC 侧网关判据)"),
 ("#   ① 闸 4 的几何是 **57 字** (0x20..0x100, 未实现 = **0x104**) —— P7B-BIZ 从 51 字扩来",
  "#   ① 闸 4 的几何是 **59 字** (0x20..0x108, 未实现 = **0x10C**) —— P7B-BIZ 从 51 字扩来"),
 ("#         `W56` = `app_udp_pattern.stat_tx_ovf` (TX 字 FIFO 拒写; 静默丢字类回归的守卫)",
  "#         `W56` = `app_udp_pattern.stat_tx_ovf` (TX 字 FIFO 拒写; 静默丢字类回归的守卫)\n"
  "#         `W57` = `tcp_tx_frame.o_retx_hi`     (回卷重放上界; **只在 W58=1 时有效**)\n"
  "#         `W58` = `tcp_tx_frame.o_retx_active` (重传会话进行中, 低 1 位)"),
 ("#   开关: G4_BIT=<位流路径> · EXPECT_BID=0x... · SNAP_WORDS=57 · G4_IFACE=enp1s0f1np1\n"
  "#         ⚠️ P7B-BIZ 起窗口 = **57 字** (RTL `board/wrapper_p4.v` 的 `SNAP_NW_P6E`);",
  "#   开关: G4_BIT=<位流路径> · EXPECT_BID=0x... · SNAP_WORDS=59 · G4_IFACE=enp1s0f1np1\n"
  "#         ⚠️ P7B-BIZ 起窗口 = **59 字** (RTL `board/wrapper_p4.v` 的 `SNAP_NW_P6E`);"),
 ("SNAP_WORDS=${SNAP_WORDS:-57}\nUNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 57 ⇒ 0x104 (51 ⇒ 0xEC)",
  "SNAP_WORDS=${SNAP_WORDS:-59}\nUNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 59 ⇒ 0x10C (51 ⇒ 0xEC)"),
 ("#   · P7B_10G 构建 (默认几何 57 字 / BID=7): 前端域 = PCS 的 CDR **恢复钟**",
  "#   · P7B_10G 构建 (默认几何 59 字 / BID=7): 前端域 = PCS 的 CDR **恢复钟**"),
], "accept")

sub('_proj_pcie/p6e_snap_check.sh', [
 ("#        W0..W56 (0x20..0x100), 重复项结构性不可能再出现。",
  "#        W0..W58 (0x20..0x108), 重复项结构性不可能再出现。"),
 ('#     ② "未实现地址" 0xB0 → 0xEC (51 字) → **0x104** (P7B-BIZ 57 字; = 0x20 + 4*57)。',
  '#     ② "未实现地址" 0xB0 → 0xEC (51 字) → **0x10C** (P7B-BIZ 59 字; = 0x20 + 4*59)。'),
 ("#              ⚠️ P7B-BIZ 起窗口 = **57 字** (RTL 当前值) ⇒ 读 51 字位流要显式覆盖 SNAP_WORDS=51",
  "#              ⚠️ P7B-BIZ 起窗口 = **59 字** (RTL 当前值) ⇒ 读 51 字位流要显式覆盖 SNAP_WORDS=51"),
 ("#    57 = **P7B-BIZ** (`wrapper_p4.v` 的 `SNAP_NW_P6E = 57`; 0x20..0x100, 未实现 0x104);",
  "#    59 = **P7B-BIZ** (`wrapper_p4.v` 的 `SNAP_NW_P6E = 59`; 0x20..0x108, 未实现 0x10C);"),
 ("SNAP_WORDS=${SNAP_WORDS:-57}\nUNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 57 ⇒ 0x104 (51 ⇒ 0xEC)",
  "SNAP_WORDS=${SNAP_WORDS:-59}\nUNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 59 ⇒ 0x10C (51 ⇒ 0xEC)"),
 ("#    (**57 字**把 0x20..0x100 全占了 = word 8..64 ⇒ 第一个空地址 = word 65 = 0x104;",
  "#    (**59 字**把 0x20..0x108 全占了 = word 8..66 ⇒ 第一个空地址 = word 67 = 0x10C;"),
 ("#   · **P7B_10G 构建** (本脚本默认几何 57 字 / EXPECT_BID=7): 前端域 = PCS 的 CDR **恢复钟**",
  "#   · **P7B_10G 构建** (本脚本默认几何 59 字 / EXPECT_BID=7): 前端域 = PCS 的 CDR **恢复钟**"),
 (' "udpapp_tx_ovf      (UDP app TX 字 FIFO 拒写 ⭐必须恒 0,丢字类回归守卫)" )',
  ' "udpapp_tx_ovf      (UDP app TX 字 FIFO 拒写 ⭐必须恒 0,丢字类回归守卫)"\n'
  ' # ---- P7B-BIZ 追加 B: 重传会话的定性观测 (都来自 tcp_tx_frame 的已有寄存器输出) ----\n'
  ' "tx_retx_hi          (回卷重放上界: 会话中 = ack 上界; **只在 W58=1 时有效**)"\n'
  ' "tx_retx_active      (重传/回卷重放会话**进行中**; 低 1 位)" )'),
], "snap_check")

sub('_proj_pcie/p7b_gate4_selftest.sh', [
 ("#        ⚠️ 几何**由 `SNAP_WORDS` 派生** (默认 57 = P7B-BIZ; 57 ⇒ 末字 0x100 / 未实现 0x104);",
  "#        ⚠️ 几何**由 `SNAP_WORDS` 派生** (默认 59 = P7B-BIZ; 59 ⇒ 末字 0x108 / 未实现 0x10C);"),
 ("#   默认 57 = P7B-BIZ (`board/wrapper_p4.v` 的 `SNAP_NW_P6E`); 跑 51 字旧位流: SNAP_WORDS=51。",
  "#   默认 59 = P7B-BIZ (`board/wrapper_p4.v` 的 `SNAP_NW_P6E`); 跑 51 字旧位流: SNAP_WORDS=51。"),
 ("SW=${SNAP_WORDS:-57}\nLAST_A=$(printf '0X%X' $(( 0x20 + 4*(SW-1) )))   # 末字地址  (57 ⇒ 0X100)",
  "SW=${SNAP_WORDS:-59}\nLAST_A=$(printf '0X%X' $(( 0x20 + 4*(SW-1) )))   # 末字地址  (59 ⇒ 0X108)"),
 ("UNIMPL_A=$(printf '0X%X' $(( 0x20 + 4*SW )))      # 未实现地址 (57 ⇒ 0X104)",
  "UNIMPL_A=$(printf '0X%X' $(( 0x20 + 4*SW )))      # 未实现地址 (59 ⇒ 0X10C)"),
 ("  0X100) V=0;;     # W56 app_udp_pattern.stat_tx_ovf (必须 0)\n"
  "  0X104) V=\\${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (57 字; 旧版是 0xEC)",
  "  0X100) V=0;;     # W56 app_udp_pattern.stat_tx_ovf (必须 0)\n"
  "  0X104) V=0;;                                        # W57 tcp_tx_frame.o_retx_hi\n"
  "  0X108) V=0;;                                        # W58 tcp_tx_frame.o_retx_active\n"
  "  0X10C) V=\\${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (59 字; 旧版 0xEC -> 0x104 -> 0x10C)"),
], "selftest")

sub('_proj_pcie/p7b_biz/p7b_snap.sh', [
 ("# p7b_snap.sh -- 板侧 57 字快照窗口的取数器 (P7B-BIZ: BID=7 (合体后 8) / SNAP_NW=57)",
  "# p7b_snap.sh -- 板侧 59 字快照窗口的取数器 (P7B-BIZ: BID=7 (合体后 8) / SNAP_NW=59)"),
 ("#   bash p7b_snap.sh full TAG                # 触发一次 + 打全 57 字 (带名字)",
  "#   bash p7b_snap.sh full TAG                # 触发一次 + 打全 59 字 (带名字)"),
 ("NW=${NW:-57}\nUNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*NW )))}   # 57 ⇒ 0x104 (51 ⇒ 0xEC)",
  "NW=${NW:-59}\nUNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*NW )))}   # 59 ⇒ 0x10C (51 ⇒ 0xEC)"),
 ("#      W54 app_mismatch / W55 tx_stat_retx / W56 app_udp_pattern.stat_tx_ovf",
  "#      W54 app_mismatch / W55 tx_stat_retx / W56 app_udp_pattern.stat_tx_ovf /\n"
  "#      W57 tx_retx_hi (回卷重放上界) / W58 tx_retx_active (会话进行中)"),
], "p7b_snap")

sub('_proj_10g/notes/p7b_gate4_3/final_state.sh', [
 ('UNIMPL=$(rd 0x104) gen=$(( (s >> 16) & 0xffff ))"',
  'UNIMPL=$(rd 0x10C) gen=$(( (s >> 16) & 0xffff ))"'),
 ("# ⚠️ UNIMPL 地址跟窗口宽度走: **57 字 (P7B-BIZ 起) ⇒ 0x104**; 51 字位流 ⇒ 0xEC。",
  "# ⚠️ UNIMPL 地址跟窗口宽度走: **59 字 (P7B-BIZ 起) ⇒ 0x10C**; 51 字位流 ⇒ 0xEC。"),
 ('echo "W51=$(rd 0xec) W52=$(rd 0xf0) W53=$(rd 0xf4) W54=$(rd 0xf8) W55=$(rd 0xfc) W56=$(rd 0x100)  # P7B-BIZ 六字"',
  'echo "W51=$(rd 0xec) W52=$(rd 0xf0) W53=$(rd 0xf4) W54=$(rd 0xf8) W55=$(rd 0xfc) W56=$(rd 0x100) W57=$(rd 0x104) W58=$(rd 0x108)  # P7B-BIZ 八字"'),
], "final_state")

sub('_proj_pcie/p6b_accept.sh', [
 ("#   **P7B-BIZ 的 57 字**占 0x20..0x100 ⇒ 未实现 = **0x104**",
  "#   **P7B-BIZ 的 59 字**占 0x20..0x108 ⇒ 未实现 = **0x10C**"),
 ("#   **P7B-BIZ 57 字 = max {56,5'b0} = 1792 ⇒ 同一个 `[11:0]` 仍够, 本轮未动这一行**。",
  "#   **P7B-BIZ 59 字 = max {58,5'b0} = 1856 ⇒ 同一个 `[11:0]` 仍够, 本轮未动这一行**。"),
], "p6b_accept")

# ---- check_window.py: 判据 5 的槽号范围随 NW 走 (51..NW-1) ----
sub('_proj_10g/notes/p7b_biz_win/check_window.py', [
 ("    top6 = [code_of(x) for x in items[:6]]\n"
  "    want6 = [\"p7bdp_dout[%d*32 +: 32]\" % (17 - i) for i in range(6)]   # W56,W55,...,W51\n"
  "    ck(top6 == want6, \"5a 最上面 6 项 = W56..W51 的槽 (槽 17..12, MSB 先写)\",\n"
  "       \"(实际 %s)\" % top6)",
  "    nnew = NW - 51            # BIZ 新增字数 (51..NW-1)\n"
  "    topN = [code_of(x) for x in items[:nnew]]\n"
  "    wantN = [\"p7bdp_dout[%d*32 +: 32]\" % (NW - 40 - i) for i in range(nnew)]   # W(NW-1)..W51\n"
  "    ck(topN == wantN, \"5a 最上面 %d 项 = W%d..W51 的槽 (MSB 先写)\" % (nnew, NW - 1),\n"
  "       \"(实际 %s)\" % topN)"),
 ("    for k in range(51, 57):\n        slot = k - 39",
  "    for k in range(51, NW):\n        slot = k - 39"),
], "check_window")
print("ALL OK")
