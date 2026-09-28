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
// 依赖替身 sim/p6e_pcie/xdma_0_sim_stub.v  |  跑法: run_tb_p6e_pcie_counters.bat
//   (编译时须定义 PCIE_OBS + DEV_USP + APP_MODE, 与真实构建一致)
//=============================================================================
module tb_p6e_pcie_counters;

    // 驱动拍数 = 期望增量 (单一定义: 断言直接用这三个数, 不出现魔数)
    localparam integer N_RX = 200;   // B: tvalid&&tready 同时为高的拍数
    localparam integer N_NG = 100;   // C: 只 tvalid / 只 tready 的拍数 (期望增量 0)
    localparam integer N_HR = 150;   // D: hls_rst_n 低电平拍数

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

    always #4 phy1_rxc = ~phy1_rxc;                                    // 125MHz = 1G 的 RXC
    always #5 pcie_sys_clk_p = ~pcie_sys_clk_p;                        // 100MHz 差分参考钟
    always #5 pcie_sys_clk_n = ~pcie_sys_clk_n;

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
        .pcie_rxn       (pcie_rxn)
    );

    integer    fails = 0;
    integer    k, ok_r;
    reg [31:0] v;
    // 每次快照读回的 5 个字 (随用途命名, 免得 a/b/c 混)
    reg [31:0] w16, w17, w5, w0, w19;
    reg [31:0] w16_p, w17_p, w5_p, w0_p, w19_p;    // _p = previous (上一相位的读数)
    reg [31:0] w16_base, w17_base;                 // 基线 (判据 F 的总账参照)

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
        u_dut.u_pcie_xdma.axil_read(32'h04, v); chk("0b BUILD_ID (24-word integrated = 4)", v, 32'h00000004);
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
        @(negedge u_dut.gmii_clk);
        force u_dut.u_slow_rx.hls_rx_tvalid = 1'b1;   // 生产者节点 (slow_rx_adp 输出)
        force u_dut.hls_rx_tready           = 1'b1;   // 生产者是 HLS IP ⇒ 只能打 wrapper 线
        repeat (5) @(posedge u_dut.gmii_clk);
        // B0: force 生效的**直接证据** = wrapper 那根线必须跟着生产者的 force 走。
        //     若线没接在这个生产者上 (F1 那一类错), 这里当场抓到。
        if (u_dut.hls_rx_tvalid === 1'b1)
            $display("  [PASS] B0 producer force 传到 wrapper 线 (hls_rx_tvalid = 1)");
        else begin
            $display("  [FAIL] B0 producer force 没传到 wrapper 线 (hls_rx_tvalid = %b): 线没接在生产者上",
                     u_dut.hls_rx_tvalid);
            fails = fails + 1;
        end
        repeat (N_RX - 5) @(posedge u_dut.gmii_clk);
        @(negedge u_dut.gmii_clk);
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
        @(negedge u_dut.gmii_clk);
        force u_dut.u_slow_rx.hls_rx_tvalid = 1'b1;
        force u_dut.hls_rx_tready           = 1'b0;
        repeat (N_NG) @(posedge u_dut.gmii_clk);
        @(negedge u_dut.gmii_clk);
        release u_dut.u_slow_rx.hls_rx_tvalid;
        release u_dut.hls_rx_tready;
        snap_read;
        show("C1 after tvalid-only");
        chk("C1 W16 delta == 0 (no count when tready=0)", w16 - w16_p, 0);

        // C2 只 tready: 把条件写成 `if (tready)` 的实现在这里当场 +N_NG ⇒ FAIL。
        $display("  --- 判据 C2: 只 tready (tvalid=0) %0d 拍 ⇒ 不许计数 ---", N_NG);
        @(negedge u_dut.gmii_clk);
        force u_dut.u_slow_rx.hls_rx_tvalid = 1'b0;
        force u_dut.hls_rx_tready           = 1'b1;
        repeat (N_NG) @(posedge u_dut.gmii_clk);
        @(negedge u_dut.gmii_clk);
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
        @(negedge u_dut.gmii_clk);
        force u_dut.u_slow_rx.hls_rst_n_r = 1'b0;      // 生产者节点 (slow_rx_adp 看门狗寄存器)
        repeat (5) @(posedge u_dut.gmii_clk);
        // D0: 同 B0 —— 生产者被拉低后 wrapper 那根线必须跟着低 (连接证据)
        if (u_dut.hls_rst_n === 1'b0)
            $display("  [PASS] D0 producer force 传到 wrapper 线 (hls_rst_n = 0)");
        else begin
            $display("  [FAIL] D0 producer force 没传到 wrapper 线 (hls_rst_n = %b): 线没接在生产者上",
                     u_dut.hls_rst_n);
            fails = fails + 1;
        end
        repeat (N_HR - 5) @(posedge u_dut.gmii_clk);
        @(negedge u_dut.gmii_clk);
        force  u_dut.u_slow_rx.hls_rst_n_r = 1'b1;     // ← 显式推回空闲值 (见上面的 ⚠️⚠️)
        @(negedge u_dut.gmii_clk);
        release u_dut.u_slow_rx.hls_rst_n_r;
        snap_read;
        show("D after watchdog-low");
        chk("D1 W17 delta == N_HR (1 count per low cycle)", w17 - w17_p, N_HR);
        chk("D2 W16 delta == 0 (rx fifo empty, no handshake)", w16 - w16_p, 0);

        // ================= 判据 E: release 后 W17 必须停 =================
        // (证明它数的是"低电平拍数", 不是"某个自由计数")
        $display("  --- 判据 E: hls_rst_n 回到高 ⇒ W17 停涨 ---");
        repeat (100) @(posedge u_dut.gmii_clk);
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

        if (fails == 0) $display("PASS_ALL  tb_p6e_pcie_counters: W16/W17 增量逻辑全过");
        else            $display("FAIL      tb_p6e_pcie_counters: %0d 项失败", fails);
        $display("=== done ===");
        $finish;
    end

    initial begin #4000000; $display("TIMEOUT"); $finish; end
endmodule
