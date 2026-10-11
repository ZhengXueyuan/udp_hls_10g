`timescale 1ns/1ps
//=============================================================================
// tb_app_rx_mirror.v — M1「载荷镜像」的**单元门** (自检式, 无 Python)
//=============================================================================
// 被测 = rtl/app_rx_mirror.v (snoop tap + ^0xA5 + 字节打包 + fifo_async(dp→pcie))
// ⚠️ 判据名一律 **纯 ASCII** —— xsim 会把经 [255:0] 端口传的非 ASCII 逐字节损坏
//    (本工程实测, 见 tb_fifo_async.v 的同款注释)。
//
// 为什么必须有它 (设计件 v2 §V5-A-1):
//   ① **FIFO 写门是本模块的第一号判据** —— 本工程同类缺陷踩过两次 (app_udp_pattern
//      每帧静默丢 8B / 两个适配器 latent), 两次都是"写使能与空间门错拍 ⇒ 丢字不可观测"。
//   ② 字节打包的**字节序**是"错了也只会读出另一个看似合理的值"的一类错 (全链门看不见
//      模块内部), 必须有一处**手算锚**。
//   ③ snoop 合同: 只采样 tvalid && tready, 不驱动任何握手 —— 要有一条"tready=0 的拍
//      一个字都不许采"的断言。
//
// 判据分组 (每条都对着一个具体的失效模式):
//   G0 reset state (empty/level/drop/sticky all 0)
//   G1 cap_en=0 => zero capture (negative control)
//   G2 one full 64-bit beat = **2 words** (hand anchors 0xF0C3D22D / 0xB48796E1)
//   G3 partial beat keep=0x0F => 1 word (hand anchor 0xE19687B4)
//   G4 cross-beat accumulator 1+0+2+1 bytes (anchor 0x78691E0F)
//   G5 tlast does NOT flush (anchor 0xF01E0FB4)
//   G6 snoop: beats with tready=0 are never captured (negative control)
//   G7 byte account: offered == 4*words (no-drop phase)
//   G8 drop counter has teeth: 8B/**cycle** burst (over the 4B/cycle structural cap)
//      => drop_bytes>0 AND any_drop=1
//   G9 clr: drain-flush (level->0) + any_drop cleared + accumulator cleared
//      (post-clr first word == the fresh 4 bytes; anchor 0xA1A6A7A4)
//      + drop_bytes NOT zeroed (v2 freeze list does not include it; registered)
//   G10 final state: level==0 && empty==1
//
// golden = TB-side byte-stream rebuild (top-n bytes, MSB->LSB order, ^0xA5);
//   ⚠️ golden and DUT are two implementations of the SAME rule => G2..G5/G9 each pin a
//   **hand-computed constant anchor** independent of the golden model.
//   ⚠️ keep contract = **top n bytes valid** (0xFF<<(8-n)); non-contiguous keep is out of
//   contract (module header says the same).
// run: sim/p7b_mir/run_tb_app_rx_mirror.bat [real|mut_gate|mut_order]
//=============================================================================
module tb_app_rx_mirror;

    // ---- clocks: write = dp_clk 156.25MHz (6.4ns) / read = pcie_axi_aclk 250MHz (4ns) ----
    reg clk_w = 1'b0, clk_r = 1'b0;
    always #3.2 clk_w = ~clk_w;
    always #2.0 clk_r = ~clk_r;

    integer fails = 0;

    task chk(input [255:0] name, input [31:0] got, input [31:0] exp);
        begin
            if (got === exp) $display("  [PASS] %0s = %08x", name, got);
            else begin $display("  [FAIL] %0s = %08x (exp %08x)", name, got, exp); fails = fails + 1; end
        end
    endtask
    task chk1(input [255:0] name, input got, input exp);
        begin
            if (got === exp) $display("  [PASS] %0s = %b", name, got);
            else begin $display("  [FAIL] %0s = %b (exp %b)", name, got, exp); fails = fails + 1; end
        end
    endtask
    task chkc(input [255:0] name, input integer got, input integer exp);
        begin
            if (got === exp) $display("  [PASS] %0s = %0d", name, got);
            else begin $display("  [FAIL] %0s = %0d (exp %0d)", name, got, exp); fails = fails + 1; end
        end
    endtask

    // ---- DUT stimulus regs (all registered; negedge landing => zero race, traps 3/17) ----
    reg        rst_n = 1'b0;
    reg [63:0] tv_data  = 64'd0;
    reg [7:0]  tv_keep  = 8'd0;
    reg        tv_valid = 1'b0;
    reg        tv_ready = 1'b1;
    reg        tv_last  = 1'b0;
    reg        cap_en   = 1'b0;
    reg        clr_tgl  = 1'b0;
    reg        rd_en_r  = 1'b0;

    wire [31:0] dout;
    wire        empty;
    wire [8:0]  level;
    wire [31:0] drop_bytes;
    wire        any_drop, any_drop_rd;
    // ---- ⭐ 期 B: aux 读口 (DMA 排空器) ----
    reg         dma_req = 1'b0;
    wire        dma_gnt, clr_pulse_rd;

    app_rx_mirror #(.XORC(8'hA5)) u_dut (
        .clk          (clk_w),
        .rst_n        (rst_n),
        .s_tdata      (tv_data),
        .s_tkeep      (tv_keep),
        .s_tvalid     (tv_valid),
        .s_tready     (tv_ready),
        .s_tlast      (tv_last),
        .ctrl_cap_en  (cap_en),
        .ctrl_clr_tgl (clr_tgl),
        .rd_clk       (clk_r),
        .rd_rst_n     (rst_n),
        .rd_en        (rd_en_r),
        .dout         (dout),
        .empty        (empty),
        .level        (level),
        .dma_req      (dma_req),
        .dma_gnt      (dma_gnt),
        .clr_pulse_rd (clr_pulse_rd),
        .drop_bytes   (drop_bytes),
        .any_drop     (any_drop),
        .any_drop_rd  (any_drop_rd)
    );

    // ---------------- golden model (TB-side byte stream rebuild) ----------------
    localparam integer GMAX = 8192;
    reg  [7:0] gold [0:GMAX-1];
    integer    gold_n   = 0;
    reg        gold_on  = 1'b0;        // on only in no-drop phases
    integer    offered  = 0;           // sum of popcount(keep) over accepted beats

    integer bi, ob;
    integer dcnt, dmis, dgt, tt;       // ⭐ 期 B: aux 口判据的计数
    always @(posedge clk_w) begin
        // same cycle/value as the DUT (both read pre-edge values => same handshake view)
        if (tv_valid && tv_ready) begin
            for (ob = 0; ob < 8; ob = ob + 1) if (tv_keep[ob]) offered = offered + 1;
            if (gold_on) begin
                for (bi = 7; bi >= 0; bi = bi - 1) begin
                    if (tv_keep[bi]) begin
                        gold[gold_n] = tv_data[bi*8 +: 8] ^ 8'hA5;
                        gold_n = gold_n + 1;
                    end
                end
            end
        end
    end

    // ---- stimulus tasks ----
    task beat(input [63:0] d, input [7:0] k, input l);
        begin
            @(negedge clk_w); tv_data <= d; tv_keep <= k; tv_last <= l; tv_valid <= 1'b1;
            @(negedge clk_w); tv_valid <= 1'b0;
        end
    endtask
    task set_ready(input r);
        begin @(negedge clk_w); tv_ready <= r; end
    endtask
    task wait_w(input integer n);
        integer i; begin for (i = 0; i < n; i = i + 1) @(posedge clk_w); end
    endtask
    task wait_r(input integer n);
        integer i; begin for (i = 0; i < n; i = i + 1) @(posedge clk_r); end
    endtask

    // ---- readout (FWFT: dout valid while !empty; rd_en pulses one rd cycle) ----
    integer p;
    task pop1(output [31:0] v, output integer ok);
        begin
            ok = 0; v = 32'hxxxxxxxx;
            for (p = 0; p < 4000; p = p + 1) begin
                @(negedge clk_r);
                if (!empty) begin
                    v = dout;
                    rd_en_r <= 1'b1;
                    @(negedge clk_r);
                    rd_en_r <= 1'b0;
                    ok = 1;
                    p = 100000;
                end
            end
        end
    endtask
    task clr_pulse;
        begin
            @(negedge clk_w); clr_tgl <= ~clr_tgl;
            wait_w(6);
        end
    endtask

    integer wc, ok_n;
    reg [31:0] wv;
    integer    dsave;

    initial begin
        $display("=== tb_app_rx_mirror: M1 payload mirror unit gate ===");
        tv_ready = 1'b1; cap_en = 1'b0; clr_tgl = 1'b0;
        repeat (20) @(posedge clk_w);
        rst_n = 1'b1;
        repeat (10) @(posedge clk_w);

        // ---- G0 reset state ----
        $display("  --- G0: reset state ---");
        chk1("G0a empty == 1", empty, 1'b1);
        chkc("G0b level == 0", level, 0);
        chk ("G0c drop_bytes == 0", drop_bytes, 32'd0);
        chk1("G0d any_drop == 0", any_drop, 1'b0);
        chk1("G0e any_drop_rd == 0", any_drop_rd, 1'b0);

        // ---- G1 cap_en=0 => no capture (negative control) ----
        $display("  --- G1: cap_en=0, inject beats, capture must stay off ---");
        gold_on = 1'b0;
        beat(64'h8877665544332211, 8'hFF, 1'b0);
        wait_w(4);
        beat(64'h0123456789ABCDEF, 8'h0F, 1'b0);
        wait_w(20);
        chkc("G1a level == 0 (cap_en=0 no capture)", level, 0);
        chk ("G1b drop_bytes == 0", drop_bytes, 32'd0);
        chk1("G1c empty == 1", empty, 1'b1);

        // ---- G2 one full beat = 2 words (hand anchors) ----
        // data=0x8877665544332211, keep=FF => bytes 88 77 66 55 44 33 22 11
        // word_a = {55',66',77',88'} = {F0,C3,D2,2D} = 0xF0C3D22D
        // word_b = {11',22',33',44'} = {B4,87,96,E1} = 0xB48796E1
        $display("  --- G2: cap_en=1, one full beat => 2 words (anchors) ---");
        @(negedge clk_w); cap_en <= 1'b1;
        wait_w(6);
        gold_n = 0; offered = 0; gold_on = 1'b1;
        beat(64'h8877665544332211, 8'hFF, 1'b0);
        wait_w(6);
        wait_r(20);
        chkc("G2a level == 2 (8 bytes = 2 words)", level, 2);
        pop1(wv, ok_n);
        chk ("G2b anchor: word_a == 0xF0C3D22D", wv, 32'hF0C3D22D);
        wait_r(6);
        chkc("G2c level == 1 after first pop", level, 1);
        pop1(wv, ok_n);
        chk ("G2d anchor: word_b == 0xB48796E1", wv, 32'hB48796E1);
        wait_r(10);
        chkc("G2e level == 0 after both pops", level, 0);

        // ---- G3 partial beat keep=0x0F => 1 word (hand anchor) ----
        // data = 0x1122334455667788 keep=0x0F => valid = top 4 = 11 22 33 44
        // word = {44',33',22',11'} = {E1,96,87,B4} = 0xE19687B4
        $display("  --- G3: keep=0x0F partial beat => 1 word (anchor) ---");
        gold_n = 0; offered = 0;
        beat(64'h1122334455667788, 8'h0F, 1'b1);
        wait_w(6); wait_r(20);
        chkc("G3a level == 1", level, 1);
        pop1(wv, ok_n);
        chk ("G3b anchor: word == 0xE19687B4", wv, 32'hE19687B4);
        wait_r(10);

        // ---- G4 cross-beat accumulator 1+0+2+1 ----
        $display("  --- G4: accumulator across beats (1+0+2+1) ---");
        gold_n = 0; offered = 0;
        beat(64'hAA00000000000000, 8'h80, 1'b0);      // 1 byte: 0xAA
        wait_w(4);
        beat(64'h0000000000000000, 8'h00, 1'b0);      // 0 bytes (no contribution)
        wait_w(4);
        beat(64'hBBCC000000000000, 8'hC0, 1'b0);      // 2 bytes: 0xBB, 0xCC
        wait_w(6);
        chkc("G4a 3 beats, still <1 word => level == 0", level, 0);
        beat(64'hDD00000000000000, 8'h80, 1'b0);      // +1 byte: 0xDD => complete
        wait_w(6); wait_r(20);
        chkc("G4b complete => level == 1", level, 1);
        pop1(wv, ok_n);
        // stream AA BB CC DD => word = {DD',CC',BB',AA'} = {78,69,1E,0F} = 0x78691E0F
        chk ("G4c anchor: cross-beat word == 0x78691E0F", wv, 32'h78691E0F);
        chkc("G4d offered == 4", offered, 4);
        chkc("G4e gold_n == 4", gold_n, 4);
        wait_r(10);

        // ---- G5 tlast does not flush ----
        $display("  --- G5: tlast=1 mid-stream does not break the byte stream ---");
        gold_n = 0; offered = 0;
        beat(64'h1122334400000000, 8'h80, 1'b1);      // 1 byte 0x11 + tlast
        wait_w(4);
        beat(64'hAABBCCDD00000000, 8'hC0, 1'b1);      // 2 bytes 0xAA,0xBB + tlast
        wait_w(4);
        beat(64'h5566778800000000, 8'h80, 1'b1);      // 1 byte 0x55 + tlast => complete
        wait_w(6); wait_r(20);
        chkc("G5a level == 1 (tlast is not flush)", level, 1);
        pop1(wv, ok_n);
        // stream 11 AA BB 55 => word = {55',BB',AA',11'} = {F0,1E,0F,B4} = 0xF01E0FB4
        chk ("G5b anchor: word == 0xF01E0FB4", wv, 32'hF01E0FB4);
        wait_r(10);
        chkc("G5c level == 0 (FIFO empty before G6)", level, 0);

        // ---- G6 snoop: tready=0 beats are never captured ----
        $display("  --- G6: tready=0 beats must not be captured ---");
        set_ready(1'b0);
        wait_w(2);
        gold_on = 1'b0;
        beat(64'hDEADBEEF00000000, 8'hFF, 1'b0);
        wait_w(4);
        beat(64'hCAFEBABE00000000, 8'hFF, 1'b0);
        wait_w(4);
        beat(64'h0011223300000000, 8'hFF, 1'b0);
        wait_w(6);
        chkc("G6a level == 0 (tready=0 => no capture)", level, 0);
        chk1("G6b empty == 1", empty, 1'b1);
        set_ready(1'b1);
        wait_w(4);

        // ---- G7 byte account ----
        $display("  --- G7: byte account, offered == 4*words ---");
        gold_n = 0; offered = 0; gold_on = 1'b1;
        beat(64'h0102030405060708, 8'hF0, 1'b0);      // 4B => 1 word
        wait_w(10);
        beat(64'h1112131415161718, 8'hF8, 1'b0);      // 5B => 1 word + 1B residue
        wait_w(10);
        beat(64'h2122232425262728, 8'hE0, 1'b0);      // 3B => residue 1+3 = 1 word
        wait_w(10); wait_r(30);
        $display("  [INFO] G7 offered=%0d gold_n=%0d level=%0d drop=%0d", offered, gold_n, level, drop_bytes);
        chkc("G7a drop_bytes == 0 in this phase", drop_bytes, 32'd0);
        chkc("G7b level == 3", level, 3);
        wc = 0;
        while (!empty && wc < 100) begin pop1(wv, ok_n); wc = wc + 1; end
        wait_r(10);
        chkc("G7c drained words == 3", wc, 3);
        chkc("G7d words*4 == offered", wc * 4, offered);
        chkc("G7e level == 0 after drain", level, 0);

        // ---- G8 drop counter has teeth (8B/cycle burst) ----
        $display("  --- G8: 8B/cycle burst => drop_bytes>0 and any_drop=1 ---");
        gold_on = 1'b0;
        begin : burst
            integer q;
            reg [63:0] d0;
            @(negedge clk_w); tv_keep <= 8'hFF; tv_valid <= 1'b1;
            for (q = 0; q < 300; q = q + 1) begin
                d0 = 64'hB000000000000000 + q;
                @(negedge clk_w); tv_data <= d0;
            end
            @(negedge clk_w); tv_valid <= 1'b0;
        end
        wait_w(10); wait_r(40);
        $display("  [INFO] G8 offered=%0d drop_bytes=%0d level=%0d", offered, drop_bytes, level);
        if (drop_bytes > 32'd0) $display("  [PASS] G8a drop_bytes > 0 (burst was counted)");
        else begin $display("  [FAIL] G8a drop_bytes == 0 (8B/cycle with no drops => counter has no teeth)"); fails = fails + 1; end
        chk1("G8b any_drop == 1 (sticky)", any_drop, 1'b1);
        wait_r(30);
        wc = 0;                                        // drain (content is holed by design)
        while (!empty && wc < 400) begin pop1(wv, ok_n); wc = wc + 1; end
        wait_r(30);
        chkc("G8c still drainable (level == 0)", level, 0);

        // ---- G11 write gate under FULL (module criterion #1: slow reader fills the FIFO) ----
        // 变异靶子 = mut_gate (`wr_en = have`, 丢掉 !full): FIFO 自身仍会拒写 (`wr_ok=wr_en&&!full`),
        //   但**镜像把累加器清了**、而拒写只进 FIFO 的 ovf_cnt (本模块不接) ⇒ 那一字**静默消失**、
        //   drop_bytes 不动 ⇒ 只有这条"字节账恒等式"能抓它 (设计件 §V5-A-1 点名的第一号判据)。
        // ⚠️ 必须确认真的压到 full (否则本相位是空判据 —— G11a 就是这个前置见证)。
        $display("  --- G11: write gate under full: byte identity holds (no silent loss) ---");
        gold_on = 1'b0; offered = 0; dsave = drop_bytes;
        begin : g11fill
            integer q;
            for (q = 0; q < 600; q = q + 1) begin
                if (u_dut.fifo_full) q = 100000;
                else begin beat(64'hC000000000000000 + q, 8'hFF, 1'b0); wait_w(1); end
            end
        end
        wait_w(6);
        chk1("G11a FIFO reached full (state witness)", u_dut.fifo_full, 1'b1);
        chk ("G11b paced fill added no drops", drop_bytes, dsave);
        dsave = drop_bytes;
        beat(64'hD000000000000000, 8'hFF, 1'b0);       // 满态再注 1 拍 = 2 字
        wait_w(10); wait_r(20);
        wc = 0;
        begin : g11drain
            integer rr;
            for (rr = 0; rr < 3; rr = rr + 1) begin     // 双排: "被握住的字"会在排空后才落笔
                while (!empty && wc < 800) begin pop1(wv, ok_n); wc = wc + 1; end
                wait_r(20);
            end
        end
        $display("  [INFO] G11 offered=%0d drained_words=%0d d_drop=%0d level=%0d",
                 offered, wc, drop_bytes - dsave, level);
        // 字节账恒等式 (设计件 §V5-A-1 的第一号判据): 每个被接受的字节
        //   要么进了 FIFO (4*字数), 要么被计进 drop_bytes —— **没有第三种去处**。
        //   mut_gate (`wr_en=have`) 在这里差 8B: 被 FIFO 拒写的字既没进 FIFO 也没计数。
        chkc("G11c identity: offered == 4*drained + d_drop", wc * 4 + (drop_bytes - dsave), offered);
        chkc("G11d level == 0 after drain", level, 0);

        // ---- G9 clr ----
        $display("  --- G9: clr (toggle) ---");
        gold_on = 1'b0;
        beat(64'h9988776655443322, 8'hF0, 1'b0);       // 4B => 1 word
        wait_w(8);
        beat(64'h000000000000ABCD, 8'hC0, 1'b0);       // 2B => accumulator only
        wait_w(8); wait_r(30);
        chkc("G9a pre: level == 1 (1 word + 2B residue in acc)", level, 1);
        dsave = drop_bytes;
        clr_pulse();
        wait_r(60);
        chkc("G9b after clr: level == 0 (drain flush)", level, 0);
        chk1("G9c after clr: any_drop == 0", any_drop, 1'b0);
        wait_r(10);
        chk1("G9d after clr: any_drop_rd == 0 (clear crossed CDC)", any_drop_rd, 1'b0);
        chk ("G9e clr does NOT zero drop_bytes (not in v2 freeze list)", drop_bytes, dsave);
        // accumulator really cleared: feed only 4 fresh bytes; first word must be those 4
        gold_n = 0; offered = 0; gold_on = 1'b1;
        beat(64'h0102030400000000, 8'hF0, 1'b0);       // 4 bytes: 01 02 03 04
        wait_w(8); wait_r(30);
        chkc("G9f post-clr: level == 1", level, 1);
        pop1(wv, ok_n);
        // word = {04',03',02',01'} = {A1,A6,A7,A4} = 0xA1A6A7A4
        chk ("G9g post-clr first word == 0xA1A6A7A4 (acc cleared)", wv, 32'hA1A6A7A4);

        // ---- G10 final state ----
        $display("  --- G10: final state ---");
        wait_r(40);
        chkc("G10a level == 0", level, 0);
        chk1("G10b empty == 1", empty, 1'b1);

        // ================= ⭐ 期 B: aux 读口 (DMA 排空器) =================
        //   合同: ① dma_req && !empty ⇒ 每拍弹 1 字 (dma_gnt=1, dout = 该字);
        //         ② 与主机弹出同时请求时 **主机优先** (dma_gnt=0, 不双弹);
        //         ③ 空态不弹 (dma_gnt=0)。
        $display("  --- G12: aux pop port (dma_req/dma_gnt) + host-priority ---");
        // 空态: req 高也不弹 (③)
        dma_req = 1'b1;
        wait_r(10);
        chkc("G12a empty: dma_gnt == 0", dma_gnt, 0);
        dma_req = 1'b0;
        // 灌 4 字 (4 × 4B)
        beat(64'h0102030405060708, 8'hF0, 0);
        beat(64'h0102030405060708, 8'hF0, 0);
        beat(64'h0102030405060708, 8'hF0, 0);
        beat(64'h0102030405060708, 8'hF0, 0);
        wait_w(20);
        chkc("G12b level == 4", level, 4);
        // aux 弹出 4 字: 计数 + 内容 (①)
        dma_req = 1'b1;
        dcnt = 0; dmis = 0;
        for (tt = 0; tt < 400; tt = tt + 1) begin
            @(posedge clk_r);
            if (dma_gnt) begin
                dcnt = dcnt + 1;
                if (dout !== 32'hA1A6A7A4) dmis = dmis + 1;
            end
            if (dcnt == 4) tt = 4000;
        end
        chkc("G12c aux popped exactly 4 words", dcnt, 4);
        chkc("G12d aux word content = 0xA1A6A7A4", dmis, 0);
        wait_r(10);
        chkc("G12e level == 0 after aux drain", level, 0);
        // 主机优先 (②): 两路同时请求 ⇒ dma_gnt 必须恒 0 (主机吃掉), 且只消费 2 字 (不双弹)
        dma_req = 1'b0;
        beat(64'hA1B2C3D4E5F60718, 8'hF0, 0);
        beat(64'h1112131415161718, 8'hF0, 0);
        wait_w(20);
        chkc("G12f level == 2", level, 2);
        dma_req = 1'b1;
        @(negedge clk_r); rd_en_r <= 1'b1;
        dgt = 0;
        for (tt = 0; tt < 6; tt = tt + 1) begin
            @(posedge clk_r);
            if (dma_gnt) dgt = dgt + 1;
        end
        @(negedge clk_r); rd_en_r <= 1'b0;
        chkc("G12g host priority: dma_gnt == 0 while host requests", dgt, 0);
        dma_req = 1'b0;
        wait_r(10);
        chkc("G12h exactly 2 words consumed (no double-pop)", level, 0);

        $display("");
        if (fails == 0) $display("APP_RX_MIRROR_GATE: PASS_ALL");
        else            $display("APP_RX_MIRROR_GATE: FAIL (%0d checks failed)", fails);
        $finish;
    end

    initial begin #2000000; $display("APP_RX_MIRROR_GATE: TIMEOUT"); $finish; end

endmodule
