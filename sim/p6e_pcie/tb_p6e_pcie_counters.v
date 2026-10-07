`timescale 1ns/1ps
//=============================================================================
// tb_p6e_pcie_counters.v — W16 (`srx_hls_bytes`) / W17 (`hr_cnt`) **增量逻辑**门
//=============================================================================
// 为什么需要这条门 (2026-09-29 审查 F2 的修复):
//   全链门 (tb_p6e_pcie_wrapper.v) 用 **force 灌常数** 验"每个字接到哪一路",
//   它**天然不覆盖增量逻辑** —— "0x60/0x64 接的确实是这两个计数器" 与
//   "这两个计数器在什么条件下 +1" 是两件事。三条既有门 (全链 / snap_cdc / axi_regs)
//   对后者都只有源码一条证据。本门补上后者: **驱动真的握手 / 真的看门狗复位**,
//   从 AXI 侧读回来, 断言**恰好 +N** (N = 本文件里驱动了多少拍, 单一定义)。
//
// 为什么例化**真 wrapper** (而不是"小 TB 例化 slow_rx_adp + 假 HLS"):
//   增量条件写在 wrapper 的 `ifdef PCIE_OBS` 分支里 (`if (hls_rx_tvalid && hls_rx_tready)`
//   与 `if (!hls_rst_n)`) ⇒ 小 TB 要么自己**重抄一遍**这个条件 (那只是在验自己抄的式子,
//   抄错了门也是绿的 —— 正是坑 8/25 的形态), 要么根本不经过 wrapper 分支。
//   只有真 wrapper 能同时证明三件事:
//     ① 增量条件 = 那两根线的 **AND** (只 tvalid 或只 tready 都不许计数 —— 判据 C1/C2)
//     ② 计数器确实落在快照的 **W16/W17 位置** (读的是 0x60/0x64, 全链走
//        计数 → snap_src → snap_cdc → axi_regs → AXI 读)
//     ③ 增量与驱动拍数**逐拍对得上** (恰好 +N, 不是"大概在涨")
//
// 正证据为什么"非零且可独立复算": 驱动拍数 N 是本文件的 localparam, 断言直接用 N
//   ⇒ 读数不是硬编码的常数, 而是"我数了 N 拍, 它就得多 N"这种**可复算**的关系;
//   同时用 W0/W5/W19 做反向对照 (不该涨的字一个都不许涨 —— 坑 25 的反面:
//   判据不能只证明"涨了", 还要证明"别的不该涨的没涨")。
//
// force 的目标 (与全链门同一条纪律, 见 tb_p6e_pcie_wrapper.v 头注释「生产者节点」):
//   · `hls_rx_tvalid` → **生产者节点** `u_dut.u_slow_rx.hls_rx_tvalid` (slow_rx_adp 的输出线)。
//     打 wrapper 级线只能证明"线的下游" (计数器读的是这根线), 打生产者才顺带证明
//     "这根线确实来自适配器" —— 即 F1 那一类"生产者↔线断开"的错在这里也逃不掉:
//     若线没接上, 生产者的 force 传不出来 ⇒ 判据 B1 直接 FAIL。
//   · `hls_rst_n` → **生产者节点** `u_dut.u_slow_rx.hls_rst_n_r` (看门狗寄存器) —— 同上。
//   · `hls_rx_tready` → **只能打 wrapper 级线**: 它的生产者是 HLS `udp_echo` IP 内部的
//     `rx_stream_TREADY` 逻辑 (IP 生成代码, 没有可长期维护的层次名)。⇒ 本门对这根线
//     额外加了一条**"必须有确定电平"的前置探针** (判据 0c): 未被驱动 / 被优化掉的线在
//     xsim 里是 z, force 会让它看起来正常 ⇒ 探针专抓这一类假 PASS。
//   · 每个 force 相位都配一条 **"生产者 force 是否真的传到 wrapper 线"** 的直接断言
//     (B0/D0) —— 这是 F1 那条纪律在"动态驱动"场景下的等价形式。
//
// ⚠️ 一条门知识 (本门第一版实测踩到, 不是 DUT 缺陷): **force 寄存器** 之后 `release`,
//   寄存器会**保持被 force 的值** (它空闲态没有过程赋值) ⇒ 必须先显式推回空闲值再 release。
//   踩到时表现为"释放后计数器还在涨"(D Δ=153 而非 150, E Δ=118 而非 0), 极易误判成 DUT 缺陷。
//   详见判据 D 的注释。**打 net 没有这个问题** (release 立刻回到连续赋值)。
// ⚠️ 副作用说明 (为什么可以忽略, 但要知道): 本门 force 的是**适配器内部**的握手线 ⇒
//   `slow_rx_adp` 内部的 `o_pop = hls_rx_tvalid && hls_rx_tready` 会被拉高, 而 FIFO 是空的
//   ⇒ `occ` 计数下溢 (0 - 300 拍)。无害的原因有二: ① `fifo_sync` 的读指针有 `rd && !empty`
//   门 (rr `rtl/fifo_sync.v`), 空读不动指针; ② 本门**不注入任何帧** (`committed` 恒 0),
//   `occ` 只参与开播节流的判断 ⇒ 无行为路径受影响。判据 B3/B4 顺带证明"没有帧被误处理"。
//   (若将来给本门加"注入真帧"的用例, 必须先复算这条下溢对 start_play 的影响。)
//
// ---- P6b 追加 (判据 G/H): 四个**新仪表**的增量逻辑 ----
//   全链门 (tb_p6e_pcie_wrapper.v) 把 29 个字 force 成常数 ⇒ 它只证明"接到哪一路"。
//   P6b 的 W26/W27/W28/W29/W30/W31 若只靠全链门, 就没有任何一条门回答
//   "它在什么条件下涨、涨多少" ⇒ 未连接输入被综合钳 0 与"从未触发"在读上不可区分
//   (工程铁律 6①)。本节驱动**真事件**并断言**可独立复算**的读数:
//     G (TX 侧): 从 DP 侧连续灌字 ⇒ u_txcdc 必然填满 (mac_tx_64 的消耗率是 1 字/8 拍 gmii,
//                而 DP 的写入率是 1 字/拍) ⇒ **W28 必须恰好 = DEPTH = 256** (峰值贴深度),
//                W29 (DP 在等线) 必须 > 0 且 <= 灌字拍数。
//     H (RX 侧): 从 FE 侧连续灌字 + 把 DP 消费者钉住 (vs_tready=0) ⇒ u_rxcdc 填满 ⇒
//                **W27 必须恰好 = 256**、**W26 (满拍数) > 0**; 松开后全部排空 ⇒
//                **W31 == 8 × W30** (每字 tkeep=8'hFF ⇒ 每字 8 字节; 每字 tlast=1 ⇒ 每帧 1 字)
//                —— 这正是 P6B_SPEC §7.3 那条恒等式 (Σpopc+4×帧 = 内容+4×帧) 的缩影。
//   ⚠️ 本节 force 的是 **u_rxcdc / u_txcdc 两侧的 wrapper 级握手线** (rxsrc_* / txsrc_* /
//      vs_tready)。打生产者 (u_mac_rx / u_tx_arb / u_classify 的输出端口) 与打这几根线
//      在网表上是**同一根 net** (端口连接不产生新 net), 所以"生产者↔线断开"这一类错
//      在本节仍会被抓到 (G0/H0 的"有确定电平 + 跟着 force 走"探针就是为它设的)。
// 依赖替身 sim/p6e_pcie/xdma_0_sim_stub.v  |  跑法: run_tb_p6e_pcie_counters.bat
//   (编译时须定义 PCIE_OBS + DEV_USP + APP_MODE + **P6B_SIM_CLKGEN**, 与真实构建一致;
//    后者只影响 clk_gen_p6b 走行为级模型 —— 综合路径仍是真 IBUFDS/MMCM)
//=============================================================================
module tb_p6e_pcie_counters;

    // ⚠️⚠️ **P6b: 本门的驱动/计数窗口必须用 `u_dut.dp_clk` (156.25MHz), 不是 gmii_clk**。
    //   `srx_hls_bytes` / `hr_cnt` 随数据面搬到了 dp_clk 域 ⇒ 用 gmii 拍数去驱一个
    //   dp 域的计数器, 读回值会**恰好 ×1.25** (实测: 期望 200 得 250 / 期望 150 得 188;
    //   250 = 200×1.25 与 188 ≈ 150×1.25 逐一对得上 —— 这本身就是"计数器确实换了域"的证据)。
    //   ⚠️ 这条是"门与板跑两个配置"的又一种形态: 门里的时间基准也必须跟着域走。

    // 驱动拍数 = 期望增量 (单一定义: 断言直接用这三个数, 不出现魔数)
    localparam integer N_RX = 200;   // B: tvalid&&tready 同时为高的拍数
    localparam integer N_NG = 100;   // C: 只 tvalid / 只 tready 的拍数 (期望增量 0)
    localparam integer N_HR = 150;   // D: hls_rst_n 低电平拍数
    // ---- P6b 判据 G/H ----
    localparam integer N_TXPSH = 400;   // G: 从 DP 侧灌进 u_txcdc 的拍数 (>DEPTH 即可填满)
    localparam integer N_RXPSH = 400;   // H: 从 FE 侧灌进 u_rxcdc 的拍数 (>DEPTH 即可填满)
    localparam integer CDC_DEPTH = 256; // 两个 FIFO 的 DEPTH (与 wrapper 的 .DEPTH 同值)

    reg        reset_n = 0;
    reg        phy1_rxc = 0;
    reg  [3:0] phy1_rxd = 0;
    reg        phy1_rxctl = 0;
    wire       phy1_txc;
    wire [3:0] phy1_txd;
    wire       phy1_txctl;
    wire       led_d0, led_d1, led_d2, led_d3;
    wire       uart_txd;
    reg        pcie_sys_clk_p = 0, pcie_sys_clk_n = 1;
    wire [3:0] pcie_txp, pcie_txn;
    reg  [3:0] pcie_rxp = 0, pcie_rxn = 0;
    // P6b: 数据面时钟源 (核心板 Y1 = 100.000000MHz 差分有源晶振)
    reg        sys_clk_p = 0, sys_clk_n = 1;

    always #4 phy1_rxc = ~phy1_rxc;                                    // 125MHz = 1G 的 RXC
    always #5 pcie_sys_clk_p = ~pcie_sys_clk_p;                        // 100MHz 差分参考钟
    always #5 pcie_sys_clk_n = ~pcie_sys_clk_n;
    always #5 sys_clk_p = ~sys_clk_p;                                  // Y1 = 100MHz
    // ⚠️ sys_clk_n 必须与 sys_clk_p **反相** (真 IBUFDS 是差分输入; 对抗审查 F3-3):
    //    同相驱动在 P6B_SIM_CLKGEN 的行为级旁路下无害, 但谁把旁路关掉就会得到"没有时钟"。
    always #5 sys_clk_n = ~sys_clk_p;

    // 端口表 = DEV_USP + PCIE_OBS 的组合 (与 build_p6e_ku5p.tcl 的 verilog_define 一致)
    wrapper_p4 u_dut (
        .reset_n        (reset_n),
        .phy1_rxc       (phy1_rxc),
        .phy1_rxd       (phy1_rxd),
        .phy1_rxctl     (phy1_rxctl),
        .phy1_txc       (phy1_txc),
        .phy1_txd       (phy1_txd),
        .phy1_txctl     (phy1_txctl),
        .led_d0         (led_d0),
        .led_d1         (led_d1),
        .led_d2         (led_d2),
        .led_d3         (led_d3),
        .uart_txd       (uart_txd),
        .pcie_sys_clk_p (pcie_sys_clk_p),
        .pcie_sys_clk_n (pcie_sys_clk_n),
        .pcie_txp       (pcie_txp),
        .pcie_txn       (pcie_txn),
        .pcie_rxp       (pcie_rxp),
        .pcie_rxn       (pcie_rxn),
        .sys_clk_p      (sys_clk_p),
        .sys_clk_n      (sys_clk_n)
    );

    integer    fails = 0;
    integer    k, ok_r;
    reg [31:0] v;
    // 每次快照读回的 5 个字 (随用途命名, 免得 a/b/c 混)
    reg [31:0] w16, w17, w5, w0, w19;
    reg [31:0] w16_p, w17_p, w5_p, w0_p, w19_p;    // _p = previous (上一相位的读数)
    reg [31:0] w16_base, w17_base;                 // 基线 (判据 F 的总账参照)
    // ---- P6b 判据 G/H 的读数 ----
    reg [31:0] w26v, w27v, w28v, w29v, w30v, w31v, w0v;

    task chk(input [255:0] name, input [31:0] got, input [31:0] exp);
        begin
            if (got === exp) $display("  [PASS] %0s = %0d", name, got);
            else begin $display("  [FAIL] %0s = %0d (期望 %0d)", name, got, exp); fails = fails + 1; end
        end
    endtask

    // 触发一次快照并等 done (SNAP_STATUS.bit1)
    task snap_take(output integer ok);
        begin
            u_dut.u_pcie_xdma.axil_write(32'h18, 32'h1);
            ok = 0;
            for (k = 0; k < 300; k = k + 1) begin
                u_dut.u_pcie_xdma.axil_read(32'h1c, v);
                if (v[1] === 1'b1) begin ok = 1; k = 1000; end
            end
        end
    endtask

    // 取一次快照, 把本门关心的 5 个字读进宫 (前一组先存进 _p)
    task snap_read;
        begin
            w16_p = w16; w17_p = w17; w5_p = w5; w0_p = w0; w19_p = w19;
            snap_take(ok_r);
            u_dut.u_pcie_xdma.axil_read(32'h60, w16);   // W16 srx_hls_bytes
            u_dut.u_pcie_xdma.axil_read(32'h64, w17);   // W17 hr_cnt
            u_dut.u_pcie_xdma.axil_read(32'h34, w5);    // W5  gmii_free   (gmii 域活性锚点)
            u_dut.u_pcie_xdma.axil_read(32'h20, w0);    // W0  rx_stat_frames (不该涨)
            u_dut.u_pcie_xdma.axil_read(32'h6c, w19);   // W19 srx_stat_drop  (不该涨)
        end
    endtask

    task show(input [255:0] tag);
        begin
            $display("  [INFO] %0s: W16=%0d (Δ%0d) W17=%0d (Δ%0d) W5=%0d W0=%0d W19=%0d",
                     tag, w16, w16 - w16_p, w17, w17 - w17_p, w5, w0, w19);
        end
    endtask

    initial begin
        $display("=== tb_p6e_pcie_counters: W16/W17 增量逻辑 (正证据 + 负对照) ===");
        repeat (20) @(posedge phy1_rxc);
        reset_n = 1;
        repeat (300) @(posedge u_dut.u_pcie_xdma.aclk);     // 等 axi_aresetn 释放 + link up

        // ================= 判据 0: 前置 —— 读数通路与"线有驱动源" =================
        $display("  --- 判据 0: 前置 (读数通路 + 被 force 的线必须有驱动源) ---");
        u_dut.u_pcie_xdma.axil_read(32'h00, v); chk("0a MAGIC (read path self-check)", v, 32'h50360001);
        // 原句 (36 字时代, 逐字保留):
        //   u_dut.u_pcie_xdma.axil_read(32'h04, v); chk("0b BUILD_ID (36-word P6b+F4 = 6)", v, 32'h00000006);
        // ⛔ 2026-10-07 订正 (P7B_STAGEB_FIX.md; 同族第 3 处 —— 回归轮只登记了 wrapper 门的
        //    BID=7 双硬编码, 本门与它同一编译集、同读 `wrapper_p4.v`, BID=6 是 36 字时代残留):
        //    窗口 36 → 51 → 61 → **63** ⇒ `board/wrapper_p4.v:3882` 的 `BUILD_ID_V = 32'h00000009`
        //    ⇒ 期望值 6 → **9**。判据语义不变 (= BUILD_ID 必须等于本构建的地图版本)。
        u_dut.u_pcie_xdma.axil_read(32'h04, v); chk("0b BUILD_ID (63-word P7B-WU = 9; 原 36-word=6)", v, 32'h00000009);
        // 0c: `hls_rx_tready` 是唯一只能打 wrapper 线的握手信号 ⇒ 先证明它有确定电平。
        //     悬空/被优化掉的线在 xsim 里是 z, 而 force 会让它看起来"正常" ⇒ 专抓这类假 PASS。
        if ((u_dut.hls_rx_tready === 1'b0) || (u_dut.hls_rx_tready === 1'b1))
            $display("  [PASS] 0c hls_rx_tready 有确定电平 (= %b) ⇒ 这根线确有驱动源 (非 X/Z)",
                     u_dut.hls_rx_tready);
        else begin
            $display("  [FAIL] 0c hls_rx_tready = %b (X/Z) ⇒ 线无驱动源 (连接断/被优化), force 会掩盖它",
                     u_dut.hls_rx_tready);
            fails = fails + 1;
        end

        // ================= 判据 A: 基线 =================
        $display("  --- 判据 A: 基线 (无任何注入) ---");
        w16 = 0; w17 = 0; w5 = 0; w0 = 0; w19 = 0;
        snap_read;
        show("A baseline");
        w16_base = w16; w17_base = w17;               // 判据 F 的总账参照点

        // ================= 判据 B: 正证据 —— 恰好 N_RX 拍真握手 ⇒ W16 恰好 +N_RX ========
        // force 落在 **negedge** 上, 数 **posedge** 拍数 ⇒ 计数与 force 窗口严格对齐。
        $display("  --- 判据 B: 正证据 (tvalid&&tready 同时为高 %0d 拍) ---", N_RX);
        @(negedge u_dut.dp_clk);
        force u_dut.u_slow_rx.hls_rx_tvalid = 1'b1;   // 生产者节点 (slow_rx_adp 输出)
        force u_dut.hls_rx_tready           = 1'b1;   // 生产者是 HLS IP ⇒ 只能打 wrapper 线
        repeat (5) @(posedge u_dut.dp_clk);
        // B0: force 生效的**直接证据** = wrapper 那根线必须跟着生产者的 force 走。
        //     若线没接在这个生产者上 (F1 那一类错), 这里当场抓到。
        if (u_dut.hls_rx_tvalid === 1'b1)
            $display("  [PASS] B0 producer force 传到 wrapper 线 (hls_rx_tvalid = 1)");
        else begin
            $display("  [FAIL] B0 producer force 没传到 wrapper 线 (hls_rx_tvalid = %b): 线没接在生产者上",
                     u_dut.hls_rx_tvalid);
            fails = fails + 1;
        end
        repeat (N_RX - 5) @(posedge u_dut.dp_clk);
        @(negedge u_dut.dp_clk);
        release u_dut.u_slow_rx.hls_rx_tvalid;        // net: release 立刻回到 !o_empty (=0) ✓
        release u_dut.hls_rx_tready;
        snap_read;
        show("B after handshake");
        chk("B1 W16 delta == N_RX (1 count per handshake beat)", w16 - w16_p, N_RX);
        chk("B2 W17 delta == 0 (watchdog untouched)", w17 - w17_p, 0);
        chk("B3 W0 delta == 0 (no frame injected)", w0 - w0_p, 0);
        chk("B4 W19 delta == 0 (no slow_rx drop)", w19 - w19_p, 0);
        if (w5 > w5_p) $display("  [PASS] B5 gmii 域在跑 (W5 %0d -> %0d): 上面的 +%0d 不是停摆时钟上的假数",
                                w5_p, w5, N_RX);
        else begin $display("  [FAIL] B5 W5 没涨 (%0d -> %0d): gmii 域停摆, 本门结论不成立", w5_p, w5);
                   fails = fails + 1; end

        // ================= 判据 C: 负对照 —— 增量条件是 AND 不是 OR =================
        // C1 只 tvalid: 把条件写成 `if (tvalid)` 的实现在这里当场 +N_NG ⇒ FAIL。
        $display("  --- 判据 C1: 只 tvalid (tready=0) %0d 拍 ⇒ 不许计数 ---", N_NG);
        @(negedge u_dut.dp_clk);
        force u_dut.u_slow_rx.hls_rx_tvalid = 1'b1;
        force u_dut.hls_rx_tready           = 1'b0;
        repeat (N_NG) @(posedge u_dut.dp_clk);
        @(negedge u_dut.dp_clk);
        release u_dut.u_slow_rx.hls_rx_tvalid;
        release u_dut.hls_rx_tready;
        snap_read;
        show("C1 after tvalid-only");
        chk("C1 W16 delta == 0 (no count when tready=0)", w16 - w16_p, 0);

        // C2 只 tready: 把条件写成 `if (tready)` 的实现在这里当场 +N_NG ⇒ FAIL。
        $display("  --- 判据 C2: 只 tready (tvalid=0) %0d 拍 ⇒ 不许计数 ---", N_NG);
        @(negedge u_dut.dp_clk);
        force u_dut.u_slow_rx.hls_rx_tvalid = 1'b0;
        force u_dut.hls_rx_tready           = 1'b1;
        repeat (N_NG) @(posedge u_dut.dp_clk);
        @(negedge u_dut.dp_clk);
        release u_dut.u_slow_rx.hls_rx_tvalid;
        release u_dut.hls_rx_tready;
        snap_read;
        show("C2 after tready-only");
        chk("C2 W16 delta == 0 (no count when tvalid=0)", w16 - w16_p, 0);

        // ================= 判据 D: 正证据 —— hls_rst_n 低恰好 N_HR 拍 ⇒ W17 恰好 +N_HR =======
        // force 打在**看门狗寄存器**上 (生产者): 若 wrapper 的 `hls_rst_n` 不是从它来的,
        // force 传不出来 ⇒ D0/D1 当场 FAIL (与 F1 同一个道理)。
        // ⚠️⚠️ **寄存器 force 的 release 语义** (本门第一版实测踩到, 记为门知识):
        //   被 force 的**寄存器**在 `release` 之后**保持 force 期间的值**, 直到下一次过程赋值 ——
        //   而 `hls_rst_n_r` 在空闲状态下**根本没有过程赋值** (它在 slow_rx_adp 里只在
        //   看门狗触发与收尾那两处被写) ⇒ 直接 release 会让它**永久停在 0**:
        //   第一版实测 D1 得到 **153** (期望 150: 多的 3 拍 = release 到快照捕获之间的窗口),
        //   E1 得到 **118** (期望 0: "线还低着"一直数下去) —— 看着像 DUT 缺陷, 其实是 TB 的
        //   release 语义错。**修法**: release 之前先把寄存器**显式推回空闲值 (1)**, 再 release。
        //   (打 **net** 没有这个问题: net 一 release 就回到连续赋值的值 —— 上面 B 相位就是 net。)
        //   ⇒ 以后凡是要 force **寄存器**, 都要问一句"它在空闲态有过程赋值吗?", 没有就必须推回。
        $display("  --- 判据 D: 正证据 (hls_rst_n 低 %0d 拍) ---", N_HR);
        @(negedge u_dut.dp_clk);
        force u_dut.u_slow_rx.hls_rst_n_r = 1'b0;      // 生产者节点 (slow_rx_adp 看门狗寄存器)
        repeat (5) @(posedge u_dut.dp_clk);
        // D0: 同 B0 —— 生产者被拉低后 wrapper 那根线必须跟着低 (连接证据)
        if (u_dut.hls_rst_n === 1'b0)
            $display("  [PASS] D0 producer force 传到 wrapper 线 (hls_rst_n = 0)");
        else begin
            $display("  [FAIL] D0 producer force 没传到 wrapper 线 (hls_rst_n = %b): 线没接在生产者上",
                     u_dut.hls_rst_n);
            fails = fails + 1;
        end
        repeat (N_HR - 5) @(posedge u_dut.dp_clk);
        @(negedge u_dut.dp_clk);
        force  u_dut.u_slow_rx.hls_rst_n_r = 1'b1;     // ← 显式推回空闲值 (见上面的 ⚠️⚠️)
        @(negedge u_dut.dp_clk);
        release u_dut.u_slow_rx.hls_rst_n_r;
        snap_read;
        show("D after watchdog-low");
        chk("D1 W17 delta == N_HR (1 count per low cycle)", w17 - w17_p, N_HR);
        chk("D2 W16 delta == 0 (rx fifo empty, no handshake)", w16 - w16_p, 0);

        // ================= 判据 E: release 后 W17 必须停 =================
        // (证明它数的是"低电平拍数", 不是"某个自由计数")
        $display("  --- 判据 E: hls_rst_n 回到高 ⇒ W17 停涨 ---");
        repeat (100) @(posedge u_dut.dp_clk);
        snap_read;
        show("E after release");
        chk("E1 W17 delta == 0 (no count while high)", w17 - w17_p, 0);

        // ================= 判据 F: 全过程总账 (跨相位可独立复算) =================
        // 分相位断言各自成立, 不等于"总账"成立 (例如某相位多计一拍、另一相位少计一拍,
        // 逐相位 delta 会各自 FAIL —— 但若两个误差恰好互相抵消在**别的相位**里就没人管)。
        // 这里用基线快照做一次端到端对账: W16 总增量必须**恰等于** B 相位的驱动拍数
        // (C1/C2 零贡献), W17 总增量必须**恰等于** D 相位的低电平拍数 (E 零贡献)。
        $display("  --- 判据 F: 全过程总账 (相对基线快照) ---");
        $display("  [INFO] F 总账: W16 %0d -> %0d (Δ%0d, 期望 %0d); W17 %0d -> %0d (Δ%0d, 期望 %0d)",
                 w16_base, w16, w16 - w16_base, N_RX, w17_base, w17, w17 - w17_base, N_HR);
        chk("F1 W16 total delta == N_RX", w16 - w16_base, N_RX);
        chk("F2 W17 total delta == N_HR", w17 - w17_base, N_HR);

        // ================= 判据 G: TX 侧新仪表 (W28 峰值 / W29 等线拍数) =================
        // 读回的 6 个新字 (只用一次, 单独取)
        $display("  --- 判据 G: 从 DP 侧灌 %0d 拍 ⇒ u_txcdc 必满 ⇒ W28 恰好 = DEPTH ---", N_TXPSH);
        @(negedge u_dut.dp_clk);
        force u_dut.txsrc_tvalid = 1'b1;              // u_tx_arb 的输出 net (DP 侧生产者)
        force u_dut.txsrc_tdata  = 64'h0123456789ABCDEF;
        force u_dut.txsrc_tkeep  = 8'hFF;
        force u_dut.txsrc_tlast  = 1'b0;
        repeat (5) @(posedge u_dut.dp_clk);
        if (u_dut.txsrc_tvalid === 1'b1)
            $display("  [PASS] G0 txsrc_tvalid 有确定电平且跟着 force 走 (= 1) ⇒ 线有驱动源");
        else begin
            $display("  [FAIL] G0 txsrc_tvalid = %b ⇒ 线无驱动源 (连接断/被优化)", u_dut.txsrc_tvalid);
            fails = fails + 1;
        end
        repeat (N_TXPSH - 5) @(posedge u_dut.dp_clk);
        @(negedge u_dut.dp_clk);
        release u_dut.txsrc_tvalid;
        release u_dut.txsrc_tdata;
        release u_dut.txsrc_tkeep;
        release u_dut.txsrc_tlast;
        repeat (50) @(posedge u_dut.dp_clk);          // 让指针同步/写域占用稳定下来
        snap_take(ok_r);
        u_dut.u_pcie_xdma.axil_read(32'h90, v); w28v = v;   // W28 {16'd0,txcdc_occ_max}
        u_dut.u_pcie_xdma.axil_read(32'h94, v); w29v = v;   // W29 txwire_stall_cycles
        $display("  [INFO] G 读数: W28=%0d W29=%0d", w28v, w29v);
        chk("G1 W28 == DEPTH (灌满后峰值恰好贴深度)", w28v & 32'hFFFF, CDC_DEPTH);
        if (w29v > 0 && w29v <= N_TXPSH)
            $display("  [PASS] G2 W29 = %0d (>0 且 <= 灌字拍数 %0d) ⇒ DP 确实被线速压住", w29v, N_TXPSH);
        else begin
            $display("  [FAIL] G2 W29 = %0d 不在 (0, %0d] 内", w29v, N_TXPSH);
            fails = fails + 1;
        end

        // ================= 判据 H: RX 侧新仪表 (W26 满拍数 / W27 峰值 / W30 帧数 / W31 字节数) ==
        // 消费者钉住: vs_tready=0 ⇒ vlan_strip 收 1 个字之后 od_free=0 ⇒ u_rxcdc 只进不出。
        $display("  --- 判据 H: 从 FE 侧灌 %0d 拍 + 钉住 DP 消费者 ⇒ u_rxcdc 必满 ---", N_RXPSH);
        force u_dut.vs_tready = 1'b0;                 // u_classify 的输出 net (DP 侧消费者)
        @(negedge u_dut.dp_clk);
        force u_dut.rxsrc_tvalid = 1'b1;              // u_mac_rx 的输出 net (FE 侧生产者)
        force u_dut.rxsrc_tdata  = 64'hFEDCBA9876543210;
        force u_dut.rxsrc_tkeep  = 8'hFF;             // 每字 8 字节 (W31 的口径: Σpopc)
        force u_dut.rxsrc_tlast  = 1'b1;              // 每字一帧 (W30 的口径: TLAST 数)
        repeat (5) @(posedge u_dut.dp_clk);
        if (u_dut.rxsrc_tvalid === 1'b1 && u_dut.vs_tready === 1'b0)
            $display("  [PASS] H0 rxsrc_tvalid/vs_tready 有确定电平且跟着 force 走");
        else begin
            $display("  [FAIL] H0 rxsrc_tvalid=%b vs_tready=%b ⇒ 有无驱动源的线",
                     u_dut.rxsrc_tvalid, u_dut.vs_tready);
            fails = fails + 1;
        end
        repeat (N_RXPSH - 5) @(posedge u_dut.dp_clk);
        @(negedge u_dut.dp_clk);
        release u_dut.rxsrc_tvalid;
        release u_dut.rxsrc_tdata;
        release u_dut.rxsrc_tkeep;
        release u_dut.rxsrc_tlast;
        snap_take(ok_r);
        u_dut.u_pcie_xdma.axil_read(32'h88, v); w26v = v;   // W26 rxcdc_full_cycles
        u_dut.u_pcie_xdma.axil_read(32'h8c, v); w27v = v;   // W27 {16'd0,rxcdc_occ_max}
        $display("  [INFO] H 读数(灌满后): W26=%0d W27=%0d", w26v, w27v);
        chk("H1 W27 == DEPTH (灌满后峰值恰好贴深度)", w27v & 32'hFFFF, CDC_DEPTH);
        if (w26v > 0)
            $display("  [PASS] H2 W26 = %0d (>0: FIFO 满过, 满拍数被记下来)", w26v);
        else begin
            $display("  [FAIL] H2 W26 = 0 ⇒ 满载事件没被计数 (未连接输入会被综合钳 0)");
            fails = fails + 1;
        end
        // 松开消费者 ⇒ 全部排空 ⇒ 读侧的两个锚点必须自洽: W31 == 8 * W30
        release u_dut.vs_tready;
        repeat (4000) @(posedge u_dut.dp_clk);
        snap_take(ok_r);
        u_dut.u_pcie_xdma.axil_read(32'h98, v); w30v = v;   // W30 rxcdc_out_frames
        u_dut.u_pcie_xdma.axil_read(32'h9c, v); w31v = v;   // W31 rxcdc_out_bytes
        u_dut.u_pcie_xdma.axil_read(32'h20, v); w0v  = v;   // W0 (不该涨: 没经过 mac_rx)
        $display("  [INFO] H 读数(排空后): W30=%0d W31=%0d W0=%0d", w30v, w31v, w0v);
        if (w30v >= CDC_DEPTH)
            $display("  [PASS] H3 W30 = %0d >= DEPTH ⇒ 读侧 TLAST 计数与灌满一致", w30v);
        else begin
            $display("  [FAIL] H3 W30 = %0d < DEPTH=%0d (深度都灌满了, 读侧帧数不该更少)",
                     w30v, CDC_DEPTH);
            fails = fails + 1;
        end
        chk("H4 W31 == 8 * W30 (每字 tkeep=8'hFF ⇒ 逐字节等式, §7.3 的缩影)", w31v, w30v * 8);
        chk("H5 W0 == 0 (本相位不经过 mac_rx ⇒ 收帧锚点不该动)", w0v, 0);

        if (fails == 0) $display("PASS_ALL  tb_p6e_pcie_counters: W16/W17 + W26/W27/W28/W29/W30/W31 增量逻辑全过");
        else            $display("FAIL      tb_p6e_pcie_counters: %0d 项失败", fails);
        $display("=== done ===");
        $finish;
    end

    initial begin #4000000; $display("TIMEOUT"); $finish; end
endmodule
