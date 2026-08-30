`timescale 1ns/1ps
// P4a 全链 TB: GMII -> mac_rx_64 -> rx_classify -> fast(P3 TCP 链) / slow(HLS 慢路径)
//             -> tx_arb -> mac_tx_64 -> GMII。慢路径 = 真 HLS udp_echo (综合 verilog)。
// 结构/配置阶段/仲裁与 tb_tcp_echo 一致 (conn1 TB 预配, conn0 tcp_synp 握手);
// 新增: classify 插入 mac 之后, slow_rx_adp->udp_echo->slow_tx_adp 挂 slow 路由,
// tx_arb 汇合 fast/slow 进 mac_tx_64。cfg_src_mac = C0 (P4 统一)。
// 捕获 (resp_p4_chain.memh): 每拍 "%02h %d" (gmii_txd, tx_en) + 事件行
//   FEND k ferr / ACK k id val / SYNP 对端握手字段; 末尾 STATS7/STATS_TX/STATS_ECO
//   /CAMF/TCBF + SLOWRX (commit drop) / SLOWTX (frames purge)。
// 校验全语义 (gen_stim_p4_chain.py check): HLS 应答拍级不可预期, 快慢流自由交错。
module tb_p4_chain;

    reg        clk, rst_n;
    reg [7:0]  rx_d;
    reg        rx_dv, rx_er;
    reg [7:0]  stim_d [0:1048575];
    reg [7:0]  stim_v [0:1048575];
    reg [7:0]  stim_e [0:1048575];
    integer    nstim;
    reg [19:0] i;
    reg [31:0] k;
    reg        done;
    // 配置阶段
    reg [5:0]  cphase;
    reg [31:0] tcbc [0:95];
    reg        cfg_wr;
    reg [3:0]  cfg_addr;
    reg [31:0] cfg_sip, cfg_dip;
    reg [15:0] cfg_sport, cfg_dport;
    reg [47:0] cfg_dmac;
    reg        cfg_upd_wr;
    reg [3:0]  cfg_upd_id;
    reg [2:0]  cfg_upd_sel;
    reg [31:0] cfg_upd_val;

    // mac_rx -> classify
    wire [63:0] s_tdata;
    wire [7:0]  s_tkeep;
    wire        s_tvalid, s_tready, s_tlast, s_tuser, s_tcrs, s_terr;
    // classify -> fast (tcp_rx)
    wire [63:0] f_tdata;
    wire [7:0]  f_tkeep;
    wire        f_tvalid, f_tready, f_tlast, f_tuser, f_tcrs, f_terr;
    // classify -> slow (slow_rx_adp)
    wire [63:0] w_tdata;
    wire [7:0]  w_tkeep;
    wire        w_tvalid, w_tready, w_tlast, w_tuser, w_tcrs, w_terr;
    // tcp_rx 载荷口 -> tcp_echo
    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tready, m_tlast;
    wire [1:0]  m_tuser;
    wire        fend, ferr;
    wire        meta_valid;
    wire [3:0]  meta_conn_id;
    wire [15:0] meta_len;
    wire [3:0]  ra_id;
    wire [31:0] ra_rcv_nxt, ra_snd_nxt, ra_snd_una;
    wire [15:0] ra_rcv_wnd;
    wire [3:0]  ra_state;
    wire [3:0]  ra_wscale;
    wire        rx_upd_wr;
    wire [3:0]  rx_upd_id;
    wire [2:0]  rx_upd_sel;
    wire [31:0] rx_upd_val;
    wire        rx_upd_gnt;
    wire        ack_req;
    wire [3:0]  ack_id;
    wire [31:0] ack_val;
    wire [31:0] cam_q_sip, cam_q_dip;
    wire [15:0] cam_q_sport, cam_q_dport;
    wire        cam_q_hit;
    wire [3:0]  cam_q_id;
    wire [31:0] rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                rx_stat_seq, rx_stat_ack, rx_stat_bytes;
    // tcp_echo -> tcp_tx_frame
    wire [63:0] eco_tdata;
    wire [7:0]  eco_tkeep;
    wire        eco_tvalid, eco_tready, eco_tlast;
    wire [3:0]  eco_tid;
    wire [31:0] eco_stat_echo, eco_stat_drop_crc;
    // tcp_tx_frame
    wire [3:0]  rb_id;
    wire [31:0] rb_rcv_nxt, rb_snd_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;
    wire        tx_upd_wr;
    wire [3:0]  tx_upd_id;
    wire [2:0]  tx_upd_sel;
    wire [31:0] tx_upd_val;
    wire [3:0]  cam_rd_id;
    wire [47:0] cam_rd_dmac;
    wire [31:0] cam_rd_sip, cam_rd_dip;
    wire [15:0] cam_rd_sport, cam_rd_dport;
    // tcp_tx_frame -> tx_arb (fast)
    wire [63:0] x_tdata;
    wire [7:0]  x_tkeep;
    wire        x_tvalid, x_tready, x_tlast;
    // slow_tx_adp -> tx_arb (slow)
    wire [63:0] z_tdata;
    wire [7:0]  z_tkeep;
    wire        z_tvalid, z_tready, z_tlast;
    // tx_arb -> mac_tx_64
    wire [63:0] a_tdata;
    wire [7:0]  a_tkeep;
    wire        a_tvalid, a_tready, a_tlast;
    wire [7:0]  gmii_txd;
    wire        gmii_tx_en;
    wire [31:0] tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_ack_drop;
    wire [31:0] tx_stat_eend;
    wire [31:0] mac_stat_frames, mac_stat_abort;
    // tcp_rx SYN sideband (P4b: SYN 已分流慢路径, sideband 空挂)
    wire        syn_v;
    wire [47:0] syn_smac;
    wire [31:0] syn_sip;
    wire [15:0] syn_sport, syn_dport;
    wire [31:0] syn_seq;
    wire [15:0] syn_wnd;
    // slow_cfg_adp 输出 (P4b: HLS cfg_stream -> CAM/TCB)
    wire        scfg_cam_wr;
    wire [3:0]  scfg_cam_addr;
    wire [31:0] scfg_cam_sip, scfg_cam_dip;
    wire [15:0] scfg_cam_sport, scfg_cam_dport;
    wire [47:0] scfg_cam_dmac;
    wire        scfg_upd_wr;
    wire [3:0]  scfg_upd_id;
    wire [2:0]  scfg_upd_sel;
    wire [31:0] scfg_upd_val;
    wire        scfg_gnt;
    wire [31:0] scfg_add, scfg_del;
    // 慢路径
    wire [15:0] hls_rx_tdata;
    wire        hls_rx_tvalid, hls_rx_tready;
    wire [15:0] hls_tx_tdata;
    wire        hls_tx_tvalid, hls_tx_tready;
    wire [31:0] hls_cfg_tdata;
    wire        hls_cfg_tvalid, hls_cfg_tready;
    wire        hls_rst_n;
    wire [31:0] srx_commit, srx_drop, stx_frames, stx_purge;

    // ---- CAM 配置口二选一: TB 配置阶段优先, 其次 slow_cfg ----
    wire        cam_cfg_wr    = cfg_wr | scfg_cam_wr;
    wire [3:0]  cam_cfg_addr  = cfg_wr ? cfg_addr  : scfg_cam_addr;
    wire [31:0] cam_cfg_sip   = cfg_wr ? cfg_sip   : scfg_cam_sip;
    wire [31:0] cam_cfg_dip   = cfg_wr ? cfg_dip   : scfg_cam_dip;
    wire [15:0] cam_cfg_sport = cfg_wr ? cfg_sport : scfg_cam_sport;
    wire [15:0] cam_cfg_dport = cfg_wr ? cfg_dport : scfg_cam_dport;
    wire [47:0] cam_cfg_dmac  = cfg_wr ? cfg_dmac  : scfg_cam_dmac;

    // ---- TX 的 ACK 请求: 仅 tcp_rx (synp 已拆; SYN+ACK 由 HLS 慢路径直发) ----
    wire        tx_ack_req = ack_req;
    wire [3:0]  tx_ack_id  = ack_id;
    wire [31:0] tx_ack_val = ack_val;
    wire        tx_ack_syn = 1'b0;

    // ---- TCB 更新仲裁 (tx > rx > cfg; cfg 级 = TB 配置 | slow_cfg(带 gnt)) ----
    wire        scfg_gnt_i  = !tx_upd_wr && !rx_upd_wr && !cfg_upd_wr && scfg_upd_wr;
    wire        cfglvl_wr   = cfg_upd_wr | (scfg_upd_wr && scfg_gnt_i);
    wire [2:0]  cfglvl_sel  = cfg_upd_wr ? cfg_upd_sel : scfg_upd_sel;
    wire [3:0]  cfglvl_id   = cfg_upd_wr ? cfg_upd_id  : scfg_upd_id;
    wire [31:0] cfglvl_val  = cfg_upd_wr ? cfg_upd_val : scfg_upd_val;
    wire        sel_tx = tx_upd_wr;
    wire        sel_rx = !sel_tx && rx_upd_wr;
    wire        tcb_wr  = sel_tx || sel_rx || cfglvl_wr;
    wire [2:0]  tcb_sel = sel_tx ? tx_upd_sel : (sel_rx ? rx_upd_sel : cfglvl_sel);
    wire [3:0]  tcb_id  = sel_tx ? tx_upd_id  : (sel_rx ? rx_upd_id  : cfglvl_id);
    wire [31:0] tcb_val = sel_tx ? tx_upd_val : (sel_rx ? rx_upd_val : cfglvl_val);
    assign rx_upd_gnt = sel_rx;
    assign scfg_gnt   = scfg_gnt_i;

    integer     fd;

    // ================= P4b-6 PC 反应式 ACK 模型 (+PCACK) =================
    // 窗口门控下 snd_una 必须随 echo 推进, 否则 in_flight 打满 snd_wnd 锁死。
    // 捕获 conn0 echo 数据帧 (GMII TX: 0800/proto6/sport 1F90/dport 3039/
    // flags 18), 帧尾记 echo_end_seq = seq + (ip_tlen-40); RX 流帧间隙注入
    // 纯 ACK (60B: seq=rcv_nxt_r[0], ack=echo_end_seq, wnd 0x4000)。
    // 注入帧 IP 头除 csum 外恒定, TCP csum fast 路径不查 (填 0)。
    reg        pcack_en;
    reg        inj_play;          // 正在播放注入帧
    reg [6:0]  inj_idx;
    reg [31:0] inj_ack_val;
    reg [7:0]  inj_buf [0:71];    // 8 前导 + 60 帧 + 4 FCS
    reg [31:0] seq_b, ack_b, inj_crc;
    reg [15:0] ipcs_c;
    integer    bi;
    // TX echo 帧头捕获 (前 48 字节)
    reg        tx_en_d, tx_inf;
    reg [5:0]  txbc;
    reg [7:0]  cap [0:47];
    // echo_seen / inj_done 分属捕获/驱动两个 always (单驱动铁律); 差值 = 待注入
    reg [15:0] echo_seen, inj_done;
    wire       inj_pend = pcack_en && (echo_seen != inj_done);
    reg [15:0] inj_wnd;   // 注入 ACK 的通告窗口 (默认 0x4000; +PCWND1K 压 0x0400
                          //  — SYN 带 WS=2, 缩放后有效窗口 0x1000, 强迫门控交战)
    reg [3:0]  gap_cnt;   // 已连续播放的间隙字节数 (采样 rcv_nxt 须等上一帧
                          //  fend 的 drain 落地 = fend+3 拍, 否则注入帧带旧 seq
                          //  被 tcp_rx 拒收 — TB 模型噪声, 但污染统计)

    function [7:0] inj_byte;
        input [6:0] idx;
        input [31:0] sq;
        input [31:0] ak;
        input [15:0] ics;
        begin
            case (idx)
                7'd0:  inj_byte = 8'h00;  7'd1:  inj_byte = 8'h0A;
                7'd2:  inj_byte = 8'h35;  7'd3:  inj_byte = 8'h01;
                7'd4:  inj_byte = 8'hFE;  7'd5:  inj_byte = 8'hC0;
                7'd6:  inj_byte = 8'h11;  7'd7:  inj_byte = 8'h22;
                7'd8:  inj_byte = 8'h33;  7'd9:  inj_byte = 8'h44;
                7'd10: inj_byte = 8'h55;  7'd11: inj_byte = 8'h66;
                7'd12: inj_byte = 8'h08;  7'd13: inj_byte = 8'h00;
                7'd14: inj_byte = 8'h45;  7'd15: inj_byte = 8'h00;
                7'd16: inj_byte = 8'h00;  7'd17: inj_byte = 8'h28;
                7'd18: inj_byte = 8'h77;  7'd19: inj_byte = 8'h77;
                7'd20: inj_byte = 8'h00;  7'd21: inj_byte = 8'h00;
                7'd22: inj_byte = 8'h40;  7'd23: inj_byte = 8'h06;
                7'd24: inj_byte = ics[15:8]; 7'd25: inj_byte = ics[7:0];
                7'd26: inj_byte = 8'hC0;  7'd27: inj_byte = 8'hA8;
                7'd28: inj_byte = 8'h64;  7'd29: inj_byte = 8'h01;
                7'd30: inj_byte = 8'hC0;  7'd31: inj_byte = 8'hA8;
                7'd32: inj_byte = 8'h64;  7'd33: inj_byte = 8'h02;
                7'd34: inj_byte = 8'h30;  7'd35: inj_byte = 8'h39;
                7'd36: inj_byte = 8'h1F;  7'd37: inj_byte = 8'h90;
                7'd38: inj_byte = sq[31:24]; 7'd39: inj_byte = sq[23:16];
                7'd40: inj_byte = sq[15:8];  7'd41: inj_byte = sq[7:0];
                7'd42: inj_byte = ak[31:24]; 7'd43: inj_byte = ak[23:16];
                7'd44: inj_byte = ak[15:8];  7'd45: inj_byte = ak[7:0];
                7'd46: inj_byte = 8'h50;  7'd47: inj_byte = 8'h10;
                7'd48: inj_byte = inj_wnd[15:8]; 7'd49: inj_byte = inj_wnd[7:0];
                default: inj_byte = 8'h00;   // 50..53 tcp csum/urg=0, 54..59 pad
            endcase
        end
    endfunction

    function [15:0] ip_csum_inj;   // 注入帧 IP 头恒定 → csum 恒定
        input dummy;             // verilog 函数至少一个输入
        reg [31:0] s;
        begin
            s = 32'h4500 + 32'h0028 + 32'h7777 + 32'h0000 + 32'h4006 +
                32'hC0A8 + 32'h6401 + 32'hC0A8 + 32'h6402;
            s = (s & 32'hFFFF) + (s >> 16);
            s = (s & 32'hFFFF) + (s >> 16);
            ip_csum_inj = ~s[15:0];
        end
    endfunction

    function [31:0] crc32b;
        input [31:0] crc;
        input [7:0]  d;
        integer j;
        reg [31:0] cc;
        begin
            cc = crc ^ {24'b0, d};
            for (j = 0; j < 8; j = j + 1)
                cc = cc[0] ? ((cc >> 1) ^ 32'hEDB88320) : (cc >> 1);
            crc32b = cc;
        end
    endfunction

    mac_rx_64 u_mac (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(s_tdata), .m_axis_tkeep(s_tkeep), .m_axis_tvalid(s_tvalid),
        .m_axis_tready(s_tready), .m_axis_tlast(s_tlast), .m_axis_tuser(s_tuser),
        .m_axis_terr(s_terr), .m_axis_tcrs(s_tcrs),
        .stat_frames(), .stat_crc_err(), .stat_drop(), .stat_bytes()
    );

    rx_classify u_classify (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .m_fast_tdata(f_tdata), .m_fast_tkeep(f_tkeep), .m_fast_tvalid(f_tvalid),
        .m_fast_tready(f_tready), .m_fast_tlast(f_tlast), .m_fast_tuser(f_tuser),
        .m_fast_tcrs(f_tcrs), .m_fast_terr(f_terr),
        .m_slow_tdata(w_tdata), .m_slow_tkeep(w_tkeep), .m_slow_tvalid(w_tvalid),
        .m_slow_tready(w_tready), .m_slow_tlast(w_tlast), .m_slow_tuser(w_tuser),
        .m_slow_tcrs(w_tcrs), .m_slow_terr(w_terr),
        .stat_fast(), .stat_slow()
    );

    tcp_rx u_rx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(f_tdata), .s_axis_tkeep(f_tkeep), .s_axis_tvalid(f_tvalid),
        .s_axis_tready(f_tready), .s_axis_tlast(f_tlast), .s_axis_tuser(f_tuser),
        .s_axis_tcrs(f_tcrs), .s_axis_terr(f_terr),
        .cfg_suppress_data_ack(1'b1),   // 与板上 wrapper_p4 一致 (echo 应用)
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .fend(fend), .ferr(ferr),
        .meta_valid(meta_valid), .meta_src_ip(), .meta_src_port(),
        .meta_len(meta_len), .meta_conn_id(meta_conn_id), .meta_seq(),
        .ra_id(ra_id),
        .ra_rcv_nxt(ra_rcv_nxt), .ra_snd_nxt(ra_snd_nxt), .ra_snd_una(ra_snd_una),
        .ra_rcv_wnd(ra_rcv_wnd), .ra_state(ra_state), .ra_wscale(ra_wscale),
        .upd_wr(rx_upd_wr), .upd_id(rx_upd_id), .upd_sel(rx_upd_sel), .upd_val(rx_upd_val),
        .upd_gnt(rx_upd_gnt),
        .ack_req(ack_req), .ack_id(ack_id), .ack_val(ack_val),
        .syn_v(syn_v), .syn_smac(syn_smac), .syn_sip(syn_sip),
        .syn_sport(syn_sport), .syn_dport(syn_dport),
        .syn_seq(syn_seq), .syn_wnd(syn_wnd),
        .cam_q_sip(cam_q_sip), .cam_q_dip(cam_q_dip),
        .cam_q_sport(cam_q_sport), .cam_q_dport(cam_q_dport),
        .cam_q_hit(cam_q_hit), .cam_q_id(cam_q_id),
        .stat_pass(rx_stat_pass), .stat_drop_nonmatch(rx_stat_nonmatch),
        .stat_drop_ipcsum(rx_stat_ipcsum), .stat_drop_crc(rx_stat_crc),
        .stat_drop_seq(rx_stat_seq), .stat_ack(rx_stat_ack), .stat_bytes(rx_stat_bytes)
    );

    tcp_echo u_echo (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(m_tdata), .s_axis_tkeep(m_tkeep), .s_axis_tvalid(m_tvalid),
        .s_axis_tready(m_tready), .s_axis_tlast(m_tlast), .s_axis_tuser(m_tuser),
        .fend(fend), .ferr(ferr),
        .meta_valid(meta_valid), .meta_conn_id(meta_conn_id), .meta_len(meta_len),
        .m_axis_tdata(eco_tdata), .m_axis_tkeep(eco_tkeep), .m_axis_tvalid(eco_tvalid),
        .m_axis_tready(eco_tready), .m_axis_tlast(eco_tlast), .m_axis_tid(eco_tid),
        .stat_echo(eco_stat_echo), .stat_drop_crc(eco_stat_drop_crc)
    );

    tcp_cam u_cam (
        .clk(clk), .rst_n(rst_n),
        .cfg_wr(cam_cfg_wr), .cfg_addr(cam_cfg_addr),
        .cfg_sip(cam_cfg_sip), .cfg_dip(cam_cfg_dip),
        .cfg_sport(cam_cfg_sport), .cfg_dport(cam_cfg_dport), .cfg_dmac(cam_cfg_dmac),
        .q_sip(cam_q_sip), .q_dip(cam_q_dip),
        .q_sport(cam_q_sport), .q_dport(cam_q_dport),
        .q_id(cam_q_id), .q_hit(cam_q_hit),
        .rd_id(cam_rd_id), .rd_dmac(cam_rd_dmac), .rd_sip(cam_rd_sip), .rd_dip(cam_rd_dip),
        .rd_sport(cam_rd_sport), .rd_dport(cam_rd_dport)
    );

    tcb u_tcb (
        .clk(clk), .rst_n(rst_n),
        .ra_id(ra_id), .ra_rcv_nxt(ra_rcv_nxt), .ra_snd_nxt(ra_snd_nxt),
        .ra_snd_una(ra_snd_una), .ra_rcv_wnd(ra_rcv_wnd), .ra_snd_wnd(),
        .ra_state(ra_state), .ra_wscale(ra_wscale),
        .rb_id(rb_id), .rb_rcv_nxt(rb_rcv_nxt), .rb_snd_nxt(rb_snd_nxt),
        .rb_snd_una(rb_snd_una), .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
        .upd_wr(tcb_wr), .upd_id(tcb_id), .upd_sel(tcb_sel), .upd_val(tcb_val)
    );

    slow_cfg_adp u_slow_cfg (
        .clk(clk), .rst_n(rst_n & hls_rst_n),
        .s_axis_tdata(hls_cfg_tdata), .s_axis_tvalid(hls_cfg_tvalid),
        .s_axis_tready(hls_cfg_tready),
        .cam_cfg_wr(scfg_cam_wr), .cam_cfg_addr(scfg_cam_addr),
        .cam_cfg_sip(scfg_cam_sip), .cam_cfg_dip(scfg_cam_dip),
        .cam_cfg_sport(scfg_cam_sport), .cam_cfg_dport(scfg_cam_dport),
        .cam_cfg_dmac(scfg_cam_dmac),
        .upd_wr(scfg_upd_wr), .upd_id(scfg_upd_id),
        .upd_sel(scfg_upd_sel), .upd_val(scfg_upd_val),
        .cfg_gnt(scfg_gnt),
        .stat_add(scfg_add), .stat_del(scfg_del)
    );

    tcp_tx_frame u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(eco_tdata), .s_axis_tkeep(eco_tkeep),
        .s_axis_tvalid(eco_tvalid), .s_axis_tready(eco_tready), .s_axis_tlast(eco_tlast),
        .s_axis_tid(eco_tid),
        .ack_req(tx_ack_req), .ack_id(tx_ack_id), .ack_val(tx_ack_val),
        .ack_syn(tx_ack_syn),
        .rb_id(rb_id), .rb_snd_nxt(rb_snd_nxt), .rb_rcv_nxt(rb_rcv_nxt),
        .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_una(rb_snd_una), .rb_snd_wnd(rb_snd_wnd),
        .upd_wr(tx_upd_wr), .upd_id(tx_upd_id), .upd_sel(tx_upd_sel), .upd_val(tx_upd_val),
        .cam_rd_id(cam_rd_id), .cam_rd_dmac(cam_rd_dmac), .cam_rd_sip(cam_rd_sip),
        .cam_rd_sport(cam_rd_sport), .cam_rd_dport(cam_rd_dport),
        .cfg_src_mac(48'h000A3501FEC0), .cfg_src_ip(32'hC0A86402),
        .m_axis_tdata(x_tdata), .m_axis_tkeep(x_tkeep),
        .m_axis_tvalid(x_tvalid), .m_axis_tready(x_tready), .m_axis_tlast(x_tlast),
        .stat_frames(tx_stat_frames), .stat_bytes(tx_stat_bytes),
        .stat_ack(tx_stat_ack), .stat_ack_drop(tx_stat_ack_drop),
        .stat_eend(tx_stat_eend)
    );

    // ---- 慢路径: slow_rx_adp -> udp_echo (HLS) -> slow_tx_adp ----
    slow_rx_adp u_slow_rx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(w_tdata), .s_axis_tkeep(w_tkeep), .s_axis_tvalid(w_tvalid),
        .s_axis_tready(w_tready), .s_axis_tlast(w_tlast), .s_axis_tuser(w_tuser),
        .s_axis_tcrs(w_tcrs), .s_axis_terr(w_terr),
        .hls_rx_tdata(hls_rx_tdata), .hls_rx_tvalid(hls_rx_tvalid),
        .hls_rx_tready(hls_rx_tready),
        .hls_rst_n(hls_rst_n),
        .stat_commit(srx_commit), .stat_drop(srx_drop)
    );

    udp_echo u_hls (
        .ap_clk(clk), .ap_rst_n(rst_n & hls_rst_n), .reset_n(rst_n & hls_rst_n),
        .rx_stream_TDATA(hls_rx_tdata), .rx_stream_TVALID(hls_rx_tvalid),
        .rx_stream_TREADY(hls_rx_tready),
        .tx_stream_TDATA(hls_tx_tdata), .tx_stream_TVALID(hls_tx_tvalid),
        .tx_stream_TREADY(hls_tx_tready),
        .msg_stream_TDATA(), .msg_stream_TVALID(), .msg_stream_TREADY(1'b1),
        .cfg_stream_TDATA(hls_cfg_tdata), .cfg_stream_TVALID(hls_cfg_tvalid),
        .cfg_stream_TREADY(hls_cfg_tready),
        .led_d0(), .led_d1(), .led_d2(), .led_d3()
    );

    slow_tx_adp u_slow_tx (
        .clk(clk), .rst_n(rst_n),
        .hls_tx_tdata(hls_tx_tdata), .hls_tx_tvalid(hls_tx_tvalid),
        .hls_tx_tready(hls_tx_tready),
        .m_axis_tdata(z_tdata), .m_axis_tkeep(z_tkeep),
        .m_axis_tvalid(z_tvalid), .m_axis_tready(z_tready), .m_axis_tlast(z_tlast),
        .stat_frames(stx_frames), .stat_purge(stx_purge)
    );

    tx_arb u_tx_arb (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(x_tdata), .s_fast_tkeep(x_tkeep), .s_fast_tvalid(x_tvalid),
        .s_fast_tready(x_tready), .s_fast_tlast(x_tlast),
        .s_slow_tdata(z_tdata), .s_slow_tkeep(z_tkeep), .s_slow_tvalid(z_tvalid),
        .s_slow_tready(z_tready), .s_slow_tlast(z_tlast),
        .m_axis_tdata(a_tdata), .m_axis_tkeep(a_tkeep),
        .m_axis_tvalid(a_tvalid), .m_axis_tready(a_tready), .m_axis_tlast(a_tlast)
    );

    mac_tx_64 u_mactx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(a_tdata), .s_axis_tkeep(a_tkeep),
        .s_axis_tvalid(a_tvalid), .s_axis_tready(a_tready), .s_axis_tlast(a_tlast),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(),
        .stat_frames(mac_stat_frames), .stat_abort(mac_stat_abort)
    );

    always #4 clk = ~clk;     // 125 MHz

    // ---- 时钟化激励驱动 + 配置阶段 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            i <= 0; k <= 32'hFFFFFFFF; rx_d <= 8'h07; rx_dv <= 0; rx_er <= 0; done <= 0;
            cphase <= 0;
            inj_play <= 0; inj_idx <= 0; inj_done <= 0; gap_cnt <= 0;
            cfg_wr <= 0; cfg_addr <= 0; cfg_sip <= 0; cfg_dip <= 0;
            cfg_sport <= 0; cfg_dport <= 0; cfg_dmac <= 0;
            cfg_upd_wr <= 0; cfg_upd_id <= 0; cfg_upd_sel <= 0; cfg_upd_val <= 0;
        end else begin
            k <= k + 1;
            if (cphase < 40) begin
                rx_dv <= 0; rx_er <= 0;
                cfg_wr <= (cphase == 6'd2);
                cfg_addr <= 4'd1;
                case (cphase)
                    6'd2: begin
                        cfg_sip <= 32'h0A000009; cfg_dip <= 32'hC0A86409;
                        cfg_sport <= 16'hD431; cfg_dport <= 16'h1F91;
                        cfg_dmac <= 48'hAABBCCDDEE01;
                    end
                    default: ;
                endcase
                cfg_upd_wr <= (cphase >= 6 && cphase <= 11);
                cfg_upd_id  <= 4'd1;
                cfg_upd_sel <= (cphase - 6) % 6;
                cfg_upd_val <= tcbc[cphase - 6];
                cphase <= cphase + 1;
            end else begin
                cfg_wr <= 0; cfg_upd_wr <= 0;
                if (inj_play) begin
                    // 注入帧播放 (静态流暂停, i 冻结 — rcv_nxt 播放期不变)。
                    // 前 12 拍播 IFG (dv=0)! 直接进前导会让 mac_rx_64 收不到
                    // 帧间间隙 → 注入帧与静态前帧融合成一帧 (PCACK 首版实锤)。
                    if (inj_idx < 7'd12) begin
                        rx_d  <= 8'h07;
                        rx_dv <= 1'b0;
                    end else begin
                        rx_d  <= inj_buf[inj_idx - 7'd12];
                        rx_dv <= 1'b1;
                    end
                    rx_er <= 1'b0;
                    if (inj_idx == 7'd83) inj_play <= 1'b0;   // 12 IFG + 72 帧
                    inj_idx <= inj_idx + 7'd1;
                end else if (i < nstim) begin
                    if (pcack_en && inj_pend && !stim_v[i][0] &&
                        gap_cnt >= 4'd11) begin
                        // 帧间隙: 构建纯 ACK (此刻静态流在间隙, rcv_nxt 冻结)。
                        // 本拍仍播该间隙字节, 下拍起 12 拍 IFG 再进前导。
                        seq_b  = u_tcb.rcv_nxt_r[0];
                        ack_b  = inj_ack_val;
                        ipcs_c = ip_csum_inj(1'b0);
                        inj_crc = 32'hFFFFFFFF;
                        for (bi = 0; bi < 8; bi = bi + 1)
                            inj_buf[bi] <= (bi == 7) ? 8'hD5 : 8'h55;
                        for (bi = 0; bi < 60; bi = bi + 1) begin
                            inj_buf[8 + bi] <= inj_byte(bi, seq_b, ack_b, ipcs_c);
                            inj_crc = crc32b(inj_crc, inj_byte(bi, seq_b, ack_b, ipcs_c));
                        end
                        inj_crc = ~inj_crc;
                        inj_buf[68] <= inj_crc[7:0];      // FCS 线上 LSB-first
                        inj_buf[69] <= inj_crc[15:8];
                        inj_buf[70] <= inj_crc[23:16];
                        inj_buf[71] <= inj_crc[31:24];
                        inj_done <= echo_seen;   // 累计 ACK 一次覆盖全部待注入
                        inj_play <= 1'b1;
                        inj_idx  <= 7'd0;
                        rx_d  <= stim_d[i];      // 本拍照旧播间隙字节并消耗之
                        rx_dv <= stim_v[i][0];
                        rx_er <= stim_e[i][0];
                        i <= i + 1;
                    end else begin
                        rx_d  <= stim_d[i];
                        rx_dv <= stim_v[i][0];
                        rx_er <= stim_e[i][0];
                        i <= i + 1;
                        if (stim_v[i][0]) gap_cnt <= 4'd0;
                        else if (gap_cnt != 4'hF) gap_cnt <= gap_cnt + 4'd1;
                    end
                end else if (pcack_en && inj_pend && gap_cnt >= 4'd11) begin
                    // 静态流已尽, 尾帧 echo 的 ACK 仍需注入 (否则门控卡住尾批)
                    seq_b  = u_tcb.rcv_nxt_r[0];
                    ack_b  = inj_ack_val;
                    ipcs_c = ip_csum_inj(1'b0);
                    inj_crc = 32'hFFFFFFFF;
                    for (bi = 0; bi < 8; bi = bi + 1)
                        inj_buf[bi] <= (bi == 7) ? 8'hD5 : 8'h55;
                    for (bi = 0; bi < 60; bi = bi + 1) begin
                        inj_buf[8 + bi] <= inj_byte(bi, seq_b, ack_b, ipcs_c);
                        inj_crc = crc32b(inj_crc, inj_byte(bi, seq_b, ack_b, ipcs_c));
                    end
                    inj_crc = ~inj_crc;
                    inj_buf[68] <= inj_crc[7:0];
                    inj_buf[69] <= inj_crc[15:8];
                    inj_buf[70] <= inj_crc[23:16];
                    inj_buf[71] <= inj_crc[31:24];
                    inj_done <= echo_seen;
                    inj_play <= 1'b1;
                    inj_idx  <= 7'd0;
                    rx_dv <= 1'b0;   // 本拍即入 IFG
                    rx_er <= 1'b0;
                end else begin
                    rx_dv <= 0; rx_er <= 0;
                    if (gap_cnt != 4'hF) gap_cnt <= gap_cnt + 4'd1;
                end
                if (i >= nstim && !inj_pend && !inj_play) done <= 1;
            end
        end
    end

    initial begin
        clk = 0; rst_n = 0;
        pcack_en = $test$plusargs("PCACK");
        inj_wnd = $test$plusargs("PCWND1K") ? 16'h0400 : 16'h4000;
        $readmemh("stim_data.memh", stim_d);
        $readmemh("stim_dv.memh",   stim_v);
        $readmemh("stim_er.memh",   stim_e);
        $readmemh("cfg_tcb.memh",   tcbc);
        nstim = 0;
        while (nstim < 1048576 && stim_d[nstim] !== 8'hxx) nstim = nstim + 1;
        fd = $fopen("resp_p4_chain.memh", "w");
        #200; rst_n = 1;
        wait (done == 1);
        repeat (60000) @(posedge clk);   // HLS 应答余量 (拍级不可预期)
        $fwrite(fd, "STATS7 %0d %0d %0d %0d %0d %0d %0d\n",
                rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                rx_stat_seq, rx_stat_ack, rx_stat_bytes);
        $fwrite(fd, "STATS_TX %0d %0d %0d %0d\n",
                tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_ack_drop);
        $fwrite(fd, "STATS_ECO %0d %0d\n", eco_stat_echo, eco_stat_drop_crc);
        $fwrite(fd, "CAMF %08h %08h %04h %04h %012h\n",
                u_cam.sip_r[0], u_cam.dip_r[0], u_cam.sport_r[0],
                u_cam.dport_r[0], u_cam.dmac_r[0]);
        $fwrite(fd, "TCBF %08h %08h %08h %04h %04h %0d %08h %08h %08h %04h %04h %0d\n",
                u_tcb.rcv_nxt_r[0], u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                u_tcb.rcv_wnd_r[0], u_tcb.snd_wnd_r[0], u_tcb.state_r[0],
                u_tcb.rcv_nxt_r[1], u_tcb.snd_nxt_r[1], u_tcb.snd_una_r[1],
                u_tcb.rcv_wnd_r[1], u_tcb.snd_wnd_r[1], u_tcb.state_r[1]);
        $fwrite(fd, "SLOWRX %0d %0d\n", srx_commit, srx_drop);
        $fwrite(fd, "SLOWTX %0d %0d\n", stx_frames, stx_purge);
        $fwrite(fd, "STATS_MAC %0d %0d %0d\n", mac_stat_frames, mac_stat_abort,
                tx_stat_eend);
        $fclose(fd);
        $display("DONE rx(pass=%0d nm=%0d ack=%0d) tx(fr=%0d ack=%0d) eco(echo=%0d) slow(cmt=%0d drp=%0d tx=%0d pg=%0d)",
                 rx_stat_pass, rx_stat_nonmatch, rx_stat_ack,
                 tx_stat_frames, tx_stat_ack, eco_stat_echo,
                 srx_commit, srx_drop, stx_frames, stx_purge);
        $finish;
    end

    // ---- GMII 字节捕获 + 事件捕获 ----
    always @(posedge clk) begin
        if (rst_n) begin
            $fwrite(fd, "%02h %d\n", gmii_txd, gmii_tx_en);
            if (fend)
                $fwrite(fd, "FEND %0d %0d\n", k, ferr);
            if (tx_ack_req)
                $fwrite(fd, "ACK %0d %0d %08h\n", k, tx_ack_id, tx_ack_val);
            if (syn_v)
                $fwrite(fd, "SYNP %012h %08h %04h %04h %08h %04h\n",
                        syn_smac, syn_sip, syn_sport, syn_dport, syn_seq, syn_wnd);
        end
    end

    // ---- P4b-6 缺陷 A 哨兵 (无条件, 变化即报): TX 欠载提前收帧 / MAC 断供 abort
    //      — 两者结构分析不可达, 亮灯即缺陷 A 实锤 ----
    reg [31:0] ab_prev = 0, ee_prev = 0, nm_prev = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (mac_stat_abort != ab_prev)
                $display("MACABORT k=%0d n=%0d", k, mac_stat_abort);
            if (tx_stat_eend != ee_prev)
                $display("TXEEND k=%0d n=%0d plen_r=%0d", k, tx_stat_eend,
                         u_tx.plen_r);
            if ($test$plusargs("PROBE") && rx_stat_nonmatch != nm_prev)
                $display("NM k=%0d n=%0d rxst=%0d wcnt=%0d", k,
                         rx_stat_nonmatch, u_rx.state, u_rx.wcnt);
            if ($test$plusargs("PROBE") && tcb_wr && tcb_sel == 3'd0)
                $display("RCVW k=%0d id=%0d val=%0d", k, tcb_id, tcb_val);
            if ($test$plusargs("PROBE") && tcb_wr && tcb_sel == 3'd2)
                $display("UNAW k=%0d id=%0d val=%08h", k, tcb_id, tcb_val);
            ab_prev <= mac_stat_abort;
            ee_prev <= tx_stat_eend;
            nm_prev <= rx_stat_nonmatch;
        end
    end


    // ---- TX echo 帧捕获: 帧尾锁存 echo_end_seq, echo_seen++ ----
    always @(posedge clk) begin
        if (!rst_n) begin
            tx_en_d <= 0; tx_inf <= 0; txbc <= 0;
            echo_seen <= 0; inj_ack_val <= 0;
        end else begin
            tx_en_d <= gmii_tx_en;
            if (gmii_tx_en) begin
                if (!tx_en_d) begin tx_inf <= 0; txbc <= 0; end
                else if (!tx_inf) begin
                    if (gmii_txd == 8'hD5) begin tx_inf <= 1; txbc <= 0; end
                end else if (txbc < 6'd48) begin
                    cap[txbc] <= gmii_txd;
                    txbc <= txbc + 6'd1;
                end
            end else if (tx_en_d) begin
                // 帧尾: conn0 echo 数据帧 → 其累计 ACK 待注入
                if (cap[12] == 8'h08 && cap[13] == 8'h00 && cap[23] == 8'h06 &&
                    cap[34] == 8'h1F && cap[35] == 8'h90 && cap[36] == 8'h30 &&
                    cap[37] == 8'h39 && cap[47] == 8'h18 &&
                    {cap[16], cap[17]} > 16'd40) begin
                    echo_seen   <= echo_seen + 16'd1;
                    inj_ack_val <= {cap[38], cap[39], cap[40], cap[41]} +
                                   {16'b0, cap[16], cap[17]} - 32'd40;
                end
            end
        end
    end

    // ---- slow_cfg 排障: 记录 cfg_stream 每词 + S_CAM 拍的 w 寄存器 ----
    always @(posedge clk) begin
        if (rst_n && $test$plusargs("PROBE")) begin
            if (hls_cfg_tvalid && hls_cfg_tready)
                $display("CFGWORD k=%0d d=%08h wcnt=%0d st=%0d femp=%b fdout=%08h rp=%0d wp=%0d",
                         k, hls_cfg_tdata, u_slow_cfg.wcnt, u_slow_cfg.state,
                         u_slow_cfg.f_empty, u_slow_cfg.f_dout,
                         u_slow_cfg.u_fifo.rptr, u_slow_cfg.u_fifo.wptr);
            if (u_slow_cfg.state == 3'd0 && !u_slow_cfg.f_empty)
                $display("CFGLAT k=%0d wcnt=%0d fdout=%08h rp=%0d wp=%0d",
                         k, u_slow_cfg.wcnt, u_slow_cfg.f_dout,
                         u_slow_cfg.u_fifo.rptr, u_slow_cfg.u_fifo.wptr);
            if (u_slow_cfg.state == 2'd1)   // S_CAM
                $display("CFGATCAM k=%0d w0=%08h w1=%08h w2=%08h w3=%08h w4=%08h w5=%08h w6=%08h w7=%08h",
                         k, u_slow_cfg.w0, u_slow_cfg.w1, u_slow_cfg.w2,
                         u_slow_cfg.w3, u_slow_cfg.w4, u_slow_cfg.w5,
                         u_slow_cfg.w6, u_slow_cfg.w7);
            // 排障: slow_rx_adp 输入字流 (rx_classify slow 输出) + HLS rx 字节流
            if (w_tvalid && w_tready)
                $display("SRXW k=%0d d=%016h kp=%02h l=%b u=%b", k, w_tdata,
                         w_tkeep, w_tlast, w_tuser);
            if (hls_rx_tvalid && hls_rx_tready)
                $display("HLSRX k=%0d d=%02h l=%b", k, hls_rx_tdata[7:0],
                         hls_rx_tdata[8]);
            if (hls_tx_tvalid && hls_tx_tready)
                $display("HLSTX k=%0d d=%02h l=%b", k, hls_tx_tdata[7:0],
                         hls_tx_tdata[8]);
            // 排障: fast 路径每帧 w5 判定拍 (acc 在 w5→w6 沿锁存, 探 w6 是错的)
            if (u_rx.state == 3'd0 && u_rx.accept && u_rx.wcnt == 3'd5)
                $display("RXW5 k=%0d cam=%b st=%0d seq=%08h rnxt=%08h ack=%08h suna=%08h snxt=%08h base=%b win=%b seqeq=%b flags_ok=%b doff_ok=%b len_ok=%b frag=%b tlast=%b",
                         k, u_rx.cam_hit_l, u_rx.ra_state, u_rx.seq32,
                         u_rx.ra_rcv_nxt, u_rx.ack32, u_rx.ra_snd_una,
                         u_rx.ra_snd_nxt, u_rx.base_ok, u_rx.win_ok,
                         u_rx.seq_eq, u_rx.flags_ok, u_rx.doff_ok,
                         u_rx.len_ok, u_rx.frag_ok, f_tlast);
            if (u_rx.state == 3'd1 && u_rx.accept && f_tlast)
                $display("RXPAY k=%0d pcount=%0d pay_r=%0d pop8=%0d fend_pay=%b emit_v=%b m_rdy=%b plen_l=%0d",
                         k, u_rx.pcount, u_rx.pay_r, u_rx.pop8w,
                         u_rx.fend_pay, u_rx.emit_v, m_tready, u_rx.plen_l);
            // 缺陷 A 排障: burst0 帧尾区段逐拍 (fast 路由接受/保持)
            if (k >= 85560 && k <= 85600 && (f_tvalid || u_rx.state != 3'd0))
                $display("RXW k=%0d v=%b rdy=%b d=%016h kp=%02h l=%b u=%b rxst=%0d pc=%0d cls=%0d",
                         k, f_tvalid, f_tready, f_tdata, f_tkeep, f_tlast, f_tuser,
                         u_rx.state, u_rx.pcount, u_classify.state);
        end
    end

    // ---- abort 转变沿侦测 (排障) ----
    reg ab_d = 0;
    always @(posedge clk) begin
        if (rst_n && $test$plusargs("PROBE")) begin
            ab_d <= u_slow_rx.abort;
            if (u_slow_rx.abort != ab_d)
                $display("ABCHG k=%0d ab=%b | s_acc=%b ffull=%b snap=%b ifm=%b rsd=%b | ps=%0d cmt=%0d ffw=%0d ffr=%0d",
                         k, u_slow_rx.abort, u_slow_rx.s_acc, u_slow_rx.u_ff.full,
                         u_slow_rx.ff_snap, u_slow_rx.in_frame, u_slow_rx.resync_drop,
                         u_slow_rx.pstate, u_slow_rx.committed,
                         u_slow_rx.u_ff.wptr, u_slow_rx.u_ff.rptr);
            // 细粒度窗口: abort 翻转区逐拍
            if (k >= 8530 && k <= 8560)
                $display("FINE k=%0d ab=%b acc=%b u=%b l=%b crs=%b err=%b ful=%b snap=%b fe=%b te=%b ifm=%b rsd=%b",
                         k, u_slow_rx.abort, u_slow_rx.s_acc, u_slow_rx.s_axis_tuser,
                         u_slow_rx.s_axis_tlast, u_slow_rx.s_axis_tcrs, u_slow_rx.s_axis_terr,
                         u_slow_rx.u_ff.full, u_slow_rx.ff_snap,
                         u_slow_rx.frame_end, u_slow_rx.trunc_evt,
                         u_slow_rx.in_frame, u_slow_rx.resync_drop);
        end
    end

    // ---- PROBE 模式 (+PROBE): 每 5000 拍打印慢路径内部状态 (泛洪排障) ----
    integer fd2 = 0;
    always @(posedge clk) begin
        if (rst_n && $test$plusargs("PROBE")) begin
            if (fd2 == 0) fd2 = $fopen("hls_rx_bytes.memh", "w");
            if (hls_rx_tvalid && hls_rx_tready)
                $fwrite(fd2, "%0d %03h\n", k, hls_rx_tdata[8:0]);
            if (w_tvalid && w_tready)
                $fwrite(fd2, "SRX %0d u=%b l=%b c=%b e=%b k=%02h ab=%b rs=%b if=%b ful=%b cmt=%0d\n",
                        k, w_tuser, w_tlast, w_tcrs, w_terr, w_tkeep,
                        u_slow_rx.abort, u_slow_rx.resync_drop, u_slow_rx.in_frame,
                        u_slow_rx.u_ff.full, u_slow_rx.committed);
            if (k % 32'd5000 == 0)
                $display("PROBE k=%0d | cls state=%0d | srx pstate=%0d cmt=%0d ab=%b rsd=%b ifm=%b ffw=%0d ffr=%0d occw=%0d | hls rxrdy=%b txv=%b txrdy=%b cs=%h hrn=%b txreq=%b | stx tstate=%0d cmt=%0d",
                         k, u_classify.state, u_slow_rx.pstate, u_slow_rx.committed,
                         u_slow_rx.abort, u_slow_rx.resync_drop, u_slow_rx.in_frame,
                         u_slow_rx.u_ff.wptr, u_slow_rx.u_ff.rptr,
                         (u_slow_rx.u_ofifo.wptr - u_slow_rx.u_ofifo.rptr),
                         hls_rx_tready, hls_tx_tvalid, hls_tx_tready,
                         u_hls.ap_CS_fsm,
                         hls_rst_n, u_hls.tx_req_request,
                         u_slow_tx.tstate, u_slow_tx.committed);
        end
    end
endmodule
