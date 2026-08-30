`timescale 1ns/1ps
// slow_cfg_adp: HLS cfg_stream (32b AXIS) -> CAM 配置写 + TCB 更新写。
//
// 记录 = 定长 8 词 (见 hls/src/layer_tcp.cpp cfg_write):
//   w0 = (wscale<<16)|(cmd<<8)|slot   cmd: 0=ADD (建连), 1=DEL (拆除)
//        wscale = 对端 window scale (握手 SYN 选项解析值, fast 侧 snd_wnd 缩放用)
//   w1 = peer_ip            w2 = local_ip
//   w3 = (peer_port<<16)|local_port
//   w4 = peer_mac[47:16]    w5 = (peer_mac[15:0]<<16)|peer_wnd (已按 wscale 缩放)
//   w6 = rcv_nxt (= 对端 ISS+1)
//   w7 = snd_nxt (= 我方 ISS+1, SYN+ACK 已占一个序号)
//
// ADD: CAM 写一条 (sip/dip/sport/dport/dmac) + TCB 七字段
//      (rcv_nxt / snd_nxt / snd_una=snd_nxt / rcv_wnd=0x3000 / snd_wnd=peer_wnd
//       / state=1 ESTABLISHED / wscale)。
// DEL: CAM 该槽清零 (sip=0 永不匹配) + TCB state=0。
// TCB 写经 cfg 仲裁级 (tx>rx>cfg): upd_wr 电平保持到 cfg_gnt 才前进 —
// 无 gnt 反馈的盲写在有其它连接流量时会丢字段 (连接建立错号), 必须等授权。
module slow_cfg_adp (
    input  wire        clk,
    input  wire        rst_n,
    // HLS cfg_stream (32b)
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    // CAM 配置口 (单拍)
    output reg         cam_cfg_wr,
    output reg  [3:0]  cam_cfg_addr,
    output reg  [31:0] cam_cfg_sip,
    output reg  [31:0] cam_cfg_dip,
    output reg  [15:0] cam_cfg_sport,
    output reg  [15:0] cam_cfg_dport,
    output reg  [47:0] cam_cfg_dmac,
    // TCB 更新口 (cfg 仲裁级, 电平 + gnt)
    output reg         upd_wr,
    output reg  [3:0]  upd_id,
    output reg  [2:0]  upd_sel,
    output reg  [31:0] upd_val,
    input  wire        cfg_gnt,
    output reg  [31:0] stat_add,
    output reg  [31:0] stat_del
);
    // 词流缓冲 (HLS 突发 8 词; 解析慢于写入不丢)
    // FWFT 铁律: f_rd 组合 (与消费同拍) — 寄存器化 rd 会让每词被采两次
    // (记录错位一词, CAM/TCB 全错; 已是本工程第三次踩铁律#4)。
    localparam S_RECV = 3'd0, S_CAM = 3'd1, S_TCB = 3'd2, S_TCB_LAST = 3'd3;
    reg [2:0]  state;
    reg [2:0]  wcnt;          // 已收词数 0..8
    wire [31:0] f_dout;
    wire        f_empty, f_full;
    wire        f_rd = (state == S_RECV) && !f_empty;
    assign s_axis_tready = !f_full;

    fifo_sync #(.W(32), .D(16), .AW(4)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr(s_axis_tvalid && s_axis_tready), .din(s_axis_tdata),
        .rd(f_rd), .dout(f_dout), .empty(f_empty), .full(f_full)
    );
    reg [31:0] w0, w1, w2, w3, w4, w5, w6, w7;
    reg [2:0]  tcb_idx;       // TCB 写字段序
    wire [7:0] cmd   = w0[15:8];
    wire [3:0] slot  = w0[3:0];
    wire       is_add = (cmd == 8'd0);
    wire       is_del = (cmd == 8'd1);

    // TCB 当前字段值 (组合选择)
    reg [31:0] tcb_val_c;
    always @(*) begin
        case (tcb_idx)
            3'd0:    tcb_val_c = w6;                    // rcv_nxt
            3'd1:    tcb_val_c = w7;                    // snd_nxt
            3'd2:    tcb_val_c = w7;                    // snd_una
            3'd3:    tcb_val_c = 32'h00003000;          // rcv_wnd 通告 12K
            3'd4:    tcb_val_c = {16'b0, w5[15:0]};     // snd_wnd = 对端窗口(已缩放)
            3'd5:    tcb_val_c = 32'd1;                 // state = ESTABLISHED
            default: tcb_val_c = {28'b0, w0[19:16]};    // 3'd6: wscale
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_RECV; wcnt <= 3'd0; tcb_idx <= 3'd0;
            cam_cfg_wr <= 1'b0; cam_cfg_addr <= 4'd0;
            cam_cfg_sip <= 0; cam_cfg_dip <= 0;
            cam_cfg_sport <= 0; cam_cfg_dport <= 0; cam_cfg_dmac <= 0;
            upd_wr <= 1'b0; upd_id <= 4'd0; upd_sel <= 3'd0; upd_val <= 32'd0;
            stat_add <= 0; stat_del <= 0;
            w0 <= 0; w1 <= 0; w2 <= 0; w3 <= 0; w4 <= 0; w5 <= 0; w6 <= 0; w7 <= 0;
        end else begin
            case (state)
                S_RECV: begin
                    cam_cfg_wr <= 1'b0;
                    if (!f_empty) begin
                        case (wcnt)
                            3'd0: w0 <= f_dout;
                            3'd1: w1 <= f_dout;
                            3'd2: w2 <= f_dout;
                            3'd3: w3 <= f_dout;
                            3'd4: w4 <= f_dout;
                            3'd5: w5 <= f_dout;
                            3'd6: w6 <= f_dout;
                            default: w7 <= f_dout;
                        endcase
                        if (wcnt == 3'd7) begin
                            wcnt <= 3'd0;
                            state <= S_CAM;
                        end else begin
                            wcnt <= wcnt + 3'd1;
                        end
                    end
                end
                S_CAM: begin
                    // CAM 写单拍 (无仲裁, 配置口独占)
                    cam_cfg_wr   <= 1'b1;
                    cam_cfg_addr <= slot;
                    if (is_add) begin
                        cam_cfg_sip   <= w1;
                        cam_cfg_dip   <= w2;
                        cam_cfg_sport <= w3[31:16];
                        cam_cfg_dport <= w3[15:0];
                        cam_cfg_dmac  <= {w4, w5[31:16]};
                        stat_add <= stat_add + 1;
                    end else begin
                        cam_cfg_sip   <= 32'd0;    // 清零槽位 (永不匹配)
                        cam_cfg_dip   <= 32'd0;
                        cam_cfg_sport <= 16'd0;
                        cam_cfg_dport <= 16'd0;
                        cam_cfg_dmac  <= 48'd0;
                        stat_del <= stat_del + 1;
                    end
                    state   <= S_TCB;
                    tcb_idx <= 3'd0;
                end
                S_TCB: begin
                    cam_cfg_wr <= 1'b0;
                    if (is_del) begin
                        // DEL: 只写 state=0
                        upd_wr  <= 1'b1;
                        upd_id  <= slot;
                        upd_sel <= 3'd5;
                        upd_val <= 32'd0;
                        if (cfg_gnt) begin
                            upd_wr <= 1'b0;
                            state  <= S_RECV;
                        end
                    end else begin
                        upd_wr  <= 1'b1;
                        upd_id  <= slot;
                        upd_sel <= tcb_idx;
                        upd_val <= tcb_val_c;
                        if (cfg_gnt) begin
                            if (tcb_idx == 3'd6) begin
                                // upd_sel/upd_val 寄存器比 tcb_idx 晚一拍:
                                // 本拍 gnt 写的是字段 5, wscale 字段 (sel=6)
                                // 要到下一拍才在输出上 — upd_wr 再保持一拍。
                                state <= S_TCB_LAST;
                            end else begin
                                tcb_idx <= tcb_idx + 3'd1;
                            end
                        end
                    end
                end
                S_TCB_LAST: begin
                    // 本拍 upd_sel=6 / upd_val=wscale 已可见, gnt 拍落地 wscale
                    cam_cfg_wr <= 1'b0;
                    upd_wr  <= 1'b1;
                    if (cfg_gnt) begin
                        upd_wr <= 1'b0;
                        state  <= S_RECV;
                    end
                end
                default: state <= S_RECV;
            endcase
        end
    end
endmodule
