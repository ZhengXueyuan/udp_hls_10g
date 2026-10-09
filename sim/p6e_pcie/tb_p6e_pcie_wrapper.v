`timescale 1ns/1ps
//=============================================================================
// tb_p6e_pcie_wrapper.v — P6e 合体的 **真 wrapper 全链门** (工程坑 8)
//=============================================================================
// 为什么必须另开一门: snap_cdc / axi_regs 各自的单元门都自己搭链, **不走 wrapper 的
//   `ifdef PCIE_OBS` 接线分支** —— "每个字各接的是哪一路计数" "snap_req/valid 有没有接反"
//   "复位有没有接对" 这类错在单元门里完全隐身 (P5a W1 / P5e-T2 两次血的教训:
//   子模块 TB 全绿, 板上却是静默故障)。
//
// 本门怎么抓: 把数据面那 29 路计数源用 `force` 打成**互不相同的常数**, 然后**从 AXI 侧**
//   把 36 个字读回来, 逐字比对常数 ⇒ 任何"接错一路"都会当场现形。
//   ⚠️ P6b 起快照是**两个域的两束** (FE 10 字 + DP 22 字) 经 rtl/snap_seq.v 链式触发拼成
//      32 字 —— 本门因此额外承担"两束的索引表抄错"的检测 (那是新的第 ⑦ 处扩窗风险点,
//      lint 完全看不见), 逐字读回是唯一手段。
//   (gmii_free 那一路故意**不 force**: 它是自由计数器, 用"两次快照之间必须递增"来验它 ——
//    既证明它接对了, 又证明 gmii 域在仿真里真的在跑。)
//   ⚠️ 逐字比对的**地址必须覆盖到最后一个字** (0x9C): 只验前一半的话, "读侧选字位宽截断"
//      (高地址回绕读低地址的字) 这类错会从门里逃逸 —— 24 字版扩窗前就是靠这一点抓到的。
//
// ⭐⭐ force 的目标必须是**生产者节点** (2026-09-29 审查 F1 修 —— 本门最大的覆盖缺口):
//   `force` 会压掉该 net 的**一切驱动** ⇒ 只打 wrapper 级线 (如 `force u_dut.mac_tx_frames`)
//   时, "生产者 ↔ 线"这根连接**完全不被检验**: 实测把 wrapper 的
//   `.stat_frames(mac_tx_frames)` 改回 `.stat_frames()` (W20 恒 0), 门**照样 PASS_ALL**;
//   改成打 `u_dut.u_mac_tx.stat_frames` (生产者的寄存器) 后, **同一个变异体当场 FAIL**。
//   ⇒ 判据 6 现在除下面 3 路例外外**全部打生产者节点**。**新加字必须遵守这条**。
//   三路例外 (为什么只能打 wrapper 级, 逐条给理由 —— 不是偷懒):
//     · W2 `wl_last` —— 生产者**在 wrapper 自己身上** (帧长锁存寄存器, 见 wrapper 的
//       `always @(posedge gmii_clk)` 那段), 没有子模块节点可打; 打它本身即"打到最深处",
//       它被掩盖的是锁存逻辑 (而锁存逻辑由 `wl_last_lat`/`rx_wire_last` 那条路另验)。
//     · W16/W17 `srx_hls_bytes` / `hr_cnt` —— 同上是 wrapper 自己的寄存器, 生产者就是本模块
//       的 always 块。它们的**增量逻辑**由另一条专门的门覆盖:
//       `sim/p6e_pcie/run_tb_p6e_pcie_counters.bat` (驱动**真握手/真 hls_rst_n**, 断言恰好 +N,
//       含"只 tvalid / 只 tready 都不许计数"的负对照)。本门只负责
//       "这两路确实落在快照的 W16/W17 位置上" —— 两条门各验一半, 别张冠李戴。
//     · W5 `gmii_free` 完全不 force (见上一条)。
//     · W24 `dp_free` / W25 `mmcm_locked` 也**完全不 force** (P6b 新增): 它们是"数据面
//       真的跑在 156.25MHz 独立时钟上"的**功能正证据** —— 判据 5b 用两次快照的
//       ΔW24/ΔW5 比值验 (两个自由计数、两个域, 比值必须 ≈ 156.25/125 = 1.25)。
//
// 门里还有: AXI 读通路 (MAGIC/BUILD_ID = 合体版 24 字 = 4)、触发/done 协议、字冻结、
//   未实现地址 SLVERR、HW_STATUS 的 user_lnk_up。
//   ⛔ 2026-10-07 订正 (P7B_STAGEB_FIX.md): 本句 "24 字 = 4" 是 24 字时代的叙述 (扩窗时未跟着改);
//      现役几何 = **63 字 / BUILD_ID = 9 / 未实现地址 0x11C** (源码 = `board/wrapper_p4.v:3125`
//      `SNAP_NW_P6E = 63` + `:3882` `BUILD_ID_V = 32'h00000009`) —— 见下判据 2 与判据 9 的就地订正。
//      ⛔ 2026-10-10 订正 (构建 C 门同步轮): 上面这句**已过时** —— 现役 = **65 字 / BUILD_ID = 17 /
//      未实现地址 0x124** (源码 `SNAP_NW_P6E = 65` + `BUILD_ID_V = 32'h00000017`)。原句保留;
//      本文件里**两条**跟着地图走的判据 (**判据 2** = BUILD_ID 期望值、**判据 9** = 未实现地址)
//      已同批订正 —— 它们必须一起改 (参数化即可, 见两处的就地说明)。
// ============================================================================
// 依赖替身 sim/p6e_pcie/xdma_0_sim_stub.v (IP 的功能模型只在 Vivado 工程里, 见其头注释)
// 跑法: run_tb_p6e_pcie.bat (编译时须定义 PCIE_OBS + DEV_USP + APP_MODE, 与真实构建一致)
//=============================================================================
module tb_p6e_pcie_wrapper;

    reg        reset_n = 0;
    reg        phy1_rxc = 0;
    reg  [3:0] phy1_rxd = 0;
    reg        phy1_rxctl = 0;
    wire       phy1_txc;
    wire [3:0] phy1_txd;
    wire       phy1_txctl;
    wire       led_d0, led_d1, led_d2, led_d3;
    wire       uart_txd;
    // PCIe 侧
    reg        pcie_sys_clk_p = 0, pcie_sys_clk_n = 1;
    wire [3:0] pcie_txp, pcie_txn;
    reg  [3:0] pcie_rxp = 0, pcie_rxn = 0;
    // P6b: 数据面时钟源 (核心板 Y1 = 100.000000MHz 差分有源晶振, T25/U25)
    reg        sys_clk_p = 0, sys_clk_n = 1;

    always #4 phy1_rxc = ~phy1_rxc;                                    // 125MHz = 1G 的 RXC
    always #5 pcie_sys_clk_p = ~pcie_sys_clk_p;                        // 100MHz 差分参考钟
    always #5 pcie_sys_clk_n = ~pcie_sys_clk_n;
    always #5 sys_clk_p = ~sys_clk_p;                                  // Y1 = 100MHz (周期 10ns)
    // ⚠️ sys_clk_n 必须与 sys_clk_p **反相** (真 IBUFDS 是差分输入; 对抗审查 F3-3):
    //    同相驱动在 P6B_SIM_CLKGEN 的行为级旁路下无害, 但谁把旁路关掉就会得到"没有时钟"。
    always #5 sys_clk_n = ~sys_clk_p;

    // ⚠️ 端口表 = DEV_USP + PCIE_OBS 的组合 (与 build_p6e_ku5p.tcl 的 verilog_define 一致):
    //    DEV_USP ⇒ 没有 fpga_gclk; PCIE_OBS ⇒ 有 4 个 PCIe 口 + sys_clk_p/n
