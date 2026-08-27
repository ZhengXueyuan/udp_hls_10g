`timescale 1ns/1ps
// TCP echo: tcp_rx 载荷流 + meta + fend/ferr -> frame_fifo (坏帧回卷) -> tcp_tx_frame。
// 帧级判定 (fend) 后才开始转发 -> 端到端延迟 = 帧长 (echo 为测试件)。
//
// 与 udp_echo 的差异:
// - meta 只有 conn_id (寻址由 CAM/TCB 负责); conn_id 进独立 FIFO 随帧排队
//   (udp_echo 单 meta 寄存器在背靠背判定时会串扰, 此处无此问题)
// - tcp_rx 对纯 ACK 段也发 fend (无载荷), 用 has_data 跟踪过滤: 只有出现过
//   meta_valid 的帧才进判定 (tcp_rx 的 meta_valid 仅 plen>0 时发)
// - 零长数据帧不存在 (TCP 无零长数据段), 无 ztx 路径
// - 帧边界由 tcp_tx_frame 的 s_axis_tready 天然隔离 (S_WAIT 起 tready=0,
//   新帧首字被挡住直到 S_IDLE), 无需额外握手
module tcp_echo (
    input  wire        clk,
    input  wire        rst_n,
    // 来自 tcp_rx
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire [1:0]  s_axis_tuser,   // [0]=crc_ok (TLAST 拍)
    input  wire        fend,
    input  wire        ferr,
    input  wire        meta_valid,
    input  wire [3:0]  meta_conn_id,
    input  wire [15:0] meta_len,
    // 到 tcp_tx_frame (载荷 + tid = meta_conn_id 随帧排队)
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire [3:0]  m_axis_tid,
    // 统计
    output reg  [31:0] stat_echo,
    output reg  [31:0] stat_drop_crc
);

    localparam [1:0] S_IDLE = 2'd0, S_FWD = 2'd1;

    reg  [1:0]  state;
    reg         first_b;
    reg         has_data;               // 本帧有载荷 (meta_valid 见过)
    reg         pend;                   // fend 已见, 等载荷末字实际交付
    reg         p_err;                  // 本帧坏 (fend 拍锁存)
    reg         rback;                  // 回卷脉冲 (判定拍)
    reg  [3:0]  fq;                     // 已判定好帧队列深度 (cq 深度冗余, fq 是权威计数)

    wire        accept = s_axis_tvalid && s_axis_tready;
    wire [72:0] fdin   = {s_axis_tlast, s_axis_tkeep, s_axis_tdata};
    wire [72:0] fdout;
    wire        fifo_empty, fifo_full;
    wire [3:0]  cq_dout;
    wire        cq_empty, cq_full;
    wire        fwd_rd  = (state == S_FWD) && m_axis_tvalid && m_axis_tready;
    wire        judged  = pend && (accept && s_axis_tlast);

    assign s_axis_tready = !fifo_full;
    assign m_axis_tdata  = (state == S_FWD) ? fdout[63:0] : 64'h0;
    assign m_axis_tkeep  = (state == S_FWD) ? fdout[71:64] : 8'h00;
    assign m_axis_tlast  = (state == S_FWD) ? fdout[72] : 1'b0;
    assign m_axis_tvalid = (state == S_FWD) && !fifo_empty;
    assign m_axis_tid    = cq_dout;

    frame_fifo #(.W(73), .D(2048), .AW(11)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr(accept), .din(fdin),
        .snap(accept && first_b),
        .rollback(rback),
        .rd(fwd_rd), .dout(fdout),
        .empty(fifo_empty), .full(fifo_full)
    );

    // conn_id 队列: 判定好帧推入, 转发完弹出 (与载荷帧同序)
    wire cq_push = judged && !p_err;
    wire cq_pop  = fwd_rd && fdout[72];
    fifo_sync #(.W(4), .D(16), .AW(4)) u_cq (
        .clk(clk), .rst_n(rst_n),
        .wr(cq_push && !cq_full), .din(meta_conn_id),
        .rd(cq_pop), .dout(cq_dout),
        .empty(cq_empty), .full(cq_full)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; first_b <= 1'b1;
            has_data <= 1'b0; pend <= 1'b0; p_err <= 1'b0; rback <= 1'b0;
            fq <= 4'd0;
            stat_echo <= 0; stat_drop_crc <= 0;
        end else begin
            rback <= 1'b0;
            if (accept && first_b) first_b <= 1'b0;
            if (meta_valid) has_data <= 1'b1;

            // ---- 帧判定 (与转发并发, 不依赖 state); 纯 ACK 段 (无 meta) 不进 pend ----
            if (fend && has_data && !pend) begin
                pend <= 1'b1;
                p_err <= ferr;
            end else if (judged) begin
                pend <= 1'b0;
                has_data <= 1'b0;
                first_b <= 1'b1;
                if (p_err) begin
                    rback <= 1'b1;
                    stat_drop_crc <= stat_drop_crc + 1;
                end
                // 好帧: cq_push 入队 (组合, 本拍)
            end

            // fq 权威计数 (cq_empty 是弹前值, 不能用于帧尾判决)
            case ({cq_push, cq_pop})
                2'b10: fq <= fq + 4'd1;
                2'b01: fq <= fq - 4'd1;
                default: ;
            endcase

            // ---- 转发 ----
            case (state)
                S_IDLE: begin
                    if (fq != 4'd0) state <= S_FWD;
                end
                default: begin   // S_FWD: 顺序转发; 末字拍弹 conn, fq==1 则回 IDLE
                    if (fwd_rd && fdout[72]) begin
                        stat_echo <= stat_echo + 1;
                        if (fq == 4'd1) state <= S_IDLE;
                    end
                end
            endcase
        end
    end
endmodule
