`timescale 1ns/1ps
// UDP echo: udp_rx 载荷流 + meta + fend/ferr -> frame_fifo (坏帧回卷) -> udp_tx_frame。
// 帧级判定 (fend) 后才开始转发 -> 端到端延迟 = 帧长 (echo 为测试件;
// 行情数据面走 udp_rx 直出不经过本模块)。
//
// 时序关键: 短帧载荷字在 fend 脉冲后 1..2 拍才上总线 (udp_rx emit 寄存器一拍延迟),
// 故 fend 后挂起 (pend), 等载荷末字实际交付 (accept&&tlast) 或 meta_len==0 再判定。
// 判定与转发并发 (上一帧转发期间新帧照常收/判), 好帧入队 (fwd_pend) 顺序转发。
// 零长载荷帧 (无字): 直接向 tx 发零长帧 (单拍 tlast 且 tkeep=0, ztx 电平挂起到被收)。
module udp_echo (
    input  wire        clk,
    input  wire        rst_n,
    // 来自 udp_rx
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire [1:0]  s_axis_tuser,   // [0]=crc_ok (TLAST 拍)
    input  wire        fend,
    input  wire        ferr,
    input  wire        meta_valid,
    input  wire [47:0] meta_src_mac,
    input  wire [31:0] meta_src_ip,
    input  wire [15:0] meta_src_port,
    input  wire [15:0] meta_len,
    // 本机地址 (回发帧的 src)
    input  wire [47:0] cfg_my_mac,
    input  wire [31:0] cfg_my_ip,
    input  wire [15:0] cfg_my_port,
    // 到 udp_tx_frame (载荷 + 动态 cfg: dst = 原帧 src, 锁存于 meta_valid 拍)
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire [47:0] tx_cfg_dst_mac,
    output wire [31:0] tx_cfg_dst_ip,
    output wire [15:0] tx_cfg_dst_port,
    // 统计
    output reg  [31:0] stat_echo,
    output reg  [31:0] stat_drop_crc
);

    localparam [1:0] S_IDLE = 2'd0, S_FWD = 2'd1;

    reg  [1:0]  state;
    reg         first_b;
    reg         ztx;                    // 零长帧回发占位 (电平)
    reg         pend;                   // fend 已见, 等载荷末字实际交付
    reg         p_err;                  // 本帧坏 (fend 拍锁存)
    reg  [3:0]  fq;                     // 已判定好帧队列深度 (转发一帧期间可积压多帧)
    reg         rback;                  // 回卷脉冲 (判定拍)
    reg  [47:0] meta_mac_r;
    reg  [31:0] meta_ip_r;
    reg  [15:0] meta_port_r;
    reg  [15:0] meta_len_r;

    wire        accept = s_axis_tvalid && s_axis_tready;
    wire [72:0] fdin   = {s_axis_tlast, s_axis_tkeep, s_axis_tdata};
    wire [72:0] fdout;
    wire        fifo_empty, fifo_full;
    wire        fwd_rd  = (state == S_FWD) && m_axis_tvalid && m_axis_tready;
    wire        ztx_ok  = ztx && m_axis_tvalid && m_axis_tready;
    wire        judged  = pend && ((accept && s_axis_tlast) || (meta_len_r == 16'd0));

    assign s_axis_tready = !fifo_full;
    assign tx_cfg_dst_mac  = meta_mac_r;
    assign tx_cfg_dst_ip   = meta_ip_r;
    assign tx_cfg_dst_port = meta_port_r;
    assign m_axis_tdata  = (state == S_FWD) ? fdout[63:0] : 64'h0;
    assign m_axis_tkeep  = (state == S_FWD) ? fdout[71:64] : 8'h00;
    assign m_axis_tlast  = (state == S_FWD) ? fdout[72] : ztx;
    assign m_axis_tvalid = (state == S_FWD) ? !fifo_empty : ztx;

    frame_fifo #(.W(73), .D(2048), .AW(11)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr(accept), .din(fdin),
        .snap(accept && first_b),
        .rollback(rback),
        .rd(fwd_rd), .dout(fdout),
        .empty(fifo_empty), .full(fifo_full)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; first_b <= 1'b1; ztx <= 1'b0;
            pend <= 1'b0; p_err <= 1'b0; fq <= 4'd0; rback <= 1'b0;
            meta_mac_r <= 0; meta_ip_r <= 0; meta_port_r <= 0; meta_len_r <= 0;
            stat_echo <= 0; stat_drop_crc <= 0;
        end else begin
            rback <= 1'b0;
            if (accept && first_b) first_b <= 1'b0;
            if (meta_valid) begin
                meta_mac_r <= meta_src_mac;
                meta_ip_r <= meta_src_ip;
                meta_port_r <= meta_src_port;
                meta_len_r <= meta_len;
            end

            // ---- 帧判定 (与转发并发, 不依赖 state) ----
            if (fend && !ztx && !pend) begin
                pend <= 1'b1;
                p_err <= ferr;
            end else if (judged) begin
                pend <= 1'b0;
                first_b <= 1'b1;
                if (p_err) begin
                    rback <= 1'b1;
                    stat_drop_crc <= stat_drop_crc + 1;
                end else if (meta_len_r == 16'd0) begin
                    ztx <= 1'b1;             // 零长: 直接回发零长帧
                end else begin
                    fq <= fq + 4'd1;         // 好帧入队 (上一帧可能还在转发)
                end
            end

            // ---- 转发 ----
            case (state)
                S_IDLE: begin
                    if (fq != 4'd0 && !ztx) begin
                        fq <= fq - 4'd1;
                        state <= S_FWD;
                    end
                end
                default: begin   // S_FWD: 顺序转发, 帧尾时看队列续转或回 IDLE
                    if (fwd_rd && fdout[72]) begin
                        stat_echo <= stat_echo + 1;
                        if (fq == 4'd0) state <= S_IDLE;
                        else fq <= fq - 4'd1;
                    end
                end
            endcase

            // ---- 零长帧回发 (ztx 电平挂起到 tx 收下; S_FWD 期间被 mux 屏蔽, 回 IDLE 后自然完成) ----
            if (ztx_ok) begin
                ztx <= 1'b0;
                stat_echo <= stat_echo + 1;
            end
        end
    end
endmodule
