`timescale 1ns/1ps
//=============================================================================
// tb_app_udp_rate: app UDP TX 通路**线速**测量 TB (P5f 验收)
//
// 链: app_udp_pattern → udp_tx_cfg (peer 门) → udp_tx_frame (组帧) → mac_tx_64
//     (tx_arb 不参与: 本门只看"无人竞争时 app 通路能跑多快")
//
// 判据: mac_tx 的 GMII 前导沿之间的**拍数** (= 帧周期) 与 1472B 载荷比
//   ⇒ 载荷速率 = 1472*8 / (周期/125MHz) bps。
//   理论口径: 1538 拍/帧 (8 前导 + 1514 内容 + 4 FCS + 12 IFG) ⇒ 957 Mbps 载荷。
//
// ⭐ 2026-09-30 (P7B-W9 门覆盖面收口): 本 TB 从"只打印"改成**自判** —— 见下方
//   `FRM_EXP`/`WIRE_EXP`/`SATFLOOR` 三组判据。末行判据 = "RATE GATE: OK" /
//   "RATE GATE: FAIL errs=<n>" (门脚本按它定成败)。
//   `sim/p5e_rate/run_tb_rate.bat p7b1472` = **饱和档** (8 B/拍发生器 + 背靠背,
//   结构性 8:1 产消差) ⇒ 这是唯一能覆盖 "TX 字 FIFO 饱和那拍静默丢字" 的档。
//
// TX_GAP 由 `-d TXGAP=<value>` 覆盖 (默认 0), 便于一版 RTL 跑多档。
// 编译 (独立目录 sim/p5e_rate):
//   xvlog tb/tb_app_udp_rate.v rtl/{app_udp_pattern,udp_tx_cfg,udp_tx_frame,
//                                  checksum16,fifo_sync,mac_tx_64,crc32_8b}.v
//   xelab -d TXGAP=16'd0 xil_defaultlib.tb_app_udp_rate -s s -timescale 1ns/1ps
//=============================================================================
// 档位选择: 本版 xvlog 的 -d 只接受**裸宏名** (不能带 =值) ⇒ 用具名档位宏。
`ifdef GAP58000
  `define TXGAP 16'd58000
`elsif GAP5000
  `define TXGAP 16'd5000
`elsif GAP2760
  `define TXGAP 16'd2760
`elsif GAP1380
  `define TXGAP 16'd1380
`else
  `define TXGAP 16'd0
`endif
`ifdef PL512
  `define PAYLEN 12'd512
`elsif PL996
  `define PAYLEN 12'd996
`else
  `define PAYLEN 12'd1472
`endif
`define MAXCYC 8000000

