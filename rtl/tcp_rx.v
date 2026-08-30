`timescale 1ns/1ps
// TCP RX: 段解析 (w0..w6) + CAM 4 元组匹配 + seq==rcv_nxt 顺序流检查 + 载荷直出 (6 字节偏移)
// + 每数据段 ACK 请求 + TCB 更新 (rcv_nxt/snd_una/snd_wnd, drain 排序一字段一拍)。
//
// 字节布局 (帧首 = tdata[63:56], 无 VLAN, TCP 头 20B, 载荷偏移 = 54 字节 = 6 整字 + 6 字节):
//   w4 = dst_ip[15:0]+src_port+dst_port+seq[31:16]
//   w5 = seq[15:0]+ack[31:0]+data_off/reserved+flags
//   w6 = window+tcp_csum+urg+载荷[0..1]
// 载荷流 = 源字流偏移 6 字节: 输出字 = {上一源字低 2 字节, 当前源字高 6 字节}。
//
// P3 范围 (握手/重传/RTO 归 P4 慢路径): 仅 ESTABLISHED 数据段; 顺序流假设
// 只接受 seg.seq == rcv_nxt; 乱序/重复 (窗口内) 丢数据仍回 ACK (快速重传依赖);
// 窗口外丢段不回 ACK; SYN/FIN/RST/带选项段丢弃 (P4 处理); 纯 ACK 段只更新
// snd_una/snd_wnd, 绝不回 ACK (防 ACK 环)。TCP 校验和 cut-through 无法验证, 不查。
// 填充帧: pop8(TLAST) 允许 > 剩余载荷 (60B 最小帧填充), 多余字节按填充忽略。
// 坏 FCS 段: 载荷照发 (tuser[0]=0 标记) 但不回 ACK、不推进 rcv_nxt (对端重传)。
module tcp_rx (
    input  wire        clk,
    input  wire        rst_n,
    // 来自 mac_rx_64
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,   // SOP
    input  wire        s_axis_tcrs,    // TLAST: FCS 正确
    input  wire        s_axis_terr,    // TLAST: 帧内 rx_er
    // 配置: echo 应用场景置 1 — 被接受的顺序数据段不再发纯 ACK (echo 帧自带
    // ACK 位+ack 号, 纯 ACK 冗余)。板测实锤: 每段 2 帧使 TX 比 RX 慢 16%
    // (536B 段) → echo fifo 持续净流入 → 溢出丢段 → 对端重传雪崩 (1.5Mbps)。
    // dup/ooo (drop_ack) 路径不受此门控 (快速重传依赖), 纯 ACK 本就不回。
    input  wire        cfg_suppress_data_ack,
    // 载荷直出 (左对齐; meta_valid 指示帧首)
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire [1:0]  m_axis_tuser,   // [0]=crc_ok [1]=err (TLAST 拍)
    output wire        fend,           // 接受帧完成脉冲 (载荷 TLAST 拍 / 纯 ACK 帧尾拍)
    output wire        ferr,           // fend 拍有效: 帧坏 (FCS 错或 rx_er)
    // 每帧元数据 (meta_valid 脉冲 = w6 接受拍, 即载荷首拍前)
    output wire        meta_valid,
    output wire [31:0] meta_src_ip,
    output wire [15:0] meta_src_port,
    output wire [15:0] meta_len,       // 载荷字节数 = IP total_len - 40
    output wire [3:0]  meta_conn_id,
    output wire [31:0] meta_seq,
    // TCB 读口 A (顶层实例化 tcb 并连线; 本模块仅 w5 拍组合判读)
    output wire [3:0]  ra_id,
    input  wire [31:0] ra_rcv_nxt,
    input  wire [31:0] ra_snd_nxt,
    input  wire [31:0] ra_snd_una,
    input  wire [15:0] ra_rcv_wnd,
    input  wire [3:0]  ra_state,
    input  wire [3:0]  ra_wscale,   // 对端 window scale (snd_wnd drain 缩放用)
    // TCB 更新 (fend 后 drain: 拍1 rcv_nxt, 拍2 snd_una, 拍3 snd_wnd;
    // 组合电平输出, upd_gnt 未给则保持该字段 — 顶层仲裁必须无损 (tx 优先时 rx 靠 gnt 顺延)
    output wire        upd_wr,
    output wire [3:0]  upd_id,
    output wire [2:0]  upd_sel,
    output wire [31:0] upd_val,
    input  wire        upd_gnt,
    // ACK 请求 (TX 侧消费: 发无载荷 ACK 段, ack 号 = ack_val)
    output wire        ack_req,
    output wire [3:0]  ack_id,
    output wire [31:0] ack_val,
    // SYN sideband (P4-lite 握手用): 纯 SYN 段帧尾脉冲 (FCS 好才发), 字段全锁存
    output reg         syn_v,
    output wire [47:0] syn_smac,
    output wire [31:0] syn_sip,
    output wire [15:0] syn_sport,
    output wire [15:0] syn_dport,
    output wire [31:0] syn_seq,
    output wire [15:0] syn_wnd,
    // CAM 查询 (外部 tcp_cam 实例, 与 TX 读回共享同一份连接表;
    // q_* 组合输出在 w4 拍有效, q_hit/q_id 同拍返回)
    output wire [31:0] cam_q_sip,
    output wire [31:0] cam_q_dip,
    output wire [15:0] cam_q_sport,
    output wire [15:0] cam_q_dport,
    input  wire        cam_q_hit,
    input  wire [3:0]  cam_q_id,
    // 统计
    output reg  [31:0] stat_pass,          // 接受且 FCS 好 (含纯 ACK)
    output reg  [31:0] stat_drop_nonmatch, // 头坏/非 TCP/CAM 未命中/状态/标志/带选项/窗口外/截断
    output reg  [31:0] stat_drop_ipcsum,   // IP 头校验和错
    output reg  [31:0] stat_drop_crc,      // 接受但 FCS 坏 (载荷交付, 不回 ACK)
    output reg  [31:0] stat_drop_seq,      // 窗口内 seq 不符 (重复/乱序): 丢数据仍回 ACK
    output reg  [31:0] stat_ack,           // ACK 请求数
    output reg  [31:0] stat_bytes          // 接受且 FCS 好的载荷字节
);

    localparam [2:0] S_HDR = 3'd0, S_PAY = 3'd1, S_PAD = 3'd2, S_DROP = 3'd3, S_TAIL = 3'd4;
    localparam [3:0] ESTAB = 4'd1;   // tcb state: 1 = ESTABLISHED (P4 加握手态)

    reg  [2:0]  state;
    reg  [2:0]  wcnt;
    reg  [15:0] w1_lo, w3_r;             // w3_r[15:0] = dst_ip[31:16]
    reg  [63:0] w2_r;                    // 必须 64 位 (IP 校验和树读全部 4 半字)
    reg  [19:0] ipc_s9;
    reg  [15:0] mac_lo;                  // src_mac[47:32] (SYN 应答要用对端 MAC)
    reg  [31:0] mac_hi;                  // src_mac[31:0]
    reg  [31:0] src_ip_r;
    reg  [15:0] src_port_r, seq_hi_r, dport_r;
    reg         syn_l, drop_syn_r;
    reg  [15:0] syn_wnd_r;
    reg         cam_hit_l;
    reg  [3:0]  conn_id_l;
    // w5 拍判读锁存 (w5->w6 沿)
    reg         acc_l, ackresp_l, ack_adv_l;
    reg  [31:0] ack32_l, seq32_l, rcv_nxt_l;
    reg  [15:0] plen_l;                  // 载荷字节数 = IP total_len - 40
    reg  [15:0] wnd_l;                   // w6 拍锁存对端窗口
    reg         drop_ack;
    reg  [15:0] hold16;                  // 上一源字低 2 字节 (载荷字节 8j..8j+1)
    reg  [15:0] pcount;
    reg         emit_v;
    reg  [63:0] emit_d;
    reg  [7:0]  emit_k;
    reg         emit_l;
    reg  [1:0]  emit_u;
    reg         tail_stage;
    reg  [63:0] tail_d;
    reg  [7:0]  tail_k;
    reg  [1:0]  tail_u;
    // fend 后 TCB 更新 pend + drain FSM
    reg         pend_rcv, pend_una, pend_wnd;
    reg  [3:0]  pend_id;
    reg  [31:0] pend_rcv_val, pend_una_val;
    reg  [15:0] pend_wnd_val;
    reg  [1:0]  drn;

    wire        accept = s_axis_tvalid && s_axis_tready;

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

    // 1..2 字节窗口左对齐 (短载荷尾字 / 溢出尾字共用)
    function [63:0] ljust2;
        input [15:0] w;
        input [2:0]  p;
        begin
            case (p)
                3'd1: ljust2 = {w[15:8], 56'b0};
                default: ljust2 = {w[15:0], 48'b0};
            endcase
        end
    endfunction

    function [15:0] fold16x;
        input [19:0] v;
        reg [16:0] f1;
        begin
            f1 = v[15:0] + {12'b0, v[19:16]};
            fold16x = f1[15:0] + {15'b0, f1[16]};
        end
    endfunction

    // IP 头校验和: 同 udp_rx (proto 字节不同, 校验和覆盖同样 20 字节)
    wire [19:0] ipc_sum9 = {4'b0, w1_lo} + {4'b0, w2_r[15:0]} + {4'b0, w2_r[31:16]} +
                           {4'b0, w2_r[47:32]} + {4'b0, w2_r[63:48]} +
                           {4'b0, s_axis_tdata[15:0]} + {4'b0, s_axis_tdata[31:16]} +
                           {4'b0, s_axis_tdata[47:32]} + {4'b0, s_axis_tdata[63:48]};
    wire [19:0] ipc_sum10 = ipc_s9 + {4'b0, s_axis_tdata[63:48]};
    wire        ipcsum_ok = (fold16x(ipc_sum10) == 16'hFFFF);
    wire        hdr_ok1   = (wcnt == 3'd1) && (s_axis_tdata[31:16] == 16'h0800) &&
                            (s_axis_tdata[15:8] == 8'h45);
    wire        hdr_ok2   = (wcnt == 3'd2) && (s_axis_tdata[7:0] == 8'h06);

    // ---- w5 拍判读 (组合, 寄存器 ra_id 提供 TCB 读) ----
    assign ra_id = conn_id_l;
    wire [31:0] seq32    = {seq_hi_r, s_axis_tdata[63:48]};   // seq[15:0] = 字节 40..41
    wire [31:0] ack32    = s_axis_tdata[47:16];               // ack[31:0] = 字节 42..45
    wire [7:0]  flags    = s_axis_tdata[7:0];
    wire        flags_ok = flags[4] && !flags[2] && !flags[1] && !flags[0];  // ACK 置, RST/SYN/FIN 清
    wire        doff_ok  = (s_axis_tdata[15:12] == 4'd5);
    wire        state_ok = (ra_state == ESTAB);
    wire        len_ok   = (w2_r[63:48] >= 16'd40);
    wire [31:0] seq_diff = seq32 - ra_rcv_nxt;
    wire        win_ok   = (seq_diff < {16'b0, ra_rcv_wnd});
    wire        seq_eq   = (seq32 == ra_rcv_nxt);
    wire        seq_lt   = (seq32 < ra_rcv_nxt);   // 重复/旧段 (回绕安全: 无符号比较)
    wire        ack_ok   = ((ack32 - ra_snd_una) <= (ra_snd_nxt - ra_snd_una));
    wire        ack_adv  = ack_ok && (ack32 != ra_snd_una);
    wire [15:0] plen_w   = w2_r[63:48] - 16'd40;
    wire        frag_ok  = (w2_r[29:16] == 14'h0);   // MF=0 且片偏移=0 (分片段丢给 P4)
    wire        base_ok  = cam_hit_l && state_ok && flags_ok && doff_ok && len_ok &&
                           frag_ok;
    wire        acc      = base_ok && win_ok && seq_eq;
    // 窗口内乱序 (seq > rcv_nxt) 与重复 (seq < rcv_nxt): 丢数据仍回 ACK (快速重传/dup-ACK 依赖)
    wire        ackresp  = base_ok && !seq_eq && (win_ok || seq_lt) && (plen_w != 16'd0);

    // ---- 帧尾/ACK 组合信号 ----
    wire [3:0] pop8w   = pop8(s_axis_tkeep);
    wire [15:0] pay_r   = plen_l - pcount;      // TLAST 拍剩余载荷字节
    wire w6_tlast_ok = acc_l && (plen_l <= 16'd2) && (pop8w == 4'd6 + plen_l[3:0]);
    wire fend_w6 = (state == S_HDR) && accept && (wcnt == 3'd6) && s_axis_tlast && w6_tlast_ok;
    wire fend_pay = (state == S_PAY) && (!emit_v || m_axis_tready) && accept &&
                    s_axis_tlast && ({12'b0, pop8w} >= pay_r);
    wire fend_pad = (state == S_PAD) && accept && s_axis_tlast;
    assign fend   = fend_w6 || fend_pay || fend_pad;
    assign ferr   = !s_axis_tcrs || s_axis_terr;
    // ACK 请求: 接受的数据段 (FCS 好, 可被 cfg_suppress_data_ack 抑制 — echo 场景)
    // / 窗口内 seq 不符数据段 (丢数据仍回 ACK); 纯 ACK 绝不回
    assign ack_req = (((fend_w6 && (plen_l != 16'd0)) || fend_pay) && s_axis_tcrs &&
                      !cfg_suppress_data_ack) ||
                     ((state == S_HDR) && accept && (wcnt == 3'd6) && s_axis_tlast &&
                      ackresp_l && s_axis_tcrs) ||
                     ((state == S_DROP) && accept && s_axis_tlast && drop_ack && s_axis_tcrs);
    assign ack_id  = conn_id_l;
    assign ack_val = (fend_w6 || fend_pay) ? (rcv_nxt_l + {16'b0, plen_l}) : rcv_nxt_l;

    assign meta_valid   = (state == S_HDR) && accept && (wcnt == 3'd6) &&
                          acc_l && (plen_l != 16'd0) &&
                          (!s_axis_tlast || w6_tlast_ok);
    assign meta_src_ip   = src_ip_r;
    assign meta_src_port = src_port_r;
    assign meta_len      = plen_l;
    assign meta_conn_id  = conn_id_l;
    assign meta_seq      = seq32_l;

    // w6 拍可能发短帧末字, 须等上一帧尾字排空 (硬背压跨帧角例)
    assign s_axis_tready = (state == S_PAY) ? (m_axis_tready || !emit_v) :
                           (state == S_TAIL) ? 1'b0 :
                           ((state == S_HDR) && (wcnt == 3'd6)) ?
                               (m_axis_tready || !emit_v) : 1'b1;
    assign m_axis_tdata  = emit_d;
    assign m_axis_tkeep  = emit_k;
    assign m_axis_tvalid = emit_v;
    assign m_axis_tlast  = emit_l;
    assign m_axis_tuser  = emit_u;

    // CAM 查询 (外部实例): 4 元组组合输出, w4 拍锁存结果
    assign cam_q_sip   = src_ip_r;
    assign cam_q_dip   = {w3_r[15:0], s_axis_tdata[63:48]};
    assign cam_q_sport = s_axis_tdata[47:32];
    assign cam_q_dport = s_axis_tdata[31:16];

    assign syn_smac  = {mac_lo, mac_hi};
    assign syn_sip   = src_ip_r;
    assign syn_sport = src_port_r;
    assign syn_dport = dport_r;
    assign syn_seq   = seq32_l;
    assign syn_wnd   = syn_wnd_r;

    wire [15:0] wnd_f = fend_w6 ? s_axis_tdata[63:48] : wnd_l;
    // snd_wnd drain 按握手 wscale 缩放 (P4b-6 窗口门控的真实量纲; 钳 16 位 —
    // echo 在飞上限 = 我方通告 rcv_wnd 0x3000 << 64K, 钳位不影响门控语义)。
    // 32 位扩展再钳: wscale>7 (HLS 侧钳 ws<=7 是软契约, 此处自防守)
    wire [31:0] wnd_scaled = {16'b0, wnd_f} << ra_wscale;
    wire [15:0] wnd_ws    = |wnd_scaled[31:16] ? 16'hFFFF : wnd_scaled[15:0];

    // TCB 更新口 (组合: drn 状态电平保持, gnt 拍被写进 TCB 并顺延下一字段)
    assign upd_wr  = ((drn == 2'd1) && pend_rcv) || ((drn == 2'd2) && pend_una) ||
                     ((drn == 2'd3) && pend_wnd);
    assign upd_id  = pend_id;
    assign upd_sel = (drn == 2'd1) ? 3'd0 : (drn == 2'd2) ? 3'd2 : 3'd4;
    assign upd_val = (drn == 2'd1) ? pend_rcv_val :
                     (drn == 2'd2) ? pend_una_val : {16'b0, pend_wnd_val};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_HDR; wcnt <= 0;
            w1_lo <= 0; w2_r <= 0; w3_r <= 0; ipc_s9 <= 0;
            src_ip_r <= 0; src_port_r <= 0; seq_hi_r <= 0; dport_r <= 0;
            mac_lo <= 0; mac_hi <= 0;
            syn_l <= 0; drop_syn_r <= 0; syn_wnd_r <= 0; syn_v <= 0;
            cam_hit_l <= 0; conn_id_l <= 0;
            acc_l <= 0; ackresp_l <= 0; ack_adv_l <= 0;
            ack32_l <= 0; seq32_l <= 0; rcv_nxt_l <= 0; plen_l <= 0; wnd_l <= 0;
            drop_ack <= 0; hold16 <= 0; pcount <= 0;
            emit_v <= 0; emit_d <= 0; emit_k <= 0; emit_l <= 0; emit_u <= 0;
            tail_stage <= 0; tail_d <= 0; tail_k <= 0; tail_u <= 0;
            pend_rcv <= 0; pend_una <= 0; pend_wnd <= 0;
            pend_id <= 0; pend_rcv_val <= 0; pend_una_val <= 0; pend_wnd_val <= 0;
            drn <= 0;
            stat_pass <= 0; stat_drop_nonmatch <= 0; stat_drop_ipcsum <= 0;
            stat_drop_crc <= 0; stat_drop_seq <= 0; stat_ack <= 0; stat_bytes <= 0;
        end else begin
            if (m_axis_tready && emit_v) emit_v <= 1'b0;   // 输出被消费
            syn_v <= 1'b0;                                 // 脉冲型: 每拍默认清零
            // ---- fend 拍锁存 TCB 更新 (drain 下拍开始, 一字段一拍, gnt 未给则保持) ----
            if (fend) begin
                pend_rcv <= acc_l && (plen_l != 16'd0) && s_axis_tcrs;
                pend_una <= ack_adv_l && s_axis_tcrs;
                pend_wnd <= s_axis_tcrs;
                pend_id <= conn_id_l;
                pend_rcv_val <= rcv_nxt_l + {16'b0, plen_l};
                pend_una_val <= ack32_l;
                pend_wnd_val <= wnd_ws;
                drn <= 2'd1;
            end else begin
                // ---- drain FSM (upd_* 组合输出, gnt 拍才前进) ----
                case (drn)
                    2'd1: if (!pend_rcv || upd_gnt) drn <= 2'd2;
                    2'd2: if (!pend_una || upd_gnt) drn <= 2'd3;
                    2'd3: if (!pend_wnd || upd_gnt) drn <= 2'd0;
                    default: ;
                endcase
            end
            if (ack_req) stat_ack <= stat_ack + 1;
            case (state)
                S_HDR: begin
                    if (accept) begin
                        if (s_axis_tuser) begin
                            // 截断防御: 本字即新帧 w0。仅清半帧残留 (emit_l=0);
                            // 完整帧尾 (emit_l=1) 未消费时必须保留, w6 门控等其排空
                            if (!emit_l) emit_v <= 1'b0;
                        end
                        if (s_axis_tlast && (wcnt != 3'd6)) begin
                            // 头没走完帧就结束 (TCP 最小帧 54B, w6 之前 TLAST 必畸形)
                            state <= S_HDR; wcnt <= 3'd0;
                            stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                        end else begin
                            case (s_axis_tuser ? 3'd0 : wcnt)
                                3'd0: begin
                                    if (s_axis_tkeep != 8'hFF) begin
                                        state <= S_DROP; drop_ack <= 1'b0; drop_syn_r <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        mac_lo <= s_axis_tdata[15:0];   // src_mac[47:32]
                                        drop_syn_r <= 1'b0;
                                        wcnt <= 3'd1;
                                    end
                                end
                                3'd1: begin
                                    if (s_axis_tkeep != 8'hFF || !hdr_ok1) begin
                                        state <= S_DROP; drop_ack <= 1'b0; drop_syn_r <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        mac_hi <= s_axis_tdata[63:32];
                                        w1_lo <= s_axis_tdata[15:0];
                                        wcnt <= 3'd2;
                                    end
                                end
                                3'd2: begin
                                    if (s_axis_tkeep != 8'hFF || !hdr_ok2) begin
                                        state <= S_DROP; drop_ack <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        w2_r <= s_axis_tdata;
                                        wcnt <= 3'd3;
                                    end
                                end
                                3'd3: begin
                                    if (s_axis_tkeep != 8'hFF) begin
                                        state <= S_DROP; drop_ack <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        w3_r <= s_axis_tdata[15:0];
                                        src_ip_r <= s_axis_tdata[47:16];
                                        ipc_s9 <= ipc_sum9;
                                        wcnt <= 3'd4;
                                    end
                                end
                                3'd4: begin
                                    if (s_axis_tkeep != 8'hFF) begin
                                        state <= S_DROP; drop_ack <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else if (!ipcsum_ok) begin
                                        state <= S_DROP; drop_ack <= 1'b0;
                                        stat_drop_ipcsum <= stat_drop_ipcsum + 1;
                                    end else begin
                                        cam_hit_l <= cam_q_hit;
                                        conn_id_l <= cam_q_id;
                                        src_port_r <= s_axis_tdata[47:32];
                                        dport_r <= s_axis_tdata[31:16];
                                        seq_hi_r <= s_axis_tdata[15:0];
                                        wcnt <= 3'd5;
                                    end
                                end
                                3'd5: begin
                                    if (s_axis_tkeep != 8'hFF) begin
                                        state <= S_DROP; drop_ack <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        acc_l <= acc;
                                        ackresp_l <= ackresp;
                                        ack_adv_l <= ack_adv;
                                        ack32_l <= ack32;
                                        seq32_l <= seq32;
                                        plen_l <= plen_w;
                                        rcv_nxt_l <= ra_rcv_nxt;
                                        syn_l <= (flags == 8'h02);   // 纯 SYN (无 ACK/RST/FIN)
                                        wcnt <= 3'd6;
                                    end
                                end
                                default: begin   // wcnt==6: 判定 + 载荷入口
                                    syn_wnd_r <= s_axis_tdata[63:48];
                                    if (s_axis_tlast) begin
                                        state <= S_HDR; wcnt <= 3'd0;
                                        if (w6_tlast_ok) begin
                                            // 纯 ACK (plen=0) 或短载荷 (plen=1..2, 无填充)
                                            if (s_axis_tcrs) begin
                                                stat_pass <= stat_pass + 1;
                                                stat_bytes <= stat_bytes + plen_l;
                                            end else begin
                                                stat_drop_crc <= stat_drop_crc + 1;
                                            end
                                            if (plen_l != 16'd0) begin
                                                emit_v <= 1'b1;
                                                emit_d <= ljust2(s_axis_tdata[15:0], plen_l[2:0]);
                                                emit_k <= 8'hFF << (4'd8 - plen_l[3:0]);
                                                emit_l <= 1'b1;
                                                emit_u <= {s_axis_terr, s_axis_tcrs};
                                            end
                                        end else if (ackresp_l) begin
                                            stat_drop_seq <= stat_drop_seq + 1;
                                        end else begin
                                            // 纯 SYN 短帧 (w6-tlast): 帧尾即报握手
                                            if (syn_l && s_axis_tcrs && !s_axis_terr)
                                                syn_v <= 1'b1;
                                            stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                        end
                                    end else if (acc_l) begin
                                        if (plen_l == 16'd0) begin
                                            state <= S_PAD;   // 纯 ACK 带填充: 吞到帧尾
                                        end else begin
                                            state <= S_PAY;
                                            hold16 <= s_axis_tdata[15:0];
                                            pcount <= (plen_l >= 16'd2) ? 16'd2 : 16'd1;
                                        end
                                        wnd_l <= s_axis_tdata[63:48];
                                        wcnt <= 3'd7;
                                    end else if (ackresp_l) begin
                                        state <= S_DROP; drop_ack <= 1'b1; drop_syn_r <= 1'b0;
                                        stat_drop_seq <= stat_drop_seq + 1;
                                    end else begin
                                        state <= S_DROP; drop_ack <= 1'b0;
                                        drop_syn_r <= syn_l;   // SYN 帧在 S_DROP 帧尾报握手
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end
                                end
                            endcase
                        end
                    end
                end
                S_PAY: begin
                    if ((!emit_v || m_axis_tready) && accept) begin
                        if (s_axis_tuser) begin
                            // 截断防御: 丢弃当前帧残余, 本字即新帧 w0
                            if (!emit_l) emit_v <= 1'b0;
                            if (s_axis_tlast) begin
                                state <= S_HDR; wcnt <= 3'd0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else if (s_axis_tkeep != 8'hFF) begin
                                state <= S_DROP; drop_ack <= 1'b0; drop_syn_r <= 1'b0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else begin
                                mac_lo <= s_axis_tdata[15:0];   // 本字即新帧 w0
                                drop_syn_r <= 1'b0;
                                state <= S_HDR; wcnt <= 3'd1;
                            end
                        end else if (s_axis_tlast) begin
                            state <= S_HDR; wcnt <= 3'd0;
                            if ({12'b0, pop8w} < pay_r) begin
                                // 截断
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else begin
                                if (s_axis_tcrs) begin
                                    stat_pass <= stat_pass + 1;
                                    stat_bytes <= stat_bytes + plen_l;
                                end else begin
                                    stat_drop_crc <= stat_drop_crc + 1;
                                end
                                emit_v <= 1'b1;
                                emit_u <= {s_axis_terr, s_axis_tcrs};
                                if (pay_r == 16'd0) begin
                                    // 短载荷带填充: 只剩 hold16
                                    emit_d <= ljust2(hold16, plen_l[2:0]);
                                    emit_k <= 8'hFF << (4'd8 - plen_l[3:0]);
                                    emit_l <= 1'b1;
                                end else if (pay_r <= 16'd6) begin
                                    emit_d <= {hold16, s_axis_tdata[63:16]};
                                    emit_k <= 8'hFF << (4'd8 - (pay_r[3:0] + 4'd2));
                                    emit_l <= 1'b1;
                                end else begin
                                    // 主尾字 8 字节 + 溢出尾字 (pay_r-6 字节在源字低 2 字节区)
                                    emit_d <= {hold16, s_axis_tdata[63:16]};
                                    emit_k <= 8'hFF;
                                    emit_l <= 1'b0;
                                    state <= S_TAIL; tail_stage <= 1'b0;
                                    // pay_r ∈ {7,8}: 必须用 4 位截 (3 位会把 8 截成 0)
                                    tail_d <= ljust2(s_axis_tdata[15:0], pay_r[3:0] - 4'd6);
                                    tail_k <= 8'hFF << (4'd8 - (pay_r[3:0] - 4'd6));
                                    tail_u <= {s_axis_terr, s_axis_tcrs};
                                end
                            end
                        end else begin
                            if (s_axis_tkeep != 8'hFF) begin
                                state <= S_DROP; drop_ack <= 1'b0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else if (pcount + 16'd8 > plen_l) begin
                                // 帧身超过 IP total_len 声明的载荷: 畸形, 吞掉防 pcount 回绕
                                state <= S_DROP; drop_ack <= 1'b0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else begin
                                emit_v <= 1'b1;
                                emit_d <= {hold16, s_axis_tdata[63:16]};
                                emit_k <= 8'hFF;
                                emit_l <= 1'b0;
                                hold16 <= s_axis_tdata[15:0];
                                pcount <= pcount + 16'd8;
                            end
                        end
                    end
                end
                S_PAD: begin
                    if (accept) begin
                        if (s_axis_tuser) begin
                            if (s_axis_tlast) begin
                                state <= S_HDR; wcnt <= 3'd0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else if (s_axis_tkeep != 8'hFF) begin
                                state <= S_DROP; drop_ack <= 1'b0; drop_syn_r <= 1'b0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else begin
                                mac_lo <= s_axis_tdata[15:0];   // 本字即新帧 w0
                                drop_syn_r <= 1'b0;
                                state <= S_HDR; wcnt <= 3'd1;
                            end
                        end else if (s_axis_tlast) begin
                            state <= S_HDR; wcnt <= 3'd0;
                            if (s_axis_tcrs) stat_pass <= stat_pass + 1;
                            else stat_drop_crc <= stat_drop_crc + 1;
                        end
                    end
                end
                S_TAIL: begin
                    if (tail_stage) begin
                        if (m_axis_tready) begin
                            state <= S_HDR; wcnt <= 3'd0;   // 溢出尾字已消费
                            emit_v <= 1'b0;
                        end
                    end else if (m_axis_tready) begin
                        emit_v <= 1'b1; emit_d <= tail_d;
                        emit_k <= tail_k; emit_l <= 1'b1; emit_u <= tail_u;
                        tail_stage <= 1'b1;
                    end
                end
                default: begin   // S_DROP: 吞到帧尾 (drop_ack 帧尾回 ACK; drop_syn 帧尾报握手)
                    if (accept && s_axis_tlast) begin
                        state <= S_HDR; wcnt <= 3'd0;
                        if (drop_syn_r && s_axis_tcrs && !s_axis_terr) syn_v <= 1'b1;
                        drop_ack <= 1'b0;
                        drop_syn_r <= 1'b0;
                    end
                end
            endcase
        end
    end
endmodule
