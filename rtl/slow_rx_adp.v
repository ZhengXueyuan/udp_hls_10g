`timescale 1ns/1ps
// 慢路径 RX 适配器: 64bit 字流 -> HLS udp_echo 的 rx_stream (16bit, bit8=TLAST)。
//
// HLS MAC RX 契约 (layer_mac.cpp): 需要 0x55 前导 + 0xD5 同步 (MAC_RX_IDLE/PREAMBLE);
// 单播过滤 dst==00:0A:35:01:FE:C0 或广播; **不校验 FCS** (payload 之后的尾部字节
// 被 IP total_len / ARP 定长自然忽略) — 因此本适配器补前导但不重生成 FCS,
// tlast 落在最后一个内容字节。坏 FCS / rx_er 帧由本层按 tcrs/terr 整帧回卷丢弃
// (HLS 无 FCS 检查, 坏帧必须在此拦截)。
//
// 结构: 字流 -> frame_fifo (整帧缓冲, snap@SOP / commit@好帧尾 / rollback@坏帧)
//       -> 字节播放器 (8B 前导 + 逐字节内容) -> 9bit 字节 FIFO -> HLS rx_stream。
// 输入侧 s_tready 恒 1 (fifo 满则吞字打 abort, 帧尾回卷) — 绝不反压 classify。
module slow_rx_adp #(
    // 看门狗阈值 (拍): hls_rx_tvalid && !tready 持续超此则复位 HLS (默认 2^21
    // ≈16.8ms @125MHz; TB 用小值)。防 HLS 内部死锁 (其 512 词内部帧 fifo 满
    // 则 mac_rx 写阻塞 → 永久停读 — 泛洪实测实锤) 后永久失联。
    // 位宽铁律: 2^21 需 22 位! [20:0] 会把 2097152 截成 0 (看门狗立刻乱触发)。
    parameter [21:0] WDOG = 22'd2097152
) (
    input  wire        clk,
    input  wire        rst_n,
    // 来自 rx_classify (slow 路由)
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,   // SOP
    input  wire        s_axis_tcrs,    // TLAST: FCS 正确
    input  wire        s_axis_terr,    // TLAST: 帧内 rx_er
    // HLS udp_echo rx_stream (TDATA = {6'b0, TLAST, byte})
    output wire [15:0] hls_rx_tdata,
    output wire        hls_rx_tvalid,
    input  wire        hls_rx_tready,
    output wire        hls_rst_n,      // 看门狗: 饥饿超时给 HLS 打 64 拍复位脉冲
    output reg  [31:0] stat_commit,    // 提交给 HLS 的帧数
    output reg  [31:0] stat_drop       // 回卷丢弃 (坏 FCS/rx_er/fifo 满)
);
    // ---------------- 输入侧: 整帧缓冲 + 提交/回卷 ----------------
    // frame_fifo 字 = {tlast, tkeep, tdata} 73 位
    wire        ff_full, ff_empty;
    wire [72:0] ff_dout;
    reg         ff_rd;
    reg         abort;          // 本帧已写坏 (fifo 满吞字)
    reg         in_frame;       // 已接 SOP 未接 TLAST
    reg         resync_drop;    // 截断事件后牺牲吞掉当前帧
    reg  [7:0]  committed;      // 已提交未播放帧数

    assign s_axis_tready = 1'b1;
    wire s_acc  = s_axis_tvalid;
    wire sop_any   = s_acc && s_axis_tuser;
    wire sop_multi = sop_any && !s_axis_tlast;
    wire sop_1w    = sop_any && s_axis_tlast;                // 单字 runt: 整体忽略
    // SOP 防御: 前帧无 tlast 即来新 SOP = mac_rx_64 截断产物 (其 fifo 满丢帧)。
    // 回卷前帧残余并牺牲新帧吞到其 tlast — frame_fifo 不能同拍 rollback+写,
    // 别无选择; fast 路由侧由 tcp_rx 的 SOP 防御兜住同事件 (审查轮 finding)。
    wire trunc_evt = sop_any && in_frame;
    wire ff_wr   = s_acc && !resync_drop && !sop_1w && !trunc_evt && !abort && !ff_full;
    wire ff_snap = sop_multi && !in_frame && !resync_drop;
    wire frame_end = s_acc && s_axis_tlast && !s_axis_tuser && !resync_drop;
    wire frame_bad = abort || ff_full || !s_axis_tcrs || s_axis_terr;
    wire do_commit = frame_end && !frame_bad;
    wire do_rollbk = (frame_end && frame_bad) || trunc_evt;

    frame_fifo #(.W(73), .D(512), .AW(9)) u_ff (
        .clk(clk), .rst_n(rst_n),
        .wr(ff_wr), .din({s_axis_tlast, s_axis_tkeep, s_axis_tdata}),
        .snap(ff_snap), .rollback(do_rollbk),
        .rd(ff_rd), .dout(ff_dout), .empty(ff_empty), .full(ff_full)
    );

    // ---------------- 输出侧: 9bit 字节 FIFO -> HLS ----------------
    wire [8:0] o_dout;
    wire       o_empty, o_full;
    reg        o_wr;
    reg  [8:0] o_din;

    fifo_sync #(.W(9), .D(2048), .AW(11)) u_ofifo (
        .clk(clk), .rst_n(rst_n),
        .wr(o_wr), .din(o_din),
        .rd(hls_rx_tvalid && hls_rx_tready),
        .dout(o_dout), .empty(o_empty), .full(o_full)
    );
    assign hls_rx_tdata  = {7'b0, o_dout};
    assign hls_rx_tvalid = !o_empty;

    // ---- o_fifo 占用计数 (节流 + 观测) ----
    // 与 fifo 精确同步: 写入接受 = o_wr && !o_full (播放器只在 !o_full 时写),
    // 读出 = rd。占用 = 写-读滚动。
    reg  [11:0] occ;
    wire        o_pop = hls_rx_tvalid && hls_rx_tready;
    // ---- 看门狗: HLS 有数据可读 (tvalid) 但长期不读 = 内部死锁 -> 复位 ----
    reg  [21:0] starv;      // 位宽 = WDOG 同宽 (22 位, 见参数注释)
    reg  [6:0]  rst_cnt;
    reg         hls_rst_n_r;
    assign hls_rst_n = hls_rst_n_r;
    wire        starve = hls_rx_tvalid && !hls_rx_tready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            occ <= 12'd0; starv <= 21'd0; rst_cnt <= 7'd0; hls_rst_n_r <= 1'b1;
        end else begin
            occ <= occ + (o_wr ? 12'd1 : 12'd0) - (o_pop ? 12'd1 : 12'd0);
            if (rst_cnt != 7'd0) begin
                rst_cnt <= rst_cnt - 7'd1;
                starv   <= 21'd0;
                if (rst_cnt == 7'd1) hls_rst_n_r <= 1'b1;
            end else if (starve) begin
                if (starv >= WDOG) begin
                    starv        <= 21'd0;
                    rst_cnt      <= 7'd64;
                    hls_rst_n_r  <= 1'b0;
                end else begin
                    starv <= starv + 21'd1;
                end
            end else begin
                starv <= 21'd0;
            end
        end
    end

    // ---------------- 字节播放器 ----------------
    // committed 语义: 提交未开播的帧数; P_IDLE 开播拍即 -1 (不等播完) —
    // 若等播完 (done_pulse 拍) 再减, P_IDLE 会在最后一帧播完的下拍读到
    // 未减的旧值 → 幻影开播 → 抢读下一帧的未提交词 (unit TB 实锤)。
    // 开播节流: occ > 256 (o_fifo 约 3-4 帧) 不开新帧 — HLS 读速
    // (~1B/20拍) 远慢于线速, 任其排队灌入会把 HLS 内部 512 词帧 fifo
    // 灌满 → mac_rx 写阻塞 → HLS 永久停读 (泛洪实测实锤)。occ 是 HLS
    // 内部积压的直接代理: 节流后 HLS 内 backlog 恒 ≤ ~4 帧 ≪ 512 词。
    localparam P_IDLE = 2'd0, P_PRE = 2'd1, P_LOAD = 2'd2, P_EMIT = 2'd3;
    reg [1:0]  pstate;
    reg [2:0]  pre_cnt;
    reg [63:0] wreg;
    reg        wlast;
    reg [3:0]  nb;            // 本字有效字节数 (1..8)
    reg [3:0]  idx;

    wire start_play = (pstate == P_IDLE) && (committed != 8'd0) &&
                      (occ <= 12'd256);

    function [3:0] keep2n(input [7:0] k);
        casez (k)
            8'b1111_1111: keep2n = 4'd8;
            8'b1111_111?: keep2n = 4'd7;
            8'b1111_11??: keep2n = 4'd6;
            8'b1111_1???: keep2n = 4'd5;
            8'b1111_????: keep2n = 4'd4;
            8'b111?_????: keep2n = 4'd3;
            8'b11??_????: keep2n = 4'd2;
            default:      keep2n = 4'd1;
        endcase
    endfunction

    reg [7:0] cur_byte;
    always @(*) begin
        case (idx[2:0])
            3'd0: cur_byte = wreg[63:56];
            3'd1: cur_byte = wreg[55:48];
            3'd2: cur_byte = wreg[47:40];
            3'd3: cur_byte = wreg[39:32];
            3'd4: cur_byte = wreg[31:24];
            3'd5: cur_byte = wreg[23:16];
            3'd6: cur_byte = wreg[15:8];
            default: cur_byte = wreg[7:0];
        endcase
    end

    wire last_byte_of_frame = wlast && (idx == nb - 4'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            abort <= 1'b0; in_frame <= 1'b0; resync_drop <= 1'b0;
            committed <= 8'd0;
            stat_commit <= 0; stat_drop <= 0;
            pstate <= P_IDLE; pre_cnt <= 3'd0;
            wreg <= 64'd0; wlast <= 1'b0; nb <= 4'd8; idx <= 4'd0;
            ff_rd <= 1'b0; o_wr <= 1'b0; o_din <= 9'd0;
        end else begin
            ff_rd <= 1'b0; o_wr <= 1'b0;

            // 输入侧 in_frame / resync_drop / abort / commit / rollback
            if (ff_snap) in_frame <= 1'b1;
            if (frame_end) begin
                in_frame <= 1'b0;
                abort    <= 1'b0;
                if (frame_bad) stat_drop  <= stat_drop + 1;
                else           stat_commit <= stat_commit + 1;
            end
            if (trunc_evt) begin
                in_frame  <= 1'b0;
                abort     <= 1'b0;
                stat_drop <= stat_drop + 1;          // 前帧截断残余 + 本帧牺牲
                if (!s_axis_tlast) resync_drop <= 1'b1;
            end else if (resync_drop && s_acc && s_axis_tlast)
                resync_drop <= 1'b0;
            if (s_acc && !s_axis_tuser && ff_full && !abort && in_frame &&
                !s_axis_tlast)
                abort <= 1'b1;                       // 帧身写不下, 吞字打标记
                // (!tlast 门控: 若恰好 TLAST 拍首次满, frame_end 的 frame_bad
                //  已含 ff_full → 回卷, abort 必须留给下一帧清零 — 否则粘住
                //  把下一帧也回卷, 慢路径永久死 (泛洪实测实锤))
            if (ff_snap && ff_full)
                abort <= 1'b1;                       // SOP 即满
            if (sop_1w && !in_frame && !resync_drop)
                stat_drop <= stat_drop + 1;          // 单字 runt

            // 播放器
            case (pstate)
                P_IDLE: if (committed != 8'd0 && occ <= 12'd256) begin
                    pstate  <= P_PRE; pre_cnt <= 3'd0;
                end
                P_PRE: if (!o_full) begin
                    o_wr  <= 1'b1;
                    o_din <= {1'b0, (pre_cnt == 3'd7) ? 8'hD5 : 8'h55};
                    if (pre_cnt == 3'd7) pstate <= P_LOAD;
                    pre_cnt <= pre_cnt + 3'd1;
                end
                P_LOAD: if (!ff_empty) begin
                    wreg   <= ff_dout[63:0];
                    wlast  <= ff_dout[72];
                    nb     <= keep2n(ff_dout[71:64]);
                    idx    <= 4'd0;
                    ff_rd  <= 1'b1;
                    pstate <= P_EMIT;
                end
                P_EMIT: if (!o_full) begin
                    o_wr  <= 1'b1;
                    o_din <= {last_byte_of_frame, cur_byte};
                    if (idx == nb - 4'd1) begin
                        if (wlast) pstate <= P_IDLE;
                        else       pstate <= P_LOAD;
                    end
                    idx <= idx + 4'd1;
                end
                default: pstate <= P_IDLE;
            endcase
            // committed: +1 commit / -1 开播, 同拍互抵
            if (do_commit && !start_play)      committed <= committed + 8'd1;
            else if (!do_commit && start_play) committed <= committed - 8'd1;
        end
    end
endmodule
