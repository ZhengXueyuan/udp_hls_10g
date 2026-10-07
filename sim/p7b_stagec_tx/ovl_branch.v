    // =========================================================================
    // P7b Stage C: 乒乓双 bank / 收发重叠 (宏 TCP_TX_OVL)
    // -------------------------------------------------------------------------
    // 设计件 = _proj_10g/notes/P7B_TX_PINGPONG_FIX_DESIGN.md (REV3; 3 轮对抗审查)。
    //   · RX 引擎 4 态 RX_IDLE/RX_RING/RX_FIN/RX_FLUSH (收帧 + 重放读 ring +
    //     校验和收尾 5 拍 + 中止冲洗); TX 引擎 5 态 T_IDLE/T_HDR/T_PAY/T_TAIL/
    //     T_DONE (发 bank = 数据/重放帧, 或发控制帧槽)。载荷 FIFO 拆两个 256×73。
    //   · FIX-1: snd_nxt 推进写从 TX 侧 "发送末拍 S_DONE" 搬到 RX 侧
    //     **RX_FIN 首拍 (fin_cnt==0)**: 值 = f_seq[rx_bank] + f_plen[rx_bank]
    //     (该 bank 自己的两个不可变寄存器) ⇒ 任何帧首拍读 rb_snd_nxt 都含全部
    //     "已收完"帧的推进 (tcb.v:91 同步写 + :110 组合读 ⇒ 写沿落地、下拍可读;
    //     最早下一帧首拍 = T_last+6 ⇒ 余量 4 拍)。读侧一字未改。
    //   · FIX-2': FIN/RST/SYN 的 +1 在 start_ack 拍**同拍预留** (upd_wr_ctrl);
    //     控制帧 IP/TCP 校验和 = start_ack 拍的**组合树** (与 checksum16 三拍 aen
    //     逐位等价: acc 是纯 32 位累加器 + 单次 fold16 ⇒ 32 位加法结合律)
    //     ⇒ 不占 checksum16、不占 RX 引擎、无 S_WAIT 5 拍 (TX 侧 13 → 8 拍)。
    //   · 控制帧槽跨拍独占: ctrl_slot_busy ∈ [start_ack, 该帧 T_DONE] 挡 start_ack;
    //     仲裁键 = ctrl_tx_pend ∈ [start_ack, 该帧启动拍] ⇒ pend ⊆ busy (结构性)
    //     ⇒ 控制帧自己的 T_DONE 拍不会被重发 (C9), 槽也不会在 T_HDR 中段被换 (C8)。
    //   · 三写源 (upd_wr_data / upd_wr_ctrl / upd_wr_rew) 逐拍 $onehot0:
    //     数据写要求 RX_FIN, 控制/回卷要求 rx_idle = (RX_IDLE && recv_first)
    //     ⇒ 状态互斥 (3 对, 全部结构性)。
    //   · 回卷门: 控制帧槽里有在飞的 SYN/FIN/RST 时推迟 svc (否则预留的 +1 会被
    //     retx_hi 吃进重放区间 ⇒ 在 FIN 的 seq 上重放 1 字节; 设计 §1.4(4))。
    //   · 与默认分支的差异 (逐条登记在 P7B_STAGEC_TX.md): 无 per-bank is_* 位
    //     (帧类型由来源结构决定: bank ⇒ 数据/重放, 槽 ⇒ 控制); flush_pend 由
    //     RX_FLUSH 状态承载; 控制帧无 S_WAIT。
    //   · 默认构建 (宏未定义) 走 `else 分支, 逐字 = HEAD (0 deletions)。
    // =========================================================================
    localparam ACKQ_W = 39;
    localparam [1:0] RX_IDLE = 2'd0, RX_RING = 2'd1, RX_FIN = 2'd2, RX_FLUSH = 2'd3;
    localparam [2:0] T_IDLE  = 3'd0, T_HDR  = 3'd1, T_PAY   = 3'd2,
                     T_TAIL  = 3'd3, T_DONE = 3'd4;

    // ---- 纯函数 (与默认分支逐字同款; 本分支内需重新声明) ----
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

    function [3:0] prio_lo;
        input [15:0] v;
        integer i;
        begin
            prio_lo = 4'd0;
            for (i = 15; i >= 0; i = i - 1)
                if (v[i]) prio_lo = i[3:0];
        end
    endfunction

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

    // 与 rtl/checksum16.v:31-38 的 fold16 逐位同款 (单次折叠, 对 32 位入参良定义)
    function [15:0] fold16;
        input [31:0] v;
        reg [16:0] f1;
        begin
            f1 = {1'b0, v[15:0]} + {1'b0, v[31:16]};
            fold16 = f1[15:0] + {15'b0, f1[16]};
        end
    endfunction

    // ---- 状态/索引 ----
    reg  [1:0]  rx_state;
    reg  [2:0]  tx_state;      // ⚠️ 必须 ≥3 位 (T_DONE = 4; 2 位会被截成 T_IDLE)
    reg         rx_bank, tx_bank;
    reg         recv_first;
    reg  [2:0]  fin_cnt;       // RX_FIN 的 5 拍 (0..4); ⚠️ 必须 ≥3 位
    reg  [2:0]  thcnt;
    reg  [11:0] plen;          // RX 帧内载荷累计
    reg         len_bad;
    reg  [15:0] id_r;          // IP id 计数器 (全局递增)
    reg  [63:0] hold48;
    reg  [63:0] tail_d;
    reg  [7:0]  tail_k;
    reg         tx_is_ctrl;    // TX 引擎本帧来自控制帧槽 (而非 bank)

    // ---- 每 bank 帧上下文 (304 bit × 2) ----
    reg  [1:0]  bank_rdy;
    reg  [31:0] f_seq[0:1], f_ack[0:1], f_dip[0:1];
    reg  [15:0] f_wnd[0:1], f_doff[0:1], f_sport[0:1], f_dport[0:1], f_idcap[0:1],
                f_tcplen[0:1], f_totlen[0:1], f_ipcsum[0:1], f_tcpcsum[0:1];
    reg  [11:0] f_plen[0:1];
    reg  [3:0]  f_conn[0:1];
    reg  [47:0] f_dmac[0:1];

    // ---- 控制帧槽 (第三个上下文, 无 bank) ----
    reg         ctrl_slot_busy;   // 槽上下文占用: [start_ack, 该帧 T_DONE]
    reg         ctrl_tx_pend;     // 槽里有未发送帧: [start_ack, 启动拍] ← 仲裁键
    reg  [3:0]  ctrl_id;
    reg  [2:0]  ctrl_is;          // {rst, fin, syn} (纯 ACK = 0 ⇒ 不占 seq)
    reg  [31:0] ctrl_seq, ctrl_ack, ctrl_dip;
    reg  [15:0] ctrl_wnd, ctrl_doff, ctrl_sport, ctrl_dport, ctrl_idcap,
                ctrl_ipcsum, ctrl_tcpcsum;
    reg  [47:0] ctrl_dmac;

    // ---- 重传 / 扫描 / 记账 (与默认分支同名同语义) ----
    reg         retx_active;
    reg  [3:0]  retx_id_r;
    reg  [31:0] retx_hi;
    reg  [3:0]  scan_id;
    reg  [20:0] rto_timer [0:15];
    reg  [15:0] rto_pend;
    reg  [31:0] ring_seq;
    reg  [11:0] ring_rem;
    reg  [7:0]  nbeats;
    reg  [7:0]  beat_cnt;
    reg  [63:0] ring_d_r;
    reg  [31:0] tap_seq;
    reg  [31:0] snd_una_prev [0:15];
    reg  [3:0]  epoch [0:15];
    reg  [15:0] fin_sent_r;
    reg  [15:0] rst_sent_r;
    reg  [31:0] fin_seq_r [0:15];
    reg  [15:0] fin_retx_pend;
    reg         ack_pend_r;
    reg  [3:0]  svc_id_r;
    reg         rto_pend_any;
    reg  [3:0]  tick_cnt;
    reg  [31:0] stat_retx_wrap;   // F1 事件计数: 会话存活期间 snd_nxt 被 +1 预留越过
    reg         retx_ovf_p;       //   (上升沿计数; 板上快照未接线 ⇒ 登记为 silent class)
    integer     ri;
    integer     ti;

    // =========================== 组合网络 ===========================
    // ---- 载荷 FIFO 双 bank (FWFT) ----
    wire [72:0] fdo_a, fdo_b;
    wire        em_a, em_b, fu_a, fu_b;
    wire [8:0]  dwpr_a, dwpr_b, drpr_a, drpr_b;
    wire        dfu_a, dfu_b, dem_a, dem_b, dovf_a, dovf_b;
    wire [72:0] fdout_tx      = tx_bank ? fdo_b : fdo_a;
    wire        fifo_empty_tx = tx_bank ? em_b : em_a;
    wire        fifo_empty_rx = rx_bank ? em_b : em_a;
    wire        fifo_full     = rx_bank ? fu_b : fu_a;   // 接受门 = 当前接收 bank

    // ---- RX 引擎空闲 (唯一"无任何在飞帧"拍: 收帧中/收尾/重放/冲洗 全为 0) ----
    wire        rx_idle   = (rx_state == RX_IDLE) && recv_first;
    // flush_pend 的等价物 = RX_FLUSH 状态 (默认分支的 flag 由其状态承载)
    wire        rx_flush  = (rx_state == RX_FLUSH);
    wire        flush_act = rx_flush;
    wire        scan_tick = (tick_cnt == 4'd15);

    // ---- ACK 队列 (实例在下方, 线网先声明) ----
    wire        ackq_full, ackq_empty;
    wire [ACKQ_W-1:0] ackq_dout;
    wire        aq_syn  = ackq_dout[34];
    wire        aq_fin  = ackq_dout[33];
    wire        aq_rst  = ackq_dout[32];
    wire [3:0]  start_id = ack_pend_r ? ackq_dout[38:35] : s_axis_tid;

    // ---- 状态门 (与默认分支同源; 只在 APP_MODE 编译) ----
`ifdef APP_MODE
    wire        scan_estab = (rb_state == 4'd1);
    wire        st_ok    = (rb_state == 4'd1);
`else
    wire        scan_estab = 1'b1;
    wire        st_ok    = 1'b1;
`endif
    wire        wnd_open  = win_open;
    wire [15:0] tx_blk = fin_req | fin_sent_r | rst_sent_r | rst_req;
    wire        tx_blk_sid = tx_blk[start_id] | ~st_ok;

    // ---- 帧启动/服务门 (逐子句对应默认分支; state==S_IDLE → rx_idle) ----
    wire [3:0]  svc_id    = svc_id_r;
    wire        blocked   = (epoch[svc_id] >= 4'd15);
    wire        svc       = rx_idle && !ack_pend_r && !retx_active && !rx_flush &&
                            (retx_req || rto_pend_any);
    // ⚠️ REV3b 教训落地: 重放**要吃 bank** ⇒ 必须等当前接收 bank 被归还 (设计 §1.2 表)
    //    (缺这一项 ⇒ 重放会写进正在被 TX 引擎发送的 bank ⇒ FIFO 内容被踩/被截断)
    wire        ring_eval = rx_idle && !ack_pend_r && retx_active && !svc && !rx_flush &&
                            !bank_rdy[rx_bank];
    wire        scan_now  = rx_idle && !ack_pend_r && !svc && !ring_eval && !rx_flush &&
                            scan_tick;
    wire        start_ack = rx_idle && ack_pend_r && !ackq_empty && !rx_flush &&
                            !ctrl_slot_busy;          // ← 槽跨拍独占门 (C7/C8)
    wire        ctrl_adv_inflight = ctrl_slot_busy && (|ctrl_is) && (ctrl_id == svc_id);
    wire        svc_x     = svc && !ctrl_adv_inflight;    // 回卷门 (§1.4(4))
    wire        svc_rewind= svc_x && (rb_snd_nxt != rb_snd_una) && !blocked;
    wire        retx_deny = blocked && fin_sent_r[svc_id];
    wire        retx_begin= svc_x && !retx_deny;

    // ---- TCB 三写源 (逐拍 $onehot0; 门互斥见头注) ----
    wire        upd_wr_data = (rx_state == RX_FIN) && (fin_cnt == 3'd0);
    wire        upd_wr_ctrl = start_ack && (aq_syn | aq_fin | aq_rst);
    wire        upd_wr_rew  = svc_rewind;
    assign      upd_wr  = upd_wr_data || upd_wr_ctrl || upd_wr_rew;
    assign      upd_id  = upd_wr_data ? f_conn[rx_bank] :
                          (upd_wr_ctrl ? start_id : svc_id);
    assign      upd_sel = 3'd1;
    assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + {20'b0, f_plen[rx_bank]}) :
                          (upd_wr_ctrl ? (rb_snd_nxt + 32'd1) : rb_snd_una);
    assign      retx_gnt = svc_x && retx_req;

    // ---- rb/cam 读口 mux (旁路拍 = 各服务引擎自己的目标连接) ----
    assign rb_id     = svc ? svc_id : ring_eval ? retx_id_r : scan_now ? scan_id :
                       (rx_state == RX_IDLE) ? start_id : f_conn[rx_bank];
    assign cam_rd_id = rb_id;

    // ---- 帧首/帧内判据 ----
    wire        accept = s_axis_tvalid && s_axis_tready;
    wire [11:0] plen_n = (recv_first ? 12'd0 : plen) + {8'b0, pop8(s_axis_tkeep)};
    wire        len_over = (plen_n > PLEN_MAX);

    // ⚠️ 坑 10: 接受门与启动门**逐字同门** (双子句逐字写出, 见设计 §1.2)
    assign s_axis_tready =
          (  ( (rx_state == RX_IDLE) && !recv_first )
          || ( (rx_state == RX_IDLE) &&  recv_first && !ack_pend_r && !svc &&
               !ring_eval && !scan_now && !rx_flush && wnd_open && !tx_blk_sid ) )
          && !fifo_full && !bank_rdy[rx_bank];
    wire        start_data = (rx_state == RX_IDLE) && recv_first && !ack_pend_r &&
                             !svc && !ring_eval && !scan_now && !rx_flush &&
                             s_axis_tvalid && !fifo_full && !bank_rdy[rx_bank] &&
                             wnd_open && !tx_blk_sid;

    // ---- 重传 ring 读/写 + 会话 ----
    wire        ring_act = (rx_state == RX_RING);
    wire [7:0]  ring_end = nbeats + 8'd2;
    wire        ring_wr  = ring_act && (beat_cnt >= 8'd3);
    wire        ring_fin = ring_act && (beat_cnt == ring_end);
    wire [7:0]  ring_tkeep = ring_fin ? ((ring_rem == 12'd8) ? 8'hFF :
                             (8'hFF << (4'd8 - {1'b0, ring_rem[2:0]}))) : 8'hFF;
    wire [63:0] ring_d;
    wire [63:0] ring_w = ring_fin ? (ring_d_r & rm_mask(ring_rem[2:0])) : ring_d_r;
    wire [72:0] fdin_ring = {ring_fin, ring_tkeep, ring_w};
    wire [31:0] ring_delta = retx_hi - rb_snd_nxt;
    // ⭐ 修复 (对抗审查 B1/F1): 控制帧帧首预留的 +1 能让 `rb_snd_nxt` **越过** `retx_hi`
    //    ⇒ `ring_delta` 32 位下溢成 0xFFFFFFFF, 而 `!=0` 判据仍为真 ⇒ 伪 ring_start ⇒
    //    每次 1460 B 重放且 snd_nxt 继续前进 = **G9 类自持洪水**。
    //    改成**回绕安全的"正 delta"**: snd_nxt 越顶时不再起重放, 让会话走排空支收尾。
    wire        retx_ovf = (rb_snd_nxt != retx_hi) &&
                           ((rb_snd_nxt - retx_hi) < 32'h8000_0000);
    wire        ring_start = ring_eval && (ring_delta != 32'd0) && !retx_ovf &&
                             scan_estab;
    wire        rd_tap = ring_start || (ring_act && (beat_cnt < nbeats));
    wire [15:0] r_tap_seq = ring_start ? rb_snd_nxt[15:0] : ring_seq[15:0];
    wire [11:0] plen_preset = (ring_delta >= 32'd1460) ? 12'd1460 : ring_delta[11:0];

    // ---- 载荷写口 (活帧 + 重放共写当前接收 bank) ----
    wire        wr_ring = ring_wr;
    wire        wr_act  = accept && (s_axis_tkeep != 8'h00) && !len_bad;
    wire        wr      = wr_act || wr_ring;
    wire [72:0] fdin    = wr_ring ? fdin_ring :
                          {s_axis_tlast, s_axis_tkeep, s_axis_tdata};

    // ---- ring 写口 (tap) ----
    wire        wr_tap      = accept && (s_axis_tkeep != 8'h00) && !len_bad;
    wire [3:0]  w_tap_conn  = (rx_state == RX_IDLE && !recv_first) ? f_conn[rx_bank] :
                              start_id;
    wire [31:0] w_tap_seq   = start_data ? rb_snd_nxt : tap_seq;

    // ---- 校验和 (唯一实例; 控制帧不占它) ----
    wire [31:0] csum_init_val = {4'b0, cfg_src_ip[31:16]} + {4'b0, cfg_src_ip[15:0]} +
                                {4'b0, cam_rd_sip[31:16]} + {4'b0, cam_rd_sip[15:0]} +
                                32'h0006;
    wire        csum_init = start_data || ring_start;
    wire        csum_den  = wr_act || wr_ring;
    wire [63:0] csum_din   = wr_ring ? ring_w : s_axis_tdata;
    wire [7:0]  csum_dkeep = wr_ring ? ring_tkeep : s_axis_tkeep;
    wire        csum_aen  = (rx_state == RX_FIN) && (fin_cnt <= 3'd2);
    wire [17:0] aen_v1 = {2'b0, f_tcplen[rx_bank]} + {2'b0, f_sport[rx_bank]} +
                         {2'b0, f_dport[rx_bank]} + {2'b0, f_seq[rx_bank][31:16]};
    wire [17:0] aen_v2 = {2'b0, f_seq[rx_bank][15:0]} + {2'b0, f_ack[rx_bank][31:16]} +
                         {2'b0, f_ack[rx_bank][15:0]} + {2'b0, f_doff[rx_bank]};
    wire [17:0] aen_v3 = {2'b0, f_wnd[rx_bank]};
    wire [17:0] aen_val = (fin_cnt == 3'd0) ? aen_v1 :
                          (fin_cnt == 3'd1) ? aen_v2 : aen_v3;
    wire        csum_fin = (rx_state == RX_FIN) && (fin_cnt == 3'd3);
    wire [15:0] csum;
    wire        csum_valid;

    // ---- 控制帧的组合校验和树 (start_ack 拍值, 与帧头同拍同源) ----
    wire [31:0] ctrl_ack_now  = (aq_fin || aq_rst) ? rb_rcv_nxt : ackq_dout[31:0];
    wire [15:0] ctrl_doff_now = {8'h50, aq_syn ? 8'h12 : aq_fin ? 8'h11 :
                                 aq_rst ? 8'h14 : 8'h10};
    wire [17:0] ctl_aen_v1 = 18'd20 + {2'b0, cam_rd_dport} + {2'b0, cam_rd_sport} +
                             {2'b0, rb_snd_nxt[31:16]};
    wire [17:0] ctl_aen_v2 = {2'b0, rb_snd_nxt[15:0]} + {2'b0, ctrl_ack_now[31:16]} +
                             {2'b0, ctrl_ack_now[15:0]} + {2'b0, ctrl_doff_now};
    wire [17:0] ctl_aen_v3 = {2'b0, rb_rcv_wnd};
    // ⚠️ 一次折叠、加完再折 (不许边加边折成 16 位) — 与三拍 aen 序列逐位等价
    wire [31:0] ctrl_acc = csum_init_val + {14'b0, ctl_aen_v1} + {14'b0, ctl_aen_v2} +
                           {14'b0, ctl_aen_v3};
    wire [15:0] ctrl_tcpcsum_now = ~fold16(ctrl_acc);
    wire [15:0] ctrl_ipcsum_now  = ip_csum_calc(16'd40, id_r, cam_rd_sip);

    // ---- TX 引擎: 头字段来源 mux (控制槽 vs bank) ----
    wire        h_ctrl    = tx_is_ctrl;
    wire [11:0] h_plen    = h_ctrl ? 12'd0        : f_plen[tx_bank];
    wire [15:0] h_totlen  = h_ctrl ? 16'd40       : f_totlen[tx_bank];
    wire [15:0] h_idcap   = h_ctrl ? ctrl_idcap   : f_idcap[tx_bank];
    wire [15:0] h_ipcsum  = h_ctrl ? ctrl_ipcsum  : f_ipcsum[tx_bank];
    wire [15:0] h_tcpcsum = h_ctrl ? ctrl_tcpcsum : f_tcpcsum[tx_bank];
    wire [31:0] h_dip     = h_ctrl ? ctrl_dip     : f_dip[tx_bank];
    wire [15:0] h_sport   = h_ctrl ? ctrl_sport   : f_sport[tx_bank];
    wire [15:0] h_dport   = h_ctrl ? ctrl_dport   : f_dport[tx_bank];
    wire [31:0] h_seq     = h_ctrl ? ctrl_seq     : f_seq[tx_bank];
    wire [31:0] h_ack     = h_ctrl ? ctrl_ack     : f_ack[tx_bank];
    wire [15:0] h_doff    = h_ctrl ? ctrl_doff    : f_doff[tx_bank];
    wire [15:0] h_wnd     = h_ctrl ? ctrl_wnd     : f_wnd[tx_bank];
    wire [47:0] h_dmac    = h_ctrl ? ctrl_dmac    : f_dmac[tx_bank];
    wire        nxt_bank  = ~tx_bank;

    // ---- TX 读口 (bank) 与 RX 冲洗读口 (两 bank 恒不同: 见 P7B_STAGEC_TX.md) ----
    wire        pay_load = (tx_state == T_PAY) && (m_axis_tready || !m_axis_tvalid);
    wire        rd_tx = pay_load && (h_plen != 12'd0) && !fifo_empty_tx;
    wire        rd_fl = flush_act && !fifo_empty_rx;
    wire        rd_a  = (rd_tx && !tx_bank) || (rd_fl && !rx_bank);
    wire        rd_b  = (rd_tx &&  tx_bank) || (rd_fl &&  rx_bank);

    // =========================== 实例 ===========================
    fifo_sync #(.W(73), .D(256), .AW(8)) u_fifo_a (
        .clk(clk), .rst_n(rst_n),
        .wr(wr && !rx_bank), .din(fdin),
        .rd(rd_a), .dout(fdo_a),
        .empty(em_a), .full(fu_a),
        .dbg_wptr(dwpr_a), .dbg_rptr(drpr_a), .dbg_full(dfu_a), .dbg_empty(dem_a),
        .full_next(), .ovf_pulse(dovf_a)
    );
    fifo_sync #(.W(73), .D(256), .AW(8)) u_fifo_b (
        .clk(clk), .rst_n(rst_n),
        .wr(wr && rx_bank), .din(fdin),
        .rd(rd_b), .dout(fdo_b),
        .empty(em_b), .full(fu_b),
        .dbg_wptr(dwpr_b), .dbg_rptr(drpr_b), .dbg_full(dfu_b), .dbg_empty(dem_b),
        .full_next(), .ovf_pulse(dovf_b)
    );

    retx_ram u_retx (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_tap), .w_conn(w_tap_conn), .w_seq(w_tap_seq[15:0]),
        .w_data(s_axis_tdata), .w_n(pop8(s_axis_tkeep)),
        .rd_en(rd_tap), .r_conn(retx_id_r), .r_seq(r_tap_seq), .r_data(ring_d)
    );

    checksum16 u_csum (
        .clk(clk), .rst_n(rst_n),
        .init(csum_init), .init_val(csum_init_val),
        .den(csum_den), .din(csum_din), .dkeep(csum_dkeep),
        .aen(csum_aen), .add_val(aen_val),
        .fin(csum_fin),
        .csum(csum), .csum_valid(csum_valid)
    );

    // ---- FIN/RST 排队 (与默认分支逐字同款: 扫描拍 + ackq 优先级 mux) ----
    wire        fin_push = scan_now && fin_req[scan_id] && !fin_sent_r[scan_id] &&
                           !ackq_full && (rb_state == 4'd1) &&
                           (rb_snd_nxt == rb_snd_una);
    wire        rst_push = scan_now && rst_req[scan_id] && !rst_sent_r[scan_id] &&
                           !ackq_full && (rb_state == 4'd1);
    wire        fin_repush = ring_eval && !ring_start && fin_retx_pend[retx_id_r] &&
                             !ackq_full && (rb_state == 4'd1) &&
                             (rb_snd_una == fin_seq_r[retx_id_r]);
    wire        ack_req_ok = ack_req && !ackq_full;
    wire        fin_repush_ok = fin_repush && !ack_req_ok && !ackq_full;
    wire        wu_push    = wu_req && !ackq_full && !ack_req_ok && !fin_push &&
                             !rst_push && !fin_repush;
    wire        ackq_wr    = ack_req_ok || fin_push || rst_push || fin_repush ||
                             wu_push;
    wire [ACKQ_W-1:0] ackq_din = ack_req_ok ? {ack_id, ack_syn, ack_fin, ack_rst, ack_val} :
                                 fin_push   ? {scan_id, 1'b0, 1'b1, 1'b0, 32'h0} :
                                 rst_push   ? {scan_id, 1'b0, 1'b0, 1'b1, 32'h0} :
                                 fin_repush ? {retx_id_r, 1'b0, 1'b1, 1'b0, 32'h0} :
                                              {wu_id, 1'b0, 1'b0, 1'b0, wu_val};
    assign      wu_gnt = wu_push;

    fifo_sync #(.W(ACKQ_W), .D(ACKQ_D), .AW(ACKQ_AW)) u_ackq (
        .clk(clk), .rst_n(rst_n),
        .wr(ackq_wr), .din(ackq_din),
        .rd(start_ack), .dout(ackq_dout),
        .empty(ackq_empty), .full(ackq_full),
        .full_next(), .ovf_pulse()
    );

    assign o_fin_sent = fin_sent_r;
    assign o_rst_sent = rst_sent_r;
    assign o_retx_id  = retx_id_r;
    assign o_retx_hi     = retx_hi;
    assign o_retx_active = retx_active;

    // =========================== 时序块 ===========================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state <= RX_IDLE; tx_state <= T_IDLE;
            rx_bank <= 1'b0; tx_bank <= 1'b0; recv_first <= 1'b1;
            fin_cnt <= 3'd0; thcnt <= 3'd0;
            plen <= 12'd0; len_bad <= 1'b0; id_r <= 16'd0;
            hold48 <= 64'd0; tail_d <= 64'd0; tail_k <= 8'd0; tx_is_ctrl <= 1'b0;
            bank_rdy <= 2'b00;
            f_seq[0] <= 32'd0; f_seq[1] <= 32'd0;
            f_ack[0] <= 32'd0; f_ack[1] <= 32'd0;
            f_dip[0] <= 32'd0; f_dip[1] <= 32'd0;
            f_wnd[0] <= 16'd0; f_wnd[1] <= 16'd0;
            f_doff[0] <= 16'd0; f_doff[1] <= 16'd0;
            f_sport[0] <= 16'd0; f_sport[1] <= 16'd0;
            f_dport[0] <= 16'd0; f_dport[1] <= 16'd0;
            f_idcap[0] <= 16'd0; f_idcap[1] <= 16'd0;
            f_tcplen[0] <= 16'd0; f_tcplen[1] <= 16'd0;
            f_totlen[0] <= 16'd0; f_totlen[1] <= 16'd0;
            f_ipcsum[0] <= 16'd0; f_ipcsum[1] <= 16'd0;
            f_tcpcsum[0] <= 16'd0; f_tcpcsum[1] <= 16'd0;
            f_plen[0] <= 12'd0; f_plen[1] <= 12'd0;
            f_conn[0] <= 4'd0; f_conn[1] <= 4'd0;
            f_dmac[0] <= 48'd0; f_dmac[1] <= 48'd0;
            ctrl_slot_busy <= 1'b0; ctrl_tx_pend <= 1'b0; ctrl_id <= 4'd0;
            ctrl_is <= 3'd0; ctrl_seq <= 32'd0; ctrl_ack <= 32'd0; ctrl_dip <= 32'd0;
            ctrl_wnd <= 16'd0; ctrl_doff <= 16'd0; ctrl_sport <= 16'd0;
            ctrl_dport <= 16'd0; ctrl_idcap <= 16'd0; ctrl_ipcsum <= 16'd0;
            ctrl_tcpcsum <= 16'd0; ctrl_dmac <= 48'd0;
            m_axis_tdata <= 0; m_axis_tkeep <= 0; m_axis_tvalid <= 0; m_axis_tlast <= 0;
            stat_frames <= 0; stat_bytes <= 0; stat_ack <= 0; stat_ack_drop <= 0;
            stat_eend <= 0; stat_tlast_in <= 0;
            stat_drop_len <= 0; stat_fin <= 0; stat_rst <= 0;
            retx_active <= 0; retx_id_r <= 0; retx_hi <= 0; scan_id <= 0;
            rto_pend <= 16'h0; ring_seq <= 0; ring_rem <= 0; tap_seq <= 0;
            nbeats <= 8'd0; beat_cnt <= 8'd0; ring_d_r <= 64'h0;
            svc_id_r <= 0; tick_cnt <= 0; rto_pend_any <= 0; ack_pend_r <= 0;
            stat_retx_wrap <= 32'd0;
            retx_ovf_p     <= 1'b0;
            stat_retx <= 0;
            fin_sent_r <= 16'h0; rst_sent_r <= 16'h0; fin_retx_pend <= 16'h0;
            for (ri = 0; ri < 16; ri = ri + 1) begin
                rto_timer[ri] <= 21'd0;
                snd_una_prev[ri] <= 32'd0;
                epoch[ri] <= 4'd0;
                fin_seq_r[ri] <= 32'd0;
            end
        end else begin
            // ---- 与默认分支逐字相同的前置块 ----
            if (cfg_up) begin
                fin_sent_r[cfg_up_id]    <= 1'b0;
                rst_sent_r[cfg_up_id]    <= 1'b0;
                fin_retx_pend[cfg_up_id] <= 1'b0;
                epoch[cfg_up_id]        <= 4'd0;
                snd_una_prev[cfg_up_id] <= 32'd0;
                rto_pend[cfg_up_id]     <= 1'b0;
                rto_timer[cfg_up_id]    <= 21'd0;
            end
            if (m_axis_tready && m_axis_tvalid) m_axis_tvalid <= 1'b0;
            if (ack_req && ackq_full) stat_ack_drop <= stat_ack_drop + 1;
            if (accept && s_axis_tlast) stat_tlast_in <= stat_tlast_in + 32'd1;
            // F1 事件计数 (上升沿): 会话存活期间 snd_nxt 被 +1 预留越过 retx_hi 的次数
            retx_ovf_p <= retx_ovf && retx_active;
            if (retx_ovf && retx_active && !retx_ovf_p)
                stat_retx_wrap <= stat_retx_wrap + 32'd1;
            svc_id_r <= retx_req ? retx_id : prio_lo(rto_pend);
            rto_pend_any <= |rto_pend;
            ack_pend_r <= !ackq_empty;
            tick_cnt <= tick_cnt + 4'd1;
            ring_d_r <= ring_d;

            // ==================== RX 引擎 ====================
            case (rx_state)
            RX_IDLE: begin
                // ---- 回卷服务拍 (svc_x: 控制槽在飞 SYN/FIN/RST 时推迟) ----
                if (svc_x) begin
                    if (rb_snd_una == snd_una_prev[svc_id]) begin
                        if (epoch[svc_id] < 4'd15)
                            epoch[svc_id] <= epoch[svc_id] + 4'd1;
                    end else
                        epoch[svc_id] <= 4'd0;
                    snd_una_prev[svc_id] <= rb_snd_una;
                    retx_hi <= (fin_sent_r[svc_id] && svc_rewind) ? fin_seq_r[svc_id] :
                               rb_snd_nxt;
                    if (fin_sent_r[svc_id]) fin_retx_pend[svc_id] <= 1'b1;
                    retx_id_r <= svc_id;
                    retx_active <= retx_begin;
                    rto_pend[svc_id] <= 1'b0;
                    rto_timer[svc_id] <= RTO_LIM;
                    if (svc_rewind) stat_retx <= stat_retx + 32'd1;
                end
                // ---- ring 帧启动 / 排空拍 ----
                if (ring_eval) begin
                    if (ring_start) begin
                        f_conn[rx_bank]   <= retx_id_r;
                        f_seq[rx_bank]    <= rb_snd_nxt;
                        f_ack[rx_bank]    <= rb_rcv_nxt;
                        f_wnd[rx_bank]    <= rb_rcv_wnd;
                        f_doff[rx_bank]   <= 16'h5018;   // 数据帧 PSH+ACK
                        f_dmac[rx_bank]   <= cam_rd_dmac;
                        f_dip[rx_bank]    <= cam_rd_sip;
                        f_sport[rx_bank]  <= cam_rd_dport;
                        f_dport[rx_bank]  <= cam_rd_sport;
                        f_idcap[rx_bank]  <= id_r;
                        id_r              <= id_r + 16'd1;
                        f_plen[rx_bank]   <= plen_preset;
                        f_tcplen[rx_bank] <= {4'b0, plen_preset} + 16'd20;
                        f_totlen[rx_bank] <= {4'b0, plen_preset} + 16'd40;
                        len_bad  <= 1'b0;
                        ring_rem <= (plen_preset[2:0] == 3'd0) ? 12'd8 :
                                    {9'b0, plen_preset[2:0]};
                        nbeats   <= (plen_preset + 12'd7) >> 3;
                        beat_cnt <= 8'd1;
                        ring_seq <= rb_snd_nxt + 32'd8;
                        rx_state <= RX_RING;
                    end else begin
                        // 区间发完 (ring_delta == 0): 1 拍气泡回活数据; FIN 重推
                        if (fin_retx_pend[retx_id_r]) begin
                            if (fin_repush_ok) begin
                                fin_retx_pend[retx_id_r] <= 1'b0;
                                retx_active <= 1'b0;
                            end else if ((rb_state != 4'd1) ||
                                         (rb_snd_una != fin_seq_r[retx_id_r])) begin
                                fin_retx_pend[retx_id_r] <= 1'b0;
                                retx_active <= 1'b0;
                            end
                        end else begin
                            retx_active <= 1'b0;
                        end
                    end
                end
                // ---- RTO 扫描 ----
                if (scan_now) begin
                    if (rb_state != 4'd1) begin
                        fin_sent_r[scan_id] <= 1'b0;
                        rst_sent_r[scan_id] <= 1'b0;
                        fin_retx_pend[scan_id] <= 1'b0;
                    end
                    if (!scan_estab)
                        rto_pend[scan_id] <= 1'b0;
                    if (fin_retx_pend[scan_id] && (rb_snd_una != fin_seq_r[scan_id]))
                        fin_retx_pend[scan_id] <= 1'b0;
                    if (scan_estab && ((rb_snd_wnd != 16'd0 && rb_snd_nxt != rb_snd_una) ||
                        fin_retx_pend[scan_id])) begin
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
                end
                // ---- 控制帧槽装载 (FIX-2': 帧首拍同拍预留 +1 = upd_wr_ctrl) ----
                if (start_ack) begin
                    ctrl_slot_busy <= 1'b1;
                    ctrl_tx_pend   <= 1'b1;
                    ctrl_id        <= start_id;
                    ctrl_is        <= {aq_rst, aq_fin, aq_syn};
                    ctrl_seq       <= rb_snd_nxt;
                    ctrl_ack       <= ctrl_ack_now;
                    ctrl_doff      <= ctrl_doff_now;
                    ctrl_wnd       <= rb_rcv_wnd;
                    ctrl_dmac      <= cam_rd_dmac;
                    ctrl_dip       <= cam_rd_sip;
                    ctrl_sport     <= cam_rd_dport;
                    ctrl_dport     <= cam_rd_sport;
                    ctrl_idcap     <= id_r;
                    ctrl_ipcsum    <= ctrl_ipcsum_now;
                    ctrl_tcpcsum   <= ctrl_tcpcsum_now;
                    id_r           <= id_r + 16'd1;
                end
                // ---- 活帧收字 (含帧首拍上下文锁存) ----
                if (accept) begin
                    if (recv_first) begin
                        recv_first <= 1'b0;
                        f_conn[rx_bank]  <= start_id;
                        f_seq[rx_bank]   <= rb_snd_nxt;
                        f_ack[rx_bank]   <= rb_rcv_nxt;
                        f_wnd[rx_bank]   <= rb_rcv_wnd;
                        f_doff[rx_bank]  <= 16'h5018;   // 数据帧 PSH+ACK
                        f_dmac[rx_bank]  <= cam_rd_dmac;
                        f_dip[rx_bank]   <= cam_rd_sip;
                        f_sport[rx_bank] <= cam_rd_dport;
                        f_dport[rx_bank] <= cam_rd_sport;
                        f_idcap[rx_bank] <= id_r;
                        id_r             <= id_r + 16'd1;
                        tap_seq <= rb_snd_nxt + {20'b0, pop8(s_axis_tkeep)};
                        plen    <= {8'b0, pop8(s_axis_tkeep)};
                    end else begin
                        tap_seq <= tap_seq + {20'b0, pop8(s_axis_tkeep)};
                        plen    <= plen + {8'b0, pop8(s_axis_tkeep)};
                    end
                    if (len_over) len_bad <= 1'b1;
                    if (s_axis_tlast) begin
                        if (len_over || len_bad) begin
                            recv_first    <= 1'b1;
                            stat_drop_len <= stat_drop_len + 32'd1;
                            rx_state      <= RX_FLUSH;
                        end else begin
                            f_plen[rx_bank]   <= plen_n;
                            f_tcplen[rx_bank] <= {4'b0, plen_n} + 16'd20;
                            f_totlen[rx_bank] <= {4'b0, plen_n} + 16'd40;
                            rx_state <= RX_FIN; fin_cnt <= 3'd0;
                        end
                    end
                end
            end
            RX_RING: begin
                // 每拍写 1 beat (ring_d_r -> 本 bank FIFO + checksum16);
                // 末写拍 ring_fin 边沿转 RX_FIN (与活帧同一条收尾)
                if (ring_fin) begin
                    rx_state <= RX_FIN; fin_cnt <= 3'd0;
                end else begin
                    beat_cnt <= beat_cnt + 8'd1;
                    ring_seq <= ring_seq + 32'd8;
                end
            end
            RX_FIN: begin
                // 5 拍: fin_cnt 0/1/2 = aen 三拍 (aen_val 组合), 3 = fin, 4 = 锁存+交棒
                // ⭐ 推进写 (upd_wr_data) 在 fin_cnt==0 拍组合发出 (见写源定义)
                if (fin_cnt == 3'd4) begin
                    f_tcpcsum[rx_bank] <= csum_valid ? csum : 16'h0;
                    f_ipcsum[rx_bank]  <= ip_csum_calc(f_totlen[rx_bank], f_idcap[rx_bank],
                                                       f_dip[rx_bank]);
                    bank_rdy[rx_bank]  <= 1'b1;      // 交棒给 TX 引擎
                    rx_bank            <= ~rx_bank;
                    rx_state           <= RX_IDLE;
                    recv_first         <= 1'b1;
                    fin_cnt            <= 3'd0;
                end else begin
                    fin_cnt <= fin_cnt + 3'd1;
                end
            end
            default: begin   // RX_FLUSH: 冲洗本 bank 的残留字 (排空才清守卫)
                if (fifo_empty_rx) begin
                    len_bad    <= 1'b0;
                    rx_state   <= RX_IDLE;
                    recv_first <= 1'b1;
                end
            end
            endcase

            // ==================== TX 引擎 ====================
            case (tx_state)
            T_IDLE: begin
                if (ctrl_tx_pend) begin
                    // 控制帧优先 (ACK 时延); 仲裁键清位 = 本帧启动拍 (与进 T_HDR 同拍)
                    tx_state     <= T_HDR; thcnt <= 3'd0; tx_is_ctrl <= 1'b1;
                    ctrl_tx_pend <= 1'b0;
                end else if (bank_rdy[tx_bank]) begin
                    tx_state     <= T_HDR; thcnt <= 3'd0; tx_is_ctrl <= 1'b0;
                end
            end
            T_HDR: begin
                if (!m_axis_tvalid || m_axis_tready) begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tkeep  <= 8'hFF;
                    m_axis_tlast  <= 1'b0;
                    case (thcnt)
                        3'd0: m_axis_tdata <= {h_dmac, cfg_src_mac[47:32]};
                        3'd1: m_axis_tdata <= {cfg_src_mac[31:0], 16'h0800, 8'h45, 8'h00};
                        3'd2: m_axis_tdata <= {h_totlen, h_idcap, 16'h0000, 8'h40, 8'h06};
                        3'd3: m_axis_tdata <= {h_ipcsum, cfg_src_ip, h_dip[31:16]};
                        3'd4: m_axis_tdata <= {h_dip[15:0], h_sport, h_dport, h_seq[31:16]};
                        default: m_axis_tdata <= {h_seq[15:0], h_ack, h_doff};
                    endcase
                    if (thcnt == 3'd5) begin
                        tx_state <= T_PAY;
                        hold48 <= {h_wnd, h_tcpcsum, 16'h0000};
                    end else begin
                        thcnt <= thcnt + 3'd1;
                    end
                end
            end
            T_PAY: begin
                if (!m_axis_tvalid || m_axis_tready) begin
                    if (h_plen == 12'd0) begin
                        // 纯 ACK / 零长数据: w6 = {window, csum, urg} 6 字节收尾
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata  <= {hold48, 16'h0000};
                        m_axis_tkeep  <= 8'hFC;
                        m_axis_tlast  <= 1'b1;
                        tx_state      <= T_DONE;
                    end else if (fifo_empty_tx) begin
                        // 欠载防御 (app 契约违规): 提前结束帧 (结构不可达哨兵)
                        stat_eend     <= stat_eend + 1;
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata  <= {hold48, 16'h0000};
                        m_axis_tkeep  <= 8'hFC;
                        m_axis_tlast  <= 1'b1;
                        tx_state      <= T_DONE;
                    end else begin
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata  <= {hold48, fdout_tx[63:48]};
                        hold48        <= fdout_tx[47:0];
                        if (fdout_tx[72]) begin
                            if (pop8(fdout_tx[71:64]) < 4'd2) begin
                                m_axis_tkeep <= 8'hFF << (4'd8 -
                                                (4'd6 + pop8(fdout_tx[71:64])));
                                m_axis_tlast <= 1'b1;
                                tx_state     <= T_DONE;
                            end else if (pop8(fdout_tx[71:64]) == 4'd2) begin
                                m_axis_tkeep <= 8'hFF;
                                m_axis_tlast <= 1'b1;
                                tx_state     <= T_DONE;
                            end else begin
                                m_axis_tkeep <= 8'hFF;
                                m_axis_tlast <= 1'b0;
                                tail_d <= ljust6(fdout_tx[47:0],
                                                 pop8(fdout_tx[71:64]) - 4'd2);
                                tail_k <= 8'hFF << (4'd8 -
                                          (pop8(fdout_tx[71:64]) - 4'd2));
                                tx_state <= T_TAIL;
                            end
                        end else begin
                            m_axis_tkeep <= 8'hFF;
                            m_axis_tlast <= 1'b0;
                        end
                    end
                end
            end
            T_TAIL: begin
                if (!m_axis_tvalid || m_axis_tready) begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= tail_d;
                    m_axis_tkeep  <= tail_k;
                    m_axis_tlast  <= 1'b1;
                    tx_state      <= T_DONE;
                end
            end
            default: begin   // T_DONE: 记账 + 归还 bank / 卸载槽 + 下一帧边界仲裁
                if (!m_axis_tvalid || m_axis_tready) begin
                    stat_frames <= stat_frames + 1;
                    stat_bytes  <= stat_bytes + {20'b0, h_plen};
                    if (tx_is_ctrl) begin
                        stat_ack <= stat_ack + 1;    // 口径 = 默认分支的 !is_data_r
                        ctrl_slot_busy <= 1'b0;      // 槽卸载 (与该帧 T_DONE 同拍)
                        if (ctrl_is[1]) begin        // FIN
                            fin_sent_r[ctrl_id]    <= 1'b1;
                            fin_seq_r[ctrl_id]     <= ctrl_seq;
                            fin_retx_pend[ctrl_id] <= 1'b0;
                            stat_fin <= stat_fin + 32'd1;
                        end
                        if (ctrl_is[2]) begin        // RST
                            rst_sent_r[ctrl_id] <= 1'b1;
                            stat_rst <= stat_rst + 32'd1;
                        end
                    end else begin
                        bank_rdy[tx_bank] <= 1'b0;   // 归还本 bank 给 RX 引擎
                        tx_bank <= nxt_bank;
                    end
                    // 下一帧边界: 槽优先 (ACK 时延), 否则就绪 bank
                    if (ctrl_tx_pend) begin
                        tx_state <= T_HDR; thcnt <= 3'd0; tx_is_ctrl <= 1'b1;
                        ctrl_tx_pend <= 1'b0;
                    end else if (tx_is_ctrl ? bank_rdy[tx_bank] : bank_rdy[nxt_bank]) begin
                        tx_state <= T_HDR; thcnt <= 3'd0; tx_is_ctrl <= 1'b0;
                    end else begin
                        tx_state <= T_IDLE;
                    end
                end
            end
            endcase
        end
    end

    // ---- 调试探针 (纯线束; 乒乓版的语义见 P7B_STAGEC_TX.md) ----
    assign dbg_wnd_open     = wnd_open;
    assign dbg_pay_full     = fifo_full;
    assign dbg_sready       = s_axis_tready;
    assign dbg_saxis_tvalid = s_axis_tvalid;
    assign dbg_plen_r       = f_plen[rx_bank];
    assign dbg_state        = tx_state;
    assign dbg_pay_wptr     = rx_bank ? dwpr_b : dwpr_a;
    assign dbg_pay_rptr     = rx_bank ? drpr_b : drpr_a;
    assign dbg_pay_full2    = rx_bank ? dfu_b : dfu_a;
    assign dbg_pay_empty    = fifo_empty_rx;
    assign dbg_plen         = plen;
