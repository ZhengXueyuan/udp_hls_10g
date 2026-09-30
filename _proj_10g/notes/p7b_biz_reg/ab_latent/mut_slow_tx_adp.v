`timescale 1ns/1ps
// 慢路径 TX 适配器: HLS udp_echo 的 tx_stream (16bit, bit8=TLAST) -> 64bit 字流。
//
// HLS MAC TX 契约 (layer_mac.cpp): 完整线上帧 = 7x0x55+0xD5 前导 | dst..payload
// (含 pad 到 60B) | FCS 4B (LSB-first), tlast 在最后一个 FCS 字节。
// 本适配器: 剥前导 (跳过 0x55..0xD5), 4 字节回持剥 FCS, 剩余内容打包成左对齐字流。
// FCS 由 mac_tx_64 重新计算追加 — HLS 的 FCS 字节直接丢弃, 天然避免双重 FCS。
//
// 结构: tx_stream -> 9bit 字节 FIFO -> 字节 FSM (剥前导/剥 FCS/打包)
//       -> frame_fifo (整帧字缓冲, commit@tlast) -> AXIS 字流 -> tx_arb。
// 整帧字缓冲后才对 tx_arb 可见: 字节产生速率 (<=1B/拍, 带空洞) 远低于字消费
// 速率 (8B/拍), 不整帧缓冲会让 mac_tx_64 欠载中止。
module slow_tx_adp (
    input  wire        clk,
    input  wire        rst_n,
    // HLS udp_echo tx_stream (TDATA = {6'b0, TLAST, byte})
    input  wire [15:0] hls_tx_tdata,
    input  wire        hls_tx_tvalid,
    output wire        hls_tx_tready,
    // AXIS 字流输出 (去 tx_arb)
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output reg  [31:0] stat_frames,    // 成功转出帧数
    output reg  [31:0] stat_purge,     // 前导非法/fifo 满回卷帧数
    // P7B-latent (2026-09-30): 字 FIFO 拒写次数 —— **结构上恒 0** (契约见 fifo_sync.v
    // 头注释与 frame_fifo.v 的 full_next 注释)。非 0 = 有已计入的字被静默丢弃。
    output reg  [31:0] stat_fifo_ovf    // u_wf 拒写次数 (恒 0; 非 0 = 静默丢失)
);
    // ---------------- HLS -> 9bit 字节 FIFO ----------------
    // FWFT 契约 (铁律 #4): rd 必须与消费同拍 (组合), 寄存器化 rd 会让同一字节
    // 在总线上挂 2 拍被二次处理 — 本模块曾因 i_rd/wf_rd 寄存器化双采被审查抓获。
    wire [8:0] i_dout;
    wire       i_empty, i_full;
    wire       i_rd;

    assign hls_tx_tready = !i_full;
    fifo_sync #(.W(9), .D(2048), .AW(11)) u_ififo (
        .clk(clk), .rst_n(rst_n),
        .wr(hls_tx_tvalid && hls_tx_tready), .din({hls_tx_tdata[8], hls_tx_tdata[7:0]}),
        .rd(i_rd), .dout(i_dout), .empty(i_empty), .full(i_full)
    );

    // ---------------- 字节 FSM 状态 ----------------
    localparam T_IDLE = 2'd0, T_PRE = 2'd1, T_DATA = 2'd2, T_PURGE = 2'd3;
    reg [1:0]  tstate;
    reg [3:0]  skip_cnt;
    reg [31:0] hold;          // 回持最近 4 字节 (帧尾 4 = FCS, 丢弃)
    reg [2:0]  hc;            // hold 有效数 0..4
    reg [63:0] pw;            // 打包字 (字节索引直写, 左对齐; 整字写出后清零)
    reg [3:0]  pc;            // 已打包字节数 0..7
    reg        abort;
    reg [7:0]  committed;
    reg        commit_pulse;

    // 输出播放器状态
    // committed 语义: 提交未开播的帧数; O_IDLE 开播拍即 -1 (不等播完) —
    // 与 slow_rx_adp 同病同药: 播完再减会让 O_IDLE 读到旧值幻影开播。
    localparam O_IDLE = 1'b0, O_SEND = 1'b1;
    reg        ostate;

    // 字 frame_fifo = {tlast, tkeep, tdata} 73 位; rd 组合 (FWFT 同拍消费)
    // ⚠️ 写口合同 (P7B-latent 修复, 2026-09-30): `wf_wr` 是**寄存器** (本轮决定、
    //    下拍落笔) ⇒ 空间门必须用 `wf_full_next` (**下一拍**的精确满值), 不能用本拍
    //    `wf_full`。用本拍 `full` 有一拍错位: "本拍 full=0 (511 占) + 本拍还有一笔在飞
    //    写" ⇒ 下拍 full=1 ⇒ 该笔写被 frame_fifo **静默丢弃**。命中相位时丢的正是
    //    **帧末字 (带 tlast)** ⇒ 帧已 commit (stat_frames++), 而线上该帧永远不闭合
    //    (与 app_udp_pattern 的 P7B-W9 同族; 同款修法先例 fifo_sync 头注释 /
    //    mac_rx_64.v:131 / app_udp_pattern.v:497)。可达性构造与反例双跑见
    //    `_proj_10g/notes/P7B_LATENT_FIFO_FIX.md`。
    reg         wf_wr, wf_snap, wf_rlbk;
    reg  [72:0] wf_din;
    wire [72:0] wf_dout;
    // wf_full 修复后**不再被读** (保留连线只为排障/未来使用; 空间门一律 full_next)。
    wire        wf_empty, wf_full, wf_full_next, wf_ovf;
    wire        wf_rd;

    frame_fifo #(.W(73), .D(512), .AW(9)) u_wf (
        .clk(clk), .rst_n(rst_n),
        .wr(wf_wr), .din(wf_din),
        .snap(wf_snap), .rollback(wf_rlbk),
        .rd(wf_rd), .dout(wf_dout), .empty(wf_empty), .full(wf_full),
        .dbg_rd_addr(9'd0), .dbg_rd_side(),  // P6c 诊断读口未用 (tcp_echo 实例才接)
        .full_next(wf_full_next),            // P7B-latent: 空间门 (下一拍满)
        .ovf_pulse(wf_ovf)                   // P7B-latent: 拒写脉冲 (自检, 恒 0)
    );
    // 无静默丢失自检回读 (合同: 生产侧必须把拒写接成计数器, 恒 0 才叫无丢字)。
    // 修复后**结构性恒 0** (写门 = !full_next ⇒ 落笔拍 full 必为 0); 一旦生产者判据
    // 回归本拍 `full`, 它立刻会响 ⇒ 这是一条有牙齿的回归守卫。
    // ⚠️ 板级可见性: 本计数器已是模块输出端口 (`stat_fifo_ovf`)。要进快照窗口需
    //    在 `board/wrapper_p4.v` 三处加 (① 端口连线 ② 快照字打包 ③ 文档表) ——
    //    本轮**未接** (该文件归另一个 agent), 见笔记 §可见性。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) stat_fifo_ovf <= 32'd0;
        else if (wf_ovf) stat_fifo_ovf <= stat_fifo_ovf + 32'd1;
    end

    wire start_play = (ostate == O_IDLE) && (committed != 8'd0) && !wf_empty;

    wire [7:0] in_b    = i_dout[7:0];
    wire       in_last = i_dout[8];
    // 组合 rd: T_PRE/T_DATA/T_PURGE 每拍消费当前字节 (T_IDLE 留住帧首字节待判)
    assign i_rd = (tstate != T_IDLE) && !i_empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tstate <= T_IDLE; skip_cnt <= 4'd0;
            hold <= 32'd0; hc <= 3'd0; pw <= 64'd0; pc <= 4'd0;
            abort <= 1'b0; committed <= 8'd0;
            wf_wr <= 1'b0; wf_snap <= 1'b0; wf_rlbk <= 1'b0;
            wf_din <= 73'd0; commit_pulse <= 1'b0;
            stat_frames <= 0; stat_purge <= 0;
        end else begin
            wf_wr <= 1'b0; wf_snap <= 1'b0; wf_rlbk <= 1'b0;
            commit_pulse <= 1'b0;

            case (tstate)
                T_IDLE: if (!i_empty) begin
                    wf_snap  <= 1'b1;          // 快照 = 即将写入的首字槽
                    skip_cnt <= 4'd0;
                    tstate   <= T_PRE;
                end
                T_PRE: if (!i_empty) begin
                    if (in_b == 8'h55 && skip_cnt < 4'd15) begin
                        skip_cnt <= skip_cnt + 4'd1;
                    end else if (in_b == 8'hD5 && skip_cnt >= 4'd4) begin
                        hc   <= 3'd0; pc <= 4'd0; pw <= 64'd0;
                        abort <= 1'b0;
                        tstate <= T_DATA;
                    end else begin
                        tstate <= T_PURGE;     // 前导非法: 吞到 tlast 回卷
                    end
                end
                T_DATA: if (!i_empty) begin
                    // 4 字节回持: 满 4 后每来 1 字节, 最老字节毕业进打包器。
                    // in_last 拍毕业字节直接合成末字 (tlast 必须落在帧的最后一个字)。
                    // ⚠️ 空间门用 `wf_full_next` (下一拍满), **不是** `wf_full` ——
                    //    wf_wr 是寄存器, 本拍判据必须预测"落笔那一拍"的满 (P7B-latent)。
                    if (hc == 3'd4 && !wf_full && !abort) begin
                        if (pc == 4'd7) begin
                            wf_wr  <= 1'b1;
                            wf_din <= {in_last, 8'hFF, pw[63:8], hold[31:24]};
                            pc     <= 4'd0;
                            pw     <= 64'd0;
                        end else if (in_last) begin
                            wf_wr <= 1'b1;
                            case (pc[2:0])
                                3'd0: wf_din <= {1'b1, 8'h80, hold[31:24], 56'b0};
                                3'd1: wf_din <= {1'b1, 8'hC0, pw[63:56], hold[31:24], 48'b0};
                                3'd2: wf_din <= {1'b1, 8'hE0, pw[63:48], hold[31:24], 40'b0};
                                3'd3: wf_din <= {1'b1, 8'hF0, pw[63:40], hold[31:24], 32'b0};
                                3'd4: wf_din <= {1'b1, 8'hF8, pw[63:32], hold[31:24], 24'b0};
                                3'd5: wf_din <= {1'b1, 8'hFC, pw[63:24], hold[31:24], 16'b0};
                                default: wf_din <= {1'b1, 8'hFE, pw[63:16], hold[31:24], 8'b0};
                            endcase
                        end else begin
                            case (pc[2:0])
                                3'd0: pw[63:56] <= hold[31:24];
                                3'd1: pw[55:48] <= hold[31:24];
                                3'd2: pw[47:40] <= hold[31:24];
                                3'd3: pw[39:32] <= hold[31:24];
                                3'd4: pw[31:24] <= hold[31:24];
                                3'd5: pw[23:16] <= hold[31:24];
                                3'd6: pw[15:8]  <= hold[31:24];
                                default: pw[7:0] <= hold[31:24];
                            endcase
                            pc <= pc + 4'd1;
                        end
                    end else if (hc == 3'd4) begin
                        abort <= 1'b1;               // 字 fifo 满: 本帧作废
                    end
                    hold <= {hold[23:0], in_b};
                    if (hc != 3'd4) hc <= hc + 3'd1;
                    if (in_last) begin
                        // hold 里 4 字节 = FCS, 已随回持丢弃 (永不毕业)
                        // 提交门同样用 full_next: 与"末字下拍一定落笔"同门 ⇒
                        // "commit 了但末字进不去" 这种静默态结构性不存在。
                        if (hc == 3'd4 && !abort && !wf_full) begin
                            commit_pulse <= 1'b1;
                            stat_frames  <= stat_frames + 1;
                        end else begin
                            wf_rlbk    <= 1'b1;      // 退化帧 (内容 <1 字) 或写坏
                            stat_purge <= stat_purge + 1;
                        end
                        tstate <= T_IDLE;
                    end
                end
                T_PURGE: if (!i_empty) begin
                    if (in_last) begin
                        wf_rlbk    <= 1'b1;
                        stat_purge <= stat_purge + 1;
                        tstate     <= T_IDLE;
                    end
                end
                default: tstate <= T_IDLE;
            endcase

            // committed: +1 commit / -1 开播, 同拍互抵
            if (commit_pulse && !start_play)      committed <= committed + 8'd1;
            else if (!commit_pulse && start_play) committed <= committed - 8'd1;
        end
    end

    // ---------------- 输出播放器: 整帧字 -> AXIS ----------------
    assign m_axis_tdata  = wf_dout[63:0];
    assign m_axis_tkeep  = wf_dout[71:64];
    assign m_axis_tlast  = wf_dout[72];
    assign m_axis_tvalid = (ostate == O_SEND) && !wf_empty;
    assign wf_rd         = m_axis_tvalid && m_axis_tready;   // 组合, 同拍消费

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ostate <= O_IDLE;
        end else begin
            case (ostate)
                O_IDLE: if (start_play) ostate <= O_SEND;
                O_SEND: if (m_axis_tvalid && m_axis_tready) begin
                    if (wf_dout[72]) ostate <= O_IDLE;   // tlast 字被消费
                end
            endcase
        end
    end
endmodule
