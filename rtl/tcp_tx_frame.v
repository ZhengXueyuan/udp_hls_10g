`timescale 1ns/1ps
// TCP TX 组帧器: ACK 段 (tcp_rx 请求, 无载荷) + app 数据段 (AXIS 字流) ->
// 完整 TCP/IP/以太网帧字流 (给 mac_tx_64)。ACK 优先于数据 (对端时延敏感)。
//
// 帧级递交 (同 udp_tx_frame 原因): TCP 校验和覆盖伪头+头+全载荷, 字段在头里
// (字节 50-51) — 载荷整帧入 FIFO 同时流过 checksum16, TLAST 后校验和落定再发。
//
// 头字构造 (左对齐, 帧首 = tdata[63:56], TCP 头 20B, 头共 54B = 6 整字 + 6 字节):
//   w0 = dst_mac+src_mac[47:32]; w1 = src_mac[31:0]+0800+45+00
//   w2 = total_len+id+0000+40+06; w3 = ip_csum+src_ip+dst_ip[31:16]
//   w4 = dst_ip[15:0]+src_port+dst_port+seq[31:16]
//   w5 = seq[15:0]+ack[31:0]+50(doff)+flags; w6 = window+tcp_csum+urg+载荷[0..1]
// 载荷相对帧头 6 字节偏移: 输出字 = {hold48, 当前载荷字高 2 字节} (hold48 初值 =
// {window, csum, urg}); 溢出尾字 = 末载荷字低 6 字节区左对齐 n-2 字节。
//
// 校验和 (与 UDP 不同!): TCP 头无长度字段, tcp_len 只在伪头计一次; 9 个半字分
// 3 拍 aen 补足 (checksum16 add_val 仅 18 位, 每组 ≤4 项不溢出)。init = src_ip +
// dst_ip + 0x0006。伪头协议字节 0x06。纯 ACK 段 flags=0x10, 数据段 0x18 (PSH+ACK)。
// 数据段 seq = TCB snd_nxt (首拍锁存), 发完 snd_nxt += plen; ack = rcv_nxt。
// 对端信息 (dmac/dip/端口) 由 CAM 读回口按 conn_id 组合取得, 首拍锁存。
// app 契约: 载荷 ≤1500B (plen 12 位, 超 4095 回绕不检查); S_IDLE 因 ACK 优先或
// FIFO 满挡数据期间, app 须保持 tdata/tkeep/tlast/tid 稳定 (presenting 契约)。
// csum_valid 由 fin 时序保证 (aen→fin→取数固定间隔), 不另检查。
module tcp_tx_frame (
    input  wire        clk,
    input  wire        rst_n,
    // app 载荷输入 (左对齐; tid = conn_id, 帧内稳定; 零长帧 = 单拍 tlast 且 tkeep=0)
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire [3:0]  s_axis_tid,
    // ACK 请求 (tcp_rx 脉冲 / tcp_synp SYN+ACK 请求; 入 8 深队列, 满则丢并计数)
    input  wire        ack_req,
    input  wire [3:0]  ack_id,
    input  wire [31:0] ack_val,
    input  wire        ack_syn,        // 1 = SYN+ACK 段 (flags=0x12, 发完 snd_nxt+1)
    // TCB 读口 B (顶层实例化 tcb 并连线)
    output wire [3:0]  rb_id,
    input  wire [31:0] rb_snd_nxt,
    input  wire [31:0] rb_rcv_nxt,
    input  wire [15:0] rb_rcv_wnd,
    // TCB 更新 (数据段末字消费拍组合脉冲: sel=1 snd_nxt <= seq+plen;
    // 与状态回 S_IDLE 同拍写入 — 下一帧最早下拍启动, 读到的是更新后的值)
    output wire        upd_wr,
    output wire [3:0]  upd_id,
    output wire [2:0]  upd_sel,
    output wire [31:0] upd_val,
    // CAM 读回 (顶层连 tcp_cam 读回口; 慢路径保证条目有效)
    output wire [3:0]  cam_rd_id,
    input  wire [47:0] cam_rd_dmac,
    input  wire [31:0] cam_rd_sip,     // 对端 IP = 发送帧 dst IP (dip 字段是本地 IP!)
    input  wire [15:0] cam_rd_sport,   // 对端端口 = 发送 dst_port
    input  wire [15:0] cam_rd_dport,   // 本地端口 = 发送 src_port
    // 配置
    input  wire [47:0] cfg_src_mac,
    input  wire [31:0] cfg_src_ip,
    // 帧字流输出 (接 mac_tx_64)
    output reg  [63:0] m_axis_tdata,
    output reg  [7:0]  m_axis_tkeep,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,
    // 统计
    output reg  [31:0] stat_frames,
    output reg  [31:0] stat_bytes,
    output reg  [31:0] stat_ack,        // 发出的纯 ACK 段数
    output reg  [31:0] stat_ack_drop    // ACK 队列满丢弃
);

    localparam [2:0] S_IDLE = 3'd0, S_RECV = 3'd1, S_WAIT = 3'd2, S_HDR = 3'd3,
                     S_PAY  = 3'd4, S_TAIL = 3'd5, S_DONE = 3'd6;

    reg  [2:0]  state;
    reg  [11:0] plen;
    reg  [11:0] plen_r;
    reg  [15:0] tcp_len_r, total_len_r, ip_csum_r, tcp_csum_r;
    reg  [15:0] id_r, id_cap;
    reg  [2:0]  wait_cnt;
    reg  [2:0]  hcnt;
    reg  [47:0] hold48;
    reg  [63:0] tail_d;    // ljust6 返回 64 位左对齐字, 截断会丢高 2 字节
    reg  [7:0]  tail_k;
    // 帧首拍锁存
    reg  [3:0]  cur_id;
    reg         is_data_r, is_syn_r;
    reg  [31:0] seq_r, ack_r;
    reg  [15:0] wnd_r;
    reg  [15:0] doff_flags_r;
    reg  [47:0] dmac_r;
    reg  [31:0] dip_r;
    reg  [15:0] sport_r, dport_r;

    // ---- ACK 请求队列 ([36:33]=id [32]=syn [31:0]=ack_val) ----
    wire        ackq_full, ackq_empty;
    wire [36:0] ackq_dout;
    wire        pay_full, pay_empty;
    wire        ack_pend = !ackq_empty;
    wire [3:0]  start_id = ack_pend ? ackq_dout[36:33] : s_axis_tid;

    assign rb_id     = (state == S_IDLE) ? start_id : cur_id;
    assign cam_rd_id = (state == S_IDLE) ? start_id : cur_id;

    assign upd_wr  = (state == S_DONE) && (is_data_r || is_syn_r) &&
                     m_axis_tvalid && m_axis_tready;
    assign upd_id  = cur_id;
    assign upd_sel = 3'd1;
    assign upd_val = seq_r + (is_data_r ? {20'b0, plen_r} : 32'd1);

    wire        start_ack  = (state == S_IDLE) && ack_pend;
    wire        start_data = (state == S_IDLE) && !ack_pend &&
                             s_axis_tvalid && !pay_full;

    assign s_axis_tready = ((state == S_RECV) ||
                            ((state == S_IDLE) && !ack_pend)) && !pay_full;
    wire        accept = s_axis_tvalid && s_axis_tready;

    // ---- 载荷 FIFO + 校验和 ----
    wire [72:0] fdin   = {s_axis_tlast, s_axis_tkeep, s_axis_tdata};
    wire [72:0] fdout;
    wire        wr = accept && (s_axis_tkeep != 8'h00);
    wire        pay_load = (state == S_PAY) && (m_axis_tready || !m_axis_tvalid);
    wire        rd = pay_load && (plen_r != 12'd0) && !pay_empty;

    function [3:0] pop8;
        input [7:0] v;
        integer i;
        reg [3:0] c;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]};
            pop8 = c;
        end
    endfunction

    // 末载荷字低 6 字节区左对齐 (溢出尾字, 1..6 字节)
    function [63:0] ljust6;
        input [47:0] w;
        input [2:0]  p;
        begin
            case (p)
                3'd1: ljust6 = {w[47:40], 56'b0};
                3'd2: ljust6 = {w[47:32], 48'b0};
                3'd3: ljust6 = {w[47:24], 40'b0};
                3'd4: ljust6 = {w[47:16], 32'b0};
                3'd5: ljust6 = {w[47:8],  24'b0};
                3'd6: ljust6 = {w[47:0],  16'b0};
                default: ljust6 = 64'b0;
            endcase
        end
    endfunction

    // IP 头校验和 (组合树): S_WAIT 首拍算 (所有字段已锁存)
    function [15:0] ip_csum_calc;
        input [15:0] tlen;
        input [15:0] idc;
        input [31:0] dip;
        reg [19:0] s;
        reg [16:0] f1;
        begin
            s = {4'b0, 16'h4500} + {4'b0, tlen} + {4'b0, idc} + {4'b0, 16'h0000} +
                {4'b0, 16'h4006} + {4'b0, 16'h0000} + {4'b0, cfg_src_ip[31:16]} +
                {4'b0, cfg_src_ip[15:0]} + {4'b0, dip[31:16]} + {4'b0, dip[15:0]};
            f1 = s[15:0] + {12'b0, s[19:16]};
            ip_csum_calc = ~(f1[15:0] + {15'b0, f1[16]});
        end
    endfunction

    // 帧长 (tlast 拍): start_data 时 plen 还是上一帧残留值, 必须显式归零
    wire [11:0] plen_n = (start_data ? 12'd0 : plen) + {8'b0, pop8(s_axis_tkeep)};
    // 校验和伪头初值: dst IP 用组合读回 (dip_r 本拍才锁存)
    wire [31:0] csum_init_val = {4'b0, cfg_src_ip[31:16]} + {4'b0, cfg_src_ip[15:0]} +
                                {4'b0, cam_rd_sip[31:16]} + {4'b0, cam_rd_sip[15:0]} +
                                32'h0006;
    wire        csum_init = start_ack || start_data;
    wire        csum_den  = (start_data || (state == S_RECV)) && accept &&
                            (s_axis_tkeep != 8'h00);
    // aen 三拍补足 9 半字 (每组 ≤4 项 < 2^18): 伪头 tcp_len + TCP 头 (csum/urg=0 不参与)
    wire        csum_aen  = (state == S_WAIT) && (wait_cnt <= 3'd2);
    wire [17:0] aen_v1 = {2'b0, tcp_len_r} + {2'b0, sport_r} + {2'b0, dport_r} +
                         {2'b0, seq_r[31:16]};
    wire [17:0] aen_v2 = {2'b0, seq_r[15:0]} + {2'b0, ack_r[31:16]} +
                         {2'b0, ack_r[15:0]} + {2'b0, doff_flags_r};
    wire [17:0] aen_v3 = {2'b0, wnd_r};
    wire [17:0] aen_val = (wait_cnt == 3'd0) ? aen_v1 :
                          (wait_cnt == 3'd1) ? aen_v2 : aen_v3;
    wire        csum_fin  = (state == S_WAIT) && (wait_cnt == 3'd3);
    wire [15:0] csum;
    wire        csum_valid;

    checksum16 u_csum (
        .clk(clk), .rst_n(rst_n),
        .init(csum_init), .init_val(csum_init_val),
        .den(csum_den), .din(s_axis_tdata), .dkeep(s_axis_tkeep),
        .aen(csum_aen), .add_val(aen_val),
        .fin(csum_fin),
        .csum(csum), .csum_valid(csum_valid)
    );

    fifo_sync #(.W(73), .D(256), .AW(8)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr(wr), .din(fdin),
        .rd(rd), .dout(fdout),
        .empty(pay_empty), .full(pay_full)
    );

    fifo_sync #(.W(37), .D(8), .AW(3)) u_ackq (
        .clk(clk), .rst_n(rst_n),
        .wr(ack_req && !ackq_full), .din({ack_id, ack_syn, ack_val}),
        .rd(start_ack), .dout(ackq_dout),
        .empty(ackq_empty), .full(ackq_full)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            plen <= 0; plen_r <= 0;
            tcp_len_r <= 0; total_len_r <= 0; ip_csum_r <= 0; tcp_csum_r <= 0;
            id_r <= 0; id_cap <= 0;
            wait_cnt <= 0; hcnt <= 0; hold48 <= 0; tail_d <= 0; tail_k <= 0;
            cur_id <= 0; is_data_r <= 0; is_syn_r <= 0;
            seq_r <= 0; ack_r <= 0; wnd_r <= 0; doff_flags_r <= 0;
            dmac_r <= 0; dip_r <= 0; sport_r <= 0; dport_r <= 0;
            m_axis_tdata <= 0; m_axis_tkeep <= 0; m_axis_tvalid <= 0; m_axis_tlast <= 0;
            stat_frames <= 0; stat_bytes <= 0; stat_ack <= 0; stat_ack_drop <= 0;
        end else begin
            if (m_axis_tready && m_axis_tvalid) m_axis_tvalid <= 1'b0;
            if (ack_req && ackq_full) stat_ack_drop <= stat_ack_drop + 1;
            case (state)
                S_IDLE: begin
                    if (start_ack || start_data) begin
                        // 帧首拍: 锁存连接上下文 (rb/cam_rd 组合输出对 start_id 有效)
                        cur_id <= start_id;
                        is_data_r <= start_data;
                        is_syn_r <= start_ack && ackq_dout[32];
                        seq_r <= rb_snd_nxt;
                        ack_r <= start_data ? rb_rcv_nxt : ackq_dout[31:0];
                        wnd_r <= rb_rcv_wnd;
                        doff_flags_r <= {8'h50, start_data ? 8'h18 :
                                         (ackq_dout[32] ? 8'h12 : 8'h10)};
                        dmac_r <= cam_rd_dmac;
                        dip_r <= cam_rd_sip;       // 对端 IP
                        sport_r <= cam_rd_dport;   // 本地端口
                        dport_r <= cam_rd_sport;   // 对端端口
                        id_cap <= id_r;
                        id_r <= id_r + 1;
                        if (start_ack) begin
                            plen_r <= 12'd0;
                            tcp_len_r <= 16'd20;
                            total_len_r <= 16'd40;
                            state <= S_WAIT; wait_cnt <= 3'd0;
                        end else begin
                            plen <= {8'b0, pop8(s_axis_tkeep)};
                            if (s_axis_tlast) begin
                                plen_r <= plen_n;
                                tcp_len_r <= {4'b0, plen_n} + 16'd20;
                                total_len_r <= {4'b0, plen_n} + 16'd40;
                                state <= S_WAIT; wait_cnt <= 3'd0;
                            end else begin
                                state <= S_RECV;
                            end
                        end
                    end
                end
                S_RECV: begin
                    if (accept) begin
                        plen <= plen + {8'b0, pop8(s_axis_tkeep)};
                        if (s_axis_tlast) begin
                            plen_r <= plen_n;
                            tcp_len_r <= {4'b0, plen_n} + 16'd20;
                            total_len_r <= {4'b0, plen_n} + 16'd40;
                            state <= S_WAIT; wait_cnt <= 3'd0;
                        end
                    end
                end
                S_WAIT: begin
                    if (wait_cnt == 3'd0)
                        ip_csum_r <= ip_csum_calc(total_len_r, id_cap, dip_r);
                    if (wait_cnt == 3'd4) begin
                        tcp_csum_r <= csum_valid ? csum : 16'h0;
                        state <= S_HDR; hcnt <= 3'd0;
                    end else begin
                        wait_cnt <= wait_cnt + 3'd1;
                    end
                end
                S_HDR: begin
                    if (!m_axis_tvalid || m_axis_tready) begin
                        m_axis_tvalid <= 1'b1;
                        m_axis_tkeep <= 8'hFF;
                        m_axis_tlast <= 1'b0;
                        case (hcnt)
                            // 每字拼接必须恰 64 位
                            3'd0: m_axis_tdata <= {dmac_r, cfg_src_mac[47:32]};
                            3'd1: m_axis_tdata <= {cfg_src_mac[31:0], 16'h0800, 8'h45, 8'h00};
                            3'd2: m_axis_tdata <= {total_len_r, id_cap, 16'h0000, 8'h40, 8'h06};
                            3'd3: m_axis_tdata <= {ip_csum_r, cfg_src_ip, dip_r[31:16]};
                            3'd4: m_axis_tdata <= {dip_r[15:0], sport_r, dport_r, seq_r[31:16]};
                            default: m_axis_tdata <= {seq_r[15:0], ack_r, doff_flags_r};
                        endcase
                        if (hcnt == 3'd5) begin
                            state <= S_PAY;
                            hold48 <= {wnd_r, tcp_csum_r, 16'h0000};  // w6 前导 6 字节
                        end else begin
                            hcnt <= hcnt + 3'd1;
                        end
                    end
                end
                S_PAY: begin
                    if (!m_axis_tvalid || m_axis_tready) begin
                        if (plen_r == 12'd0) begin
                            // 纯 ACK 段 / 零长数据: w6 = {window, csum, urg} 6 字节收尾
                            m_axis_tvalid <= 1'b1;
                            m_axis_tdata <= {hold48, 16'h0000};   // 拼接必须 64 位
                            m_axis_tkeep <= 8'hFC;
                            m_axis_tlast <= 1'b1;
                            state <= S_DONE;
                        end else if (pay_empty) begin
                            // 欠载防御 (app 契约违规): 提前结束帧
                            m_axis_tvalid <= 1'b1;
                            m_axis_tdata <= {hold48, 16'h0000};
                            m_axis_tkeep <= 8'hFC;
                            m_axis_tlast <= 1'b1;
                            state <= S_DONE;
                        end else begin
                            m_axis_tvalid <= 1'b1;
                            m_axis_tdata <= {hold48, fdout[63:48]};
                            hold48 <= fdout[47:0];
                            if (fdout[72]) begin
                                // 末载荷字: n 有效字节。输出字 = {hold48(6B), cur[63:48](2B)}
                                // n<2: 本拍 6+n 字节收尾; n==2: 满字收尾; n>2: 满字+溢出尾字 (n-2 字节)
                                if (pop8(fdout[71:64]) < 4'd2) begin
                                    m_axis_tkeep <= 8'hFF << (4'd8 -
                                                    (4'd6 + pop8(fdout[71:64])));
                                    m_axis_tlast <= 1'b1;
                                    state <= S_DONE;
                                end else if (pop8(fdout[71:64]) == 4'd2) begin
                                    m_axis_tkeep <= 8'hFF;
                                    m_axis_tlast <= 1'b1;
                                    state <= S_DONE;
                                end else begin
                                    m_axis_tkeep <= 8'hFF;
                                    m_axis_tlast <= 1'b0;
                                    tail_d <= ljust6(fdout[47:0],
                                                     pop8(fdout[71:64]) - 4'd2);
                                    tail_k <= 8'hFF << (4'd8 -
                                              (pop8(fdout[71:64]) - 4'd2));
                                    state <= S_TAIL;
                                end
                            end else begin
                                m_axis_tkeep <= 8'hFF;
                                m_axis_tlast <= 1'b0;
                            end
                        end
                    end
                end
                S_TAIL: begin
                    if (!m_axis_tvalid || m_axis_tready) begin
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata <= tail_d;
                        m_axis_tkeep <= tail_k;
                        m_axis_tlast <= 1'b1;
                        state <= S_DONE;
                    end
                end
                default: begin   // S_DONE: 等末字消费 (upd_* 组合脉冲突发于本拍)
                    if (!m_axis_tvalid || m_axis_tready) begin
                        stat_frames <= stat_frames + 1;
                        stat_bytes <= stat_bytes + plen_r;
                        if (!is_data_r) stat_ack <= stat_ack + 1;
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end
endmodule
