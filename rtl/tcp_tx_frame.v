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
    // P4b-6 窗口门控: 在飞字节 = snd_nxt - snd_una, >= 对端通告窗口 (drain 时已
    // 按 wscale 缩放) 则不开新数据帧 (纯 ACK 不挡 — 保活/窗口探测语义不受影响;
    // 无门控时板测实锤: PC 窗口关死后 FPGA 狂发被栈层静默丢弃, echo seq 出现
    // 永久空洞, 对端等缺失字节 -> 双向死锁 -> RST)
    input  wire [31:0] rb_snd_una,
    input  wire [15:0] rb_snd_wnd,
    // 重传请求 (P3: tcp_rx dup-ACK 检测电平保持至 retx_gnt; P2 先接地, RTO 自触发)
    input  wire        retx_req,
    input  wire [3:0]  retx_id,
    output wire        retx_gnt,           // 脉冲: retx_req 已服务 (回卷或确认空)
    output reg  [31:0] stat_retx,          // 回卷次数 (重传会话启动数)
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
    output reg  [31:0] stat_ack_drop,   // ACK 队列满丢弃
    output reg  [31:0] stat_eend        // S_PAY 欠载提前收帧 (结构不可达; 亮灯即缺陷 A)
);

    parameter integer RTO_LIM  = 781250;   // RTO 扫描数 (~100ms @125MHz /16 连接)
    parameter [15:0]  RING_CAP = 16'h3000; // 窗口门控帽 = ring 容量 (在飞不溢 ring)

    localparam [2:0] S_IDLE = 3'd0, S_RECV = 3'd1, S_WAIT = 3'd2, S_HDR = 3'd3,
                     S_PAY  = 3'd4, S_TAIL = 3'd5, S_DONE = 3'd6, S_RING = 3'd7;

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
    // ---- P4b-7 重传状态 (retx 空闲时全部静止, 零行为影响) ----
    reg         retx_active;              // 重传会话进行中 (ring 帧源仲裁门)
    reg  [3:0]  retx_id_r;                // 会话连接
    reg  [31:0] retx_hi;                  // 会话重发上界 (svc 拍锁存回卷前 snd_nxt)
    reg  [3:0]  scan_id;                  // RTO 扫描指针 0..15 (每空闲拍 +1)
    reg  [20:0] rto_timer [0:15];         // 每连接 RTO 计时 (以该连接扫描次数计)
    reg  [15:0] rto_pend;                 // 每连接 RTO 未决 (等 svc 回卷)
    reg  [31:0] ring_seq;                 // ring 读游标 (S_RING 内待读字 seq)
    reg  [11:0] ring_rem;                 // 本 ring 帧剩余字节数
    reg  [31:0] tap_seq;                  // ring 写游标 (下一待写字节 seq)
    // ---- P4b-7-P5 SEV2-1: RTO 无进展上限 (每连接) ----
    reg  [31:0] snd_una_prev [0:15];      // 上次 svc 拍的 snd_una (进展比对基)
    reg  [3:0]  epoch [0:15];             // 连续 svc 无进展会话计数 (封顶 15)
    // ---- P4b-7-P5 SEV2-2: force_scan (门关+tvalid 扫描饿死解药) ----
    reg  [3:0]  block_cnt;                // 门关阻塞展示拍计数
    reg         force_scan;               // 计数到 16 后下一 S_IDLE 强制扫 1 拍
    integer     ri;

    // ---- ACK 请求队列 ([36:33]=id [32]=syn [31:0]=ack_val) ----
    wire        ackq_full, ackq_empty;
    wire [36:0] ackq_dout;
    wire        pay_full, pay_empty;
    wire        ack_pend = !ackq_empty;
    wire [3:0]  start_id = ack_pend ? ackq_dout[36:33] : s_axis_tid;

    // ---- S_IDLE 帧启动仲裁链 (P4b-7): ack > retx svc > ring 帧 > RTO 扫描 > 活数据 ----
    // svc: 回卷一次重传会话 (snd_nxt <= snd_una, 占 TCB 写口 1 拍); svc_id 请求源
    // 优先 retx_req (电平, tcp_rx), 否则 RTO 未决最低位连接
    wire [3:0]  svc_id  = retx_req ? retx_id : prio_lo(rto_pend);
    wire        svc     = (state == S_IDLE) && !ack_pend && !retx_active &&
                          (retx_req || (|rto_pend));
    // ring_eval: retx 会话期间每个无 ACK 的 S_IDLE 拍评估 (ack 插帧不打断会话)
    wire        ring_eval = (state == S_IDLE) && !ack_pend && retx_active && !svc;
    wire [31:0] ring_delta = retx_hi - rb_snd_nxt;   // rb_* 已 mux 到 retx_id_r
    wire        ring_start = ring_eval && (ring_delta != 32'd0);
    // SEV2-2: 门关 + 数据展示 (tvalid 常高) 曾使扫描饿死 — 丢帧 + 对端静默 +
    // 在飞钉死 RING_CAP + app 持续展示 (tvalid 每拍=1) 时, start_data 永不开
    // (wnd_open=0) 而 scan_now 又被 !s_axis_tvalid 挡死 -> RTO 永不触发, 无
    // 自愈路径。解药: data_blocked (register 计数, 无组合环) 连续 16 拍置
    // force_scan, 下一 S_IDLE 拍强制扫 scan_id 一次 (rb_* mux 指向 scan_id)。
    // 该拍 start_data 必须加 !scan_now (否则锁错连接 snd_nxt), s_axis_tready
    // S_IDLE 项必须加 !scan_now (否则 accept=1 吞帧首字 + ring 写错游标)。
    // 扫描恢复间隔 ~16 拍/次, rto_timer 按访问计数 — 墙钟计时不变。
    wire        scan_now = (state == S_IDLE) && !ack_pend && !svc && !ring_eval &&
                           (!s_axis_tvalid || force_scan);
    wire        start_ack  = (state == S_IDLE) && ack_pend;
    // 窗口门控: 在飞 < min(snd_wnd, RING_CAP) 才开新数据帧。在飞硬上界 =
    // RING_CAP-1 + plen_max 4095 = 16382 < 16384 = ring 容量, 结构性不溢出 ring。
    wire [15:0] wnd_eff  = (rb_snd_wnd < RING_CAP) ? rb_snd_wnd : RING_CAP;
    wire [31:0] in_flight = rb_snd_nxt - rb_snd_una;
    wire        wnd_open  = (in_flight < {16'b0, wnd_eff});
    // SEV2-2 阻塞判据 (见 scan_now 注释): 窗关 + 展示中, 数据无法启动的拍
    wire        data_blocked = (state == S_IDLE) && !ack_pend && !svc &&
                               !ring_eval && s_axis_tvalid && !pay_full &&
                               !wnd_open;
    wire        start_data = (state == S_IDLE) && !ack_pend && !svc && !ring_eval &&
                             !scan_now && s_axis_tvalid && !pay_full && wnd_open;

    // rb/cam 读口 mux: svc/ring_eval/scan_now 拍旁路 start_id (TCB/CAM 组合读,
    // 本拍即目标连接值)。scan_now 与 start_data 靠 tvalid 互斥, 无组合环。
    assign rb_id     = svc ? svc_id : ring_eval ? retx_id_r : scan_now ? scan_id :
                       (state == S_IDLE) ? start_id : cur_id;
    assign cam_rd_id = rb_id;

    // TCB 更新 (sel=1 snd_nxt): S_DONE 数据段末字消费拍 或 svc 回卷拍。两拍互斥
    // (svc 仅 S_IDLE, S_DONE 段仅 S_DONE), TCB 单写口无冲突。
    // SEV2-1: blocked = 该连接连续 16 次 svc 无 snd_una 进展 (对端死), 停回卷 —
    // 回卷写/stat_retx 全经 svc_rewind 门控; retx_gnt 不门控 (tcp_rx 电平请求
    // 始终释放), rto_pend 清/计时器重装亦无条件 (svc 每次照常应答)。
    wire        blocked = (epoch[svc_id] >= 4'd15);
    wire        svc_rewind = svc && (rb_snd_nxt != rb_snd_una) && !blocked;
    assign upd_wr  = ((state == S_DONE) && (is_data_r || is_syn_r) &&
                      m_axis_tvalid && m_axis_tready) || svc_rewind;
    assign upd_id  = svc_rewind ? svc_id : cur_id;
    assign upd_sel = 3'd1;
    assign upd_val = svc_rewind ? rb_snd_una :
                     seq_r + (is_data_r ? {20'b0, plen_r} : 32'd1);
    assign retx_gnt = svc && retx_req;

    // svc 拍 accept 必须禁 (start_data 被 svc 压制, accept 不再等于帧首拍消费,
    // 否则会吞一个既不入 FIFO 计数也不入 plen 的字)
    assign s_axis_tready = ((state == S_RECV) ||
                            ((state == S_IDLE) && !ack_pend && !svc &&
                             !ring_eval && !scan_now && wnd_open)) &&
                           !pay_full;
    wire        accept = s_axis_tvalid && s_axis_tready;

    // ---- 载荷 FIFO + 校验和 (活帧与 ring 帧共用写口; wr/fdin 定义见下, 需先
    //      声明 ring_beat/fdin_ring) ----
    wire [72:0] fdout;
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

    // RTO 未决最低位优先 (bit0 先服务)
    function [3:0] prio_lo;
        input [15:0] v;
        integer i;
        begin
            prio_lo = 4'd0;
            for (i = 15; i >= 0; i = i - 1)
                if (v[i]) prio_lo = i[3:0];
        end
    endfunction

    // ring 末拍字节掩码 (按字节 lane, rem=0 视为 8 全保留; 界外清零)
    function [63:0] rm_mask;
        input [2:0] rem;
        begin
            case (rem)
                3'd0: rm_mask = 64'hFFFFFFFFFFFFFFFF;
                3'd1: rm_mask = 64'hFF00000000000000;
                3'd2: rm_mask = 64'hFFFF000000000000;
                3'd3: rm_mask = 64'hFFFFFF0000000000;
                3'd4: rm_mask = 64'hFFFFFFFF00000000;
                3'd5: rm_mask = 64'hFFFFFFFFFF000000;
                3'd6: rm_mask = 64'hFFFFFFFFFFFF0000;
                default: rm_mask = 64'hFFFFFFFFFFFFFF00;
            endcase
        end
    endfunction

    // ---- P4b-7 重传 ring: 写拍点 = 活帧每个有效 accept 拍 (ring 源帧 accept=0
    //      天然不重写); 读口数据 rd_en 后 1 拍 ----
    wire        wr_tap = accept && (s_axis_tkeep != 8'h00);
    wire [3:0]  w_tap_conn = (state == S_RECV) ? cur_id : start_id;
    wire [31:0] w_tap_seq  = start_data ? rb_snd_nxt : tap_seq;

    // ---- ring 源帧 (S_RING): 每拍 1 beat 入 u_fifo + u_csum ----
    wire        ring_beat = (state == S_RING);
    wire        ring_last = ring_beat && (ring_rem <= 12'd8);
    wire [7:0]  ring_tkeep = ring_last ?
                             ((ring_rem == 12'd8) ? 8'hFF :
                              (8'hFF << (4'd8 - {1'b0, ring_rem[2:0]}))) : 8'hFF;
    wire [63:0] ring_d;
    // 末拍界外 lane (ring 读回的后续字节) 清零, 不进 FIFO/校验和
    wire [63:0] ring_w = ring_last ? (ring_d & rm_mask(ring_rem[2:0])) : ring_d;
    wire [72:0] fdin_ring = {ring_last, ring_tkeep, ring_w};
    // ring 读口: 首读在 ring_start 拍 (数据下拍 = S_RING 首拍可用), S_RING 内每
    // 非末拍预读下一字 (下拍写入)
    wire        rd_tap = ring_start || (ring_beat && !ring_last);
    wire [13:0] r_tap_seq = ring_start ? rb_snd_nxt[13:0] : ring_seq[13:0];
    // ring 帧载荷 = min(1460, 会话剩余区间); delta<1460 时 12 位精确不截断
    wire [11:0] plen_preset = (ring_delta >= 32'd1460) ? 12'd1460 :
                              ring_delta[11:0];

    retx_ram u_retx (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_tap), .w_conn(w_tap_conn), .w_seq(w_tap_seq[13:0]),
        .w_data(s_axis_tdata), .w_n(pop8(s_axis_tkeep)),
        .rd_en(rd_tap), .r_conn(retx_id_r), .r_seq(r_tap_seq), .r_data(ring_d)
    );

    // ---- 载荷 FIFO/校验和 写口 mux (活帧与 ring 帧按状态互斥) ----
    wire        wr  = (accept && (s_axis_tkeep != 8'h00)) || ring_beat;
    wire [72:0] fdin = ring_beat ? fdin_ring :
                       {s_axis_tlast, s_axis_tkeep, s_axis_tdata};

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
    wire        csum_init = start_ack || start_data || ring_start;
    wire        csum_den  = ((start_data || (state == S_RECV)) && accept &&
                             (s_axis_tkeep != 8'h00)) || ring_beat;
    wire [63:0] csum_din   = ring_beat ? ring_w : s_axis_tdata;
    wire [7:0]  csum_dkeep = ring_beat ? ring_tkeep : s_axis_tkeep;
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
        .den(csum_den), .din(csum_din), .dkeep(csum_dkeep),
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
            stat_eend <= 0;
            retx_active <= 0; retx_id_r <= 0; retx_hi <= 0; scan_id <= 0;
            rto_pend <= 16'h0; ring_seq <= 0; ring_rem <= 0; tap_seq <= 0;
            stat_retx <= 0;
            block_cnt <= 4'd0; force_scan <= 1'b0;
            for (ri = 0; ri < 16; ri = ri + 1) begin
                rto_timer[ri] <= 21'd0;
                snd_una_prev[ri] <= 32'd0;
                epoch[ri] <= 4'd0;
            end
        end else begin
            if (m_axis_tready && m_axis_tvalid) m_axis_tvalid <= 1'b0;
            if (ack_req && ackq_full) stat_ack_drop <= stat_ack_drop + 1;
            case (state)
                S_IDLE: begin
                    // 重传服务拍: 锁存会话 (上界 = 回卷前 snd_nxt, 连接 = svc_id),
                    // 回卷 snd_nxt -> snd_una (svc_rewind 组合脉冲突发), 清该连接
                    // RTO 未决并重装计时器; 请求应答与回卷同拍
                    if (svc) begin
                        // SEV2-1: snd_una 进展比对 — 无进展会话计数 +1 (封顶
                        // 15), 有进展清零; blocked 后 svc 仍应答但不回卷
                        if (rb_snd_una == snd_una_prev[svc_id]) begin
                            if (epoch[svc_id] < 4'd15)
                                epoch[svc_id] <= epoch[svc_id] + 4'd1;
                        end else
                            epoch[svc_id] <= 4'd0;
                        snd_una_prev[svc_id] <= rb_snd_una;
                        retx_hi <= rb_snd_nxt;
                        retx_id_r <= svc_id;
                        retx_active <= 1'b1;
                        rto_pend[svc_id] <= 1'b0;
                        rto_timer[svc_id] <= RTO_LIM;
                        if (svc_rewind) stat_retx <= stat_retx + 32'd1;
                    end
                    // ring 帧启动拍: 帧首锁存同活帧 (rb/cam_rd 已 mux 到
                    // retx_id_r); ring_seq 预推进 8 = 下拍(S_RING 首拍)预读地址
                    if (ring_eval) begin
                        if (ring_start) begin
                            cur_id <= retx_id_r;
                            is_data_r <= 1'b1;
                            is_syn_r <= 1'b0;
                            seq_r <= rb_snd_nxt;
                            ack_r <= rb_rcv_nxt;
                            wnd_r <= rb_rcv_wnd;
                            doff_flags_r <= 16'h5018;   // 数据帧 PSH+ACK
                            dmac_r <= cam_rd_dmac;
                            dip_r <= cam_rd_sip;       // 对端 IP
                            sport_r <= cam_rd_dport;   // 本地端口
                            dport_r <= cam_rd_sport;   // 对端端口
                            id_cap <= id_r;
                            id_r <= id_r + 1;
                            plen_r <= plen_preset;
                            tcp_len_r <= {4'b0, plen_preset} + 16'd20;
                            total_len_r <= {4'b0, plen_preset} + 16'd40;
                            ring_rem <= plen_preset;
                            ring_seq <= rb_snd_nxt + 32'd8;
                            state <= S_RING;
                        end else begin
                            retx_active <= 1'b0;    // 区间发完: 1 拍气泡回活数据
                        end
                    end
                    // SEV2-2: 门关阻塞计数 — 16 拍展示无法启动置 force_scan
                    // (data_blocked 不挡 svc/ack/ring 拍); scan_now 拍清零。
                    // 两者同拍时本段先执行, scan_now 段的清零后写覆盖 (最后赋值胜)
                    if (data_blocked) begin
                        block_cnt <= block_cnt + 4'd1;
                        if (block_cnt == 4'd15) force_scan <= 1'b1;
                    end
                    // RTO 扫描: 每 scan_now 拍访 scan_id 连接 (rb_* mux 到 scan_id;
                    // 该连接在飞且窗开: 计时 0->装 / 1->置未决并重装 / 否则自减)
                    if (scan_now) begin
                        // SEV3-4: 原 '!(retx_active && (scan_id==retx_id_r))' 排除项
                        // 是死代码 — scan_now 要求 !ring_eval; retx_active 期间
                        // ring_eval 覆盖全部 S_IDLE&&!ack_pend 拍 (ack_pend 也
                        // 排除 scan_now), 故 scan_now 拍 retx_active 恒 0
                        if (rb_snd_wnd != 16'd0 && rb_snd_nxt != rb_snd_una) begin
                            if (rto_timer[scan_id] == 21'd0)
                                rto_timer[scan_id] <= RTO_LIM;
                            else if (rto_timer[scan_id] == 21'd1) begin
                                rto_pend[scan_id] <= 1'b1;
                                rto_timer[scan_id] <= RTO_LIM;
                            end else
                                rto_timer[scan_id] <= rto_timer[scan_id] - 21'd1;
                        end else
                            rto_timer[scan_id] <= 21'd0;
                        scan_id <= scan_id + 4'd1;
                        force_scan <= 1'b0;
                        block_cnt <= 4'd0;
                    end
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
                            // ring 写游标越过本拍字节 (首拍 beat0 写 rb_snd_nxt,
                            // 游标 = 下一 beat 偏移)
                            tap_seq <= rb_snd_nxt + {20'b0, pop8(s_axis_tkeep)};
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
                        tap_seq <= tap_seq + {20'b0, pop8(s_axis_tkeep)};
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
                            stat_eend <= stat_eend + 1;   // 结构不可达 (整帧先入 FIFO
                            m_axis_tvalid <= 1'b1;        //  才开 S_WAIT) — 计数哨兵
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
                3'd7: begin   // S_RING: ring 字流拍 (每拍 1 beat 写 u_fifo+u_csum;
                    // 首字已在 ring_start 拍读出, ring_last 拍后转 S_WAIT)
                    if (ring_last) begin
                        state <= S_WAIT; wait_cnt <= 3'd0;
                    end else begin
                        ring_rem <= ring_rem - 12'd8;
                        ring_seq <= ring_seq + 32'd8;
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