//    (P6b: sys_clk_p/n 包在 `ifdef PCIE_OBS 内 —— P6a 那条分支仍是单域, 见 P6B_SPEC §B-B2)
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
    integer    k, ok_r, gen0;
    reg [31:0] v, v5a, v5b, a0, b0;
    reg [31:0] v24a, v24b;      // P6b: W24 (数据面自由计数)
    integer    d5, d24;         // P6b: 判据 5b 的增量

    task chk(input [255:0] name, input [31:0] got, input [31:0] exp);
        begin
            if (got === exp) $display("  [PASS] %0s = %08x", name, got);
            else begin $display("  [FAIL] %0s = %08x (期望 %08x)", name, got, exp); fails = fails + 1; end
        end
    endtask

    // 触发一次快照并等 done (SNAP_STATUS.bit1); 返回 1 = 成功
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

    initial begin
        $display("=== tb_p6e_pcie_wrapper: P6e 合体真 wrapper 全链门 ===");
        repeat (20) @(posedge phy1_rxc);
        reset_n = 1;
        repeat (300) @(posedge u_dut.u_pcie_xdma.aclk);      // 等 axi_aresetn 释放 + link up

        $display("  --- 判据 1-3: AXI 读通路 (替身主机 → wrapper 内 axi_regs) ---");
        u_dut.u_pcie_xdma.axil_read(32'h00, v); chk("1  MAGIC", v, 32'h50360001);
        // 原句 (51 字时代, 逐字保留):
        //   u_dut.u_pcie_xdma.axil_read(32'h04, v); chk("2  BUILD_ID (P7b 五束 51 字=7)", v, 32'h00000007);
        // ⛔ 2026-10-07 订正 (P7B_STAGEB_FIX.md; 出处 P7B_STAGEB_RX8_REGRESSION.md §6-③ "BID=7 双硬编码"):
        //    窗口 51 → 61 (BIZ) → **63** (Stage A / P7B-WU 二轮) ⇒ 源码 `board/wrapper_p4.v:3882`
        //    的 `BUILD_ID_V = 32'h00000009` (该处注释逐字: "验收脚本/取数器的 NW 与 EXPECT_BID
        //    必须跟着改") ⇒ 期望值 7 → **9**。判据语义不变 (= BUILD_ID 必须等于本构建的地图版本)。
        // 原句 (63 字 / P7B-WU 二轮时代, 逐字保留):
        //   u_dut.u_pcie_xdma.axil_read(32'h04, v); chk("2  BUILD_ID (P7b 63 字=9; 原 51 字=7)", v, 32'h00000009);
        // ⛔ 2026-10-10 订正 (构建 C 门同步轮): 窗口 63 → **65 字** ⇒ `board/wrapper_p4.v` 的
        //    `BUILD_ID_V = 32'h00000017` ⇒ 期望值 9 → **17**。判据语义不变
        //    (= BUILD_ID 必须等于**本构建**的地图版本); 本条与上面判据 9 的地址是同一次订正。
        u_dut.u_pcie_xdma.axil_read(32'h04, v); chk("2  BUILD_ID (构建 E 67 字=0x19; 原 66 字=0x18 / 65 字=17 / 63 字=9)", v, 32'h00000019);
        u_dut.u_pcie_xdma.axil_read(32'h14, v); chk("3  MARKER", v, 32'hDEADBEEF);
        // HW_STATUS 字段: [7:5]=msi_vec_w [4]=msi_enable [3]=user_lnk_up [2:0]=0
        u_dut.u_pcie_xdma.axil_read(32'h10, v);
        if (v[3] === 1'b1) $display("  [PASS] 4  HW_STATUS.bit3 = user_lnk_up = 1 (替身已报链路起)");
        else begin $display("  [FAIL] 4  HW_STATUS.bit3 = %b (期望 1), HW_STATUS=%08x", v[3], v);
                   fails = fails + 1; end

        // ---- 判据 5: gmii 域活着 (自由计数在跑) ----
        // ⚠️ ok_r 用独立变量: snap_take 的输出端口会覆盖调用处传进来的变量,
        //    拿同一个变量当"代际基线"会被悄悄改写 (本门第一版就踩了这个)。
        $display("  --- 判据 5: gmii_clk 域活性 (W5 两次快照之间必须递增) ---");
        snap_take(ok_r); u_dut.u_pcie_xdma.axil_read(32'h34, v5a);
        repeat (2000) @(posedge phy1_rxc);
        snap_take(ok_r); u_dut.u_pcie_xdma.axil_read(32'h34, v5b);
        $display("  [INFO] W5(gmii_free): %08x -> %08x", v5a, v5b);
        if (v5b > v5a) $display("  [PASS] 5  gmii 域自由计数在跑 (快照 CDC 真的在搬数)");
        else begin $display("  [FAIL] 5  W5 没递增 (gmii 域死了或 W5 接错)"); fails = fails + 1; end

        // ---- 判据 5b (P6b 新增): **两个域真在两个不同频率上** ----
        // W24 = dp_free (156.25MHz 域) / W5 = gmii_free (125MHz 域), 都不 force。
        // 同一次快照的比值 —— 两个自由计数、两个域 ⇒ 比值必须 ≈ 156.25/125 = 1.25。
        // ⚠️ 这条是本门唯一**不靠 force** 就能证明"数据面确实搬到了新域"的判据;
        //    只改 Clock Summary / 只加一条空约束是骗不过它的 (它是功能读数)。
        $display("  --- 判据 5b: W24(dp 域) / W5(fe 域) 的增量比必须 ≈ 1.25 ---");
        snap_take(ok_r); u_dut.u_pcie_xdma.axil_read(32'h34, v5a);
                         u_dut.u_pcie_xdma.axil_read(32'h80, v24a);
        repeat (4000) @(posedge phy1_rxc);
        snap_take(ok_r); u_dut.u_pcie_xdma.axil_read(32'h34, v5b);
                         u_dut.u_pcie_xdma.axil_read(32'h80, v24b);
        d5  = v5b  - v5a;
        d24 = v24b - v24a;
        $display("  [INFO] W5(fe)=%0d->%0d (Δ%0d)  W24(dp)=%0d->%0d (Δ%0d)", v5a, v5b, d5, v24a, v24b, d24);
        if (d5 == 0) begin
            $display("  [FAIL] 5b ΔW5 = 0 (前端域停摆 ⇒ 比值无意义)"); fails = fails + 1;
        end else if ((d24 > (d5*124)/100) && (d24 < (d5*126)/100))
            $display("  [PASS] 5b ΔW24/ΔW5 = %0d/%0d = %.4f ∈ [1.24, 1.26] ⇒ 数据面跑在 156.25MHz (1.25×125MHz)",
                     d24, d5, d24 * 1.0 / d5);
        else begin
            $display("  [FAIL] 5b ΔW24/ΔW5 = %.4f 不在 [1.24, 1.26]: **数据面没跑在 156.25MHz**",
                     d24 * 1.0 / d5);
            fails = fails + 1;
        end
        // W25 = {31'd0, mmcm_locked}: 不 force ⇒ 直接读, 必须是 1
        u_dut.u_pcie_xdma.axil_read(32'h84, v); chk("5c W25 = mmcm_locked == 1 (DP 时钟源锁定)", v, 32'd1);

        // ---- 判据 6: 24 个字的**逐路映射** (核心: 把源打成互不相同的常数再读回来) ----
        // ⭐ force 目标 = **生产者节点** (子模块例化点的端口名), 不是 wrapper 级线 ——
        //    原理与实测证据见文件头注释「force 的目标必须是生产者节点」。加新字照抄此模式。
        $display("  --- 判据 6: 快照 32 字逐路映射 (源 force 成常数; 29 路 force + 3 路活体) ---");
        force u_dut.u_mac_rx.stat_frames      = 32'h11111111;   // W0  MAC 收帧
        force u_dut.u_mac_rx.stat_bytes       = 32'h22222222;   // W1  MAC 收字节
        force u_dut.wl_last                   = 16'hABCD;       // W2  (wrapper 自己的锁存寄存器, 见头注释)
        force u_dut.u_mac_rx.stat_crc_err     = 32'h33333333;   // W3  FCS 错
        force u_dut.u_mac_rx.stat_drop        = 32'h44444444;   // W4  MAC 丢弃
        force u_dut.u_slow_rx.stat_commit     = 32'h66666666;   // W6  提交给 HLS 的慢帧
        force u_dut.u_slow_tx.stat_frames     = 32'h77777777;   // W7  HLS 慢路径发帧 (ping 回包)
        force u_dut.u_app_udp.stat_tx_frames  = 32'h88888888;   // W8  图案 app 发帧
        force u_dut.u_app_udp.stat_tx_bytes   = 32'h99999999;   // W9  图案 app 发字节
        force u_dut.u_app_udp.stat_rx_frames  = 32'hAAAAAAAA;   // W10 图案 app 收帧
        force u_dut.u_app_udp.stat_rx_bytes   = 32'hBBBBBBBB;   // W11 图案 app 收字节
        force u_dut.u_app_udp.stat_rx_null    = 32'hCCCCCCCC;   // W12 空帧
        force u_dut.u_app_udp.stat_mismatch   = 32'hDDDDDDDD;   // W13 图案失配
        force u_dut.u_tcp_tx.stat_frames      = 32'hEEEEEEEE;   // W14 **TCP fast path**(tcp_tx_frame) 发帧
        force u_dut.u_tcp_tx.stat_bytes       = 32'hFFFFFFFF;   // W15 **TCP fast path** 发字节 ——
        //   ⚠️ 注释更正 (2026-09-29): 这两路原写成"MAC 发帧/字节"是**错的**。它们接的是
        //   `tcp_tx_frame` 的计数 (TCP fast path); MAC 级计数是 W20 = `mac_tx_64.stat_frames`
        //   (原来悬空, 本轮接出)。原来那行错标签正是"MAC 发=0 却明明在线速跑"的来源。
        // ---- W16-W23: 本轮新增 (慢路径健康位 + MAC 级 TX 锚点) ----
        force u_dut.srx_hls_bytes             = 32'h01020304;   // W16 HLS 真读走的字节 (wrapper 自计数, 见头注释)
        force u_dut.hr_cnt                    = 32'h05060708;   // W17 hls_rst_n 低电平拍数 (同上)
        force u_dut.u_slow_tx.stat_purge      = 32'h090A0B0C;   // W18 slow_tx_adp 回卷
        force u_dut.u_slow_rx.stat_drop       = 32'h0D0E0F10;   // W19 slow_rx_adp 丢帧
        force u_dut.u_mac_tx.stat_frames      = 32'h11121314;   // W20 **MAC 级**发帧 (原悬空; ⭐ F1 的关键一路)
        force u_dut.u_mac_tx.stat_abort       = 32'h15161718;   // W21 MAC 帧内中止
        force u_dut.u_tcp_rx.stat_pass        = 32'h191A1B1C;   // W22 TCP fast path 接受帧
        force u_dut.u_tcp_rx.stat_drop_nonmatch = 32'h1D1E1F20; // W23 TCP fast path nonmatch
        // ---- F4 新增的 4 路 (W32..W35, 全在 FE 束) ----
        force u_dut.u_mac_rx.stat_drop_partial = 32'h35363738;   // W32 C10 必需
        force u_dut.u_mac_rx.stat_orphan_bytes = 32'h393A3B3C;   // W33 C10 必需
        force u_dut.u_mac_rx.stat_drop_full    = 32'h3D3E3F40;   // W34 健康位
        force u_dut.u_mac_rx.stat_fifo_ovf     = 32'h41424344;   // W35 恒 0 健康位
        // ---- P6b 新增的 6 路 (W26/W27/W28/W29/W30/W31) ----
        force u_dut.rxcdc_full_cycles         = 32'h21222324;   // W26 RX FIFO 满拍数 (FE)
        force u_dut.rxcdc_occ_max             = 16'h2526;       // W27 RX FIFO 占用峰值 (FE)
        force u_dut.txcdc_occ_max             = 16'h2728;       // W28 TX FIFO 占用峰值 (DP)
        force u_dut.txwire_stall_cycles       = 32'h292A2B2C;   // W29 DP 在等线拍数 (DP)
        force u_dut.rxcdc_out_frames          = 32'h2D2E2F30;   // W30 RX FIFO 读侧 TLAST 数 (DP)
        force u_dut.rxcdc_out_bytes           = 32'h31323334;   // W31 RX FIFO 读侧 Σpopc (DP)
        // gmii_free (W5) / dp_free (W24) / mmcm_locked (W25) 故意不 force
        // (判据 5/5b/5c 已用活性、域比值与锁定位验过 —— "活体"比常数更强)
        repeat (10) @(posedge phy1_rxc);                     // 让 force 生效于 gmii 域
        // 诊断: force 到底落在哪根线上 —— 新加的字曾读回 zzzz, 用这行区分
        // "force 没落上" vs "快照路径没接对" (打印两束的最高位段)
        // (F1 改打生产者后, 这里读的 wrapper 线是**被生产者驱动**的: 它显示 Z/z 就说明
        //  生产者没接上 — 这正是打线时看不见、打生产者后才看得见的那一类错。)
        $display("  [DBG] 源: rx_stat_frames=%h mac_tx_frames=%h rxcdc_out_bytes=%h",
                 u_dut.rx_stat_frames, u_dut.mac_tx_frames, u_dut.rxcdc_out_bytes);
        $display("  [DBG] fe_src[319:256]=%h  dp_src[191:128]=%h",
                 u_dut.fe_src[319:256], u_dut.dp_src[191:128]);
        snap_take(ok_r);
        u_dut.u_pcie_xdma.axil_read(32'h20, v); chk("6 W0 = rx_stat_frames",  v, 32'h11111111);
        u_dut.u_pcie_xdma.axil_read(32'h24, v); chk("6 W1 = rx_stat_bytes",   v, 32'h22222222);
        u_dut.u_pcie_xdma.axil_read(32'h28, v); chk("6 W2 = {16'd0,wl_last}", v, 32'h0000ABCD);
        u_dut.u_pcie_xdma.axil_read(32'h2c, v); chk("6 W3 = rx_stat_crc_err", v, 32'h33333333);
        u_dut.u_pcie_xdma.axil_read(32'h30, v); chk("6 W4 = rx_stat_drop",    v, 32'h44444444);
        u_dut.u_pcie_xdma.axil_read(32'h38, v); chk("6 W6 = srx_stat_commit", v, 32'h66666666);
        u_dut.u_pcie_xdma.axil_read(32'h3c, v); chk("6 W7  = stx_stat_frames", v, 32'h77777777);
        u_dut.u_pcie_xdma.axil_read(32'h40, v); chk("6 W8  = udpapp_tx_frames", v, 32'h88888888);
        u_dut.u_pcie_xdma.axil_read(32'h44, v); chk("6 W9  = udpapp_tx_bytes",  v, 32'h99999999);
        u_dut.u_pcie_xdma.axil_read(32'h48, v); chk("6 W10 = udpapp_rx_frames", v, 32'hAAAAAAAA);
        u_dut.u_pcie_xdma.axil_read(32'h4c, v); chk("6 W11 = udpapp_rx_bytes",  v, 32'hBBBBBBBB);
        u_dut.u_pcie_xdma.axil_read(32'h50, v); chk("6 W12 = udpapp_rx_null",   v, 32'hCCCCCCCC);
        u_dut.u_pcie_xdma.axil_read(32'h54, v); chk("6 W13 = udpapp_mismatch",  v, 32'hDDDDDDDD);
        u_dut.u_pcie_xdma.axil_read(32'h58, v); chk("6 W14 = tx_stat_frames (TCP)",   v, 32'hEEEEEEEE);
        u_dut.u_pcie_xdma.axil_read(32'h5c, v); chk("6 W15 = tx_stat_bytes (TCP)",    v, 32'hFFFFFFFF);
        // ⚠️ chk 的名字走 `[255:0]` 向量端口 ⇒ **含中文的名字会被 xsim 打乱/吃掉**
        //    (本门既有行也这样, 是渲染问题不是功能问题) ⇒ 新加的行一律纯 ASCII 便于读读数。
        u_dut.u_pcie_xdma.axil_read(32'h60, v); chk("6 W16 = srx_hls_bytes",  v, 32'h01020304);
        u_dut.u_pcie_xdma.axil_read(32'h64, v); chk("6 W17 = hr_cnt",         v, 32'h05060708);
        u_dut.u_pcie_xdma.axil_read(32'h68, v); chk("6 W18 = stx_stat_purge", v, 32'h090A0B0C);
        u_dut.u_pcie_xdma.axil_read(32'h6c, v); chk("6 W19 = srx_stat_drop",  v, 32'h0D0E0F10);
        u_dut.u_pcie_xdma.axil_read(32'h70, v); chk("6 W20 = mac_tx_frames",  v, 32'h11121314);
        u_dut.u_pcie_xdma.axil_read(32'h74, v); chk("6 W21 = tx_stat_abort",  v, 32'h15161718);
        u_dut.u_pcie_xdma.axil_read(32'h78, v); chk("6 W22 = rx_stat_pass",   v, 32'h191A1B1C);
        u_dut.u_pcie_xdma.axil_read(32'h7c, v); chk("6 W23 = rx_stat_nonmatch", v, 32'h1D1E1F20);
        // ---- P6b 新增的 8 个字 (W24/W25 不 force, 见上) ----
        u_dut.u_pcie_xdma.axil_read(32'h88, v); chk("6 W26 = rxcdc_full_cycles",   v, 32'h21222324);
        u_dut.u_pcie_xdma.axil_read(32'h8c, v); chk("6 W27 = {16'd0,rxcdc_occ_max}", v, 32'h00002526);
        u_dut.u_pcie_xdma.axil_read(32'h90, v); chk("6 W28 = {16'd0,txcdc_occ_max}", v, 32'h00002728);
        u_dut.u_pcie_xdma.axil_read(32'h94, v); chk("6 W29 = txwire_stall_cycles", v, 32'h292A2B2C);
        u_dut.u_pcie_xdma.axil_read(32'h98, v); chk("6 W30 = rxcdc_out_frames",    v, 32'h2D2E2F30);
        u_dut.u_pcie_xdma.axil_read(32'h9c, v); chk("6 W31 = rxcdc_out_bytes",     v, 32'h31323334);
        // ---- F4 的 4 个新字 (W32..W35) ----
        u_dut.u_pcie_xdma.axil_read(32'hA0, v); chk("6 W32 = stat_drop_partial (C10)", v, 32'h35363738);
        u_dut.u_pcie_xdma.axil_read(32'hA4, v); chk("6 W33 = stat_orphan_bytes (C10)", v, 32'h393A3B3C);
        u_dut.u_pcie_xdma.axil_read(32'hA8, v); chk("6 W34 = stat_drop_full",          v, 32'h3D3E3F40);
        u_dut.u_pcie_xdma.axil_read(32'hAC, v); chk("6 W35 = stat_fifo_ovf (恒 0 健康位)", v, 32'h41424344);
        // ⚠️ W24/W25 用**活体**判据 (不 force): 见判据 5b/5c —— 它们证明"这两路确实接在
        //    数据面域的自由计数与 LOCKED 上", 比灌常数更强。

        // ---- 判据 7: 未触发时 24 个字必须冻结 (读窗口原子性) ----
        // ⚠️ 2026-09-29 审查 F7 修: 这里原来读 **W0 (0x20)**, 而 W0 在本门里被 force 成常数
        //    ⇒ 判据恒真 = **空判据** (抓不到任何东西)。改读 **W5 (0x34) = `gmii_free`**:
        //    它是本门唯一**不被 force** 的字, 且在 gmii 域每拍 +1 ⇒ 真出现隐性重触发 /
        //    窗口撕裂时它必变。这样判据才有判别力 (同坑 18)。
        $display("  --- 判据 7: 未触发 ⇒ 字冻结 (探针 = W5 自由计数, 全门唯一未 force 的字) ---");
        u_dut.u_pcie_xdma.axil_read(32'h34, a0);
        repeat (500) @(posedge u_dut.u_pcie_xdma.aclk);
        u_dut.u_pcie_xdma.axil_read(32'h34, b0);
        chk("7 W5 (gmii_free, free-running) frozen while not triggered", b0, a0);

        // ---- 判据 8: 触发清 done, gen 递增 ----
        $display("  --- 判据 8: 触发清 done / gen 递增 ---");
        u_dut.u_pcie_xdma.axil_read(32'h1c, v);
        gen0 = v[31:16];
        snap_take(ok_r);                                     // ⚠️ 输出端口别用 gen0 (会被覆盖)
        u_dut.u_pcie_xdma.axil_read(32'h1c, v);
        if (v[31:16] == gen0 + 1) $display("  [PASS] 8  gen 恰好 +1 (%0d -> %0d)", gen0, v[31:16]);
        else begin $display("  [FAIL] 8  gen = %0d (期望 %0d)", v[31:16], gen0+1); fails = fails + 1; end

        // ---- 判据 9: 未实现地址必须回 SLVERR ----
        // ⚠️ 这里查的是 **rresp = SLVERR (2)**, 不是数据值: 板上主机脚本看到 0xffffffff,
        //    那是 **XDMA 的 AXI-Lite 主机**在错误响应时填的数据, 不是 axi_regs 的行为
        //    (axi_regs 的读 mux 对未实现地址给 0 + rresp=SLVERR)。替身不模仿 XDMA 那一段,
        //    所以本门只能验 rresp —— 两边各验自己能验的那一半, 别把结论张冠李戴。
        // ⚠️ **P7b (2026-09-29) 地图又长了**: 51 字快照占 0x20..0xE8 (word 58) ⇒ 未实现地址 = word 59 = **0xEC**
        //    (随地图扩张挪过: 0x18 -> 0x44 -> 0x60 -> 0x84 -> 0xA0 -> 0xB0 -> 0xEC).
        //    绝不能用 ≥0x100 的地址: `ar_word = araddr[7:2]` 6 位 ⇒ 每 256 字节回绕
        //    (0x100 别名到 MAGIC ⇒ 假 PASS 于"读出的不是 0xffffffff"这类判据)。
        // ⛔ 2026-10-10 订正 (构建 C 门同步轮): 窗口 63 → **65 字** (新增 W63/W64;
        //    `board/wrapper_p4.v` 的 `SNAP_NW_P6E = 65`) ⇒ 末字 W64 @ 0x120 ⇒
        //    **未实现地址 = 0x20 + 4*65 = 0x124** (word 73)。`0x11C` 现在是窗口内的真字 W63
        //    ⇒ 原地址上的判据必然红 (断言失去判别力) ⇒ 只换地址常量。
        //    红线不变 (读侧译码 7 位 ⇒ **绝不能挑 ≥0x200**); 判据语义不变 (只验 rresp=SLVERR)。
        //    原句 (63 字时代) 保留在下方。
        // ⛔ 2026-10-07 订正 (P7B_STAGEB_FIX.md; 出处 P7B_STAGEB_RX8_REGRESSION.md §6-③):
        //    63 字地图 (0x20..0x118) 下 **0xEC = W51 已是真字** ⇒ 未实现地址 = word 63 = **0x11C**;
        //    且读侧译码 BIZ 轮起已 6→**7** 位 (`ar_word = araddr[8:2]`) ⇒ 回绕红线从 ≥0x100
        //    改成 **绝不能挑 ≥0x200** (见 `P7B_BIZ_WINDOW.md` §1 / `board/wrapper_p4.v:3108-3112`)。
        //    判据语义不变 (未实现地址必须回 rresp=SLVERR), 只换地址常量。
        // 原句 (51 字时代, 逐字保留):
        //   u_dut.u_pcie_xdma.axil_read(32'hEC, v);
        //   chk("9  未实现地址 0xEC ⇒ rresp = SLVERR", {30'd0, u_dut.u_pcie_xdma.last_rresp}, 32'd2);
        // 原句 (63 字时代, 逐字保留):
        //   u_dut.u_pcie_xdma.axil_read(32'h11C, v);
        //   chk("9  未实现地址 0x11C ⇒ rresp = SLVERR", {30'd0, u_dut.u_pcie_xdma.last_rresp}, 32'd2);
        // ⛔ 2026-10-10 (构建 E): 窗口 66 → **67 字** (`SNAP_NW_P6E = 67`) ⇒ 末字 W66 @ 0x128
        //    ⇒ 未实现地址 = 0x20 + 4*67 = **0x12C** (word 75)。0x128 现在是窗口内的真字。
        u_dut.u_pcie_xdma.axil_read(32'h12C, v);
        chk("9  未实现地址 0x12C ⇒ rresp = SLVERR", {30'd0, u_dut.u_pcie_xdma.last_rresp}, 32'd2);

        // ⚠️ release 的层次名必须与上面 force 的目标**逐字一致** (坑 22: 名字不一致时
        //    xelab 直接报 "not declared under prefix"; 但漏 release 是**静默**的 —— 后续判据
        //    会带着残留 force 跑, 所以这里逐条列全, 一条不漏)。
        release u_dut.u_mac_rx.stat_frames;
        release u_dut.u_mac_rx.stat_bytes;
        release u_dut.wl_last;
        release u_dut.u_mac_rx.stat_crc_err;
        release u_dut.u_mac_rx.stat_drop;
        release u_dut.u_slow_rx.stat_commit;
        release u_dut.u_slow_tx.stat_frames;
        release u_dut.u_app_udp.stat_tx_frames;
        release u_dut.u_app_udp.stat_tx_bytes;
        release u_dut.u_app_udp.stat_rx_frames;
        release u_dut.u_app_udp.stat_rx_bytes;
        release u_dut.u_app_udp.stat_rx_null;
        release u_dut.u_app_udp.stat_mismatch;
        release u_dut.u_tcp_tx.stat_frames;
        release u_dut.u_tcp_tx.stat_bytes;
        release u_dut.srx_hls_bytes;
        release u_dut.hr_cnt;
        release u_dut.u_slow_tx.stat_purge;
        release u_dut.u_slow_rx.stat_drop;
        release u_dut.u_mac_tx.stat_frames;
        release u_dut.u_mac_tx.stat_abort;
        release u_dut.u_tcp_rx.stat_pass;
        release u_dut.u_tcp_rx.stat_drop_nonmatch;
        release u_dut.u_mac_rx.stat_drop_partial;
        release u_dut.u_mac_rx.stat_orphan_bytes;
        release u_dut.u_mac_rx.stat_drop_full;
        release u_dut.u_mac_rx.stat_fifo_ovf;
        release u_dut.rxcdc_full_cycles;
        release u_dut.rxcdc_occ_max;
        release u_dut.txcdc_occ_max;
        release u_dut.txwire_stall_cycles;
        release u_dut.rxcdc_out_frames;
        release u_dut.rxcdc_out_bytes;

        if (fails == 0) $display("PASS_ALL  tb_p6e_pcie_wrapper: 全链门全过");
        else            $display("FAIL      tb_p6e_pcie_wrapper: %0d 项失败", fails);
        $display("=== done ===");
        $finish;
    end

    initial begin #4000000; $display("TIMEOUT"); $finish; end
endmodule
