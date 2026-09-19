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
    // P4b-7 P4 (RTO 门): tick 版扫描下 RTO = RTO_LIM x 16 tick x 16 连接 =
    // RTO_LIM x 256 拍; 默认 48828 ≈ 12.5M 拍 ≈ 100ms 板级。sim 尾窗 60k 拍
    // -> RTOLIM_FAST 压到 125 (125x256 = 32k 拍) 落在尾窗内。仅 +RTOLIM_FAST
    // (burst 门) 压缩; chain 门 (无对端 ACK 模型) 保持默认, 压缩会让
    // conn0/conn1 在尾窗 RTO 风暴 (stat_retx>0) 破门。conn1 的 20B echo 无
    // PCACK 确认 — 压缩后其 RTO 风暴由 burst 刺激尾部的 c1ack 纯 ACK
    // (gen_stim_p4_chain.py) 追平 snd_una 平息。
`ifdef RTOLIM_FAST
    defparam u_tx.RTO_LIM = 125;
`endif

    reg        clk, rst_n;
    reg [7:0]  rx_d;
    reg        rx_dv, rx_er;
    reg [7:0]  stim_d [0:4194303];
    reg [7:0]  stim_v [0:4194303];
    reg [7:0]  stim_e [0:4194303];
    integer    nstim;
    reg [22:0] i;
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
    // P4b-7-P6 半帧中止注入 (HALFDROP): mac_rx 原始出口 -> tlast 掩码 -> classify
    wire [63:0] raw_tdata;
    wire [7:0]  raw_tkeep;
    wire        raw_tvalid, raw_tready, raw_tlast, raw_tuser, raw_tcrs, raw_terr;
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
    wire        retx_req;    // P4b-7 P3: dup-ACK 快速重传 (u_rx -> u_tx)
    wire [3:0]  retx_id;
    wire        retx_gnt;
    wire [31:0] tx_stat_retx;
    wire [31:0] cam_q_sip, cam_q_dip;
    wire [15:0] cam_q_sport, cam_q_dport;
    wire        cam_q_hit;
    wire [3:0]  cam_q_id;
    wire [31:0] rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                rx_stat_seq, rx_stat_ack, rx_stat_bytes;
    wire [31:0] rx_stat_trunc;   // P4b-7-P6: 截断帧计数 (stat_drop_trunc)
    // tcp_echo -> tcp_tx_frame
    wire [63:0] eco_tdata;
    wire [7:0]  eco_tkeep;
    wire        eco_tvalid, eco_tready, eco_tlast;
    wire [3:0]  eco_tid;

    // P4b-7-P6: echo -> tx_frame 流水寄存器总线 (拆 frame_fifo RAMB -> csum 临界路径)
    wire [63:0] eco2_tdata;
    wire [7:0]  eco2_tkeep;
    wire        eco2_tvalid, eco2_tready, eco2_tlast;
    wire [3:0]  eco2_tid;
    wire [76:0] eco2_pack;
    assign {eco2_tkeep, eco2_tlast, eco2_tdata, eco2_tid} = eco2_pack;
    wire [31:0] eco_stat_echo, eco_stat_drop_crc;
    // tcp_tx_frame
    wire [3:0]  rb_id;
    wire [31:0] rb_rcv_nxt, rb_snd_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;
    // P4b-7-P6: tcb 注册窗口读口 -> tcp_tx_frame 门控 (win_id = rb_id 同一条线)
    // P4b-7-P6-fix: win_open = 注册 32 位回绕正确门 (替代已废 win_hi_eq)
    wire        win_open;
    wire [15:0] win_inflight;
    wire [15:0] win_wnd_eff;
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
    reg [15:0] inj_wnd;   // 注入 ACK 的通告窗口 (默认 0x4000; +PCWND1K 压 0x0010
                          //  — SYN 带 WS=8, 缩放后有效窗口 4096, 强迫门控交战)
    reg [3:0]  gap_cnt;   // 已连续播放的间隙字节数 (采样 rcv_nxt 须等上一帧
                          //  fend 的 drain 落地 = fend+3 拍, 否则注入帧带旧 seq
                          //  被 tcp_rx 拒收 — TB 模型噪声, 但污染统计)
    // P4c ACK-early 复现 (+PCACKOOB): 注入 ACK 的 seq = 窗口右沿 (PC 满窗
    // 停发后的纯 ACK 语义 — seq = PC snd_nxt ≈ FPGA rcv_nxt+rcv_wnd, 零长段
    // RFC 合法)。旧 tcp_rx 对 seq 非边界纯 ACK 无 fend -> ACK 丢弃 -> snd_una
    // 停滞 -> RTO 风暴 (板级 17.6Mbps 暴跌复现); 修复后应正常推进。
    reg        pcack_oob;

    // ================= P5 PCACTIVE 主动连接反应式模型 (+PCACTIVE) =================
    // HLS 侧 ACTIVE_CONNECT=1 时复位后自发 SYN (sport 1F90 / dport 2382 /
    // flags 02, seq = ACTIVE_ISS 0x89ABCDEF) — 拍级不可预期, 静态刺激不可行。
    // 本模型在 GMII TX 捕获板侧主动连接帧并按需注入:
    //   (1) 板上 ARP who-has (ARP 未命中) -> 注入 ARP reply (spa=192.168.100.1,
    //       sha=PC_MAC) 教 MAC;
    //   (2) 板上 SYN -> 记 seq, 注入 SYN+ACK (seq=PCA_PEER_ISS, ack=SYN.seq+1,
    //       doff=6 带 MSS=1460; FCS 用 crc32b 算);
    //   (3) 板上纯 ACK (seq=SYN.seq+1, ack=PCA_PEER_ISS+1) -> 注入 100B 数据段
    //       (seq=PCA_PEER_ISS+1, ack=ACTIVE_ISS+1, 载荷 = payload(100)) ->
    //       板侧 fast path CAM/TCB (HLS cfg 记录写) echo (seq=ACTIVE_ISS+1)。
    // 判据: 全链完成后 done; resp 落 PCA/PCACAM 行供 check_active 核验。
    // 与 PCACK 互斥 (各自独立注入缓冲, 不要同开)。
    localparam [31:0] PCA_PEER_ISS = 32'h77000000;   // 对端 ISS (TB 固定值)
    localparam [31:0] PCA_MY_ISS   = 32'h89ABCDEF;   // HLS ACTIVE_ISS
    localparam [31:0] PCA_ACT_IP   = 32'hC0A86463;   // 192.168.100.99 -- MUST
    //   equal the netlist's ACTIVE_IP (hls/run_hls_active.tcl passes
    //   -DACTIVE_IP=0xC0A86463; the layer_tcp.cpp default 192.168.100.1 is
    //   pre-learned by the stimulus' ARP request, which would skip the
    //   who-has path this gate is meant to exercise).
    localparam [15:0] PCA_ACT_PORT = 16'h2382;       // 9090 = HLS ACTIVE_PORT
    localparam [15:0] PCA_MY_PORT  = 16'h1F90;       // 8080 = HLS TCP_PORT_ECHO
    reg        pca_en;
    reg        pca_arp_req, pca_arp_inj;    // who-has 捕获 / reply 已注入
    reg        pca_syn_seen, pca_synack_inj;
    reg        pca_ack_seen, pca_data_inj;
    reg        pca_echo_seen, pca_echo_ok;
    reg        pca_to;                      // 超时 (SYN 未出现, 防挂)
    reg [31:0] pca_iss;                     // 捕获的板上 SYN seq
    reg [31:0] pca_k_syn;                   // SYN 捕获拍 (报告用)
    reg        pca_play;                    // 正在播放注入帧
    reg [8:0]  pca_idx, pca_len, pca_tot;   // 播放索引 / 帧体字节 / 总拍数
    reg [7:0]  pca_buf [0:255];             // 8 前导 + 帧体 + FCS
    reg [31:0] pca_crc;
    integer    pca_i, pca_j;
    reg [31:0] pca_wait;                    // 尾窗超时计数 (拍)
    // 待注入请求 (单一来源: 捕获块置位 / 驱动块置注入位) 与主动链完成判据
    wire       pca_pend = pca_en && ((pca_arp_req && !pca_arp_inj) ||
                                     (pca_syn_seen && !pca_synack_inj) ||
                                     (pca_ack_seen && !pca_data_inj));
    wire       pca_done = pca_echo_seen || pca_to;

    // ---- P4b-7 P3: PCACK 空洞语义 (exp_seq/hole) + TXDROP 故障注入 ----
    // P4b-7-P5: exp_seq 静态建于复位 — 真实对端从握手起就知其期望 seq =
    // 我方首数据帧 seq = HLS ISS+1 (gen_stim_p4_chain.py HLS_ISS=0x12345678,
    // SYN+ACK 消费 seq 1); 原"首帧捕获建序"在首帧被 TXDROP 时把第二帧当首帧,
    // 累计 ACK 跳过空洞 -> 7B 永久头洞。TCBF 观序 (首 echo seq = 0x12345679)
    // 与此初值一致 (tcbc 数组是 conn1 的预配字段, 与 conn0 握手链无关)。
    reg [31:0] exp_seq;          // 对端已连续确认的下个字节 (期望 seq)
    reg        hole;             // 检测到空洞 (排障探针)
    reg [31:0] s_cur, p_cur;     // 帧尾解码暂存 (阻塞赋值, 同拍消费)
    integer    fdi;
    integer    txdrop_n1, txdrop_n2;   // 丢帧索引, 来自 txdrop.memh (0 = 关)
    integer    trunc_n, trunc_m;       // P4b-7-P6 截断注入 (trunc.memh, 0 = 关)
    integer    hd_n, hd_k;             // P4b-7-P6 半帧中止注入 (halfdrop.memh, 0 = 关)
    reg        hd_fired;               // 掩码已触发 (半帧残段 tlast 已抹)
    reg [31:0] tdstk_run, tdstk_max;   // tcp_tx_frame S_RECV + pay_full 连拍哨兵
    integer    eco_run, eco_max;       // echo 出口最长无 tlast 词串 (合并哨兵)
    reg [7:0]  data_cnt;         // conn0 活数据帧计数 (0 基, 丢帧编号用)
    reg        tx_en_dr;         // 原始 gmii_tx_en 打拍 (帧尾下降沿检测)
    reg [7:0]  fcb [0:2047];     // 帧字节缓冲 (整帧收齐, 帧尾判据决定写/丢)
    reg [11:0] fcl;              // 缓冲内字节数 (饱和 4095, 真帧 <= 1538)
    integer    fbi;              // 落盘循环变量
    // P4c TXDROP 帧头匹配: 帧尾 (tx_en_dr && !gmii_tx_en) 拍为判据建立拍。
    // suppress=0 下板上每段先发纯 ACK 再发 echo, 旧"arm 后首个 S_PRE"遮的是
    // ACK 帧 (数据帧全在 + 残片) -> 必须按帧头 (conn0 echo 数据帧) 匹配。
    // cur_is_d0 = 帧头字段判 conn0 echo 数据帧; cur_live = 新数据 (s>=exp,
    // ring 重放/全重包不计编号, 与原 start_data 语义一致); cur_drop = 命中。
    // 建立拍上 cap[0..47] = 本帧 body[0..47] (PC 模型前 48 拍收齐) 稳定可读。
    wire       tx_frame_end = tx_en_dr && !gmii_tx_en;
    wire [31:0] fs_cur = {cap[38], cap[39], cap[40], cap[41]};
    wire       cur_is_d0 = (txbc >= 6'd48) && cap[12] == 8'h08 && cap[13] == 8'h00 &&
                           cap[23] == 8'h06 && cap[34] == 8'h1F && cap[35] == 8'h90 &&
                           cap[36] == 8'h30 && cap[37] == 8'h39 && cap[47] == 8'h18 &&
                           {cap[16], cap[17]} > 16'd40;
    wire       cur_live = cur_is_d0 && ((fs_cur > exp_seq) ||
                                        (fs_cur == exp_seq && !hole));
    wire [7:0] d0_ord_w = data_cnt + 8'd1;
    wire       cur_drop = tx_frame_end && cur_live &&
                          ((txdrop_n1 > 0 && d0_ord_w == txdrop_n1) ||
                           (txdrop_n2 > 0 && d0_ord_w == txdrop_n2));

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

    // ---- P5 PCACTIVE 注入帧组帧 (kind: 0=ARP reply, 1=SYN+ACK, 2=data) ----
    // SIM active-connect target IP = 192.168.100.99 (PCA_ACT_IP): an address the
    // static stimulus never advertises, which forces the HLS ARP who-has query
    // path (the default macro ACTIVE_IP=192.168.100.1 would be pre-learned from
    // the stimulus' first ARP request, leaving the query branch unexercised).
    // The sim netlist must be built with the same value
    // (-DACTIVE_IP=0xC0A86463, see hls/run_hls_active.tcl) -- the SYN capture
    // checks dst IP == PCA_ACT_IP, so a mismatch fails loudly.
    function [7:0] pca_dbyte;      // data payload byte i = (i*7+3)&0xFF
        input [7:0] i;             // (same generator as gen_stim payload(n))
        pca_dbyte = (i * 8'd7 + 8'd3);
    endfunction

    function [15:0] pca_ipcs;      // IP header csum (192.168.100.99 -> .2)
        input [15:0] tot;          // IP total_len
        reg [31:0] s;
        begin
            s = 32'h4500 + {16'b0, tot} + 32'h7777 + 32'h0000 + 32'h4006 +
                32'hC0A8 + 32'h6463 + 32'hC0A8 + 32'h6402;
            s = (s & 32'hFFFF) + (s >> 16);
            s = (s & 32'hFFFF) + (s >> 16);
            pca_ipcs = ~s[15:0];
        end
    endfunction

    function [7:0] pca_byte;
        input [1:0]  kind;
        input [8:0]  idx;
        input [15:0] ipcs;
        input [15:0] tot;
        input [31:0] ackf;
        input [31:0] seqf;
        reg [8:0] b;
        begin
            b = idx;
            pca_byte = 8'h00;
            case (b)      // ethernet header (all kinds): dst=DUT_MAC, src=PC_MAC
                9'd0:  pca_byte = 8'h00;  9'd1:  pca_byte = 8'h0A;
                9'd2:  pca_byte = 8'h35;  9'd3:  pca_byte = 8'h01;
                9'd4:  pca_byte = 8'hFE;  9'd5:  pca_byte = 8'hC0;
                9'd6:  pca_byte = 8'h11;  9'd7:  pca_byte = 8'h22;
                9'd8:  pca_byte = 8'h33;  9'd9:  pca_byte = 8'h44;
                9'd10: pca_byte = 8'h55;  9'd11: pca_byte = 8'h66;
                default: ;
            endcase
            if (b >= 9'd12) begin
            if (kind == 2'd0) begin            // ARP reply: spa = PCA_ACT_IP
                case (b)
                    9'd12: pca_byte = 8'h08; 9'd13: pca_byte = 8'h06;
                    9'd14: pca_byte = 8'h00; 9'd15: pca_byte = 8'h01;
                    9'd16: pca_byte = 8'h08; 9'd17: pca_byte = 8'h00;
                    9'd18: pca_byte = 8'h06; 9'd19: pca_byte = 8'h04;
                    9'd20: pca_byte = 8'h00; 9'd21: pca_byte = 8'h02;
                    9'd22: pca_byte = 8'h11; 9'd23: pca_byte = 8'h22;
                    9'd24: pca_byte = 8'h33; 9'd25: pca_byte = 8'h44;
                    9'd26: pca_byte = 8'h55; 9'd27: pca_byte = 8'h66;
                    9'd28: pca_byte = PCA_ACT_IP[31:24];
                    9'd29: pca_byte = PCA_ACT_IP[23:16];
                    9'd30: pca_byte = PCA_ACT_IP[15:8];
                    9'd31: pca_byte = PCA_ACT_IP[7:0];
                    9'd32: pca_byte = 8'h00; 9'd33: pca_byte = 8'h0A;
                    9'd34: pca_byte = 8'h35; 9'd35: pca_byte = 8'h01;
                    9'd36: pca_byte = 8'hFE; 9'd37: pca_byte = 8'hC0;
                    9'd38: pca_byte = 8'hC0; 9'd39: pca_byte = 8'hA8;
                    9'd40: pca_byte = 8'h64; 9'd41: pca_byte = 8'h02;
                    default: pca_byte = 8'h00;     // 42..59 pad
                endcase
            end else begin
                case (b)       // IP header (kinds 1/2) + first 20B of TCP header
                    9'd12: pca_byte = 8'h08; 9'd13: pca_byte = 8'h00;
                    9'd14: pca_byte = 8'h45; 9'd15: pca_byte = 8'h00;
                    9'd16: pca_byte = tot[15:8]; 9'd17: pca_byte = tot[7:0];
                    9'd18: pca_byte = 8'h77; 9'd19: pca_byte = 8'h77;
                    9'd20: pca_byte = 8'h00; 9'd21: pca_byte = 8'h00;
                    9'd22: pca_byte = 8'h40; 9'd23: pca_byte = 8'h06;
                    9'd24: pca_byte = ipcs[15:8]; 9'd25: pca_byte = ipcs[7:0];
                    9'd26: pca_byte = 8'hC0; 9'd27: pca_byte = 8'hA8;
                    9'd28: pca_byte = 8'h64; 9'd29: pca_byte = 8'h63;
                    9'd30: pca_byte = 8'hC0; 9'd31: pca_byte = 8'hA8;
                    9'd32: pca_byte = 8'h64; 9'd33: pca_byte = 8'h02;
                    9'd34: pca_byte = 8'h23; 9'd35: pca_byte = 8'h82;  // sport 9090
                    9'd36: pca_byte = 8'h1F; 9'd37: pca_byte = 8'h90;  // dport 8080
                    9'd38: pca_byte = (kind == 2'd1) ? PCA_PEER_ISS[31:24] : seqf[31:24];
                    9'd39: pca_byte = (kind == 2'd1) ? PCA_PEER_ISS[23:16] : seqf[23:16];
                    9'd40: pca_byte = (kind == 2'd1) ? PCA_PEER_ISS[15:8]  : seqf[15:8];
                    9'd41: pca_byte = (kind == 2'd1) ? PCA_PEER_ISS[7:0]   : seqf[7:0];
                    9'd42: pca_byte = ackf[31:24]; 9'd43: pca_byte = ackf[23:16];
                    9'd44: pca_byte = ackf[15:8];  9'd45: pca_byte = ackf[7:0];
                    9'd46: pca_byte = (kind == 2'd1) ? 8'h60 : 8'h50;  // doff
                    9'd47: pca_byte = (kind == 2'd1) ? 8'h12 : 8'h18;  // SYN|ACK / PSH|ACK
                    9'd48: pca_byte = 8'h40; 9'd49: pca_byte = 8'h00;  // wnd 0x4000
                    9'd50: pca_byte = 8'h00; 9'd51: pca_byte = 8'h00;  // tcp csum (0)
                    9'd52: pca_byte = 8'h00; 9'd53: pca_byte = 8'h00;  // urg
                    9'd54: pca_byte = (kind == 2'd1) ? 8'h02 : pca_dbyte(b[7:0] - 8'd54);
                    9'd55: pca_byte = (kind == 2'd1) ? 8'h04 : pca_dbyte(b[7:0] - 8'd54);
                    9'd56: pca_byte = (kind == 2'd1) ? 8'h05 : pca_dbyte(b[7:0] - 8'd54);
                    9'd57: pca_byte = (kind == 2'd1) ? 8'hB4 : pca_dbyte(b[7:0] - 8'd54);
                    default: pca_byte = (kind == 2'd1) ? 8'h00 : pca_dbyte(b[7:0] - 8'd54);
                endcase
            end
            end
        end
    endfunction

    task pca_fill;   // append FCS over the frame body (on-wire LSB-first)
        begin
            pca_crc = 32'hFFFFFFFF;
            for (pca_i = 0; pca_i < pca_len; pca_i = pca_i + 1)
                pca_crc = crc32b(pca_crc, pca_buf[8 + pca_i]);
            pca_crc = ~pca_crc;
            pca_buf[8 + pca_len]     = pca_crc[7:0];
            pca_buf[8 + pca_len + 1] = pca_crc[15:8];
            pca_buf[8 + pca_len + 2] = pca_crc[23:16];
            pca_buf[8 + pca_len + 3] = pca_crc[31:24];
        end
    endtask

    task pca_arm;    // build one frame into pca_buf and start playing it
        input [1:0]  kind;
        input [7:0]  dlen;    // data payload bytes (kind 2)
        input [15:0] tot;     // IP total_len (kinds 1/2)
        input [31:0] ackf;
        input [31:0] seqf;
        begin
            for (pca_i = 0; pca_i < 8; pca_i = pca_i + 1)
                pca_buf[pca_i] = (pca_i == 7) ? 8'hD5 : 8'h55;
            pca_len = (kind == 2'd2) ? (9'd54 + dlen) : 9'd60;
            for (pca_i = 0; pca_i < pca_len; pca_i = pca_i + 1)
                pca_buf[8 + pca_i] = pca_byte(kind, pca_i[8:0], pca_ipcs(tot),
                                              tot, ackf, seqf);
            pca_fill;
            // 12 IFG + (8 前导 + pca_len 帧体 + 4 FCS) + 12 IFG
            pca_tot  = pca_len + 9'd36;
            pca_idx  = 9'd0;
            pca_play = 1'b1;
        end
    endtask

    task pca_do_inject;   // serve the oldest pending request, one frame per call
        begin
            if (pca_arp_req && !pca_arp_inj) begin
                pca_arm(2'd0, 8'd0, 16'd0, 32'h0, 32'h0);
                pca_arp_inj = 1'b1;
            end else if (pca_syn_seen && !pca_synack_inj) begin
                pca_arm(2'd1, 8'd0, 16'd44, pca_iss + 32'd1, 32'h0);
                pca_synack_inj = 1'b1;
            end else if (pca_ack_seen && !pca_data_inj) begin
                pca_arm(2'd2, 8'd100, 16'd140, pca_iss + 32'd1,
                        PCA_PEER_ISS + 32'd1);
                pca_data_inj = 1'b1;
            end
        end
    endtask

    mac_rx_64 u_mac (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(raw_tdata), .m_axis_tkeep(raw_tkeep),
        .m_axis_tvalid(raw_tvalid),
        .m_axis_tready(raw_tready), .m_axis_tlast(raw_tlast),
        .m_axis_tuser(raw_tuser),
        .m_axis_terr(raw_terr), .m_axis_tcrs(raw_tcrs),
        .stat_frames(), .stat_crc_err(), .stat_drop(), .stat_bytes()
    );

    // ---- P4b-7-P6 HALFDROP: mac_rx 出口 tlast 掩码 (半帧中止仿真) ----
    // 板级中止 = 半帧词不入流: 消费者只看到"SOP 无 TLAST"的残段 (rx_classify
    // 与 tcp_rx 的 SOP 截断防御据此丢弃残段并接着解析下一帧)。链 TB 的 mac_rx_64
    // 对线上中止 (帧内 dv 掉) 走 S_DATA 帧尾支: 残段仍交付一拍 push_last=1 /
    // push_crs=0 — 与板级行为不同, 故在此抹掉该拍的 tlast 以对齐板级。
    // 触发 = 唯一 tcrs=0 的 tlast 拍 (注入半帧是激励里唯一坏 FCS 帧),
    // 一次触发后置 done; hd_n==0 (无注入) 时恒不触发。
    wire raw_badtail = raw_tvalid && raw_tlast && !raw_tcrs &&
                       (hd_n > 0) && !hd_fired;
    assign s_tdata    = raw_tdata;
    assign s_tkeep    = raw_tkeep;
    assign s_tvalid   = raw_tvalid;
    assign s_tlast    = raw_tlast && !raw_badtail;
    assign s_tuser    = raw_tuser;
    assign s_tcrs     = raw_tcrs;
    assign s_terr     = raw_terr;
    assign raw_tready = s_tready;

    always @(posedge clk) begin
        if (!rst_n) hd_fired <= 1'b0;
        else if (raw_badtail) hd_fired <= 1'b1;
    end

    // ---- P4e: VLAN 剥离 shim (与 board/wrapper_p4.v 同位置: mac_rx_64 出口 ->
    //      rx_classify 之前; HALFDROP 掩码是 mac 级仿真注入, 保持在本模块之前) ----
    wire [63:0] vs_tdata;
    wire [7:0]  vs_tkeep;
    wire        vs_tvalid, vs_tready, vs_tlast, vs_tuser, vs_tcrs, vs_terr;
    wire [31:0] vlan_stat_stripped;

    vlan_strip u_vlan (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .m_axis_tdata(vs_tdata), .m_axis_tkeep(vs_tkeep), .m_axis_tvalid(vs_tvalid),
        .m_axis_tready(vs_tready), .m_axis_tlast(vs_tlast), .m_axis_tuser(vs_tuser),
        .m_axis_tcrs(vs_tcrs), .m_axis_terr(vs_terr),
        .stat_stripped(vlan_stat_stripped), .dbg_vlan()
    );

    rx_classify u_classify (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(vs_tdata), .s_axis_tkeep(vs_tkeep), .s_axis_tvalid(vs_tvalid),
        .s_axis_tready(vs_tready), .s_axis_tlast(vs_tlast), .s_axis_tuser(vs_tuser),
        .s_axis_tcrs(vs_tcrs), .s_axis_terr(vs_terr),
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
        .cfg_suppress_data_ack(1'b0),   // P4c: 与板上 wrapper_p4 一致 (数据 ACK 提前)
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
        .retx_req(retx_req), .retx_id(retx_id), .retx_gnt(retx_gnt),
        .syn_v(syn_v), .syn_smac(syn_smac), .syn_sip(syn_sip),
        .syn_sport(syn_sport), .syn_dport(syn_dport),
        .syn_seq(syn_seq), .syn_wnd(syn_wnd),
        .cam_q_sip(cam_q_sip), .cam_q_dip(cam_q_dip),
        .cam_q_sport(cam_q_sport), .cam_q_dport(cam_q_dport),
        .cam_q_hit(cam_q_hit), .cam_q_id(cam_q_id),
        .stat_pass(rx_stat_pass), .stat_drop_nonmatch(rx_stat_nonmatch),
        .stat_drop_ipcsum(rx_stat_ipcsum), .stat_drop_crc(rx_stat_crc),
        .stat_drop_seq(rx_stat_seq), .stat_ack(rx_stat_ack), .stat_bytes(rx_stat_bytes),
        .stat_drop_trunc(rx_stat_trunc)
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

    // ---- P4b-7-P6: echo -> tx_frame 1-deep 全速流水寄存器 (拆临界路径) ----
    axis_pipe #(.W(77)) u_eco_pipe (
        .clk(clk), .rst_n(rst_n),
        .s_data({eco_tkeep, eco_tlast, eco_tdata, eco_tid}),
        .s_valid(eco_tvalid), .s_ready(eco_tready),
        .m_data(eco2_pack), .m_valid(eco2_tvalid), .m_ready(eco2_tready)
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
        .win_id(rb_id), .win_open(win_open),
        .win_inflight(win_inflight), .win_wnd_eff(win_wnd_eff),
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
        .s_axis_tdata(eco2_tdata), .s_axis_tkeep(eco2_tkeep),
        .s_axis_tvalid(eco2_tvalid), .s_axis_tready(eco2_tready), .s_axis_tlast(eco2_tlast),
        .s_axis_tid(eco2_tid),
        .ack_req(tx_ack_req), .ack_id(tx_ack_id), .ack_val(tx_ack_val),
        .ack_syn(tx_ack_syn),
        .rb_id(rb_id), .rb_snd_nxt(rb_snd_nxt), .rb_rcv_nxt(rb_rcv_nxt),
        .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_una(rb_snd_una), .rb_snd_wnd(rb_snd_wnd),
        .win_open(win_open), .win_inflight(win_inflight), .win_wnd_eff(win_wnd_eff),
        .upd_wr(tx_upd_wr), .upd_id(tx_upd_id), .upd_sel(tx_upd_sel), .upd_val(tx_upd_val),
        .cam_rd_id(cam_rd_id), .cam_rd_dmac(cam_rd_dmac), .cam_rd_sip(cam_rd_sip),
        .cam_rd_sport(cam_rd_sport), .cam_rd_dport(cam_rd_dport),
        .cfg_src_mac(48'h000A3501FEC0), .cfg_src_ip(32'hC0A86402),
        .m_axis_tdata(x_tdata), .m_axis_tkeep(x_tkeep),
        .m_axis_tvalid(x_tvalid), .m_axis_tready(x_tready), .m_axis_tlast(x_tlast),
        .stat_frames(tx_stat_frames), .stat_bytes(tx_stat_bytes),
        .stat_ack(tx_stat_ack), .stat_ack_drop(tx_stat_ack_drop),
        .stat_eend(tx_stat_eend),
        .retx_req(retx_req), .retx_id(retx_id), .retx_gnt(retx_gnt),
        .stat_retx(tx_stat_retx)
    );

    // ---- P4b-7-P6 门控对账探针 (sim-only, 零 RTL 改动): 逐拍比较 u_tx 门控消费
    //      的注册 win_* (tcb 1 拍注册, 键 = 上拍 rb_id) 与 rb_* 组合读口按本拍
    //      rb_id 的 fresh 计算。差 1 拍 → 写后/连接切换后 1 拍失配属构造瞬态;
    //      长串失配 = 门控系统性问题 (板上冻结特征 = 错关长串且真在飞 < 帽)。
    //      P4b-7-P6-fix: fresh 公式改 32 位回绕正确 (f_diff = 全 32 位差 < 帽),
    //      与修复后的注册门同式对照; f_16hi 保留 = 旧 16 位公式的对照 (straddle
    //      探针): 在飞区间跨任意 64K 边界时 f_16hi=0 — 旧门此时误关, 新 32 位
    //      fresh 门必须仍开且注册门 (wnd_open) 必须保持开 (str_mm 必须 ~0)。
    //      全经 $display (写 resp 会炸 burstcheck 的 parse_gmii int(p[0],16))。
    wire [31:0] f_diff = rb_snd_nxt - rb_snd_una;  // 32 位回绕正确在飞差
    // P4c: 帽直接引用 DUT 参数 (u_tx.RING_CAP = 0xBFFE), 不再镜像字面量
    wire [15:0] f_wnd  = (rb_snd_wnd < u_tx.RING_CAP) ? rb_snd_wnd : u_tx.RING_CAP;
    wire        f_open = (f_diff < {16'b0, f_wnd});
    wire        f_16hi = (rb_snd_nxt[31:16] == rb_snd_una[31:16]);  // 旧 16 位门对照
    wire        mm_est = (rb_snd_wnd != 16'd0);    // 连接已建立 (窗非 0)
    wire        mm_dis = mm_est && (u_tx.wnd_open != f_open);   // 门/注册失配
    wire        mm_wro = mm_est &&  u_tx.wnd_open && !f_open;   // 误开
    wire        mm_wrc = mm_est && !u_tx.wnd_open && f_open;    // 误关
    wire        mm_ez  = mm_est && (win_wnd_eff == 16'd0);      // 注册窗损坏 0
    wire        mm_bs  = mm_wrc && eco2_tvalid && (u_tx.state == 3'd0) &&
                         !u_tx.ack_pend_r && !u_tx.pay_full &&
                         !u_tx.svc && !u_tx.ring_eval && !u_tx.scan_now;
                                                     // 误关挡了本可启动的活帧
    // ---- straddle 探针 (P4b-7-P6-fix 定向验证): 跨 64K 边界 (高 16 位不等)
    //      + fresh 32 位门开 = 旧 16 位公式必误关的周期; str_cnt 应 > 0 (burst
    //      seq 0x12345679 起 292KB 每次跨界都扫过), str_mm 应 ~0 (注册门跨边界
    //      期必须保持开 — 旧门正是这里关死导致板上冻结) ----
    wire        strad  = mm_est && !f_16hi && f_open;
    wire        str_mm = strad && !u_tx.wnd_open;  // 跨界期注册门误关
    reg  [31:0] mm_cnt, mm_wro_c, mm_wrc_c, mm_bs_c, mm_ez_c, mm_id0_c;
    reg  [31:0] mm_run, mm_run_op, mm_run_cl;
    reg  [31:0] mm_runmax, mm_oprunmax, mm_clrunmax;
    reg  [31:0] mm_prc, mm_bprc;
    reg  [31:0] str_cnt, str_mm_c;
    always @(posedge clk) begin
        if (!rst_n) begin
            mm_cnt <= 0; mm_wro_c <= 0; mm_wrc_c <= 0; mm_bs_c <= 0;
            mm_ez_c <= 0; mm_id0_c <= 0;
            mm_run <= 0; mm_run_op <= 0; mm_run_cl <= 0;
            mm_runmax <= 0; mm_oprunmax <= 0; mm_clrunmax <= 0;
            mm_prc <= 0; mm_bprc <= 0;
            str_cnt <= 0; str_mm_c <= 0;
        end else begin
            if (mm_ez) mm_ez_c <= mm_ez_c + 32'd1;
            if (strad) str_cnt <= str_cnt + 32'd1;
            if (str_mm) str_mm_c <= str_mm_c + 32'd1;
            if (mm_dis) begin
                mm_cnt <= mm_cnt + 32'd1;
                mm_run <= mm_run + 32'd1;
                if (mm_run + 32'd1 > mm_runmax) mm_runmax <= mm_run + 32'd1;
                if (rb_id == 4'd0) mm_id0_c <= mm_id0_c + 32'd1;
                if (u_tx.wnd_open) begin              // 误开
                    mm_wro_c <= mm_wro_c + 32'd1;
                    mm_run_op <= mm_run_op + 32'd1;
                    mm_run_cl <= 32'd0;
                    if (mm_run_op + 32'd1 > mm_oprunmax)
                        mm_oprunmax <= mm_run_op + 32'd1;
                end else begin                        // 误关
                    mm_wrc_c <= mm_wrc_c + 32'd1;
                    mm_run_cl <= mm_run_cl + 32'd1;
                    mm_run_op <= 32'd0;
                    if (mm_run_cl + 32'd1 > mm_clrunmax)
                        mm_clrunmax <= mm_run_cl + 32'd1;
                    if (mm_bs) begin
                        mm_bs_c <= mm_bs_c + 32'd1;
                        if (mm_bprc < 32'd8) begin
                            $display("MMB t=%0d rb_id=%d win=(%b %d %d) fresh=(%d %d) hi16=%b",
                                     k, rb_id, win_open, win_inflight,
                                     win_wnd_eff, f_diff[15:0], f_wnd, f_16hi);
                            mm_bprc <= mm_bprc + 32'd1;
                        end
                    end
                end
                if (mm_prc < 32'd8) begin
                    $display("MM t=%0d rb_id=%d win=(%b %d %d) fresh=(%d %d) hi16=%b",
                             k, rb_id, win_open, win_inflight, win_wnd_eff,
                             f_diff[15:0], f_wnd, f_16hi);
                    mm_prc <= mm_prc + 32'd1;
                end
            end else begin
                mm_run <= 0; mm_run_op <= 0; mm_run_cl <= 0;
            end
        end
    end

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
            pca_play <= 0; pca_idx <= 0; pca_len <= 0; pca_tot <= 0;
            pca_arp_inj <= 0; pca_synack_inj <= 0; pca_data_inj <= 0;
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
                    // P4b-7-P6: 尾 12 拍同样必须 IFG — 注入帧紧贴下一刺激帧
                    // (零空闲, 12B 帧隙被注入吃光时) 会反向融合, MAC 整帧
                    // CRC 失败双丢 (drop50 实锤: 注入 ACK 吞掉 burst 第 148
                    // 段 → rcv_nxt 冻结 → 尾部全拒收)。12+72+12 = 96 拍。
                    if (inj_idx < 7'd12) begin
                        rx_d  <= 8'h07;
                        rx_dv <= 1'b0;
                    end else if (inj_idx < 7'd84) begin
                        rx_d  <= inj_buf[inj_idx - 7'd12];
                        rx_dv <= 1'b1;
                    end else begin
                        rx_d  <= 8'h07;
                        rx_dv <= 1'b0;
                    end
                    rx_er <= 1'b0;
                    if (inj_idx == 7'd95) inj_play <= 1'b0;
                    inj_idx <= inj_idx + 7'd1;
                end else if (pca_play) begin
                    // P5: 注入帧播放 (12 拍 IFG + 帧体/FCS + 12 拍 IFG, i 冻结)。
                    // 与 PCACK 注入同构: 前后各 12 拍 IFG 防帧融合 (前向融进
                    // 上一刺激帧 / 反向融进下一刺激帧都整帧双丢)。
                    if (pca_idx < 9'd12) begin
                        rx_d  <= 8'h07;
                        rx_dv <= 1'b0;
                    end else if (pca_idx < (pca_len + 9'd24)) begin
                        // 12 IFG + 8 前导 + pca_len 帧体 + 4 FCS
                        rx_d  <= pca_buf[pca_idx - 9'd12];
                        rx_dv <= 1'b1;
                    end else begin
                        rx_d  <= 8'h07;
                        rx_dv <= 1'b0;
                    end
                    rx_er <= 1'b0;
                    if (pca_idx == (pca_tot - 9'd1)) pca_play <= 1'b0;
                    pca_idx <= pca_idx + 9'd1;
                end else if (i < nstim) begin
                    if (pcack_en && inj_pend && !stim_v[i][0] &&
                        gap_cnt >= 4'd11) begin
                        // 帧间隙: 构建纯 ACK (此刻静态流在间隙, rcv_nxt 冻结)。
                        // 本拍仍播该间隙字节, 下拍起 12 拍 IFG 再进前导。
                        // P4c PCACKOOB: seq = 窗口右沿 (板级满窗纯 ACK 语义)
                        seq_b  = pcack_oob ?
                                 (u_tcb.rcv_nxt_r[0] + {16'b0, u_tcb.rcv_wnd_r[0]}) :
                                 u_tcb.rcv_nxt_r[0];
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
                    end else if (pca_en && pca_pend && !stim_v[i][0] &&
                                 gap_cnt >= 4'd11) begin
                        // P5: 帧间隙注入主动连接应答帧 (ARP reply / SYN+ACK /
                        // 数据段)。本拍仍播间隙字节并消耗, 下拍起 12 拍 IFG。
                        pca_do_inject;
                        rx_d  <= stim_d[i];
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
                    // P4c PCACKOOB: seq = 窗口右沿 (板级满窗纯 ACK 语义)
                    seq_b  = pcack_oob ?
                             (u_tcb.rcv_nxt_r[0] + {16'b0, u_tcb.rcv_wnd_r[0]}) :
                             u_tcb.rcv_nxt_r[0];
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
                end else if (pca_en && pca_pend && gap_cnt >= 4'd11) begin
                    // P5: 静态流已尽, 尾窗注入 (线上已空闲 → gap_cnt 满)
                    pca_do_inject;
                    rx_dv <= 1'b0;
                    rx_er <= 1'b0;
                    if (gap_cnt != 4'hF) gap_cnt <= gap_cnt + 4'd1;
                end else begin
                    rx_dv <= 0; rx_er <= 0;
                    if (gap_cnt != 4'hF) gap_cnt <= gap_cnt + 4'd1;
                end
                // P5: 主动链未完成 (或注入帧在播) 时不收尾 — done 后 initial 块
                // 才写 resp (PCA/PCACAM 行), 必须等回显落地
                if (i >= nstim && !inj_pend && !inj_play && !pca_play &&
                    !(pca_en && !pca_done)) done <= 1;
            end
        end
    end

    initial begin
        clk = 0; rst_n = 0;
        pcack_en = $test$plusargs("PCACK");
        pcack_oob = $test$plusargs("PCACKOOB");
        pca_en = $test$plusargs("PCACTIVE");
        inj_wnd = $test$plusargs("PCWND1K") ? 16'h0010 : 16'h4000;
        txdrop_n1 = 0; txdrop_n2 = 0;
        // TXDROP 索引经 txdrop.memh 传入 (run_tb_p4_burst.bat 由 %7/%8 生成):
        // xsim.bat 经 loader 会把含 '=' 的 plusarg 拆碎 ("Expected a switch
        // but found 5"), -testplusarg TXDROP=N 到不了 TB — 文件通道绕开
        fdi = $fopen("txdrop.memh", "r");
        if (fdi != 0) begin
            $fscanf(fdi, "%d", txdrop_n1);
            $fscanf(fdi, "%d", txdrop_n2);
            $fclose(fdi);
        end
        // P4b-7-P6 TRUNC 同通道 (trunc.memh: "N M" = 第 N 个 conn0 数据段裁到
        // M 字节; 0 = 关)。同 txdrop: xsim loader 拆含 '=' 的 plusarg, 到不了 TB
        trunc_n = 0; trunc_m = 8;
        fdi = $fopen("trunc.memh", "r");
        if (fdi != 0) begin
            $fscanf(fdi, "%d", trunc_n);
            $fscanf(fdi, "%d", trunc_m);
            $fclose(fdi);
        end
        // P4b-7-P6 HALFDROP: 半帧中止注入 (halfdrop.memh "N K": 第 N 个 conn0
        // 数据段线上只发头 54B + K 字节载荷后停线; 0 = 关)。K 语义见
        // tools/gen_stim_p4_chain.py build_rx_frames (需 K>=6 且 (50+K)%8==0)
        hd_n = 0; hd_k = 0;
        fdi = $fopen("halfdrop.memh", "r");
        if (fdi != 0) begin
            $fscanf(fdi, "%d", hd_n);
            $fscanf(fdi, "%d", hd_k);
            $fclose(fdi);
        end
        $readmemh("stim_data.memh", stim_d);
        $readmemh("stim_dv.memh",   stim_v);
        $readmemh("stim_er.memh",   stim_e);
        $readmemh("cfg_tcb.memh",   tcbc);
        nstim = 0;
        while (nstim < 4194304 && stim_d[nstim] !== 8'hxx) nstim = nstim + 1;
        fd = $fopen("resp_p4_chain.memh", "w");
        #200; rst_n = 1;
        wait (done == 1);
        repeat (60000) @(posedge clk);   // HLS 应答余量 (拍级不可预期)
        $fwrite(fd, "STATS7 %0d %0d %0d %0d %0d %0d %0d\n",
                rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                rx_stat_seq, rx_stat_ack, rx_stat_bytes);
        $fwrite(fd, "STATS_TX %0d %0d %0d %0d\n",
                tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_ack_drop);
        $fwrite(fd, "RETX %0d\n", tx_stat_retx);
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
        // P5 PCACTIVE: 主动链事件 (arp_req/arp_inj/syn/synack/ack/data/echo/ok/
        // iss/k_syn/to) + 每槽 CAM 4 元组与 TCB 终态 (槽位由 HLS 选 — 主动连接
        // 与被动 conn0 共存, 判据按槽定位)
        if (pca_en) begin
            $fwrite(fd, "PCA %0d %0d %0d %0d %0d %0d %0d %0d %0d %08h %0d\n",
                    pca_arp_req, pca_arp_inj, pca_syn_seen, pca_synack_inj,
                    pca_ack_seen, pca_data_inj, pca_echo_seen, pca_echo_ok,
                    pca_to, pca_iss, pca_k_syn);
            for (pca_j = 0; pca_j < 3; pca_j = pca_j + 1)
                $fwrite(fd, "PCACAM %0d %08h %08h %04h %04h %012h %0d %08h %08h\n",
                        pca_j, u_cam.sip_r[pca_j], u_cam.dip_r[pca_j],
                        u_cam.sport_r[pca_j], u_cam.dport_r[pca_j],
                        u_cam.dmac_r[pca_j], u_tcb.state_r[pca_j],
                        u_tcb.rcv_nxt_r[pca_j], u_tcb.snd_nxt_r[pca_j]);
        end
        $fwrite(fd, "STATS_MAC %0d %0d %0d\n", mac_stat_frames, mac_stat_abort,
                tx_stat_eend);
        // P4b-7-P6: 截断注入参数 + 截断支计数 + echo 出口最长词串
        $fwrite(fd, "TRUNCS %0d %0d\n", trunc_n, rx_stat_trunc);
        $fwrite(fd, "ECOMAX %0d\n", eco_max);
        // P4b-7-P6: 半帧中止注入参数 + 掩码触发 + TX 卡 S_RECV 连拍
        $fwrite(fd, "HALFD %0d %0d %0d %0d\n", hd_n, hd_k, hd_fired, tdstk_max);
        // P4e: VLAN 剥离计数 (u_vlan.stat_stripped) — 仅 VLAN 注入模式 (vlan.memh)
        // 下应 > 0; 默认模式必须为 0 (fast path 不带 tag 发/收)。
        $fwrite(fd, "STRIPPED %0d\n", vlan_stat_stripped);
        $fclose(fd);
        if (trunc_n > 0 && rx_stat_trunc == 0)
            $display("TRUNC_MISS n=%0d stat_drop_trunc=0 (截断支未走过)", trunc_n);
        if (hd_n > 0)
            $display("HALFDROP n=%0d k=%0d fired=%0d ECOMAX=%0d TXSTUCK=%0d (冻结哨兵 >1000 拍)",
                     hd_n, hd_k, hd_fired, eco_max, tdstk_max);
        if (pca_en)
            $display("PCACTIVE arp_req=%0d arp_inj=%0d syn=%0d synack=%0d ack=%0d data=%0d echo=%0d ok=%0d iss=%08h k_syn=%0d to=%0d",
                     pca_arp_req, pca_arp_inj, pca_syn_seen, pca_synack_inj,
                     pca_ack_seen, pca_data_inj, pca_echo_seen, pca_echo_ok,
                     pca_iss, pca_k_syn, pca_to);
        $display("DONE rx(pass=%0d nm=%0d ack=%0d) tx(fr=%0d ack=%0d) eco(echo=%0d) slow(cmt=%0d drp=%0d tx=%0d pg=%0d)",
                 rx_stat_pass, rx_stat_nonmatch, rx_stat_ack,
                 tx_stat_frames, tx_stat_ack, eco_stat_echo,
                 srx_commit, srx_drop, stx_frames, stx_purge);
        $display("GATEPROBE mm=%0d wro=%0d wrc=%0d id0=%0d blk=%0d eff0=%0d runmax=%0d oprun=%0d clrun=%0d strad=%0d strmm=%0d",
                 mm_cnt, mm_wro_c, mm_wrc_c, mm_id0_c, mm_bs_c, mm_ez_c,
                 mm_runmax, mm_oprunmax, mm_clrunmax, str_cnt, str_mm_c);
        $finish;
    end

    // ---- P4b-7-P6: tcp_rx w6 判定拍全信号转储 (触发定位, 每数据帧 1 行) ----
    reg rxdbg_prev = 0;
    always @(posedge clk) begin
        if (!rst_n) rxdbg_prev <= 0;
        else if (u_rx.state == 3'd0 && u_rx.wcnt == 3'd6 &&
                 u_rx.s_axis_tvalid && u_rx.s_axis_tready && !rxdbg_prev)
            $display("RXDBG k=%0d seq=%08h ack=%08h plen=%0d acc=%b arsp=%b adv=%b dup=%b cam=%b st=%0d rn=%08h rw=%04h su=%08h sn=%08h tk=%02h tl=%b",
                     k, u_rx.seq32_l, u_rx.ack32_l, u_rx.plen_l, u_rx.acc_l,
                     u_rx.ackresp_l, u_rx.ack_adv_l, u_rx.dup_l, u_rx.cam_hit_l,
                     ra_state, ra_rcv_nxt, ra_rcv_wnd, ra_snd_una, ra_snd_nxt,
                     u_rx.s_axis_tkeep, u_rx.s_axis_tlast);
        if (u_rx.state == 3'd0 && u_rx.wcnt == 3'd6 &&
            u_rx.s_axis_tvalid && u_rx.s_axis_tready) rxdbg_prev <= 1;
        else rxdbg_prev <= 0;
    end

    // ---- P4b-7-P6 echo 出口最长无 tlast 词串 (帧合并/无尽帧哨兵) ----
    // tcp_echo 载荷出口 (64bit 字流, tlast 后清): 1450..1460B 单帧 = 182 个
    // 非尾词; P6 冻结签名 (tlast 丢失 -> 多段合并 = 256+ 词无尽帧) 在此现行。
    always @(posedge clk) begin
        if (!rst_n) begin
            eco_run <= 0; eco_max <= 0;
        end else if (eco_tvalid && eco_tready) begin
            if (eco_tlast) begin
                eco_run <= 0;
            end else begin
                if (eco_run + 1 > eco_max) eco_max <= eco_run + 1;
                eco_run <= eco_run + 1;
            end
        end
    end

    // ---- P4b-7-P6 HALFDROP 冻结哨兵: tcp_tx_frame 卡 S_RECV + pay FIFO 满 ----
    // 合并巨帧 (>2048B = 256 字) 下, S_RECV 吞到 pay FIFO 满即停 (tready=0,
    // tlast 永不到) — 板级冻结签名 (PLN=0x800=256 字, PF=1) 的拍级同构。
    // 正常单帧 <= 1460B (183 字) 永不满 pay FIFO: 无注入时恒 0。
    always @(posedge clk) begin
        if (!rst_n) begin
            tdstk_run <= 0; tdstk_max <= 0;
        end else if (u_tx.state == 3'd1 && u_tx.pay_full) begin
            tdstk_run <= tdstk_run + 32'd1;
            if (tdstk_run + 32'd1 > tdstk_max) tdstk_max <= tdstk_run + 32'd1;
        end else begin
            tdstk_run <= 32'd0;
        end
    end

    // ---- GMII 字节捕获 + 事件捕获 ----
    // P4c: 帧字节先入 fcb 缓冲, 帧尾 (原始 en 下降沿) 再按 cur_drop 判据整帧
    // 写/丢 — 只有帧尾才拿得到帧头判据。事件行仍即时写: checker 按 en 沿切帧 +
    // 事件行独立解析 (parse_gmii), 与文件内行序无关。帧间必须写分隔行 (否则
    // 相邻帧字节行会被解析器并成一帧)。
    always @(posedge clk) begin
        if (rst_n) begin
            tx_en_dr <= gmii_tx_en;
            if (gmii_tx_en) begin
                if (!tx_en_dr) fcl <= 12'd1;
                else if (fcl != 12'hFFF) fcl <= fcl + 12'd1;
                if ((!tx_en_dr) || (fcl < 12'd2048))
                    fcb[(!tx_en_dr) ? 12'd0 : fcl] <= gmii_txd;
            end else if (tx_en_dr) begin
                if (!cur_drop)
                    for (fbi = 0; fbi < 2048; fbi = fbi + 1)
                        if (fbi < fcl) $fwrite(fd, "%02h 1\n", fcb[fbi]);
                $fwrite(fd, "00 0\n");
            end
            if (fend)
                $fwrite(fd, "FEND %0d %0d\n", k, ferr);
            if (tx_ack_req)
                $fwrite(fd, "ACK %0d %0d %08h\n", k, tx_ack_id, tx_ack_val);
            if (syn_v)
                $fwrite(fd, "SYNP %012h %08h %04h %04h %08h %04h\n",
                        syn_smac, syn_sip, syn_sport, syn_dport, syn_seq, syn_wnd);
        end
    end

    // ---- P4b-6 缺陷 A 定位: tcp_tx_frame 帧完成 vs mac 上线帧数对账 ----
    reg [31:0] tcf_prev = 0, macf_prev = 0;
    always @(posedge clk) begin
        if (rst_n && $test$plusargs("PROBE")) begin
            if (tx_stat_frames != tcf_prev) begin
                $display("TCF k=%0d n=%0d bytes=%0d", k, tx_stat_frames,
                         tx_stat_bytes);
                tcf_prev <= tx_stat_frames;
            end
            if (mac_stat_frames != macf_prev) begin
                $display("MACF k=%0d n=%0d", k, mac_stat_frames);
                macf_prev <= mac_stat_frames;
            end
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

    // ---- TX echo 帧捕获 (原始 gmii_tx_en; TXDROP 命中帧在帧尾按 cur_drop 整
    //      帧跳过 = 等效"该帧对模型不可见", 但判据由帧头匹配给出):
    //      帧尾按空洞语义调度 ACK — 顺序帧累计推进; OOO 帧每个恰好注入一个
    //      dup (ack = exp_seq, Windows 行为); 全重包 (s+p<=exp) 也回 dup ----
    always @(posedge clk) begin
        if (!rst_n) begin
            tx_en_d <= 0; tx_inf <= 0; txbc <= 0;
            echo_seen <= 0; inj_ack_val <= 0;
            exp_seq <= 32'h12345678 + 32'd1;   // HLS_ISS+1 = 首数据帧 seq
            hole <= 0;
            pca_arp_req <= 0; pca_syn_seen <= 0; pca_iss <= 0; pca_k_syn <= 0;
            pca_ack_seen <= 0; pca_echo_seen <= 0; pca_echo_ok <= 0;
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
            end else if (tx_en_d && !cur_drop) begin
                // 帧尾: conn0 echo 数据帧 (TXDROP 命中帧整帧跳过 — 不计数不 ACK)
                if (cap[12] == 8'h08 && cap[13] == 8'h00 && cap[23] == 8'h06 &&
                    cap[34] == 8'h1F && cap[35] == 8'h90 && cap[36] == 8'h30 &&
                    cap[37] == 8'h39 && cap[47] == 8'h18 &&
                    {cap[16], cap[17]} > 16'd40) begin
                    echo_seen <= echo_seen + 16'd1;
                    s_cur = {cap[38], cap[39], cap[40], cap[41]};
                    p_cur = {16'b0, cap[16], cap[17]} - 32'd40;
                    if (s_cur == exp_seq) begin
                        // 顺序帧: 累计推进
                        exp_seq <= s_cur + p_cur;
                        hole    <= 1'b0;
                        inj_ack_val <= s_cur + p_cur;
                    end else if (s_cur > exp_seq) begin
                        // OOO: 一个乱序帧 = 一个 dup
                        hole    <= 1'b1;
                        inj_ack_val <= exp_seq;
                    end else begin
                        // 全重包 (s+p <= exp_seq): 仍回 dup
                        inj_ack_val <= exp_seq;
                    end
                end
                // ---- P5 PCACTIVE: 板侧主动连接帧捕获 (帧尾拍 cap[0..47] 稳定) ----
                if (pca_en) begin
                    // (a) ARP who-has: 0806 / op=1 / target ip = PCA_ACT_IP
                    //     (HLS 查 ARP 表未命中 → 先问 MAC, 再发 SYN)
                    if (txbc >= 6'd48 && cap[12] == 8'h08 && cap[13] == 8'h06 &&
                        cap[20] == 8'h00 && cap[21] == 8'h01 &&
                        {cap[38], cap[39], cap[40], cap[41]} == PCA_ACT_IP)
                        pca_arp_req <= 1'b1;
                    // (b) 主动 SYN: 0800 / proto6 / sport 1F90 / dport 2382 /
                    //     dst ip = ACTIVE_IP / flags 02 — 记 seq (SYN+ACK 的 ack)
                    if (txbc >= 6'd48 && cap[12] == 8'h08 && cap[13] == 8'h00 &&
                        cap[23] == 8'h06 && cap[34] == 8'h1F && cap[35] == 8'h90 &&
                        cap[36] == 8'h23 && cap[37] == 8'h82 &&
                        {cap[30], cap[31], cap[32], cap[33]} == PCA_ACT_IP &&
                        cap[47] == 8'h02) begin
                        pca_syn_seen <= 1'b1;
                        pca_iss      <= {cap[38], cap[39], cap[40], cap[41]};
                        pca_k_syn    <= k;
                    end
                    // (c) 握手后纯 ACK: seq = ISS+1, ack = PEER_ISS+1, flags 10
                    if (txbc >= 6'd48 && cap[12] == 8'h08 && cap[13] == 8'h00 &&
                        cap[23] == 8'h06 && cap[34] == 8'h1F && cap[35] == 8'h90 &&
                        cap[36] == 8'h23 && cap[37] == 8'h82 &&
                        cap[47] == 8'h10 && pca_synack_inj &&
                        {cap[38], cap[39], cap[40], cap[41]} == (pca_iss + 32'd1) &&
                        {cap[42], cap[43], cap[44], cap[45]} ==
                            (PCA_PEER_ISS + 32'd1))
                        pca_ack_seen <= 1'b1;
                    // (d) 数据段 echo (fast path 数据面): seq = ISS+1,
                    //     ack = PEER_ISS+101, ip total = 140 (100B 载荷)
                    if (txbc >= 6'd48 && cap[12] == 8'h08 && cap[13] == 8'h00 &&
                        cap[23] == 8'h06 && cap[34] == 8'h1F && cap[35] == 8'h90 &&
                        cap[36] == 8'h23 && cap[37] == 8'h82 && cap[47] == 8'h18 &&
                        pca_data_inj &&
                        {cap[38], cap[39], cap[40], cap[41]} == (pca_iss + 32'd1)) begin
                        pca_echo_seen <= 1'b1;
                        if ({cap[42], cap[43], cap[44], cap[45]} ==
                                (PCA_PEER_ISS + 32'd101) &&
                            {cap[16], cap[17]} == 16'd140)
                            pca_echo_ok <= 1'b1;
                    end
                end
            end
        end
    end

    // ---- P5 PCACTIVE 尾窗超时 (SYN 从未出现 / 序列卡住 — 防永久挂起) ----
    always @(posedge clk) begin
        if (!rst_n) begin
            pca_wait <= 0; pca_to <= 0;
        end else if (pca_en && !pca_echo_seen && i >= nstim) begin
            pca_wait <= pca_wait + 32'd1;
            if (pca_wait > 32'd250000) pca_to <= 1'b1;
        end
    end

    // ---- P4c TXDROP 故障注入 (帧头匹配版, 取代旧两阶段窗口): 计数在帧尾按
    //      cur_live (conn0 新数据 echo 帧) 自增; 序号命中拍 (帧尾) 整帧丢弃,
    //      判据与帧头一致, 不再依赖 u_mactx S_PRE 时序 (suppress=0 下 S_PRE 先
    //      落在纯 ACK 帧上 — 旧机制遮错帧: 数据帧全在 + 残片, RETX=0)。ring
    //      重放帧 (s<exp) 不计编号, 与旧 start_data 语义等价。DUT/mac 无感 =
    //      模拟链路丢帧; mac_stat_frames 仍计该帧 (对账用)。 ----
    always @(posedge clk) begin
        if (!rst_n) data_cnt <= 0;
        else if (tx_frame_end && cur_live) data_cnt <= data_cnt + 8'd1;
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

    // ---- P4b-6 排障: HLS 顶层 FSM 状态窥探 (SYN 处理卡死定位) ----
    // 顶层 ap_CS_fsm 在任意网表里都存在, 不绑定子模块实例号 (子模块
    // fu_xxxx 的编号随 HLS 输入变化: 默认网表 fu_1620 -> fu_1641,
    // ACTIVE 网表 fu_1657 — 用宏区分的老做法一改源码就 elaboration 失败)。
    wire [15:0] HLS_FSM_ST = u_hls.ap_CS_fsm;
    reg [15:0] mrx_prev = 16'hFFFF;
    always @(posedge clk) begin
        if (rst_n && $test$plusargs("PROBE")) begin
            if (HLS_FSM_ST != mrx_prev) begin
                $display("HLSTOPST k=%0d st=%04h -> %04h (rdy=%b)",
                         k, mrx_prev, HLS_FSM_ST, hls_rx_tready);
                mrx_prev <= HLS_FSM_ST;
            end
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
