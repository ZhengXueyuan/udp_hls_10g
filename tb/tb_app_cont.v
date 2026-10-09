`timescale 1ns/1ps
// ===========================================================================
// tb_app_cont.v -- P7B-LONGSEND: app_pattern 的 TX_CONTINUOUS (连续发送模式) 行为门
// ---------------------------------------------------------------------------
// 同一份 TB 源码, 四种编译方式 (bat 切宏); 见 sim/p7b_longsend/run_cont_gate.bat:
//   ARM A: 无宏                        -- 基线: 连续实例全走默认 (TX_CONTINUOUS=0)
//   ARM B: -d APP_CONT_ARM             -- 连续臂: A1..A6/A11/A12b 生效
//   ARM C: -d P7B_10G -d APP_CONT_ARM  -- 同上 + A2 整字预取路径 (Stage C)
//   ARM G: 无宏 + 冻结件                -- 与 ARM A 的全部 dump/stats 逐字节相同
//          (冻结件 = sim/p7b_stagec_tx_regress/frozen/app_pattern_rev0e804099.v,
//           即"改动前"的现役 rtl/app_pattern.v, sha256 0e804099...; 设计件 §4.3)
//   变异臂 M1..M4: -d APP_CONT_ARM + 变异件 (期望 RC != 0)
// ⚠️ ARM G 只给冻结件、**不给** rtl/app_pattern.v (同库双定义 = 编译失败)。
// ⚠️ 打印字符串一律 ASCII (xsim 写中文会变 0xFF)。
//
// 实例表 (NALL=10, 共享 clk/rst_n/全局 ev_up):
//   idx0 u_base      TX_CONTINUOUS(不写=默认0), 1000B, 1460, AC=1 -- 负对照 (A8) + A12a
//   idx1 u_cont      arm, 1000B  -- 量子=1 帧 => 重装载 3 次 (A1/A2/A3/A4/A5/A6/A12b)
//   idx2 u_cont_big  arm, 3000B  -- 量子=3 帧 (1460+1460+80) => 跨量子图案连续
//   idx3 u_cont_one  arm, 1B     -- 每帧 1 字节
//   idx4 u_zero_c    arm, 0B     -- 退化臂 (非法配置): 必须 = idx5
//   idx5 u_zero_d    (默认0), 0B -- 今天的"纯 RX/静默停滞"参考
//   idx6 u_txok      arm, 1000B, AC=0 -- 量子末边界投 tx_ok=0 => 逼 frm_wait 路径 (§1.5 陷阱)
//   idx7 u_rec1      arm, 1000B  -- ev_down(k=40)  + tready 低 300 拍 (滞留字)
//   idx8 u_rec2      arm, 1000B  -- ev_down(k=240) + tready 低 300 拍 (滞留字)
//   idx9 u_rec3      arm, 1000B  -- ev_down(k=240) + tready 低 6 拍 (收尾能完成: 对照)
//   ⭐ 构建 E (A3): rec1/rec2 由"只记录"升级为**判据** (starts_after_up >= 1);
//      修前这两臂 = 0 (ev_up 被吞 ⇒ 新连接静默零数据), 修后必须 >= 1。
// ===========================================================================
module tb_app_cont;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                       // 6.4 ns = 156.25 MHz

    localparam [63:0] SEED = 64'h9E3779B97F4A7C15;
    localparam integer NALL   = 10;
    localparam integer CY_TOT = 40000;
    localparam integer REC_DNK = 20;              // ev_down 落在第 20 个 payload beat
    localparam integer K1 = 40,  TW1 = 300;       // u_rec1: k / tready 低窗 (拍)
    localparam integer K2 = 240, TW2 = 300;       // u_rec2
    localparam integer K3 = 240, TW3 = 6;         // u_rec3

    // ---- 每实例参数表 (最左 = idx9, 最右 = idx0; 用 [gi*W +: W] 取) ----
    localparam [NALL*32-1:0] BYTTAB = {
        32'd1000, 32'd1000, 32'd1000,                         // 9 8 7 (rec)
        32'd1000,                                            // 6 u_txok
        32'd0,                                               // 5 u_zero_d
        32'd0,                                               // 4 u_zero_c
        32'd1,                                               // 3 u_cont_one
        32'd3000,                                            // 2 u_cont_big
        32'd1000,                                            // 1 u_cont
        32'd1000 };                                          // 0 u_base
    localparam [NALL*12-1:0] SEGTAB = { NALL{12'd1460} };
    // 本构建里该实例是否连续模式 (ARM A 全 0: 连续实例全走默认值)
`ifdef APP_CONT_ARM
    localparam [NALL*2-1:0] CTAB = {
        2'd1, 2'd1, 2'd1,                                    // 9 8 7
        2'd1,                                                // 6
        2'd0,                                                // 5 (未传参数)
        2'd1,                                                // 4
        2'd1, 2'd1, 2'd1,                                    // 3 2 1
        2'd0 };                                              // 0 (未传参数)
`else
    localparam [NALL*2-1:0] CTAB = { NALL{2'b00} };
`endif
    // 参与"帧长 = min(SEG, 量子剩余)"模型的实例 (重连臂/零臂不参与)
    localparam [NALL*2-1:0] LOKTAB = {
        2'd0, 2'd0, 2'd0,                                    // 9 8 7
        2'd1,                                                // 6 u_txok
        2'd0, 2'd0,                                          // 5 4 zero
        2'd1, 2'd1, 2'd1,                                    // 3 2 1
        2'd1 };                                              // 0 u_base

    // ---------------- TB 侧图案模型 (与 app / peer 同一递推) ----------------
    function [63:0] xs_next;
        input [63:0] s;  reg [63:0] t;
        begin t = s ^ (s << 13); t = t ^ (t >> 7); t = t ^ (t << 17); xs_next = t; end
    endfunction

    function [3:0] pop8v;
        input [7:0] x;
        integer q;
        begin q = 0; if (x[0]) q = q + 1; if (x[1]) q = q + 1; if (x[2]) q = q + 1;
              if (x[3]) q = q + 1; if (x[4]) q = q + 1; if (x[5]) q = q + 1;
              if (x[6]) q = q + 1; if (x[7]) q = q + 1; pop8v = q[3:0];
        end
    endfunction

    // ---------------- 实例端口阵列 ----------------
    wire [63:0] w_d [0:NALL-1];
    wire [7:0]  w_k [0:NALL-1];
    wire        w_v [0:NALL-1];
    wire        w_l [0:NALL-1];
    wire [3:0]  w_tid [0:NALL-1];
    wire [31:0] w_txb [0:NALL-1], w_txf [0:NALL-1], w_badf [0:NALL-1];
    wire [31:0] w_rxb [0:NALL-1], w_mm [0:NALL-1];
    wire        w_done [0:NALL-1], w_act [0:NALL-1], w_cr [0:NALL-1];

    // ---------------- 全局起始脉冲 (所有实例同一拍) ----------------
    reg [1:0] est;
    always @(posedge clk) if (!rst_n) est <= 2'd0;
    else est <= (est == 2'd3) ? 2'd3 : (est + 2'd1);
    wire up_glob = (est == 2'd1);

    // ---------------- m_tready: 默认全 1; rec 臂有拉低窗口 ----------------
    // (声明在前, 赋值块在事件向量之后 —— 赋值要用 dn7/8/9)
    reg [NALL-1:0] rdy_r;
    reg r1tlow, r2tlow, r3tlow;                   // 拉低窗口标志 (寄存器)
    wire [NALL-1:0] rdy = rdy_r;

    // ---------------- u_rec1/2/3: ev_down -> k 拍 -> 同槽 ev_up ----------------
    // payload beat = (tvalid && tready && tkeep != 0), 与 tb_app_a2_equiv 同口径。
    reg [15:0] r1n, r1t; reg r1dn;
    reg [15:0] r2n, r2t; reg r2dn;
    reg [15:0] r3n, r3t; reg r3dn;
    wire hv7 = w_v[7] && rdy[7] && (w_k[7] != 8'h00);
    wire hv8 = w_v[8] && rdy[8] && (w_k[8] != 8'h00);
    wire hv9 = w_v[9] && rdy[9] && (w_k[9] != 8'h00);
    wire dn7 = (r1n == REC_DNK) && hv7 && !r1dn;
    wire dn8 = (r2n == REC_DNK) && hv8 && !r2dn;
    wire dn9 = (r3n == REC_DNK) && hv9 && !r3dn;
    wire up7 = r1dn && (r1t == K1);
    wire up8 = r2dn && (r2t == K2);
    wire up9 = r3dn && (r3t == K3);
    always @(posedge clk) if (!rst_n) begin
        r1n <= 16'd0; r1t <= 16'd0; r1dn <= 1'b0; r1tlow <= 1'b0;
        r2n <= 16'd0; r2t <= 16'd0; r2dn <= 1'b0; r2tlow <= 1'b0;
        r3n <= 16'd0; r3t <= 16'd0; r3dn <= 1'b0; r3tlow <= 1'b0;
    end else begin
        if (hv7) r1n <= r1n + 16'd1;
        if (dn7) begin r1dn <= 1'b1; r1tlow <= 1'b1; end
        else if (r1dn) begin
            r1t <= r1t + 16'd1;
            if (r1t == TW1) r1tlow <= 1'b0;
        end
        if (hv8) r2n <= r2n + 16'd1;
        if (dn8) begin r2dn <= 1'b1; r2tlow <= 1'b1; end
        else if (r2dn) begin
            r2t <= r2t + 16'd1;
            if (r2t == TW2) r2tlow <= 1'b0;
        end
        if (hv9) r3n <= r3n + 16'd1;
        if (dn9) begin r3dn <= 1'b1; r3tlow <= 1'b1; end
        else if (r3dn) begin
            r3t <= r3t + 16'd1;
            if (r3t == TW3) r3tlow <= 1'b0;
        end
    end

    // 事件向量 (其余实例只有全局 ev_up)
    wire [NALL-1:0] up_x = ({{(NALL-1){1'b0}}, up7} << 7) |
                           ({{(NALL-1){1'b0}}, up8} << 8) |
                           ({{(NALL-1){1'b0}}, up9} << 9);
    wire [NALL-1:0] dn_x = ({{(NALL-1){1'b0}}, dn7} << 7) |
                           ({{(NALL-1){1'b0}}, dn8} << 8) |
                           ({{(NALL-1){1'b0}}, dn9} << 9);
    wire [NALL-1:0] up_w = {NALL{up_glob}} | up_x;
    wire [NALL-1:0] dn_w = dn_x;

    always @(posedge clk) if (!rst_n) rdy_r <= {NALL{1'b1}};
    else begin
        rdy_r <= {NALL{1'b1}};
        // ⚠️ 拉低必须与 closing 同拍生效 (dn7 是组合脉冲): 否则 W3 收尾会在下拉生效
        //    前的一拍就用 m_tready=1 完成 => "收尾被 tready 卡住"这个条件根本不存在。
        rdy_r[7] <= ~(r1tlow | dn7);
        rdy_r[8] <= ~(r2tlow | dn8);
        rdy_r[9] <= ~(r3tlow | dn9);
    end

`ifdef APP_CONT_ARM
    // 连续模式参数 (只在本宏下展开; 未定义时逐字不出现 => 冻结件也能编译)
    `define APPC .TX_CONTINUOUS(1'b1),
`else
    `define APPC
`endif

    // ---------------- u_txok (idx6): 量子末边界投 tx_ok=0 (§1.5 陷阱臂) ----------------
    // 触发 = 该实例累计交付字节数到 TX_BYTES(1000) 的那一拍 => 下拍就是帧边界拍
    // (两个构建都是"最后一个字被消费的下一拍", 见设计件 §1.5 的逐拍论证)。
    reg [31:0] tok_nby;  reg tok_low;  reg [15:0] tok_t;  reg tok_seen;
    localparam integer TOK_HOLD = 60;
    wire tok_beat = w_v[6] && rdy[6];
    wire tok_full = tok_beat && ((tok_nby + {28'b0, pop8v(w_k[6])}) >= 32'd1000);
    wire tok_rdy  = ~tok_low;
    always @(posedge clk) if (!rst_n) begin
        tok_nby <= 32'd0; tok_low <= 1'b0; tok_t <= 16'd0; tok_seen <= 1'b0;
    end else begin
        if (up_w[6]) begin tok_nby <= 32'd0; tok_low <= 1'b0; tok_t <= 16'd0; end
        else begin
            if (tok_beat) tok_nby <= tok_nby + {28'b0, pop8v(w_k[6])};
            if (tok_full && !tok_low) begin tok_low <= 1'b1; tok_seen <= 1'b1; end
            else if (tok_low) begin
                tok_t <= tok_t + 16'd1;
                if (tok_t == TOK_HOLD) begin tok_low <= 1'b0; tok_t <= 16'd0; end
            end
        end
    end

    // ---------------- DUT 阵列 ----------------
    app_pattern #(.TX_BYTES(32'd1000), .TX_SEGSZ(12'd1460), .AUTO_CLOSE(1'b1)) u_base (
        .clk(clk), .rst_n(rst_n), .ev_up(up_w[0]), .ev_down(dn_w[0]), .ev_slot(4'd0),
        .m_tdata(w_d[0]), .m_tkeep(w_k[0]), .m_tvalid(w_v[0]), .m_tready(rdy[0]),
        .m_tlast(w_l[0]), .m_tid(w_tid[0]), .app_tx_ready(16'hFFFF),
        .close_req(w_cr[0]), .close_id(),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(w_txb[0]), .stat_tx_frames(w_txf[0]), .stat_bad_frames(w_badf[0]),
        .stat_rx_bytes(w_rxb[0]), .stat_mismatch(w_mm[0]),
        .active(w_act[0]), .act_id(), .done(w_done[0]), .dbg_lfsr(), .led()
    );
    app_pattern #(`APPC.TX_BYTES(32'd1000), .TX_SEGSZ(12'd1460), .AUTO_CLOSE(1'b1)) u_cont (
        .clk(clk), .rst_n(rst_n), .ev_up(up_w[1]), .ev_down(dn_w[1]), .ev_slot(4'd0),
        .m_tdata(w_d[1]), .m_tkeep(w_k[1]), .m_tvalid(w_v[1]), .m_tready(rdy[1]),
        .m_tlast(w_l[1]), .m_tid(w_tid[1]), .app_tx_ready(16'hFFFF),
        .close_req(w_cr[1]), .close_id(),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(w_txb[1]), .stat_tx_frames(w_txf[1]), .stat_bad_frames(w_badf[1]),
        .stat_rx_bytes(w_rxb[1]), .stat_mismatch(w_mm[1]),
        .active(w_act[1]), .act_id(), .done(w_done[1]), .dbg_lfsr(), .led()
    );
    app_pattern #(`APPC.TX_BYTES(32'd3000), .TX_SEGSZ(12'd1460), .AUTO_CLOSE(1'b1)) u_cont_big (
        .clk(clk), .rst_n(rst_n), .ev_up(up_w[2]), .ev_down(dn_w[2]), .ev_slot(4'd0),
        .m_tdata(w_d[2]), .m_tkeep(w_k[2]), .m_tvalid(w_v[2]), .m_tready(rdy[2]),
        .m_tlast(w_l[2]), .m_tid(w_tid[2]), .app_tx_ready(16'hFFFF),
        .close_req(w_cr[2]), .close_id(),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(w_txb[2]), .stat_tx_frames(w_txf[2]), .stat_bad_frames(w_badf[2]),
        .stat_rx_bytes(w_rxb[2]), .stat_mismatch(w_mm[2]),
        .active(w_act[2]), .act_id(), .done(w_done[2]), .dbg_lfsr(), .led()
    );
    app_pattern #(`APPC.TX_BYTES(32'd1), .TX_SEGSZ(12'd1460), .AUTO_CLOSE(1'b1)) u_cont_one (
        .clk(clk), .rst_n(rst_n), .ev_up(up_w[3]), .ev_down(dn_w[3]), .ev_slot(4'd0),
        .m_tdata(w_d[3]), .m_tkeep(w_k[3]), .m_tvalid(w_v[3]), .m_tready(rdy[3]),
        .m_tlast(w_l[3]), .m_tid(w_tid[3]), .app_tx_ready(16'hFFFF),
        .close_req(w_cr[3]), .close_id(),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(w_txb[3]), .stat_tx_frames(w_txf[3]), .stat_bad_frames(w_badf[3]),
        .stat_rx_bytes(w_rxb[3]), .stat_mismatch(w_mm[3]),
        .active(w_act[3]), .act_id(), .done(w_done[3]), .dbg_lfsr(), .led()
    );
    app_pattern #(`APPC.TX_BYTES(32'd0), .TX_SEGSZ(12'd1460), .AUTO_CLOSE(1'b1)) u_zero_c (
        .clk(clk), .rst_n(rst_n), .ev_up(up_w[4]), .ev_down(dn_w[4]), .ev_slot(4'd0),
        .m_tdata(w_d[4]), .m_tkeep(w_k[4]), .m_tvalid(w_v[4]), .m_tready(rdy[4]),
        .m_tlast(w_l[4]), .m_tid(w_tid[4]), .app_tx_ready(16'hFFFF),
        .close_req(w_cr[4]), .close_id(),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(w_txb[4]), .stat_tx_frames(w_txf[4]), .stat_bad_frames(w_badf[4]),
        .stat_rx_bytes(w_rxb[4]), .stat_mismatch(w_mm[4]),
        .active(w_act[4]), .act_id(), .done(w_done[4]), .dbg_lfsr(), .led()
    );
    app_pattern #(.TX_BYTES(32'd0), .TX_SEGSZ(12'd1460), .AUTO_CLOSE(1'b1)) u_zero_d (
        .clk(clk), .rst_n(rst_n), .ev_up(up_w[5]), .ev_down(dn_w[5]), .ev_slot(4'd0),
        .m_tdata(w_d[5]), .m_tkeep(w_k[5]), .m_tvalid(w_v[5]), .m_tready(rdy[5]),
        .m_tlast(w_l[5]), .m_tid(w_tid[5]), .app_tx_ready(16'hFFFF),
        .close_req(w_cr[5]), .close_id(),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(w_txb[5]), .stat_tx_frames(w_txf[5]), .stat_bad_frames(w_badf[5]),
        .stat_rx_bytes(w_rxb[5]), .stat_mismatch(w_mm[5]),
        .active(w_act[5]), .act_id(), .done(w_done[5]), .dbg_lfsr(), .led()
    );
    app_pattern #(`APPC.TX_BYTES(32'd1000), .TX_SEGSZ(12'd1460), .AUTO_CLOSE(1'b0)) u_txok (
        .clk(clk), .rst_n(rst_n), .ev_up(up_w[6]), .ev_down(dn_w[6]), .ev_slot(4'd0),
        .m_tdata(w_d[6]), .m_tkeep(w_k[6]), .m_tvalid(w_v[6]), .m_tready(rdy[6]),
        .m_tlast(w_l[6]), .m_tid(w_tid[6]), .app_tx_ready({15'h7FFF, tok_rdy}),
        .close_req(w_cr[6]), .close_id(),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(w_txb[6]), .stat_tx_frames(w_txf[6]), .stat_bad_frames(w_badf[6]),
        .stat_rx_bytes(w_rxb[6]), .stat_mismatch(w_mm[6]),
        .active(w_act[6]), .act_id(), .done(w_done[6]), .dbg_lfsr(), .led()
    );
    app_pattern #(`APPC.TX_BYTES(32'd1000), .TX_SEGSZ(12'd1460), .AUTO_CLOSE(1'b1)) u_rec1 (
        .clk(clk), .rst_n(rst_n), .ev_up(up_w[7]), .ev_down(dn_w[7]), .ev_slot(4'd0),
        .m_tdata(w_d[7]), .m_tkeep(w_k[7]), .m_tvalid(w_v[7]), .m_tready(rdy[7]),
        .m_tlast(w_l[7]), .m_tid(w_tid[7]), .app_tx_ready(16'hFFFF),
        .close_req(w_cr[7]), .close_id(),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(w_txb[7]), .stat_tx_frames(w_txf[7]), .stat_bad_frames(w_badf[7]),
        .stat_rx_bytes(w_rxb[7]), .stat_mismatch(w_mm[7]),
        .active(w_act[7]), .act_id(), .done(w_done[7]), .dbg_lfsr(), .led()
    );
    app_pattern #(`APPC.TX_BYTES(32'd1000), .TX_SEGSZ(12'd1460), .AUTO_CLOSE(1'b1)) u_rec2 (
        .clk(clk), .rst_n(rst_n), .ev_up(up_w[8]), .ev_down(dn_w[8]), .ev_slot(4'd0),
        .m_tdata(w_d[8]), .m_tkeep(w_k[8]), .m_tvalid(w_v[8]), .m_tready(rdy[8]),
        .m_tlast(w_l[8]), .m_tid(w_tid[8]), .app_tx_ready(16'hFFFF),
        .close_req(w_cr[8]), .close_id(),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(w_txb[8]), .stat_tx_frames(w_txf[8]), .stat_bad_frames(w_badf[8]),
        .stat_rx_bytes(w_rxb[8]), .stat_mismatch(w_mm[8]),
        .active(w_act[8]), .act_id(), .done(w_done[8]), .dbg_lfsr(), .led()
    );
    app_pattern #(`APPC.TX_BYTES(32'd1000), .TX_SEGSZ(12'd1460), .AUTO_CLOSE(1'b1)) u_rec3 (
        .clk(clk), .rst_n(rst_n), .ev_up(up_w[9]), .ev_down(dn_w[9]), .ev_slot(4'd0),
        .m_tdata(w_d[9]), .m_tkeep(w_k[9]), .m_tvalid(w_v[9]), .m_tready(rdy[9]),
        .m_tlast(w_l[9]), .m_tid(w_tid[9]), .app_tx_ready(16'hFFFF),
        .close_req(w_cr[9]), .close_id(),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(w_txb[9]), .stat_tx_frames(w_txf[9]), .stat_bad_frames(w_badf[9]),
        .stat_rx_bytes(w_rxb[9]), .stat_mismatch(w_mm[9]),
        .active(w_act[9]), .act_id(), .done(w_done[9]), .dbg_lfsr(), .led()
    );

    // ================= 全局时钟计数 =================
    reg [31:0] cyc;
    always @(posedge clk) if (!rst_n) cyc <= 32'd0; else cyc <= cyc + 32'd1;

    // ================= 每实例: dump + oracle + AXIS + 记账 =================
    integer fd_b [0:NALL-1];        // 交付载荷字节流 (hex, 32 B/行)
    integer fd_f [0:NALL-1];        // 每帧字节数
    integer fd_z [0:1];             // u_zero_c / u_zero_d 的周期快照 (A10 的 fc /b 语料)
    reg [63:0] M_mdl [0:NALL-1];    // 图案模型
    reg [31:0] M_nby [0:NALL-1];    // TB 记账字节
    reg [31:0] M_nfr [0:NALL-1];    // TB 记账帧数 (tlast 计数)
    reg [31:0] M_nn  [0:NALL-1];    // 本帧字节
    reg        M_in  [0:NALL-1];    // 帧内标志
    reg [31:0] M_orc [0:NALL-1];    // 图案失配
    reg [31:0] M_ax  [0:NALL-1];    // AXIS 保持违约
    reg [31:0] M_cr  [0:NALL-1];    // close_req 脉冲计数
    reg [31:0] M_rem [0:NALL-1];    // 模型: 量子剩余
    reg [31:0] M_exp [0:NALL-1];    // 模型: 本帧期望长度
    reg [31:0] M_fer [0:NALL-1];    // 模型: 帧长错误数
    reg        M_ovr [0:NALL-1];    // 模型: 会话已结束 (不该再有帧)
    reg        M_actf[0:NALL-1];    // active 曾回落到 0
    reg        M_dset[0:NALL-1];    // done 曾置 1
    reg [31:0] M_fup [0:NALL-1];    // 最后一次 ev_up 之后的 tlast 数 (含旧会话收尾帧, 仅信息)
    reg [31:0] M_nst [0:NALL-1];    // 最后一次 ev_up 之后的**帧起始**数 (opener beat) = 真"恢复"
    reg [31:0] M_tl1 [0:NALL-1];    // 第 1 个 tlast 的拍号
    reg [31:0] M_tlp [0:NALL-1];    // 上一个 tlast 的拍号
    reg [31:0] M_d12 [0:NALL-1], M_d23 [0:NALL-1], M_d34 [0:NALL-1];

    genvar gi;
    generate
    for (gi = 0; gi < NALL; gi = gi + 1) begin : GB
        localparam [31:0] TXBI = BYTTAB[gi*32 +: 32];
        localparam [11:0] SEGI = SEGTAB[gi*12 +: 12];
        localparam        CONTI = CTAB[gi*2];            // 本构建该实例是否连续
        localparam        LOKI = LOKTAB[gi*2];
        reg [63:0] shd;  reg [7:0] shk;  reg shl;  reg stall;
        integer li;  reg [7:0] bb;
        always @(posedge clk) begin
            if (!rst_n) begin
                M_mdl[gi] <= SEED; M_nby[gi] <= 0; M_nfr[gi] <= 0;
                M_nn[gi] <= 0; M_in[gi] <= 0; M_orc[gi] <= 0; M_ax[gi] <= 0;
                M_cr[gi] <= 0; M_rem[gi] <= TXBI; M_exp[gi] <= (TXBI > SEGI) ? SEGI : {20'b0, TXBI[11:0]};
                M_fer[gi] <= 0; M_ovr[gi] <= (TXBI == 0); M_actf[gi] <= 1'b0;
                M_dset[gi] <= 1'b0; M_fup[gi] <= 0;
                M_tl1[gi] <= 0; M_tlp[gi] <= 0; M_d12[gi] <= 0; M_d23[gi] <= 0; M_d34[gi] <= 0;
                M_nst[gi] <= 0;
                shd <= 0; shk <= 0; shl <= 0; stall <= 0;
            end else begin
                // ---- AXIS 保持合同: 连续两拍 (tvalid && !tready) 时数据必须不变 ----
                if (stall && w_v[gi] && !rdy[gi] &&
                    ((w_d[gi] !== shd) || (w_k[gi] !== shk) || (w_l[gi] !== shl))) begin
                    M_ax[gi] <= M_ax[gi] + 32'd1;
                    $display("  [FAIL] AXIS hold violation idx=%0d cyc=%0d", gi, cyc);
                end
                stall <= w_v[gi] && !rdy[gi];
                shd <= w_d[gi]; shk <= w_k[gi]; shl <= w_l[gi];

                if (w_cr[gi]) M_cr[gi] <= M_cr[gi] + 32'd1;
                if (w_done[gi]) M_dset[gi] <= 1'b1;
                if (M_actf[gi] == 1'b0 && w_act[gi] == 1'b0 && M_dset[gi] == 1'b1)
                    M_actf[gi] <= 1'b1;      // done 之后 active 才回落的记录 (仅信息)

                // ---- 接受一个 beat ----
                if (w_v[gi] && rdy[gi]) begin
                    if (!M_in[gi]) M_in[gi] = 1'b1;      // 本帧首拍 (opener, keep=0)
                    // 帧起始拍 = opener beat (keep=0 且非 tlast; 0 载荷收尾字是 tlast, 不算)
                    if ((w_k[gi] == 8'h00) && !w_l[gi]) M_nst[gi] = M_nst[gi] + 1;
                    for (li = 0; li < 8; li = li + 1) begin
                        if (w_k[gi][7 - li]) begin
                            case (li)
                                0: bb = w_d[gi][63:56];  1: bb = w_d[gi][55:48];
                                2: bb = w_d[gi][47:40];  3: bb = w_d[gi][39:32];
                                4: bb = w_d[gi][31:24];  5: bb = w_d[gi][23:16];
                                6: bb = w_d[gi][15:8];   default: bb = w_d[gi][7:0];
                            endcase
                            $fwrite(fd_b[gi], "%02x", bb);
                            if (bb !== M_mdl[gi][31:24]) begin
                                M_orc[gi] = M_orc[gi] + 1;
                                if (M_orc[gi] <= 32'd4)
                                    $display("  [FAIL] pattern mismatch idx=%0d cyc=%0d got=%02x exp=%02x",
                                             gi, cyc, bb, M_mdl[gi][31:24]);
                            end
                            M_mdl[gi] = xs_next(M_mdl[gi]);
                            M_nby[gi] = M_nby[gi] + 1;
                            M_nn[gi]  = M_nn[gi] + 1;
                            if ((M_nby[gi] % 32) == 0) $fwrite(fd_b[gi], "\n");
                        end
                    end
                    if (w_l[gi]) begin
                        // ---- 帧长模型 (只在 LOK 且非零配置的实例上判) ----
                        if (LOKI && (TXBI != 0)) begin
                            if (M_ovr[gi]) begin
                                M_fer[gi] = M_fer[gi] + 1;
                                $display("  [FAIL] frame after session end idx=%0d cyc=%0d len=%0d",
                                         gi, cyc, M_nn[gi]);
                            end else if (M_nn[gi] != M_exp[gi]) begin
                                M_fer[gi] = M_fer[gi] + 1;
                                if (M_fer[gi] <= 32'd4)
                                    $display("  [FAIL] frame length idx=%0d cyc=%0d got=%0d exp=%0d frm=%0d",
                                             gi, cyc, M_nn[gi], M_exp[gi], M_nfr[gi]);
                                // 模型仍按真值推进, 免得一次错位污染后续读数
                                if (M_rem[gi] >= M_nn[gi]) M_rem[gi] = M_rem[gi] - M_nn[gi];
                                else                       M_rem[gi] = 32'd0;
                            end else begin
                                M_rem[gi] = M_rem[gi] - M_exp[gi];
                            end
                            if (M_rem[gi] == 32'd0) begin
                                if (CONTI) M_rem[gi] = TXBI;      // 重装载
                                else       M_ovr[gi] = 1'b1;      // 会话结束
                            end
                            M_exp[gi] = (M_rem[gi] > SEGI) ? SEGI : M_rem[gi];
                        end
                        $fwrite(fd_f[gi], "%0d\n", M_nn[gi]);
                        M_nfr[gi] = M_nfr[gi] + 1;
                        M_fup[gi] = M_fup[gi] + 1;
                        M_in[gi]  = 1'b0;
                        M_nn[gi]  = 0;
                        if (M_nfr[gi] == 32'd1) M_tl1[gi] = cyc;
                        else if (M_nfr[gi] == 32'd2) M_d12[gi] = cyc - M_tlp[gi];
                        else if (M_nfr[gi] == 32'd3) M_d23[gi] = cyc - M_tlp[gi];
                        else if (M_nfr[gi] == 32'd4) M_d34[gi] = cyc - M_tlp[gi];
                        M_tlp[gi] = cyc;
                    end
                end
                // ---- 换流/重连: 新会话图案从 SEED 重开, 帧长模型同样重开 ----
                if (up_w[gi]) begin
                    M_mdl[gi] = SEED;
                    M_rem[gi] = TXBI;
                    M_exp[gi] = (TXBI > SEGI) ? SEGI : {20'b0, TXBI[11:0]};
                    M_ovr[gi] = (TXBI == 0);
                    M_fup[gi] = 0;
                    M_nst[gi] = 0;
                end
                // ---- 零臂周期快照 (每 256 拍; 两实例必须逐字节相同) ----
                if ((gi == 4 || gi == 5) && rst_n && (cyc != 0) && (cyc[7:0] == 8'd0))
                    $fwrite(fd_z[gi-4], "cyc=%0d v=%0d k=%02x l=%0d tb=%0d txb=%0d txf=%0d act=%0d done=%0d cr=%0d\n",
                            cyc, w_v[gi], w_k[gi], w_l[gi], w_tid[gi],
                            w_txb[gi], w_txf[gi], w_act[gi], w_done[gi], w_cr[gi]);
            end
        end
    end
    endgenerate

    // ================= 判据 =================
    integer errs;
    task chk;
        input cond;  input [1023:0] msg;
        begin
            if (!cond) begin errs = errs + 1; $display("  [FAIL] %0s", msg); end
            else         $display("  [ ok ] %0s", msg);
        end
    endtask

    integer ii, jj;
    reg [255:0] fname;
    integer f_stats, f_rate;

    initial begin
        errs = 0; rst_n = 1'b0;
        est = 2'd0; cyc = 0;
        tok_nby = 0; tok_low = 1'b0; tok_t = 0;
        r1n = 0; r1t = 0; r1dn = 0; r1tlow = 0;
        r2n = 0; r2t = 0; r2dn = 0; r2tlow = 0;
        r3n = 0; r3t = 0; r3dn = 0; r3tlow = 0;
        for (ii = 0; ii < NALL; ii = ii + 1) begin
            $sformat(fname, "d%0d.hex", ii);  fd_b[ii] = $fopen(fname, "w");
            $sformat(fname, "f%0d.txt", ii);  fd_f[ii] = $fopen(fname, "w");
        end
        fd_z[0] = $fopen("z_zero_c.txt", "w");
        fd_z[1] = $fopen("z_zero_d.txt", "w");
        f_stats = $fopen("stats.txt", "w");
        f_rate  = $fopen("rate.txt", "w");

        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (CY_TOT) @(posedge clk);
        // ⚠️ 收口前让 NBA 区结算一拍 (半拍即可): 否则本 TB 的阻塞式记账 (active 区) 会
        //    比 DUT 的 NBA 记账先落地 => 边沿上在读侧差一个字 (8 B) 的假失配。
        #1;

        // ================= 收口 =================
        for (ii = 0; ii < NALL; ii = ii + 1) begin
            $fclose(fd_b[ii]);  $fclose(fd_f[ii]);
        end
        $fclose(fd_z[0]);  $fclose(fd_z[1]);

        for (ii = 0; ii < NALL; ii = ii + 1)
            $display("  I%0d: frames=%0d bytes=%0d done=%0d active=%0d cr=%0d | tb_frames=%0d tb_bytes=%0d orc=%0d ax=%0d ferr=%0d",
                     ii, w_txf[ii], w_txb[ii], w_done[ii], w_act[ii], M_cr[ii],
                     M_nfr[ii], M_nby[ii], M_orc[ii], M_ax[ii], M_fer[ii]);
        // ⭐ 构建 E (A3): 三个重连臂**全部升级为判据** (原句 = "不是判据, 只有
        //    u_rec3 有断言")。口径确认 (读 TB 自己的实现): `M_nst` 在 `up_w[gi]`
        //    那一拍被清 0 (见上面 `if (up_w[gi]) ... M_nst[gi] = 0;`) ⇒ 打印出来的
        //    `starts_after_up` 字面就是"**最近一次 ev_up 之后**新起的帧数",
        //    不是总帧数 (本轮先误以为要另立快照寄存器, 核对实现后撤回 —— 记录在此
        //    免得下一个读的人重犯)。
        //    修前机理 (审查员 ①): k 落在"收尾仍被 m_tready 卡住"的窗口内
        //    (rec1 k=40/tw=300, rec2 k=240/tw=300) ⇒ ev_up 被吞 ⇒ 修前 = 0;
        //    rec3 (tw=6, 收尾早已完成) ⇒ 修前就 >0 (对照臂, 行为不得变)。
        $display("  REC: u_rec1(k=%0d,tw=%0d) frames=%0d starts_after_up=%0d active=%0d => %0s",
                 K1, TW1, w_txf[7], M_nst[7], w_act[7],
                 (M_nst[7] > 0) ? "RESUMED" : "SILENT-ZERO-DATA");
        $display("  REC: u_rec2(k=%0d,tw=%0d) frames=%0d starts_after_up=%0d active=%0d => %0s",
                 K2, TW2, w_txf[8], M_nst[8], w_act[8],
                 (M_nst[8] > 0) ? "RESUMED" : "SILENT-ZERO-DATA");
        $display("  REC: u_rec3(k=%0d,tw=%0d) frames=%0d starts_after_up=%0d active=%0d => %0s",
                 K3, TW3, w_txf[9], M_nst[9], w_act[9],
                 (M_nst[9] > 0) ? "RESUMED" : "SILENT-ZERO-DATA");
        $display("  RATE: tl1_base=%0d tl1_cont=%0d | cont d12=%0d d23=%0d d34=%0d",
                 M_tl1[0], M_tl1[1], M_d12[1], M_d23[1], M_d34[1]);
        $display("  TOK: frames=%0d bytes=%0d done=%0d cr=%0d | tok_dropped=%0d",
                 w_txf[6], w_txb[6], w_done[6], M_cr[6], tok_seen);

        for (ii = 0; ii < NALL; ii = ii + 1)
            $fwrite(f_stats, "I%0d bytes=%0d frames=%0d bad=%0d tb_bytes=%0d tb_frames=%0d cr=%0d done=%0d act=%0d orc=%0d ax=%0d ferr=%0d fup=%0d nst=%0d\n",
                    ii, BYTTAB[ii*32 +: 32], w_txf[ii], w_badf[ii], M_nby[ii], M_nfr[ii],
                    M_cr[ii], w_done[ii], w_act[ii], M_orc[ii], M_ax[ii], M_fer[ii], M_fup[ii], M_nst[ii]);
        $fclose(f_stats);

        $fwrite(f_rate, "tl1_base=%0d tl1_cont=%0d d12=%0d d23=%0d d34=%0d\n",
                M_tl1[0], M_tl1[1], M_d12[1], M_d23[1], M_d34[1]);
        $fclose(f_rate);

        // ================= 判据 (A1..A13) =================
        // --- 通用 (全部 10 个实例) ---
        for (ii = 0; ii < NALL; ii = ii + 1) begin
            chk(M_orc[ii] == 0,  "A6 oracle: payload byte stream == TB xorshift64 model");
            chk(M_ax[ii]  == 0,  "A7 AXIS hold contract: stable while tvalid && !tready");
            chk(w_txf[ii] == M_nfr[ii], "A7b stat_tx_frames == TB tlast count");
            chk(w_txb[ii] == M_nby[ii], "A5b stat_tx_bytes == TB delivered byte count");
            chk(M_fer[ii] == 0,  "A4 frame length sequence == arithmetic model");
            chk(w_badf[ii] == 0, "no bad frames injected in this gate");
        end

        // --- A8 负对照 (门有牙): u_base 默认关 => 按时终结 ---
        chk(w_txf[0] == 32'd1,        "A8 u_base 1 frame (1000B quantum)");
        chk(w_txb[0] == 32'd1000,     "A8 u_base 1000 bytes");
        chk(w_done[0] == 1'b1,        "A8 u_base done=1");
        chk(w_act[0]  == 1'b0,        "A8 u_base active falls to 0");
        chk(M_cr[0] >= 32'd1,         "A8 u_base close_req fired (>=1)");

        // --- A10 退化臂: u_zero_c == u_zero_d (计数 + 周期快照文件由 runner fc /b) ---
        chk(w_txf[4] == w_txf[5],     "A10 zero-arm frames equal");
        chk(w_txb[4] == w_txb[5],     "A10 zero-arm bytes equal");
        chk(M_cr[4]  == M_cr[5],      "A10 zero-arm close_req count equal");
        chk(w_done[4] == w_done[5],   "A10 zero-arm done equal");
        chk(w_act[4]  == w_act[5],    "A10 zero-arm active equal");
        chk(w_txf[4] == 32'd0,        "A10 zero-arm: zero frames (silent stall, §5.1)");
        chk(w_txb[4] == 32'd0,        "A10 zero-arm: zero bytes");
        chk(w_done[4] == 1'b0,        "A10 zero-arm: done stays 0");
        chk(w_act[4] == 1'b1,         "A10 zero-arm: active stays 1");

        // --- A12a/A12b 拍/帧 ---
        chk(M_tl1[0] == M_tl1[1],     "A12a first tlast cycle: u_base == u_cont");
        chk(M_tl1[1] != 32'd0,        "A12a u_cont really produced a frame");

        // --- ⭐ 构建 E (A3): 三个重连臂都断言"换流后确有新帧起始" ----------------
        //   修前: u_rec1/u_rec2 = 0 (ev_up 被吞 ⇒ 新连接静默零数据、无自愈);
        //         u_rec3 = 1 (对照臂, 收尾早已完成 ⇒ 修前修后都恢复)。
        //   判据 = **ev_up 之后新起的帧数 >= 1** (M_nst 已在 up_w 拍清 0 ⇒ 该口径
        //   天然成立; 见打印块的就地说明)。
        chk(M_nst[7] >= 32'd1,
            "A13a u_rec1 resumed after same-slot reconnect (k=40, tready low 300)");
        chk(M_nst[8] >= 32'd1,
            "A13b u_rec2 resumed after same-slot reconnect (k=240, tready low 300)");
        chk(M_nst[9] >= 32'd1,
            "A13c u_rec3 resumed after same-slot reconnect (k=240, tready low 6; 对照臂)");
`ifndef APP_CONT_ARM
        // 对照臂**行为不得变** (只在本 TB 的非连续臂 = ARM A 成立): u_rec3 修前修后
        //   都是"恰好 1 帧" (1000B 量子; ev_up 落在帧 1 之后 ⇒ 补做换流只发下一帧)。
        //   ⚠️ 连续臂 (ARM B/C) 里它一直发 ⇒ 本条不适用 (所以包 ifndef)。
        chk(M_nst[9] == 32'd1,
            "A13c' u_rec3 resume count == 1 (补做逻辑不给对照臂多发帧; ARM A only)");
`endif
        chk(tok_seen == 1'b1,         "A11b u_txok really dropped app_tx_ready");

`ifdef APP_CONT_ARM
        // ================= 连续臂判据 (ARM B/C) =================
        // A1/A2: close_req / done 恒 0 (连续模式: done 的唯一置位点被常量关死)
        for (ii = 1; ii <= 3; ii = ii + 1) begin
            chk(M_cr[ii] == 0,        "A1 continuous: close_req == 0");
            chk(w_done[ii] == 1'b0,   "A2 continuous: done == 0");
        end
        for (ii = 6; ii <= 9; ii = ii + 1) begin
            if (ii == 6) chk(M_cr[6] == 0, "A1 continuous: close_req == 0 (u_txok)");
            else begin
                chk(M_cr[ii] == 0,    "A1 continuous: close_req == 0 (rec)");
                chk(w_done[ii] == 1'b0, "A2 continuous: done == 0 (rec)");
            end
        end
        // A3: 帧持续产生 (>= 4 个量子的帧数)
        chk(w_txf[1] >= 32'd4,        "A3 u_cont frames >= 4 (4 quanta)");
        chk(w_txf[2] >= 32'd9,        "A3 u_cont_big frames >= 9 (3 quanta x 3 frames)");
        chk(w_txf[3] >= 32'd4,        "A3 u_cont_one frames >= 4");
        // A5: 交付字节 >= 3xTX_BYTES
        chk(w_txb[1] >= 32'd3000,     "A5 u_cont bytes >= 3xTX_BYTES");
        chk(w_txb[2] >= 32'd9000,     "A5 u_cont_big bytes >= 3xTX_BYTES");
        chk(w_txb[3] >= 32'd3,        "A5 u_cont_one bytes >= 3xTX_BYTES");
        // A4b: 重装载点上的帧长 (u_cont 每帧 1000, u_cont_big 序列 1460/1460/80)
        // ⚠️ 收口拍可能停在帧中 ⇒ 交付字节 = 已完成帧 x 1000 + 在飞前缀 (< 1000)。
        //    逐帧精确长度由 A4 (ferr) 判; 这里只判"界限 + 无 0 长帧"。
        chk((w_txb[1] >= (w_txf[1] * 32'd1000)) && (w_txb[1] < ((w_txf[1] + 32'd1) * 32'd1000)),
            "A4b u_cont: all completed frames = 1000 B (in-flight prefix bounded)");
        chk(w_txf[2] >= 32'd9, "A4b u_cont_big >= 9 frames (3 quanta x 3 frames)");
        // A12b: 重装载不引入气泡 (跨量子边界的帧间隔不变)
        chk((M_d12[1] != 32'd0) && (M_d12[1] == M_d23[1]) && (M_d23[1] == M_d34[1]),
            "A12b u_cont tlast-to-tlast interval constant across reload boundary");
        // A11: u_txok 在 frm_wait 后恢复 (且无 0 长帧 —— 由 A4 覆盖)
        chk(w_txf[6] >= 32'd3,        "A11 u_txok resumed after tx_ok drop (>=3 frames)");
        chk(w_txb[6] >= 32'd3000,     "A11 u_txok bytes >= 3xTX_BYTES");
`else
        // ================= 基线 (ARM A/G): 不传参 => 今天的有限行为 =================
        chk(w_txf[1] == 32'd1,        "ARM-A u_cont behaves like u_base: 1 frame");
        chk(w_txb[1] == 32'd1000,     "ARM-A u_cont behaves like u_base: 1000 bytes");
        chk(w_done[1] == 1'b1,        "ARM-A u_cont done=1 (session ends)");
        chk(w_txf[2] == 32'd3,        "ARM-A u_cont_big 3 frames (1460+1460+80)");
        chk(w_txb[2] == 32'd3000,     "ARM-A u_cont_big 3000 bytes");
        chk(w_txf[3] == 32'd1,        "ARM-A u_cont_one 1 frame (1 byte)");
        chk(w_txb[3] == 32'd1,        "ARM-A u_cont_one 1 byte");
        chk(w_txf[6] == 32'd1,        "ARM-A u_txok 1 frame (terminate branch wins)");
        chk(w_done[6] == 1'b1,        "ARM-A u_txok done=1");
        chk(M_cr[6] == 0,             "ARM-A u_txok AUTO_CLOSE=0 => close_req never fires");
        chk(w_txf[0] == w_txf[1],     "ARM-A u_base/u_cont frame-count identical");
        chk(w_txb[0] == w_txb[1],     "ARM-A u_base/u_cont byte-count identical");
`endif

        $display("TB_APP_CONT_SUM errs=%0d", errs);
        if (errs == 0) $display("TB_APP_CONT: OK");
        else           $display("TB_APP_CONT: FAIL errs=%0d", errs);
        $display("TB_APP_CONT DONE");
        $finish;
    end
endmodule
