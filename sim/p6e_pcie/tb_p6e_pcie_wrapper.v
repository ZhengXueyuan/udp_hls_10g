`timescale 1ns/1ps
//=============================================================================
// tb_p6e_pcie_wrapper.v — P6e 合体的 **真 wrapper 全链门** (工程坑 8)
//=============================================================================
// 为什么必须另开一门: snap_cdc / axi_regs 各自的单元门都自己搭链, **不走 wrapper 的
//   `ifdef PCIE_OBS` 接线分支** —— "8 个字各接的是哪一路计数" "snap_req/valid 有没有接反"
//   "复位有没有接对" 这类错在单元门里完全隐身 (P5a W1 / P5e-T2 两次血的教训:
//   子模块 TB 全绿, 板上却是静默故障)。
//
// 本门怎么抓: 把数据面那 15 路计数源用 `force` 打成**互不相同的常数**, 然后**从 AXI 侧**
//   把 8 个字读回来, 逐字比对常数 ⇒ 任何"接错一路"都会当场现形。
//   (gmii_free 那一路故意**不 force**: 它是自由计数器, 用"两次快照之间必须递增"来验它 ——
//    既证明它接对了, 又证明 gmii 域在仿真里真的在跑。)
//
// 门里还有: AXI 读通路 (MAGIC/BUILD_ID = 合体版 2)、触发/done 协议、8 字冻结、
//   未实现地址 SLVERR、HW_STATUS 的 user_lnk_up。
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

    always #4 phy1_rxc = ~phy1_rxc;                                    // 125MHz = 1G 的 RXC
    always #5 pcie_sys_clk_p = ~pcie_sys_clk_p;                        // 100MHz 差分参考钟
    always #5 pcie_sys_clk_n = ~pcie_sys_clk_n;

    // ⚠️ 端口表 = DEV_USP + PCIE_OBS 的组合 (与 build_p6e_ku5p.tcl 的 verilog_define 一致):
    //    DEV_USP ⇒ 没有 fpga_gclk; PCIE_OBS ⇒ 有 4 个 PCIe 口
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
    integer    k, ok_r, gen0;
    reg [31:0] v, v5a, v5b, a0, b0;

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
        u_dut.u_pcie_xdma.axil_read(32'h04, v); chk("2  BUILD_ID (合体版 16 字=3)", v, 32'h00000003);
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

        // ---- 判据 6: 8 个字的**逐路映射** (核心: 把源打成互不相同的常数再读回来) ----
        $display("  --- 判据 6: 快照 8 字逐路映射 (源 force 成常数) ---");
        force u_dut.rx_stat_frames   = 32'h11111111;
        force u_dut.rx_stat_bytes    = 32'h22222222;
        force u_dut.wl_last          = 16'hABCD;
        force u_dut.rx_stat_crc_err  = 32'h33333333;
        force u_dut.rx_stat_drop     = 32'h44444444;
        force u_dut.srx_stat_commit  = 32'h66666666;
        force u_dut.stx_stat_frames  = 32'h77777777;
        force u_dut.udpapp_tx_frames = 32'h88888888;   // W8  图案 app 发帧
        force u_dut.udpapp_tx_bytes  = 32'h99999999;   // W9  图案 app 发字节
        force u_dut.udpapp_rx_frames = 32'hAAAAAAAA;   // W10 图案 app 收帧
        force u_dut.udpapp_rx_bytes  = 32'hBBBBBBBB;   // W11 图案 app 收字节
        force u_dut.udpapp_rx_null   = 32'hCCCCCCCC;   // W12 空帧
        force u_dut.udpapp_mismatch  = 32'hDDDDDDDD;   // W13 图案失配
        force u_dut.tx_stat_frames   = 32'hEEEEEEEE;   // W14 MAC 发帧
        force u_dut.tx_stat_bytes    = 32'hFFFFFFFF;   // W15 MAC 发字节
        // gmii_free (W5) 故意不 force (判据 5 已用活性验过)
        repeat (10) @(posedge phy1_rxc);                     // 让 force 生效于 gmii 域
        // 诊断: force 到底落在哪根线上 —— 新加的 8 路曾读回 zzzz, 用这行区分
        // "force 没落上" vs "快照路径没接对"
        $display("  [DBG] 源: tx_stat_frames=%h udpapp_tx_frames=%h | snap_src[511:256]=%h",
                 u_dut.tx_stat_frames, u_dut.udpapp_tx_frames, u_dut.snap_src[511:256]);
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
        u_dut.u_pcie_xdma.axil_read(32'h58, v); chk("6 W14 = tx_stat_frames",   v, 32'hEEEEEEEE);
        u_dut.u_pcie_xdma.axil_read(32'h5c, v); chk("6 W15 = tx_stat_bytes",    v, 32'hFFFFFFFF);

        // ---- 判据 7: 未触发时 8 个字必须冻结 (读窗口原子性) ----
        $display("  --- 判据 7: 未触发 ⇒ 8 字冻结 ---");
        u_dut.u_pcie_xdma.axil_read(32'h20, a0);
        repeat (500) @(posedge u_dut.u_pcie_xdma.aclk);
        u_dut.u_pcie_xdma.axil_read(32'h20, b0);
        chk("7 不触发则 W0 不变", b0, a0);

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
        // ⚠️ 0x44 现在是 W9 (16 字快照把 0x20-0x5C 全占了) ⇒ 未实现地址挪到 0x60
        u_dut.u_pcie_xdma.axil_read(32'h60, v);
        chk("9  未实现地址 0x60 ⇒ rresp = SLVERR", {30'd0, u_dut.u_pcie_xdma.last_rresp}, 32'd2);

        release u_dut.rx_stat_frames;
        release u_dut.rx_stat_bytes;
        release u_dut.wl_last;
        release u_dut.rx_stat_crc_err;
        release u_dut.rx_stat_drop;
        release u_dut.srx_stat_commit;
        release u_dut.stx_stat_frames;
        release u_dut.udpapp_tx_frames;
        release u_dut.udpapp_tx_bytes;
        release u_dut.udpapp_rx_frames;
        release u_dut.udpapp_rx_bytes;
        release u_dut.udpapp_rx_null;
        release u_dut.udpapp_mismatch;
        release u_dut.tx_stat_frames;
        release u_dut.tx_stat_bytes;

        if (fails == 0) $display("PASS_ALL  tb_p6e_pcie_wrapper: 全链门全过");
        else            $display("FAIL      tb_p6e_pcie_wrapper: %0d 项失败", fails);
        $display("=== done ===");
        $finish;
    end

    initial begin #4000000; $display("TIMEOUT"); $finish; end
endmodule
