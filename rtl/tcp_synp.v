`timescale 1ns/1ps
// P4-lite SYN 应答器 (板测/bring-up 用; 正式慢路径归 P4 HLS 层)。
// 监听 tcp_rx SYN sideband: 纯 SYN 且目的端口 == cfg_listen 时, 占用 CAM 条目 0 +
// TCB0, 配置 4 元组+对端 MAC 并把连接置 ESTABLISHED (rcv_nxt=对端 iss+1,
// snd_nxt=snd_una=cfg_iss), 然后请 tcp_tx_frame 回 SYN+ACK (ack=rcv_nxt)。
// 对端重传 SYN 到达时整套重复执行 (幂等; SYN+ACK 丢失场景自愈)。
// CAM/TCB 写发生在握手静默期 (无流量), 仲裁属 cfg 最低优先级, 无 gnt 反馈 —
// 一拍一字段顺序写, 共 ~9 拍完成, 远快于任何 RTT。
module tcp_synp (
    input  wire        clk,
    input  wire        rst_n,
    // tcp_rx SYN sideband
    input  wire        syn_v,
    input  wire [47:0] syn_smac,
    input  wire [31:0] syn_sip,
    input  wire [15:0] syn_sport,
    input  wire [15:0] syn_dport,
    input  wire [31:0] syn_seq,
    input  wire [15:0] syn_wnd,
    // CAM 配置 (条目 0 独占; 板级无其它写者)
    output reg         cfg_wr,
    output wire [3:0]  cfg_addr,
    output reg  [31:0] cfg_sip,
    output reg  [31:0] cfg_dip,
    output reg  [15:0] cfg_sport,
    output reg  [15:0] cfg_dport,
    output reg  [47:0] cfg_dmac,
    // TCB 写 (cfg 级)
    output reg         upd_wr,
    output wire [3:0]  upd_id,
    output reg  [2:0]  upd_sel,
    output reg  [31:0] upd_val,
    // SYN+ACK 请求 (进 tcp_tx_frame ACK 队列, syn=1)
    output reg         sack_req,
    output wire [3:0]  sack_id,
    output reg  [31:0] sack_ackval,
    // 配置
    input  wire [31:0] cfg_my_ip,
    input  wire [15:0] cfg_listen,     // 只应答此本地端口的 SYN
    input  wire [31:0] cfg_iss
);
    localparam [1:0] S_IDLE = 2'd0, S_CAM = 2'd1, S_TCB = 2'd2, S_SACK = 2'd3;
    reg [1:0]  state;
    reg [2:0]  tcb_idx;
    reg [31:0] rcv_nxt_r;

    assign cfg_addr = 4'd0;
    assign upd_id   = 4'd0;
    assign sack_id  = 4'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; tcb_idx <= 0;
            cfg_wr <= 0; cfg_sip <= 0; cfg_dip <= 0; cfg_sport <= 0; cfg_dport <= 0;
            cfg_dmac <= 0;
            upd_wr <= 0; upd_sel <= 0; upd_val <= 0;
            sack_req <= 0; sack_ackval <= 0; rcv_nxt_r <= 0;
        end else begin
            cfg_wr <= 1'b0; upd_wr <= 1'b0; sack_req <= 1'b0;   // 脉冲型每拍清零
            case (state)
                S_IDLE: begin
                    if (syn_v && (syn_dport == cfg_listen)) begin
                        cfg_sip <= syn_sip; cfg_dip <= cfg_my_ip;
                        cfg_sport <= syn_sport; cfg_dport <= syn_dport;
                        cfg_dmac <= syn_smac;
                        rcv_nxt_r <= syn_seq + 32'd1;
                        state <= S_CAM;
                    end
                end
                S_CAM: begin
                    cfg_wr <= 1'b1;              // 字段上一拍已锁存
                    state <= S_TCB; tcb_idx <= 3'd0;
                end
                S_TCB: begin
                    upd_wr <= 1'b1;
                    upd_sel <= tcb_idx;
                    case (tcb_idx)
                        3'd0: upd_val <= syn_seq + 32'd1;      // rcv_nxt
                        3'd1: upd_val <= cfg_iss;              // snd_nxt
                        3'd2: upd_val <= cfg_iss;              // snd_una
                        3'd3: upd_val <= 32'h00003000;         // rcv_wnd (通告 12K; echo fifo 16K 留 4K 余量)
                        3'd4: upd_val <= {16'b0, syn_wnd};     // snd_wnd = 对端通告
                        default: upd_val <= 32'd1;             // state = ESTABLISHED
                    endcase
                    if (tcb_idx == 3'd5) state <= S_SACK;
                    else tcb_idx <= tcb_idx + 3'd1;
                end
                S_SACK: begin
                    sack_req <= 1'b1;
                    sack_ackval <= rcv_nxt_r;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
