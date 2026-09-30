`timescale 1ns/1ps
// ===========================================================================
// tb_app8_equiv.v —— P7B app 8 字节/拍改造的**逐字节等价门** (自检式, 无 Python)
// ---------------------------------------------------------------------------
// 同一个 TB 用两种宏编译 (bat 里切), 两次的输出文件逐字节 diff:
//     A) 无宏        = 改造前的 RTL (逐字节路径)
//     B) -d P7B_10G  = 8 字节/拍路径
// ⇒ 判据 "改造前后在同一激励下逐字节相同" 是**文件对比**, 不是计数器对比。
//
// 配置覆盖 (T0..T6 只发不收, 把载荷字节流 + 每帧字节数 dump 到文件):
//   T0 paylen 1472 TX_BYTES 0     GAP 0   ← 板级同构 (1472 = 184*8, 背靠背)
//   T1 paylen 1477 TX_BYTES 0     GAP 0   ← 非 8 倍数 (1477 = 184*8 + 5)
//   T2 paylen    5 TX_BYTES 0     GAP 0   ← 全尾字 (< 8)
//   T3 paylen    8 TX_BYTES 0     GAP 0   ← 恰一个满字
//   T4 paylen 1501 TX_BYTES 0     GAP 0   ← > PLEN_MAX(1500): LFSR 冻结 + 0xA5 填充
//   T5 paylen 1472 TX_BYTES 4419  GAP 0   ← 有限会话: 1472 + 2947 (末帧非 8 倍数;
//                                          帧长按既有 remain>=4096 语义回落, 已实测)
//   T6 paylen 1472 TX_BYTES 0     GAP 7   ← 帧间限速 (与 T0 的背靠背互为对照)
// 回环 (TX 直连 RX, 同一实例):
//   L0 paylen 1472 / L1 paylen 1477  ⇒ stat_mismatch==0 且 stat_rx_bytes==stat_tx_bytes
// 注入式 RX 自检 (TB 用自己的**顺序模型**造帧):
//   R0 = 12 帧 (含 0 长帧) + 第 5 帧第 2 字 lane1 翻一位 ⇒ 失配**恰 1**
//   R1 = 满字 lane7 翻一位 (必须抓) + 尾字**无效 lane**翻一位 (必须不抓) ⇒ **恰 1**
// 反例 (由 bat 驱动): 把 RTL 的 M^8 退化成 M ⇒ 本门的文件 diff **必须变红**。
// ===========================================================================
module tb_app8_equiv;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                 // 6.4 ns = 156.25 MHz

    localparam integer CAP = 12000;         // 每配置最多 dump 的**载荷字节数**
    localparam integer CY_MAIN = 45000;     // 主窗口 (dump 阶段)
    localparam integer CY_TOT  = 80000;     // 总预算 (回环排空 + 检查)
    localparam [63:0]  SEED = 64'h9E3779B97F4A7C15;

    // -----------------------------------------------------------------------
    // peer.cpp 合同里的顺序模型 (先取后推进) —— 本 TB 的**独立参照**
    // -----------------------------------------------------------------------
    reg [63:0] mlfsr;
    function [63:0] xs_next;
        input [63:0] s;  reg [63:0] t;
        begin t = s ^ (s << 13); t = t ^ (t >> 7); t = t ^ (t << 17); xs_next = t; end
    endfunction
    function [3:0] pop8;
        input [7:0] v;  integer i;  reg [3:0] c;
        begin c = 4'd0; for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]}; pop8 = c; end
    endfunction
    function [7:0] byte_at;
        input [63:0] d; input [3:0] i;
        begin
            case (i)
                4'd0: byte_at = d[63:56];  4'd1: byte_at = d[55:48];
                4'd2: byte_at = d[47:40];  4'd3: byte_at = d[39:32];
                4'd4: byte_at = d[31:24];  4'd5: byte_at = d[23:16];
                4'd6: byte_at = d[15:8];   default: byte_at = d[7:0];
            endcase
        end
    endfunction
    function [7:0] kmask;
        input [3:0] n;
        begin
            case (n)
                4'd0: kmask = 8'h00;  4'd1: kmask = 8'h80;  4'd2: kmask = 8'hC0;
                4'd3: kmask = 8'hE0;  4'd4: kmask = 8'hF0;  4'd5: kmask = 8'hF8;
                4'd6: kmask = 8'hFC;  4'd7: kmask = 8'hFE;  default: kmask = 8'hFF;
            endcase
        end
    endfunction
    function [63:0] ljust8;
        input [63:0] s; input [3:0] n;
        begin
            case (n)
                4'd1: ljust8 = {s[7:0],   56'b0};
                4'd2: ljust8 = {s[15:0],  48'b0};
                4'd3: ljust8 = {s[23:0],  40'b0};
                4'd4: ljust8 = {s[31:0],  32'b0};
                4'd5: ljust8 = {s[39:0],  24'b0};
                4'd6: ljust8 = {s[47:0],  16'b0};
                4'd7: ljust8 = {s[55:0],   8'b0};
                default: ljust8 = s;
            endcase
        end
    endfunction

    // -----------------------------------------------------------------------
    // 背压: 每实例一个 LFSR, tready = !(bp[3:0]==0) ⇒ ~6% 拍拉低 (真实停顿)
    // -----------------------------------------------------------------------
    reg [15:0] bp0, bp1, bp2, bp3, bp4, bp5, bp6;
    wire rdy0 = (bp0[3:0] != 4'h0);
    wire rdy1 = (bp1[3:0] != 4'h0);
    wire rdy2 = (bp2[3:0] != 4'h0);
    wire rdy3 = (bp3[3:0] != 4'h0);
    wire rdy4 = (bp4[3:0] != 4'h0);
    wire rdy5 = (bp5[3:0] != 4'h0);
    wire rdy6 = (bp6[3:0] != 4'h0);
    always @(posedge clk) if (!rst_n) begin
        bp0 <= 16'hACE1; bp1 <= 16'h1234; bp2 <= 16'hF00D; bp3 <= 16'h55AA;
        bp4 <= 16'h9E37; bp5 <= 16'hBEEF; bp6 <= 16'hC0DE;
    end else begin
        bp0 <= {bp0[14:0], bp0[15]^bp0[13]^bp0[12]^bp0[10]};
        bp1 <= {bp1[14:0], bp1[15]^bp1[14]^bp1[12]^bp1[11]};
        bp2 <= {bp2[14:0], bp2[15]^bp2[11]^bp2[10]^bp2[9]};
        bp3 <= {bp3[14:0], bp3[15]^bp3[13]^bp3[9]^bp3[6]};
        bp4 <= {bp4[14:0], bp4[15]^bp4[12]^bp4[8]^bp4[5]};
        bp5 <= {bp5[14:0], bp5[15]^bp5[14]^bp5[9]^bp5[7]};
        bp6 <= {bp6[14:0], bp6[15]^bp6[13]^bp6[8]^bp6[4]};
    end

    // -----------------------------------------------------------------------
    // 7 个 TX-only 实例 (i_tx_ready=1: peer 已学习; i_en=1)
    // -----------------------------------------------------------------------
    wire [63:0] td0,td1,td2,td3,td4,td5,td6;
    wire [7:0]  tk0,tk1,tk2,tk3,tk4,tk5,tk6;
    wire        tv0,tv1,tv2,tv3,tv4,tv5,tv6, tl0,tl1,tl2,tl3,tl4,tl5,tl6;
    wire [31:0] tb0,tb1,tb2,tb3,tb4,tb5,tb6;      // stat_tx_bytes
    wire [31:0] tf0,tf1,tf2,tf3,tf4,tf5,tf6;      // stat_tx_frames
    wire        u_t5_dn;                         // T5 的 done (会话收尾)
    wire [31:0] u_dsi, u_ds1, u_ds2, u_dsg, u_dsd, u_dso0, u_dso1, u_dso2, u_dso3;
    wire [7:0]  u_dsg1, u_dse, u_dsp;  wire u_dsv;
    wire [63:0] u_dgw, u_dew;

    app_udp_pattern #(.TX_BYTES(32'd0),    .TX_GAP(16'd0), .PLEN_MAX(12'd1500)) u_t0 (
        .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_tx_ready(1'b1), .i_paylen(12'd1472),
        .m_tdata(td0), .m_tkeep(tk0), .m_tvalid(tv0), .m_tready(rdy0), .m_tlast(tl0),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(tb0), .stat_tx_frames(tf0), .stat_rx_bytes(), .stat_rx_frames(),
        .stat_rx_null(), .stat_mismatch(), .active(), .done(), .led(),
        .ds_idx(u_dsi), .ds_b1(u_ds1), .ds_b2(u_ds2), .ds_bg(u_dsg), .ds_dup(u_dsd),
        .ds_got(u_dsg1), .ds_exp(u_dse), .ds_prev(u_dsp), .ds_v(u_dsv),
        .ds_gw(u_dgw), .ds_ew(u_dew),
        .ds_oz(u_dso0), .ds_ol(u_dso1), .ds_om(u_dso2), .ds_oh(u_dso3)
    );
    app_udp_pattern #(.TX_BYTES(32'd0),    .TX_GAP(16'd0), .PLEN_MAX(12'd1500)) u_t1 (
        .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_tx_ready(1'b1), .i_paylen(12'd1477),
        .m_tdata(td1), .m_tkeep(tk1), .m_tvalid(tv1), .m_tready(rdy1), .m_tlast(tl1),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(tb1), .stat_tx_frames(tf1), .stat_rx_bytes(), .stat_rx_frames(),
        .stat_rx_null(), .stat_mismatch(), .active(), .done(), .led(),
        .ds_idx(), .ds_b1(), .ds_b2(), .ds_bg(), .ds_dup(),
        .ds_got(), .ds_exp(), .ds_prev(), .ds_v(),
        .ds_gw(), .ds_ew(), .ds_oz(), .ds_ol(), .ds_om(), .ds_oh()
    );
    app_udp_pattern #(.TX_BYTES(32'd0),    .TX_GAP(16'd0), .PLEN_MAX(12'd1500)) u_t2 (
        .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_tx_ready(1'b1), .i_paylen(12'd5),
        .m_tdata(td2), .m_tkeep(tk2), .m_tvalid(tv2), .m_tready(rdy2), .m_tlast(tl2),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(tb2), .stat_tx_frames(tf2), .stat_rx_bytes(), .stat_rx_frames(),
        .stat_rx_null(), .stat_mismatch(), .active(), .done(), .led(),
        .ds_idx(), .ds_b1(), .ds_b2(), .ds_bg(), .ds_dup(),
        .ds_got(), .ds_exp(), .ds_prev(), .ds_v(),
        .ds_gw(), .ds_ew(), .ds_oz(), .ds_ol(), .ds_om(), .ds_oh()
    );
    app_udp_pattern #(.TX_BYTES(32'd0),    .TX_GAP(16'd0), .PLEN_MAX(12'd1500)) u_t3 (
        .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_tx_ready(1'b1), .i_paylen(12'd8),
        .m_tdata(td3), .m_tkeep(tk3), .m_tvalid(tv3), .m_tready(rdy3), .m_tlast(tl3),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(tb3), .stat_tx_frames(tf3), .stat_rx_bytes(), .stat_rx_frames(),
        .stat_rx_null(), .stat_mismatch(), .active(), .done(), .led(),
        .ds_idx(), .ds_b1(), .ds_b2(), .ds_bg(), .ds_dup(),
        .ds_got(), .ds_exp(), .ds_prev(), .ds_v(),
        .ds_gw(), .ds_ew(), .ds_oz(), .ds_ol(), .ds_om(), .ds_oh()
    );
    app_udp_pattern #(.TX_BYTES(32'd0),    .TX_GAP(16'd0), .PLEN_MAX(12'd1500)) u_t4 (
        .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_tx_ready(1'b1), .i_paylen(12'd1501),
        .m_tdata(td4), .m_tkeep(tk4), .m_tvalid(tv4), .m_tready(rdy4), .m_tlast(tl4),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(tb4), .stat_tx_frames(tf4), .stat_rx_bytes(), .stat_rx_frames(),
        .stat_rx_null(), .stat_mismatch(), .active(), .done(), .led(),
        .ds_idx(), .ds_b1(), .ds_b2(), .ds_bg(), .ds_dup(),
        .ds_got(), .ds_exp(), .ds_prev(), .ds_v(),
        .ds_gw(), .ds_ew(), .ds_oz(), .ds_ol(), .ds_om(), .ds_oh()
    );
    app_udp_pattern #(.TX_BYTES(32'd4419), .TX_GAP(16'd0), .PLEN_MAX(12'd1500)) u_t5 (
        .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_tx_ready(1'b1), .i_paylen(12'd1472),
        .m_tdata(td5), .m_tkeep(tk5), .m_tvalid(tv5), .m_tready(rdy5), .m_tlast(tl5),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(tb5), .stat_tx_frames(tf5), .stat_rx_bytes(), .stat_rx_frames(),
        .stat_rx_null(), .stat_mismatch(), .active(), .done(u_t5_dn), .led(),
        .ds_idx(), .ds_b1(), .ds_b2(), .ds_bg(), .ds_dup(),
        .ds_got(), .ds_exp(), .ds_prev(), .ds_v(),
        .ds_gw(), .ds_ew(), .ds_oz(), .ds_ol(), .ds_om(), .ds_oh()
    );
    app_udp_pattern #(.TX_BYTES(32'd0),    .TX_GAP(16'd7), .PLEN_MAX(12'd1500)) u_t6 (
        .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_tx_ready(1'b1), .i_paylen(12'd1472),
        .m_tdata(td6), .m_tkeep(tk6), .m_tvalid(tv6), .m_tready(rdy6), .m_tlast(tl6),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(tb6), .stat_tx_frames(tf6), .stat_rx_bytes(), .stat_rx_frames(),
        .stat_rx_null(), .stat_mismatch(), .active(), .done(), .led(),
        .ds_idx(), .ds_b1(), .ds_b2(), .ds_bg(), .ds_dup(),
        .ds_got(), .ds_exp(), .ds_prev(), .ds_v(),
        .ds_gw(), .ds_ew(), .ds_oz(), .ds_ol(), .ds_om(), .ds_oh()
    );

    // -----------------------------------------------------------------------
    // 回环: TX 直连 RX (同一实例)
    // -----------------------------------------------------------------------
    reg  l0_ready, l1_ready;
    wire [63:0] ld0, ld1;  wire [7:0] lk0, lk1;
    wire        lv0, lv1, lt0, lt1, lr0, lr1;
    wire [31:0] l0_txb, l0_txf, l0_rxb, l0_rxf, l0_mm;
    wire [31:0] l1_txb, l1_txf, l1_rxb, l1_rxf, l1_mm;

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0), .PLEN_MAX(12'd1500)) u_l0 (
        .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_tx_ready(l0_ready), .i_paylen(12'd1472),
        .m_tdata(ld0), .m_tkeep(lk0), .m_tvalid(lv0), .m_tready(lr0), .m_tlast(lt0),
        .rx_tdata(ld0), .rx_tkeep(lk0), .rx_tvalid(lv0), .rx_tready(lr0),
        .rx_tlast(lt0), .rx_sof(1'b0), .rx_len(16'd1472),
        .stat_tx_bytes(l0_txb), .stat_tx_frames(l0_txf), .stat_rx_bytes(l0_rxb),
        .stat_rx_frames(l0_rxf), .stat_rx_null(), .stat_mismatch(l0_mm),
        .active(), .done(), .led(),
        .ds_idx(), .ds_b1(), .ds_b2(), .ds_bg(), .ds_dup(),
        .ds_got(), .ds_exp(), .ds_prev(), .ds_v(),
        .ds_gw(), .ds_ew(), .ds_oz(), .ds_ol(), .ds_om(), .ds_oh()
    );
    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0), .PLEN_MAX(12'd1500)) u_l1 (
        .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_tx_ready(l1_ready), .i_paylen(12'd1477),
        .m_tdata(ld1), .m_tkeep(lk1), .m_tvalid(lv1), .m_tready(lr1), .m_tlast(lt1),
        .rx_tdata(ld1), .rx_tkeep(lk1), .rx_tvalid(lv1), .rx_tready(lr1),
        .rx_tlast(lt1), .rx_sof(1'b0), .rx_len(16'd1477),
        .stat_tx_bytes(l1_txb), .stat_tx_frames(l1_txf), .stat_rx_bytes(l1_rxb),
        .stat_rx_frames(l1_rxf), .stat_rx_null(), .stat_mismatch(l1_mm),
        .active(), .done(), .led(),
        .ds_idx(), .ds_b1(), .ds_b2(), .ds_bg(), .ds_dup(),
        .ds_got(), .ds_exp(), .ds_prev(), .ds_v(),
        .ds_gw(), .ds_ew(), .ds_oz(), .ds_ol(), .ds_om(), .ds_oh()
    );

    // -----------------------------------------------------------------------
    // 注入式 RX 自检: 两个只收实例, 激励由 TB 的**顺序模型**造
    // -----------------------------------------------------------------------
    reg [63:0] q0_d [0:4095];  reg [7:0] q0_k [0:4095];  integer q0_n, q0_p;
    reg [63:0] q1_d [0:4095];  reg [7:0] q1_k [0:4095];  integer q1_n, q1_p;
    reg [4095:0] q0_sof_v;                       // 帧首字标记 (按字下标)
    reg [4095:0] q0_null_v;                      // 0 长帧标记 (rx_len 用)
    reg        q0_drive, q1_drive;
    reg [3:0]  gap0, gap1;
    wire       r0_tr, r1_tr, q0_sof;
    wire [31:0] r0_rxb, r0_rxf, r0_rxn, r0_mm;
    wire [31:0] r1_rxb, r1_rxf, r1_rxn, r1_mm;

    assign q0_sof = q0_sof_v[q0_p];
    wire [15:0] q0_len = q0_null_v[q0_p] ? 16'd0 : 16'd1472;   // 0 长帧边带

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0), .PLEN_MAX(12'd1500)) u_r0 (
        .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_tx_ready(1'b0), .i_paylen(12'd1472),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b1), .m_tlast(),
        .rx_tdata(q0_d[q0_p]), .rx_tkeep(q0_k[q0_p]), .rx_tvalid(q0_drive),
        .rx_tready(r0_tr), .rx_tlast(1'b0), .rx_sof(q0_sof), .rx_len(q0_len),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_rx_bytes(r0_rxb),
        .stat_rx_frames(r0_rxf), .stat_rx_null(r0_rxn), .stat_mismatch(r0_mm),
        .active(), .done(), .led(),
        .ds_idx(), .ds_b1(), .ds_b2(), .ds_bg(), .ds_dup(),
        .ds_got(), .ds_exp(), .ds_prev(), .ds_v(),
        .ds_gw(), .ds_ew(), .ds_oz(), .ds_ol(), .ds_om(), .ds_oh()
    );
    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0), .PLEN_MAX(12'd1500)) u_r1 (
        .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_tx_ready(1'b0), .i_paylen(12'd1472),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b1), .m_tlast(),
        .rx_tdata(q1_d[q1_p]), .rx_tkeep(q1_k[q1_p]), .rx_tvalid(q1_drive),
        .rx_tready(r1_tr), .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd1472),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_rx_bytes(r1_rxb),
        .stat_rx_frames(r1_rxf), .stat_rx_null(r1_rxn), .stat_mismatch(r1_mm),
        .active(), .done(), .led(),
        .ds_idx(), .ds_b1(), .ds_b2(), .ds_bg(), .ds_dup(),
        .ds_got(), .ds_exp(), .ds_prev(), .ds_v(),
        .ds_gw(), .ds_ew(), .ds_oz(), .ds_ol(), .ds_om(), .ds_oh()
    );

    // -----------------------------------------------------------------------
    // 造帧 (task: 从顺序模型取 len 字节; w=0 → R0 队列, w=1 → R1 队列)
    // -----------------------------------------------------------------------
    task q_frame;
        input  integer w;  input integer len;  output integer first;
        integer l, i;  reg [63:0] d;  reg [7:0] k;  reg [3:0] m;
        begin
            first = (w == 0) ? q0_n : q1_n;
            l = len;
            if (l == 0) begin
                if (w == 0) begin q0_d[q0_n]=64'd0; q0_k[q0_n]=8'h00; q0_sof_v[q0_n]=1'b1;
                                    q0_null_v[q0_n]=1'b1; q0_n=q0_n+1; end
                else        begin q1_d[q1_n]=64'd0; q1_k[q1_n]=8'h00; q1_n=q1_n+1; end
            end else while (l > 0) begin
                m = (l >= 8) ? 4'd8 : l[3:0];
                d = 64'd0;
                for (i = 0; i < m; i = i + 1) begin
                    d = {d[55:0], mlfsr[31:24]};
                    mlfsr = xs_next(mlfsr);
                end
                if (m != 4'd8) d = ljust8(d, m);
                if (w == 0) begin q0_d[q0_n]=d; q0_k[q0_n]=kmask(m); q0_sof_v[q0_n]=(l==len); q0_n=q0_n+1; end
                else        begin q1_d[q1_n]=d; q1_k[q1_n]=kmask(m); q1_n=q1_n+1; end
                l = l - m;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // dump: 每帧字节数 (.frm) + 载荷字节 (.hex, 每 32 字节一行)
    // -----------------------------------------------------------------------
    integer dfd [0:6], ffd [0:6];
    integer dcount [0:6], fcount [0:6], fcur [0:6];
    integer frec [0:6];                  // 已写入 .frm 的帧数 (只记覆盖前 CAP 字节的帧)
    reg     ffull [0:6];                 // 该配置的 .frm 已收口

    task do_dump;
        input integer idx;  input [63:0] d;  input [7:0] k;  input last;
        integer i, n;  reg [7:0] b;
        begin
            n = pop8(k);
            for (i = 0; i < n; i = i + 1) begin
                if (dcount[idx] < CAP) begin
                    b = byte_at(d, i[3:0]);
                    $fwrite(dfd[idx], "%02x", b);
                    dcount[idx] = dcount[idx] + 1;
                    if ((dcount[idx] % 32) == 0) $fwrite(dfd[idx], "\n");
                end
                fcur[idx] = fcur[idx] + 1;
            end
            if (last) begin
                // 只记录「覆盖前 CAP 字节」的那些帧 —— 此后跑完的帧数是**时序量**
                // (与 8 字节/拍这件事同源), 不是设计判据。
                if (!ffull[idx]) begin
                    $fwrite(ffd[idx], "%0d\n", fcur[idx]);  // 本帧载荷字节数
                    frec[idx] = frec[idx] + 1;
                    if (dcount[idx] >= CAP) ffull[idx] = 1'b1;
                end
                fcount[idx] = fcount[idx] + 1;
                fcur[idx]   = 0;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            if (tv0 && rdy0) do_dump(0, td0, tk0, tl0);
            if (tv1 && rdy1) do_dump(1, td1, tk1, tl1);
            if (tv2 && rdy2) do_dump(2, td2, tk2, tl2);
            if (tv3 && rdy3) do_dump(3, td3, tk3, tl3);
            if (tv4 && rdy4) do_dump(4, td4, tk4, tl4);
            if (tv5 && rdy5) do_dump(5, td5, tk5, tl5);
            if (tv6 && rdy6) do_dump(6, td6, tk6, tl6);
        end
    end

    // -----------------------------------------------------------------------
    // 检查累加
    // -----------------------------------------------------------------------
    integer errs;
    task chk;
        input cond;  input [1023:0] msg;
        begin
            if (!cond) begin errs = errs + 1; $display("  [FAIL] %0s", msg); end
            else         $display("  [ ok ] %0s", msg);
        end
    endtask

    integer i, j, fs;
    integer exp_bytes0, exp_bytes1;

    // -----------------------------------------------------------------------
    // 造好的队列按带间隙的 AXIS 驱动 (两个独立 always; rdy 拉低时保持 valid)
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            q0_drive <= 1'b0;  gap0 <= 4'd0;
        end else if (q0_p < q0_n) begin
            if (q0_drive) begin
                // 只有**真握手** (本拍 valid=1 && ready=1) 才推进; 否则保持 valid 不动
                if (r0_tr) begin q0_p <= q0_p + 1; q0_drive <= 1'b0; gap0 <= 4'd3; end
            end else if (gap0 != 4'd0) begin
                gap0 <= gap0 - 4'd1;
            end else begin
                q0_drive <= 1'b1;
            end
        end else begin
            q0_drive <= 1'b0;
        end
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            q1_drive <= 1'b0;  gap1 <= 4'd0;
        end else if (q1_p < q1_n) begin
            if (q1_drive) begin
                if (r1_tr) begin q1_p <= q1_p + 1; q1_drive <= 1'b0; gap1 <= 4'd2; end
            end else if (gap1 != 4'd0) begin
                gap1 <= gap1 - 4'd1;
            end else begin
                q1_drive <= 1'b1;
            end
        end else begin
            q1_drive <= 1'b0;
        end
    end

    initial begin
        errs = 0;
        rst_n = 1'b0;
        q0_n = 0; q0_p = 0; q1_n = 0; q1_p = 0;
        q0_drive = 1'b0; q1_drive = 1'b0; gap0 = 4'd0; gap1 = 4'd0;
        q0_sof_v = 4096'b0;  q0_null_v = 4096'b0;
        for (i = 0; i < 7; i = i + 1) begin
            dcount[i] = 0; fcount[i] = 0; fcur[i] = 0; frec[i] = 0; ffull[i] = 1'b0;
        end
        dfd[0] = $fopen("dump_T0.hex", "w");  ffd[0] = $fopen("dump_T0.frm", "w");
        dfd[1] = $fopen("dump_T1.hex", "w");  ffd[1] = $fopen("dump_T1.frm", "w");
        dfd[2] = $fopen("dump_T2.hex", "w");  ffd[2] = $fopen("dump_T2.frm", "w");
        dfd[3] = $fopen("dump_T3.hex", "w");  ffd[3] = $fopen("dump_T3.frm", "w");
        dfd[4] = $fopen("dump_T4.hex", "w");  ffd[4] = $fopen("dump_T4.frm", "w");
        dfd[5] = $fopen("dump_T5.hex", "w");  ffd[5] = $fopen("dump_T5.frm", "w");
        dfd[6] = $fopen("dump_T6.hex", "w");  ffd[6] = $fopen("dump_T6.frm", "w");

        // ---- R0 激励: 12 帧 (含 0 长帧), 第 5 帧 (len 1472) 第 2 字 lane1 翻一位 ----
        mlfsr = SEED;
        exp_bytes0 = 0;
        q_frame(0,    8, fs);  exp_bytes0 = exp_bytes0 +    8;
        q_frame(0, 1472, fs);  exp_bytes0 = exp_bytes0 + 1472;
        q_frame(0, 1477, fs);  exp_bytes0 = exp_bytes0 + 1477;
        q_frame(0,    1, fs);  exp_bytes0 = exp_bytes0 +    1;
        q_frame(0, 1472, fs);  exp_bytes0 = exp_bytes0 + 1472;   // j=4 ← 本帧被注入
        $display("  [info] R0 注入 q=%0d lane1 bit0 (满字)", fs + 1);
        q0_d[fs + 1] = q0_d[fs + 1] ^ 64'h0000_0100_0000_0000;
        q_frame(0,    0, fs);  exp_bytes0 = exp_bytes0 +    0;   // 0 长帧
        q_frame(0,   16, fs);  exp_bytes0 = exp_bytes0 +   16;
        q_frame(0, 1499, fs);  exp_bytes0 = exp_bytes0 + 1499;
        q_frame(0,    8, fs);  exp_bytes0 = exp_bytes0 +    8;
        q_frame(0, 1472, fs);  exp_bytes0 = exp_bytes0 + 1472;
        q_frame(0,    5, fs);  exp_bytes0 = exp_bytes0 +    5;
        q_frame(0, 1477, fs);  exp_bytes0 = exp_bytes0 + 1477;

        // ---- R1 激励: 满字 lane7 翻一位 (必须抓) + 尾字无效 lane 翻一位 (必须不抓) ----
        mlfsr = SEED;
        q_frame(1, 1472, fs);
        q1_d[fs + 2] = q1_d[fs + 2] ^ 64'h0000_0000_0000_0010;    // lane7 bit4 (满字)
        $display("  [info] R1 注入 q=%0d lane7 bit4 (满字, 必须抓)", fs + 2);
        exp_bytes1 = 1472;
        q_frame(1, 5, fs);
        q1_d[fs] = q1_d[fs] ^ 64'h0000_0000_0000_0010;            // lane7 超出 tkeep ⇒ 无效
        $display("  [info] R1 注入 q=%0d lane7 bit4 (尾字无效 lane, 必须不抓)", fs);
        exp_bytes1 = exp_bytes1 + 5;
        q_frame(1, 1472, fs);
        exp_bytes1 = exp_bytes1 + 1472;

        $display("--- tb_app8_equiv (CAP=%0d bytes/config, %0d cycles) ---", CAP, CY_TOT);

        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        l0_ready = 1'b1; l1_ready = 1'b1;

        // ---- 主窗口 ----
        repeat (CY_MAIN) @(posedge clk);

        // ---- 回环收尾: 停 TX (i_tx_ready 落), 让 FIFO 排空 ⇒ rxb == txb ----
        l0_ready = 1'b0; l1_ready = 1'b0;
        repeat (CY_TOT - CY_MAIN) @(posedge clk);

        // ================= 输出 =================
        for (i = 0; i < 7; i = i + 1) begin
            $fclose(dfd[i]);  $fclose(ffd[i]);
        end
        $display("  T0: txf=%0d txb=%0d | dump=%0d frm=%0d", tf0, tb0, dcount[0], frec[0]);
        $display("  T1: txf=%0d txb=%0d | dump=%0d frm=%0d", tf1, tb1, dcount[1], frec[1]);
        $display("  T2: txf=%0d txb=%0d | dump=%0d frm=%0d", tf2, tb2, dcount[2], frec[2]);
        $display("  T3: txf=%0d txb=%0d | dump=%0d frm=%0d", tf3, tb3, dcount[3], frec[3]);
        $display("  T4: txf=%0d txb=%0d | dump=%0d frm=%0d", tf4, tb4, dcount[4], frec[4]);
        $display("  T5: txf=%0d txb=%0d done=%0d | dump=%0d frm=%0d", tf5, tb5, u_t5_dn, dcount[5], frec[5]);
        $display("  T6: txf=%0d txb=%0d | dump=%0d frm=%0d", tf6, tb6, dcount[6], frec[6]);
        $display("  L0: txb=%0d rxb=%0d txf=%0d mm=%0d", l0_txb, l0_rxb, l0_txf, l0_mm);
        $display("  L1: txb=%0d rxb=%0d txf=%0d mm=%0d", l1_txb, l1_rxb, l1_txf, l1_mm);
        $display("  R0: rxb=%0d frames=%0d null=%0d mm=%0d (exp %0d / 12 / 1 / 1)",
                 r0_rxb, r0_rxf, r0_rxn, r0_mm, exp_bytes0);
        $display("  R1: rxb=%0d frames=%0d null=%0d mm=%0d (exp bytes %0d / mm 1; sof 恒 0 故帧数不判)",
                 r1_rxb, r1_rxf, r1_rxn, r1_mm, exp_bytes1);

        // ================= 判据 =================
        for (i = 0; i < 7; i = i + 1)
            if (i != 5) chk(dcount[i] == CAP, "dump 达上限 (字节流对比长度足够)");
        chk(dcount[5] == 4419, "T5 会话 dump == 4419 (有限会话全量落盘)");
        for (i = 0; i < 7; i = i + 1)
            if (i != 5) chk(frec[i] > 3, "帧数 > 3 (帧长序列可判)");
        chk(frec[5] == 2,    "T5 帧数 == 2 (1472 + 2947: 既有 remain>=4096 语义)");
        chk(u_t5_dn == 1'b1,      "T5 TX_BYTES 会话收尾 done=1");
        chk(tb5 == 32'd4419,      "T5 会话共 4419 字节 (逐字节精确)");
        chk(l0_mm == 32'd0,       "L0 回环零失配 (1472B 满字路径)");
        chk(l0_rxb == l0_txb,     "L0 回环 rxb == txb (无丢字/无重字)");
        chk(l0_txb > 32'd10000,   "L0 回环确实跑了 (txb > 10000: A/B 速度本就不同)");
        chk(l1_mm == 32'd0,       "L1 回环零失配 (1477B 尾字路径)");
        chk(l1_rxb == l1_txb,     "L1 回环 rxb == txb");
        chk(r0_rxb == exp_bytes0, "R0 收字节数 == 注入字节数");
        chk(r0_rxf == 32'd12,     "R0 帧数 == 12 (含 0 长帧)");
        chk(r0_rxn == 32'd1,      "R0 计数到 1 个 0 长帧");
        chk(r0_mm  == 32'd1,      "R0 失配恰 1 (满字 lane1 翻位被抓)");
        chk(r1_rxb == exp_bytes1, "R1 收字节数 == 注入字节数");
        chk(r1_mm  == 32'd1,      "R1 失配恰 1 (满字 lane7 抓 / 尾字无效 lane 不抓)");

        if (errs == 0) $display("TB_APP8_EQUIV: OK");
        else           $display("TB_APP8_EQUIV: FAIL errs=%0d", errs);
        $display("TB8 DONE");
        $finish;
    end
endmodule