//-----------------------------------------------------------------------------
// P7B-W9 判据口径 (2026-09-30, 门覆盖面收口)
//-----------------------------------------------------------------------------
// 要抓的不变式: `app_udp_pattern.stat_tx_bytes` 的增量 == 真正落进 TX 字 FIFO 的字节数。
// 三条判据 (互为独立观测点; 详见下方 verdict 块处的逐条注释):
//   C1 **逐拍合同检查** (主判据, 非采样): `u_app.txf_wr && u_app.txf_full` 必须 0 拍。
//      `txf_wr` 是寄存器 (T-1 决定、T 拍落笔) ⇒ 落笔拍 FIFO 已满 = 这笔已记账的推入
//      被静默丢弃。无假阳性 (合法填满那拍 full=0)。
//   C2 帧器逐帧输出长度 == `FRM_EXP` 且 min==max           (帧器 AXIS 口, 逐帧)
//   C3 线上逐帧长度     == `WIRE_EXP` 且 min==max          (mac_tx 的 gmii_tx_en, 逐帧采样)
// 期望值由 PAYLEN **推出**, 不是抄读数 (已在 1472/996/512 三档实测对账):
//   帧器 = 42(ETH 14 + IP 20 + UDP 8) + PAYLEN          (FCS 由 mac_tx_64 加)
//   线上 = 8(前导+SFD) + 42 + PAYLEN + 4(FCS) - 1       (-1 = 本 TB 的计数约定:
//           acc_wire 在帧首拍被清零, 故 = tx_en 拍数 - 1)
// 缺陷形态 (P7B-W9, `txf_wr` 是寄存器却拿本拍 `txf_full` 做空间门 ⇒ 饱和那拍丢 1 个整字):
//   P7B_10G 档下每帧短 8 B ⇒ 线上 1517 (vs 1525), 帧器 1506 (vs 1514);
//   实测 C1 = 41 拍违约 (= 全程丢 41 个字), 判据红。
// ⚠️ **但 C2/C3 只在"字 FIFO 到达饱和"的模态下才有可能变红** (饱和是缺陷的必要前提) ⇒
//   门里必须同时判**覆盖率见证** `full_cyc` (见 SATFLOOR), 且必须用**能饱和的那一档**
//   (`p7b1472` = `P7B_10G` + `TXGAP=0`; 实测: 只有它把 FIFO 顶到 55670 拍,
//   而 g58000p1472(+`P7B_10G`) 是 **0** 拍 —— 有帧间隔就结构性到不了饱和)。
//   ⚠️ 诚实标注: `full_cyc > 0` 是**必要非充分**条件 —— 默认档 (1 B/拍 + g0) 也能顶满
//   (full_cyc=3640) 而**不丢字** (相位锁定, 实测缺陷版在该档 C1 也是 0)。所以覆盖见证
//   只能证伪"激励够不到饱和", **不能**替代 C1。C1 才是判据本体。
//-----------------------------------------------------------------------------
`define FRM_EXP  ((`PAYLEN) + 12'd42)
`define WIRE_EXP ((`PAYLEN) + 12'd53)
// 覆盖率下限: 界取**两模态之间**, 不钉在样本极值上。实测 (PAYLEN=1472, 本 TB):
//   p7b1472 (8 B/拍 + 背靠背, 判据要求的饱和档) = **55670** 拍;
//   g0p1472 (逐字节发生器, 只有相位偶发顶满)     = **3640** 拍。
//   ⇒ 取 20000 (离两模态各 2.8x / 5.5x, 不贴任何一端的极值)。
`define SATFLOOR 20000

module tb_app_udp_rate;
    reg clk, rst_n;
    always #4 clk = ~clk;                  // 125 MHz @8ns

    reg         i_en;
    reg  [11:0] i_paylen;
    wire [63:0] a_td;  wire [7:0] a_tk;
    wire        a_tv, a_tr, a_tl;
    wire [31:0] a_tx_bytes, a_tx_frames, a_rx_bytes, a_rx_frames, a_rx_null, a_mm;
    wire        a_active, a_done;  wire [3:0] a_led;

    reg         peer_wr;
    reg  [47:0] peer_mac;
    reg  [31:0] peer_ip;

    wire        u_ready;
    wire [63:0] u_td;  wire [7:0] u_tk;
    wire        u_tv, u_tr, u_tl;
    wire [47:0] c_dmac, c_smac;
    wire [31:0] c_dip,  c_sip;
    wire [15:0] c_dport, c_sport;
    wire        c_csen;

    wire [63:0] m_td;  wire [7:0] m_tk;
    wire        m_tv, m_tr, m_tl;
    wire [31:0] utx_frames, utx_bytes, utx_drop;
    wire        utx_busy;

    wire [7:0]  gmii_txd;
    wire        gmii_tx_en, gmii_tx_er;
    wire [31:0] mac_frames, mac_abort;

    // ---- 测量寄存器 (声明必须在 always 之前: xvlog 先声明后用) ----
    reg  prev_en;
    reg  DBG;
    integer cyc, npre, last_pre, acc_wire;
    integer sum_p, sum_w, k, n, i;

    // ---- P7B-W9 仪器 (见文件头判据口径) ----
    integer w_min, w_max;            // 线上逐帧长度 (与 sum_w 同一采样集合: npre>5)
    integer f_n, f_min, f_max;       // 帧器逐帧长度 (所有帧)
    integer full_cyc;                // 覆盖率见证: TX 字 FIFO 满的拍数 (饱和模态 ⇒ 大)
    integer pushdec_cyc;             // 灵敏度见证: 被本判据检过的"推入落笔"笔数
    integer ovf_cyc;                 // 违约拍数 (见下 C1; 必须为 0)
    integer first_ovf_t;             // 首违约拍号 (0 = 无违约; 复位后即违约不可能发生)
    integer gate_errs;               // 判据失败计数
    reg  [31:0] fr_cur;              // 帧器本帧已计字节
    // ⚠️ min/max 的哨兵初值一律用 **0** (不用 -1): 长度是正整数, 0 恒小于任何真实读数;
    //    而 -1 与 `reg[31:0]+4bit` 的**无符号**和比较时会被当成 4294967295 ⇒
    //    max 判据结构性永不触发 (本轮实机踩坑, 见 P7B_GATE_COV_FIX.md §5.4)

    // 饱和是否**本档必须达到** (8 B/拍发生器 + 背靠背 = 唯一能饱和的模态):
    //   `P7B_10G` 把发生器加宽到 8 B/拍; TXGAP=0 让它背靠背推 ⇒ 与 1 B/拍的 mac_tx_64
    //   形成结构性 8:1 产消差 ⇒ FIFO 必满。其余档 (逐字节发生器 / 有帧间隔) 够不到饱和,
    //   本判据在那里是**空判据**, 故不要求 (见下方 COV 判据)。
`ifdef P7B_10G
    localparam SATREQ = (`TXGAP == 16'd0);
`else
    localparam SATREQ = 1'b0;
`endif

    // tkeep 字节数 (帧器的末字可能不满)
    function [3:0] popc8;
        input [7:0] v;
        integer b;
        begin
            popc8 = 4'd0;
            for (b = 0; b < 8; b = b + 1) popc8 = popc8 + v[b];
        end
    endfunction

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(`TXGAP)) u_app (
        .clk(clk), .rst_n(rst_n),
        .i_en(i_en), .i_tx_ready(u_ready), .i_paylen(i_paylen),
        .m_tdata(a_td), .m_tkeep(a_tk), .m_tvalid(a_tv),
        .m_tready(a_tr), .m_tlast(a_tl),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(a_tx_bytes), .stat_tx_frames(a_tx_frames),
        .stat_rx_bytes(a_rx_bytes), .stat_rx_frames(a_rx_frames),
        .stat_rx_null(a_rx_null), .stat_mismatch(a_mm),
        .active(a_active), .done(a_done), .led(a_led)
    );

    udp_tx_cfg u_cfg (
        .clk(clk), .rst_n(rst_n),
        .peer_wr(peer_wr), .peer_mac(peer_mac), .peer_ip(peer_ip),
        .frame_busy(utx_busy),
        .cfg_my_mac(48'h000A3501FEC0), .cfg_my_ip(32'hC0A86402),
        .cfg_my_port(16'h1F91), .cfg_dst_port(16'h1F91), .cfg_csum_en(1'b1),
        .s_axis_tdata(a_td), .s_axis_tkeep(a_tk), .s_axis_tvalid(a_tv),
        .s_axis_tready(a_tr), .s_axis_tlast(a_tl),
        .m_axis_tdata(u_td), .m_axis_tkeep(u_tk), .m_axis_tvalid(u_tv),
        .m_axis_tready(u_tr), .m_axis_tlast(u_tl),
        .o_dst_mac(c_dmac), .o_dst_ip(c_dip), .o_dst_port(c_dport),
        .o_src_mac(c_smac), .o_src_ip(c_sip), .o_src_port(c_sport),
        .o_csum_en(c_csen), .o_ready(u_ready),
        .stat_frames(), .stat_deny()
    );

    udp_tx_frame u_utx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(u_td), .s_axis_tkeep(u_tk), .s_axis_tvalid(u_tv),
        .s_axis_tready(u_tr), .s_axis_tlast(u_tl),
        .cfg_src_mac(c_smac), .cfg_dst_mac(c_dmac),
        .cfg_src_ip(c_sip),  .cfg_dst_ip(c_dip),
        .cfg_src_port(c_sport), .cfg_dst_port(c_dport), .cfg_csum_en(c_csen),
        .m_axis_tdata(m_td), .m_axis_tkeep(m_tk), .m_axis_tvalid(m_tv),
        .m_axis_tready(m_tr), .m_axis_tlast(m_tl),
        .stat_frames(utx_frames), .stat_bytes(utx_bytes),
        .stat_drop_len(utx_drop), .o_busy(utx_busy)
    );

    mac_tx_64 u_mac (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(m_td), .s_axis_tkeep(m_tk), .s_axis_tvalid(m_tv),
        .s_axis_tready(m_tr), .s_axis_tlast(m_tl),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .stat_frames(mac_frames), .stat_abort(mac_abort)
    );

    // ---- 测量: gmii_tx_en 上升沿 = 帧起 (前导首拍); 周期 = 相邻上升沿拍差 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            cyc <= 0; npre <= 0; acc_wire <= 0; last_pre <= 0;
            prev_en <= 1'b0;
            w_min <= 1000000; w_max <= 0;
        end else begin
            cyc <= cyc + 1;
            prev_en <= gmii_tx_en;
            if (gmii_tx_en) acc_wire <= acc_wire + 1;
            if (gmii_tx_en && !prev_en) begin
                if (npre > 5) begin                      // 跳过前 6 帧热机 (含首帧)
                    sum_p <= sum_p + (cyc - last_pre);   // 周期 (含本帧前导沿)
                    sum_w <= sum_w + acc_wire;           // 上一帧线上字节数
                    k     <= k + 1;
                    // P7B-W9: 逐帧"单元素"判据的 min/max (与 sum_w 同一采样集合)
                    if (acc_wire < w_min) w_min <= acc_wire;
                    if (acc_wire > w_max) w_max <= acc_wire;
                end
                if (npre < 12 && DBG)
                    $display("  [pre %0d] cyc=%0d d=%0d wire=%0d | app txs=%0d gap=%0d sent=%0d bcnt=%0d wr=%b fifo_full=%b utx_busy=%b",
                             npre, cyc, cyc - last_pre, acc_wire,
                             u_app.txs, u_app.gap_cnt, u_app.seg_sent,
                             u_app.bcnt, u_app.txf_wr, u_app.txf_full, utx_busy);
                last_pre <= cyc;
                acc_wire <= 0;
                npre <= npre + 1;
            end
        end
    end

    // ---- P7B-W9 仪器 A: 帧器逐帧长度 (独立于线上那条仪器) ----
    // 帧器长度在 `m_tlast` 处取整 (axvalid && tready 才算真消费) ⇒ 它是**逐帧**量,
    // 与线上那条 (`gmii_tx_en` 拍数) 是**两个不同的观测点** ⇒ 互为独立证据。
    always @(posedge clk) begin
        if (!rst_n) begin
            fr_cur <= 32'd0; f_n <= 0; f_min <= 1000000; f_max <= 0;
        end else begin
            if (m_tv && m_tr) fr_cur <= fr_cur + popc8(m_tk);
            if (m_tv && m_tr && m_tl) begin
                f_n <= f_n + 1;
                if ((fr_cur + popc8(m_tk)) < f_min) f_min <= fr_cur + popc8(m_tk);
                if ((fr_cur + popc8(m_tk)) > f_max) f_max <= fr_cur + popc8(m_tk);
                fr_cur <= 32'd0;
            end
        end
    end

    // ---- P7B-W9 仪器 B (主判据 C1): 逐拍合同检查 + 覆盖率/灵敏度见证 ----
    // 合同 (rtl/fifo_sync.v「写口合同」+ rtl/app_udp_pattern.v 头注释):
    //   `txf_wr` 是**寄存器** (T-1 决定推入、**T 拍落笔**), 落笔拍 FIFO 必须不满:
    //      不变式: `txf_wr(T) ⇒ !txf_full(T)`
    //   违反 ⇒ 这笔**已计入 `stat_tx_bytes`/`seg_sent`** 的推入被 FIFO 静默丢弃
    //        (正是 P7B_10G 下每帧短 8 B 的机理)。
    // 与 FIFO 内部 `ovf_pulse` 的区别 (这是缺陷藏了一整轮的原因): 后者 = `wr && full`,
    //   而缺陷版把 `wr` 预 AND 成 `txf_wr && !txf_full` ⇒ `ovf_pulse` **结构性恒 0**
    //   (自检回路哑掉)。本判据用**生产者侧**的 `txf_wr` 判, **不受该预 AND 影响**
    //   ⇒ 同一份 TB 在缺陷版/修复版上都能算, 且缺陷版必然报数。
    // 判别力: **逐拍**, 不是采样 ⇒ 一次丢字也照抓; 且**无假阳性** ——
    //   合法地"把 FIFO 填满"那一拍 `full(T)=0` (落笔发生在满之前), 只有
    //   "落笔拍已经满"才算违约。
    // 灵敏度见证 `pushdec_cyc` = 真正被检的推入笔数 (判据不是空跑)。
    always @(posedge clk) begin
        if (!rst_n) begin
            full_cyc <= 0; pushdec_cyc <= 0; ovf_cyc <= 0; first_ovf_t <= 0;
        end else begin
            if (u_app.txf_full) full_cyc <= full_cyc + 1;
            if (u_app.txf_wr) pushdec_cyc <= pushdec_cyc + 1;
            if (u_app.txf_wr && u_app.txf_full) begin
                ovf_cyc <= ovf_cyc + 1;
                if (ovf_cyc == 0) first_ovf_t <= cyc;
            end
        end
    end

    initial begin
        clk = 0; rst_n = 0; i_en = 0; i_paylen = `PAYLEN;
        peer_wr = 0; peer_mac = 48'h112233445566; peer_ip = 32'hC0A86401;
        sum_p = 0; sum_w = 0; k = 0; n = 0; DBG = 1'b1;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);
        peer_wr = 1; @(posedge clk); peer_wr = 0;     // peer 表写 1 拍
        i_en = 1;
        while (k < 35 && cyc < `MAXCYC) @(posedge clk);
        repeat (2) @(posedge clk);      // 让仪器的非阻塞更新落地 (坑 17 同族: 别读陈旧值)
        n = k;
        $display("--- tb_app_udp_rate: TXGAP=%0d paylen=%0d ---", `TXGAP, `PAYLEN);
        $display("  frames on wire      = %0d (period samples %0d)", npre, n);
        if (n > 0) begin
            $display("  mean frame period   = %0d cycles (%0.3f us)",
                     sum_p/n, (sum_p/n) * 8.0 / 1000.0);
            $display("  mean wire len       = %0d B", sum_w/n);
            $display("  PAYLOAD RATE        = %0.1f Mbps",
                     (`PAYLEN * 8.0) / ((sum_p/n) * 8.0e-9) / 1e6);
            $display("  WIRE RATE           = %0.1f Mbps",
                     ((sum_w * 1.0/n) * 8.0) / ((sum_p/n) * 8.0e-9) / 1e6);
        end
        $display("  app tx_frames=%0d bytes=%0d | utx frames=%0d bytes=%0d drop=%0d | mac frames=%0d abort=%0d",
                 a_tx_frames, a_tx_bytes, utx_frames, utx_bytes, utx_drop,
                 mac_frames, mac_abort);

        //=====================================================================
        // P7B-W9 判据 (口径见文件头) —— 三条, 互为独立观测点:
        //   C1 (主判据, 逐拍、非采样): `txf_wr && txf_full` 必须 0 拍。
        //       这是不变式 "stat_tx_bytes 增量 == 真落进 TX 字 FIFO 的字节数" 的**逐字**形式:
        //       落笔拍已满 ⇒ 这笔推入被静默丢弃。无假阳性 (合法填满那拍 full=0)。
        //   C2 帧器逐帧长度 == `FRM_EXP` 且 min==max   (帧器输出口)
        //   C3 线上逐帧长度 == `WIRE_EXP` 且 min==max  (mac_tx 的 gmii_tx_en, 与 C2 不同观测点)
        //       C2/C3 是"帧几何恒等于意图几何 + 帧长集合单元素"的落地; 相邻错值 (每帧 -8 B)
        //       会让绝对值与单元素两条同时失败。
        //   COV 覆盖率见证: 饱和模态下 `full_cyc` 必须 >= `SATFLOOR`。
        //       ⚠️ 诚实标注: 该见证是**必要非充分**条件 —— 实测默认档 (1 B/拍 + g0)
        //       也能把 FIFO 顶满 (full_cyc=3640) 而**不丢字** (相位锁定) ⇒ 它只能证伪
        //       "激励够不到饱和", 不能替 C1 担保。C1/C2/C3 才是判据本体。
        //=====================================================================
        gate_errs = 0;
        $display("  --- P7B-W9 判据 ---");
        $display("  C1 contract: txf_wr && txf_full on %0d cycles (first @cyc %0d); checked pushes=%0d",
                 ovf_cyc, first_ovf_t, pushdec_cyc);
        $display("  C2 framer frames=%0d len min/max = %0d/%0d (exp %0d)", f_n, f_min, f_max, `FRM_EXP);
        $display("  C3 wire   samples=%0d len min/max = %0d/%0d (exp %0d)", n, w_min, w_max, `WIRE_EXP);
        $display("  coverage: full_cyc=%0d (satreq=%0d floor %0d)", full_cyc, SATREQ, `SATFLOOR);
        if (ovf_cyc != 0) begin
            gate_errs = gate_errs + 1;
            $display("  [CONTRACT FAIL] %0d armed push(es) landed on a FULL TX word FIFO (first @cyc %0d)",
                     ovf_cyc, first_ovf_t);
            $display("                  => that many words were counted in stat_tx_bytes/seg_sent but NOT written");
        end
        if (f_n == 0) begin
            gate_errs = gate_errs + 1; $display("  [GEOM FAIL] no framer frame observed");
        end else begin
            if (f_min != `FRM_EXP) begin gate_errs = gate_errs + 1;
                $display("  [GEOM FAIL] framer len min %0d != exp %0d (short by %0d)",
                         f_min, `FRM_EXP, `FRM_EXP - f_min); end
            if (f_max != f_min) begin gate_errs = gate_errs + 1;
                $display("  [GEOM FAIL] framer len NOT a singleton: min %0d max %0d", f_min, f_max); end
        end
        if (n == 0) begin
            gate_errs = gate_errs + 1; $display("  [GEOM FAIL] no wire frame sample");
        end else begin
            if (w_min != `WIRE_EXP) begin gate_errs = gate_errs + 1;
                $display("  [GEOM FAIL] wire len min %0d != exp %0d (short by %0d)",
                         w_min, `WIRE_EXP, `WIRE_EXP - w_min); end
            if (w_max != w_min) begin gate_errs = gate_errs + 1;
                $display("  [GEOM FAIL] wire len NOT a singleton: min %0d max %0d", w_min, w_max); end
        end
        if (SATREQ && full_cyc < `SATFLOOR) begin
            gate_errs = gate_errs + 1;
            $display("  [COV FAIL] FIFO never saturated (full_cyc=%0d < %0d) => GEOM criteria are VACUOUS here",
                     full_cyc, `SATFLOOR);
        end
        if (gate_errs == 0)
            $display("RATE GATE: OK (C1 ovf=0 over %0d pushes; framer %0d x%0d; wire %0d x%0d; full_cyc=%0d)",
                     pushdec_cyc, `FRM_EXP, f_n, `WIRE_EXP, n, full_cyc);
        else
            $display("RATE GATE: FAIL errs=%0d", gate_errs);
        $display("RATE TB DONE");
        $finish;
    end
endmodule
