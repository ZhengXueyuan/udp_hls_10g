`timescale 1ns/1ps
//=============================================================================
// tb_p5_adv: P5a 对抗性用例 TB (app 接口契约边界 / 不变量)
//
// 与 tb_p5_app 的区别:
//   - app 侧不是 rtl/app_pattern, 而是 TB 自带的 "app 模型": 帧长 / 背靠背 /
//     是否无视 app_tx_ready 全部由脚本 (adv_cmds.memh) 控制 -> 可打边界。
//   - PC 侧是 "逐帧应答" 模型: 捕获板侧每条数据/FIN 帧, 回一条纯 ACK
//     (seq = 板侧 rcv_nxt[conn], ack = 帧 seq + plen (+1 for FIN), wnd =
//      pc_wnd[conn])。丢帧/关窗由脚本用 pc_en / pc_wnd 控制。
//   - 全部判据在 tools/gen_stim_p5_adv.py (逐字节 + 覆盖并集 + 丢弃计数),
//     TB 只做激励与落盘, 不在 TB 里自证。
//
// 脚本 adv_cmds.memh: 每行 10 个十进制整数 (op a b c d e f g h i)
//   op 1  WAIT a 拍
//   op 2  WAIT 直到板侧数据帧数 >= a
//   op 3  WAIT 直到板侧 FIN 帧数 >= a
//   op 4  CFG 记录: a=slot b=cmd(0 ADD/1 DEL) c=wscale d=peer_ip e=my_ip
//         f=(peer_port<<16)|my_port g=mac_hi h=mac_lo i=peer_wnd
//   op 5  APP 推 a 帧: b=len c=tid d=sel(0 尊重 app_tx_ready / 1 无视)
//   op 6  PC 应答开关: a=conn b=0/1
//   op 7  REG 写: a=addr b=data
//   op 8  REG 读落盘: a=addr
//   op 9  PC 通告窗: a=conn b=wnd (未缩放)
//   op 10 PC 手工注入纯 ACK: a=conn b=ack 增量 (相对已发最大 ack)
//   op 11 PC 连接表: a=conn b=sport c=dport d=peer_ip e=my_ip f=mac_hi
//         g=mac_lo h=wnd i=en
//   op 12 落盘快照
//   op 13 WAIT 直到板侧 RST 帧数 >= a
//   op 14 WAIT 直到 app 已消费帧数 >= a
//   op 15 WAIT 直到 s_axis 空 (所有已推帧被消费) 上限 a 拍
//   op 16 APP 清空 (丢弃当前帧)
//   op 17 PC 连接 seq 基: a=conn b=seq (= 该连接 ADD 的 rcv_nxt, 数据注入用)
//   op 18 CFG seq: a=slot b=rcv_nxt c=snd_nxt (op 4 用它填 w6/w7)
//=============================================================================
module tb_p5_adv;
    localparam [31:0] TB_ISS      = 32'h12345678;
    localparam [31:0] TB_SND_NXT0 = TB_ISS + 32'd1;
    localparam [31:0] TB_PEER_IP  = 32'hC0A86401;
    localparam [31:0] TB_MY_IP    = 32'hC0A86402;
    localparam [15:0] TB_PEER_PORT = 16'h3039;
    localparam [15:0] TB_MY_PORT   = 16'h1F90;
    localparam [47:0] TB_PEER_MAC  = 48'h112233445566;
    localparam [31:0] PEER_ISN     = 32'h20000000;
    localparam [63:0] P5_SEED      = 64'h9E3779B97F4A7C15;
    localparam [31:0] K_MAX        = 32'd120_000_000;  // 全局死锁上限 (拍)
    localparam [31:0] TMO_OP       = 32'd24_000_000;   // 单 op 上限 (RTO ~12.5M 拍)
    // P5b C16-修订 接受裕度 —— **镜像 board/wrapper_p4.v 的 APP_MODE 取值**
    // (C12 扩展: 参数也必须镜像; 唯一绑定点, 见 u_rx 例化处注释)。
    localparam [15:0] TB_ACC_MARGIN = 16'd4096;

    // RTL 图案 (D6): 先取 s[31:24] 再推进 s ^= s<<13; s ^= s>>7; s ^= s<<17
    function [63:0] xs_next;
        input [63:0] s;
        reg   [63:0] t;
        begin
            t = s ^ (s << 13);
            t = t ^ (t >> 7);
            t = t ^ (t << 17);
            xs_next = t;
        end
    endfunction
    function [63:0] xs_advn;      // 推进 n 步 (n = 1..8)
        input [63:0] s;
        input [3:0]  n;
        integer k;
        reg [63:0] t;
        begin
            t = s;
            for (k = 0; k < 8; k = k + 1) if (k[3:0] < n) t = xs_next(t);
            xs_advn = t;
        end
    endfunction
    function [63:0] xs_word8;     // 从 s 起 8 步, 左对齐 (b0 在 [63:56])
        input [63:0] s;
        integer k;
        reg [63:0] t, w;
        begin
            t = s; w = 64'd0;
            for (k = 0; k < 8; k = k + 1) begin
                w = {w[55:0], t[31:24]};
                t = xs_next(t);
            end
            xs_word8 = w;
        end
    endfunction
    // 取 w 的高 n 字节左对齐 (低字节清零; 修正: 不是右移 — 右移会变成右对齐,
    // 与 tkeep = kmask8(n) 的高位约定矛盾, 尾 beat 会被 DUT 采到零)
    function [63:0] rs8;
        input [63:0] w;
        input [3:0]  n;
        begin
            case (n)
                4'd1: rs8 = w & 64'hFF00000000000000;
                4'd2: rs8 = w & 64'hFFFF000000000000;
                4'd3: rs8 = w & 64'hFFFFFF0000000000;
                4'd4: rs8 = w & 64'hFFFFFFFF00000000;
                4'd5: rs8 = w & 64'hFFFFFFFFFF000000;
                4'd6: rs8 = w & 64'hFFFFFFFFFFFF0000;
                4'd7: rs8 = w & 64'hFFFFFFFFFFFFFF00;
                4'd8: rs8 = w;
                default: rs8 = 64'd0;
            endcase
        end
    endfunction
    function [7:0] kmask8;
        input [3:0] n;
        begin
            case (n)
                4'd0: kmask8 = 8'h00; 4'd1: kmask8 = 8'h80;
                4'd2: kmask8 = 8'hC0; 4'd3: kmask8 = 8'hE0;
                4'd4: kmask8 = 8'hF0; 4'd5: kmask8 = 8'hF8;
                4'd6: kmask8 = 8'hFC; 4'd7: kmask8 = 8'hFE;
                default: kmask8 = 8'hFF;
            endcase
        end
    endfunction
    function [3:0] pop8;
        input [7:0] v;
        integer i; reg [3:0] c;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]};
            pop8 = c;
        end
    endfunction

    reg        clk, rst_n;
    reg [7:0]  rx_d;
    reg        rx_dv, rx_er;
    reg [22:0] i;
    reg [31:0] k;

    // ---------------- DUT 线网 ----------------
    wire [63:0] raw_tdata;  wire [7:0] raw_tkeep;
    wire        raw_tvalid, raw_tready, raw_tlast, raw_tuser, raw_tcrs, raw_terr;
    wire [63:0] vs_tdata;   wire [7:0] vs_tkeep;
    wire        vs_tvalid, vs_tready, vs_tlast, vs_tuser, vs_tcrs, vs_terr;
    wire [63:0] f_tdata;    wire [7:0] f_tkeep;
    wire        f_tvalid, f_tready, f_tlast, f_tuser, f_tcrs, f_terr;
    wire [63:0] sl_tdata;   wire [7:0] sl_tkeep;
    wire        sl_tvalid, sl_tready, sl_tlast, sl_tuser, sl_tcrs, sl_terr;
    wire [63:0] m_tdata;    wire [7:0] m_tkeep;
    wire        m_tvalid, m_tready, m_tlast;
    wire [1:0]  m_tuser;
    wire        fend, ferr, meta_valid;
    wire [3:0]  meta_conn_id;
    wire [15:0] meta_len;
    wire [3:0]  ra_id;
    wire [31:0] ra_rcv_nxt, ra_snd_nxt, ra_snd_una;
    wire [15:0] ra_rcv_wnd;
    wire [3:0]  ra_state, ra_wscale;
    wire        rx_upd_wr, rx_upd_gnt;
    wire [3:0]  rx_upd_id;
    wire [2:0]  rx_upd_sel;
    wire [31:0] rx_upd_val;
    wire        ack_req, retx_req, retx_gnt;
    wire [3:0]  ack_id, retx_id;
    wire [31:0] ack_val;
    wire [31:0] cam_q_sip, cam_q_dip;
    wire [15:0] cam_q_sport, cam_q_dport;
    wire        cam_q_hit;
    wire [3:0]  cam_q_id;
    wire [31:0] rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                rx_stat_seq, rx_stat_ack, rx_stat_bytes, rx_stat_trunc;
    wire        syn_v;
    wire [47:0] syn_smac;
    wire [31:0] syn_sip;
    wire [15:0] syn_sport, syn_dport;
    wire [31:0] syn_seq;
    wire [15:0] syn_wnd;
    wire [63:0] eco_tdata;  wire [7:0] eco_tkeep;
    wire        eco_tvalid, eco_tready, eco_tlast;
    wire [3:0]  eco_tid;
    wire [63:0] eco2_tdata; wire [7:0] eco2_tkeep;
    wire        eco2_tvalid, eco2_tready, eco2_tlast;
    wire [3:0]  eco2_tid;
    wire [76:0] eco2_pack;
    assign {eco2_tkeep, eco2_tlast, eco2_tdata, eco2_tid} = eco2_pack;
    wire [31:0] eco_stat_echo, eco_stat_drop_crc;
    wire [63:0] app2_tdata; wire [7:0] app2_tkeep;
    wire        app2_tvalid, app2_tready, app2_tlast;
    wire [3:0]  app2_tid;
    wire [76:0] app2_pack;
    assign {app2_tkeep, app2_tlast, app2_tdata, app2_tid} = app2_pack;
    wire [3:0]  rb_id;
    wire [31:0] rb_rcv_nxt, rb_snd_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;
    wire        win_open;
    wire [15:0] win_inflight, win_wnd_eff;
    wire        tx_upd_wr;
    wire [3:0]  tx_upd_id;
    wire [2:0]  tx_upd_sel;
    wire [31:0] tx_upd_val;
    wire [3:0]  cam_rd_id;
    wire [47:0] cam_rd_dmac;
    wire [31:0] cam_rd_sip, cam_rd_dip;
    wire [15:0] cam_rd_sport, cam_rd_dport;
    wire [3:0]  rc_id;
    wire [31:0] rc_snd_nxt, rc_snd_una, rc_rcv_nxt;
    wire [15:0] rc_rcv_wnd, rc_snd_wnd;
    wire [3:0]  rc_state;
    wire [63:0] x_tdata;    wire [7:0] x_tkeep;
    wire        x_tvalid, x_tready, x_tlast;
    wire [31:0] tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_ack_drop;
    wire [31:0] tx_stat_eend, tx_stat_retx, tx_stat_drop_len, tx_stat_fin,
                tx_stat_rst;
    wire [31:0] tx_retx_hi;
    wire        tx_retx_active, tx_retx_gnt;
    wire [3:0]  tx_retx_id;
    wire [15:0] tx_fin_sent;
    wire [15:0] tx_rst_sent;   // P5c-T3 G3: tcp_tx_frame.o_rst_sent -> u_app_ctrl
    wire [15:0] app_tx_ready;
    wire [63:0] a_tdata;    wire [7:0] a_tkeep;
    wire        a_tvalid, a_tready, a_tlast;
    wire [7:0]  gmii_txd;
    wire        gmii_tx_en;
    wire [31:0] mac_stat_frames, mac_stat_abort;
    wire [31:0] mac_stat_drop;
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
    wire        ev_up, ev_down;
    wire [3:0]  ev_slot;
    wire [31:0] ev_peer_ip;
    wire [15:0] ev_peer_port;
    wire [47:0] ev_peer_mac;
    reg  [31:0] cfg_rcv_nxt [0:15];   // 每槽 ADD 的 rcv_nxt (op 18)
    reg  [31:0] cfg_snd_nxt [0:15];   // 每槽 ADD 的 snd_nxt (op 18)
    reg  [31:0] cfg_tdata;
    reg         cfg_tvalid;
    wire        cfg_tready;
    reg  [7:0]  ac_addr;
    reg         ac_wr;
    reg  [31:0] ac_wdata;
    wire [31:0] ac_rdata;
    wire        ac_ev_up, ac_ev_down;
    wire [3:0]  ac_ev_slot;
    wire [15:0] ac_fin_req, ac_rst_req;
    wire [31:0] ac_ev_up_c, ac_ev_down_c, ac_ev_drop, ac_cmd_cls, ac_cmd_abt;
    wire [3:0]  ac_c0_state;
    wire [31:0] ac_c0_snd_nxt, ac_c0_snd_una, ac_c0_rcv_nxt;
    wire [15:0] ac_c0_rcv_wnd;
    wire [16:0] rx_occ;
    // P5b: 流控跨模块线网
    wire        fc_upd_wr, app_wu_req, app_wu_gnt;
    wire [3:0]  fc_upd_id, app_wu_id;
    wire [2:0]  fc_upd_sel;
    wire [31:0] fc_upd_val, app_wu_val;
    wire        fc_gnt;
    wire        dbg_wnd_open, dbg_pay_full, dbg_sready, dbg_saxis_tvalid;
    wire [11:0] dbg_plen_r, dbg_plen;
    wire [2:0]  dbg_txstate;
    wire [7:0]  dbg_pay_wptr, dbg_pay_rptr;
    wire        dbg_pay_full2, dbg_pay_empty;
    wire [13:0] eco_wptr, eco_rptr;
    reg         tmo;                 // 脚本 WAIT 超时标志

    // ---- cam/tcb 仲裁 (tx > rx > cfg; P5b: + 第 4 级 fc 最低优先) ----
    // 与 board/wrapper_p4.v 的 APP_MODE 支同构 (scfg_gnt 表达式逐字不变)
    wire        sel_tx = tx_upd_wr;
    wire        sel_rx = !sel_tx && rx_upd_wr;
    assign rx_upd_gnt = sel_rx;
    assign scfg_gnt   = !sel_tx && !sel_rx && scfg_upd_wr;
    wire        sel_fc = !sel_tx && !sel_rx && !scfg_upd_wr && fc_upd_wr;
    wire        tcb_wr  = sel_tx || sel_rx || (scfg_upd_wr && scfg_gnt) || sel_fc;
    wire [2:0]  tcb_sel = sel_tx ? tx_upd_sel : (sel_rx ? rx_upd_sel :
                          (scfg_upd_wr ? scfg_upd_sel : fc_upd_sel));
    wire [3:0]  tcb_id  = sel_tx ? tx_upd_id  : (sel_rx ? rx_upd_id  :
                          (scfg_upd_wr ? scfg_upd_id  : fc_upd_id));
    wire [31:0] tcb_val = sel_tx ? tx_upd_val : (sel_rx ? rx_upd_val :
                          (scfg_upd_wr ? scfg_upd_val : fc_upd_val));
    assign      fc_gnt  = sel_fc;

    // ======================= DUT =======================
    mac_rx_64 u_mac (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(raw_tdata), .m_axis_tkeep(raw_tkeep),
        .m_axis_tvalid(raw_tvalid), .m_axis_tready(raw_tready),
        .m_axis_tlast(raw_tlast), .m_axis_tuser(raw_tuser),
        .m_axis_terr(raw_terr), .m_axis_tcrs(raw_tcrs),
        // P5b: stat_drop 接线 (multi 门要断言"板侧物理不丢帧")
        .stat_frames(), .stat_crc_err(), .stat_drop(mac_stat_drop), .stat_bytes()
    );

    vlan_strip u_vlan (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(raw_tdata), .s_axis_tkeep(raw_tkeep),
        .s_axis_tvalid(raw_tvalid), .s_axis_tready(raw_tready),
        .s_axis_tlast(raw_tlast), .s_axis_tuser(raw_tuser),
        .s_axis_tcrs(raw_tcrs), .s_axis_terr(raw_terr),
        .m_axis_tdata(vs_tdata), .m_axis_tkeep(vs_tkeep),
        .m_axis_tvalid(vs_tvalid), .m_axis_tready(vs_tready),
        .m_axis_tlast(vs_tlast), .m_axis_tuser(vs_tuser),
        .m_axis_tcrs(vs_tcrs), .m_axis_terr(vs_terr),
        .stat_stripped(), .dbg_vlan()
    );

    rx_classify u_classify (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(vs_tdata), .s_axis_tkeep(vs_tkeep),
        .s_axis_tvalid(vs_tvalid), .s_axis_tready(vs_tready),
        .s_axis_tlast(vs_tlast), .s_axis_tuser(vs_tuser),
        .s_axis_tcrs(vs_tcrs), .s_axis_terr(vs_terr),
        .m_fast_tdata(f_tdata), .m_fast_tkeep(f_tkeep),
        .m_fast_tvalid(f_tvalid), .m_fast_tready(f_tready),
        .m_fast_tlast(f_tlast), .m_fast_tuser(f_tuser),
        .m_fast_tcrs(f_tcrs), .m_fast_terr(f_terr),
        .m_slow_tdata(sl_tdata), .m_slow_tkeep(sl_tkeep),
        .m_slow_tvalid(sl_tvalid), .m_slow_tready(1'b1),
        .m_slow_tlast(sl_tlast), .m_slow_tuser(sl_tuser),
        .m_slow_tcrs(sl_tcrs), .m_slow_terr(sl_terr),
        .stat_fast(), .stat_slow()
    );

    tcp_rx u_rx (
        // P5b C12 / P5d H-fix: APP_MODE 对抗集 TB 镜像 wrapper 的接受裕度配置。
        // (H-fix 后 ACC_MARGIN 由参数变端口; 本门最多 2 条并发连接 ⇒ wrapper 的
        //  动态值 = min(4096, 10550/N) = 4096 (N<=2) ⇒ 本常量 = 逐位镜像。
        //  P5b 必修4: localparam 具名常量 —— 它既是 DUT 的实际配置, 也是"接受裕度
        //  <= 物理余量"判据的**唯一绑定点** (checker 断言 ADVCFG 行的 acc_margin
        //  <= 物理预算, 见 tools/gen_stim_p5_adv.py 的 ACC_BUDGET; 该 checker 按
        //  文本解析 `.ACC_MARGIN` 行 ⇒ 端口名保持大写, 见 rtl/tcp_rx.v 注释)。
        //  改这里 = 改 DUT 配置, 门会当场响。)
        .ACC_MARGIN(TB_ACC_MARGIN),
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(f_tdata), .s_axis_tkeep(f_tkeep),
        .s_axis_tvalid(f_tvalid), .s_axis_tready(f_tready),
        .s_axis_tlast(f_tlast), .s_axis_tuser(f_tuser),
        .s_axis_tcrs(f_tcrs), .s_axis_terr(f_terr),
        .cfg_suppress_data_ack(1'b0),   // APP_MODE: 逐段纯 ACK
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .m_axis_tuser(m_tuser),
        .fend(fend), .ferr(ferr),
        .meta_valid(meta_valid), .meta_src_ip(), .meta_src_port(),
        .meta_len(meta_len), .meta_conn_id(meta_conn_id), .meta_seq(),
        .ra_id(ra_id),
        .ra_rcv_nxt(ra_rcv_nxt), .ra_snd_nxt(ra_snd_nxt), .ra_snd_una(ra_snd_una),
        .ra_rcv_wnd(ra_rcv_wnd), .ra_state(ra_state), .ra_wscale(ra_wscale),
        .ra_retx_hi(tx_retx_hi), .ra_retx_active(tx_retx_active),
        .upd_wr(rx_upd_wr), .upd_id(rx_upd_id), .upd_sel(rx_upd_sel),
        .upd_val(rx_upd_val), .upd_gnt(rx_upd_gnt),
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
        .stat_drop_seq(rx_stat_seq), .stat_ack(rx_stat_ack),
        .stat_bytes(rx_stat_bytes), .stat_drop_trunc(rx_stat_trunc)
    );

    tcp_echo u_echo (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(m_tdata), .s_axis_tkeep(m_tkeep),
        .s_axis_tvalid(m_tvalid), .s_axis_tready(m_tready), .s_axis_tlast(m_tlast),
        .s_axis_tuser(m_tuser), .fend(fend), .ferr(ferr),
        .meta_valid(meta_valid), .meta_conn_id(meta_conn_id), .meta_len(meta_len),
        .m_axis_tdata(eco_tdata), .m_axis_tkeep(eco_tkeep),
        .m_axis_tvalid(eco_tvalid), .m_axis_tready(eco_tready),
        .m_axis_tlast(eco_tlast), .m_axis_tid(eco_tid),
        .stat_echo(eco_stat_echo), .stat_drop_crc(eco_stat_drop_crc),
        .stat_tlast_wr(), .stat_tlast_fwd(),
        .dbg_fifo_full(), .dbg_state(), .dbg_fifo_empty(),
        .dbg_fifo_wptr(eco_wptr), .dbg_fifo_rptr(eco_rptr),
        .dbg_rd_addr(), .dbg_rd_side()
    );

    axis_pipe #(.W(77)) u_eco_pipe (
        .clk(clk), .rst_n(rst_n),
        .s_data({eco_tkeep, eco_tlast, eco_tdata, eco_tid}),
        .s_valid(eco_tvalid), .s_ready(eco_tready),
        .m_data(eco2_pack), .m_valid(eco2_tvalid), .m_ready(eco2_tready)
    );

    tcp_cam u_cam (
        .clk(clk), .rst_n(rst_n),
        .cfg_wr(scfg_cam_wr), .cfg_addr(scfg_cam_addr),
        .cfg_sip(scfg_cam_sip), .cfg_dip(scfg_cam_dip),
        .cfg_sport(scfg_cam_sport), .cfg_dport(scfg_cam_dport),
        .cfg_dmac(scfg_cam_dmac),
        .q_sip(cam_q_sip), .q_dip(cam_q_dip),
        .q_sport(cam_q_sport), .q_dport(cam_q_dport),
        .q_id(cam_q_id), .q_hit(cam_q_hit),
        .rd_id(cam_rd_id), .rd_dmac(cam_rd_dmac), .rd_sip(cam_rd_sip),
        .rd_dip(cam_rd_dip), .rd_sport(cam_rd_sport), .rd_dport(cam_rd_dport)
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
        .dbg_snd_nxt0(), .dbg_snd_una0(), .dbg_rcv_nxt0(), .dbg_snd_wnd0(),
        .dbg_wscale0(), .dbg_state0(),
        .rc_id(rc_id), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd), .rc_snd_wnd(rc_snd_wnd),
        .rc_state(rc_state),
        .upd_wr(tcb_wr), .upd_id(tcb_id), .upd_sel(tcb_sel), .upd_val(tcb_val)
    );

    slow_cfg_adp u_slow_cfg (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(cfg_tdata), .s_axis_tvalid(cfg_tvalid),
        .s_axis_tready(cfg_tready),
        .cam_cfg_wr(scfg_cam_wr), .cam_cfg_addr(scfg_cam_addr),
        .cam_cfg_sip(scfg_cam_sip), .cam_cfg_dip(scfg_cam_dip),
        .cam_cfg_sport(scfg_cam_sport), .cam_cfg_dport(scfg_cam_dport),
        .cam_cfg_dmac(scfg_cam_dmac),
        .upd_wr(scfg_upd_wr), .upd_id(scfg_upd_id),
        .upd_sel(scfg_upd_sel), .upd_val(scfg_upd_val),
        .cfg_gnt(scfg_gnt), .stat_add(scfg_add), .stat_del(scfg_del),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(ev_peer_ip), .ev_peer_port(ev_peer_port),
        .ev_peer_mac(ev_peer_mac)
    );

    tcp_tx_frame u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(app2_tdata), .s_axis_tkeep(app2_tkeep),
        .s_axis_tvalid(app2_tvalid), .s_axis_tready(app2_tready),
        .s_axis_tlast(app2_tlast), .s_axis_tid(app2_tid),
        .ack_req(ack_req), .ack_id(ack_id), .ack_val(ack_val),
        .ack_syn(1'b0), .ack_fin(1'b0), .ack_rst(1'b0),
        .rb_id(rb_id), .rb_snd_nxt(rb_snd_nxt), .rb_rcv_nxt(rb_rcv_nxt),
        .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_una(rb_snd_una), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
        .win_open(win_open), .win_inflight(win_inflight), .win_wnd_eff(win_wnd_eff),
        .upd_wr(tx_upd_wr), .upd_id(tx_upd_id), .upd_sel(tx_upd_sel),
        .upd_val(tx_upd_val),
        .cam_rd_id(cam_rd_id), .cam_rd_dmac(cam_rd_dmac), .cam_rd_sip(cam_rd_sip),
        .cam_rd_sport(cam_rd_sport), .cam_rd_dport(cam_rd_dport),
        .cfg_src_mac(48'h000A3501FEC0), .cfg_src_ip(TB_MY_IP),
        .m_axis_tdata(x_tdata), .m_axis_tkeep(x_tkeep),
        .m_axis_tvalid(x_tvalid), .m_axis_tready(x_tready), .m_axis_tlast(x_tlast),
        .stat_frames(tx_stat_frames), .stat_bytes(tx_stat_bytes),
        .stat_ack(tx_stat_ack), .stat_ack_drop(tx_stat_ack_drop),
        .stat_eend(tx_stat_eend),
        .stat_drop_len(tx_stat_drop_len), .stat_fin(tx_stat_fin),
        .stat_rst(tx_stat_rst),
        .stat_tlast_in(),
        .retx_req(retx_req), .retx_id(retx_id), .retx_gnt(tx_retx_gnt),
        .stat_retx(tx_stat_retx),
        .o_retx_hi(tx_retx_hi), .o_retx_active(tx_retx_active),
        .o_retx_id(tx_retx_id),
        .fin_req(ac_fin_req), .rst_req(ac_rst_req), .o_fin_sent(tx_fin_sent),
        // P5c-T3 G3: RST 已发出 (abort fence) -> u_app_ctrl.rst_sent
        .o_rst_sent(tx_rst_sent),
        // P5a D1: cfg ADD 收尾脉冲清该槽 FIN/RST 已发标志 (同槽重连必需)
        .cfg_up(ev_up), .cfg_up_id(ev_slot),
        // P5b: wu 条目通道 (app_ctrl 驱动, 与 wrapper APP_MODE 支同构)
        .wu_req(app_wu_req), .wu_id(app_wu_id), .wu_val(app_wu_val),
        .wu_gnt(app_wu_gnt),
        .dbg_wnd_open(dbg_wnd_open), .dbg_pay_full(dbg_pay_full),
        .dbg_sready(dbg_sready), .dbg_saxis_tvalid(dbg_saxis_tvalid),
        .dbg_plen_r(dbg_plen_r), .dbg_state(dbg_txstate),
        .dbg_pay_wptr(dbg_pay_wptr), .dbg_pay_rptr(dbg_pay_rptr),
        .dbg_pay_full2(dbg_pay_full2), .dbg_pay_empty(dbg_pay_empty),
        .dbg_plen(dbg_plen)
    );

    tx_arb u_tx_arb (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(x_tdata), .s_fast_tkeep(x_tkeep), .s_fast_tvalid(x_tvalid),
        .s_fast_tready(x_tready), .s_fast_tlast(x_tlast),
        .s_slow_tdata(64'd0), .s_slow_tkeep(8'd0), .s_slow_tvalid(1'b0),
        .s_slow_tready(), .s_slow_tlast(1'b0),
        .m_axis_tdata(a_tdata), .m_axis_tkeep(a_tkeep), .m_axis_tvalid(a_tvalid),
        .m_axis_tready(a_tready), .m_axis_tlast(a_tlast)
    );

    mac_tx_64 u_mactx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(a_tdata), .s_axis_tkeep(a_tkeep),
        .s_axis_tvalid(a_tvalid), .s_axis_tready(a_tready), .s_axis_tlast(a_tlast),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(),
        .stat_frames(mac_stat_frames), .stat_abort(mac_stat_abort)
    );

    // ==================== app TX 模型 (TB 驱动, 组合呈交) ====================
    app_ctrl #(.WIN_CAP(16'hBFFE)) u_app_ctrl (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(ev_peer_ip), .ev_peer_port(ev_peer_port),
        .ev_peer_mac(ev_peer_mac),
        .rc_id(rc_id), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .rx_occ_bytes(rx_occ), .fin_sent(tx_fin_sent),
        .rst_sent(tx_rst_sent),   // P5c-T3 G3: abort fence
        // P5b: 窗口纠偏写 + 窗口更新 ACK
        .fc_upd_wr(fc_upd_wr), .fc_upd_id(fc_upd_id),
        .fc_upd_sel(fc_upd_sel), .fc_upd_val(fc_upd_val),
        .fc_gnt(fc_gnt),
        .wu_req(app_wu_req), .wu_id(app_wu_id), .wu_val(app_wu_val),
        .wu_gnt(app_wu_gnt),
        .o_ev_up(ac_ev_up), .o_ev_down(ac_ev_down), .o_ev_slot(ac_ev_slot),
        .fin_req(ac_fin_req), .rst_req(ac_rst_req),
        .close_req(1'b0), .close_id(4'd0),
        .reg_addr(ac_addr), .reg_wr(ac_wr), .reg_wdata(ac_wdata),
        .reg_rdata(ac_rdata),
        .app_tx_ready(app_tx_ready),
        .stat_ev_up(ac_ev_up_c), .stat_ev_down(ac_ev_down_c),
        .stat_ev_drop(ac_ev_drop), .stat_cmd_close(ac_cmd_cls),
        .stat_cmd_abort(ac_cmd_abt),
        .dbg_c0_state(ac_c0_state), .dbg_c0_snd_nxt(ac_c0_snd_nxt),
        .dbg_c0_snd_una(ac_c0_snd_una), .dbg_c0_rcv_nxt(ac_c0_rcv_nxt),
        .dbg_c0_rcv_wnd(ac_c0_rcv_wnd), .dbg_c0_snd_wnd(),
        .dbg_estab_cnt(), .dbg_ev_cnt(),
        .dbg_redge0(), .dbg_winq0(), .dbg_wu_mark0(), .dbg_pool(),
        .stat_wu(), .stat_pool_exhaust()
    );

    assign eco2_tready = 1'b1;          // app RX 快消费者 (本 TB 不产生 PC 数据)
    assign rx_occ = {(eco_wptr - eco_rptr), 3'b0};

    reg  [15:0] atx_len;      // 当前帧总长
    reg  [15:0] atx_off;      // 当前帧已呈交字节
    reg  [63:0] atx_state;    // 当前帧当前偏移处的图案 LFSR 状态
    reg         atx_bad;      // 坏帧 (载荷常数 0xA5, 不推进 LFSR)
    reg  [3:0]  atx_tid;
    reg         atx_sel;      // 1 = 无视 app_tx_ready
    reg         atx_run;      // 当前帧呈交中
    reg  [31:0] atx_qn;       // 队列中待呈交帧数 (含当前帧)
    reg  [15:0] atx_qlen;     // 队列帧长 (统一)
    reg         atx_qbad, atx_qsel;
    reg  [3:0]  atx_qtid;
    reg  [31:0] atx_frames, atx_bytes, atx_good_bytes, atx_last_len;
    reg  [31:0] atx_bad_frames;

    wire [15:0] atx_left = atx_len - atx_off;
    wire [3:0]  atx_n    = (atx_left >= 16'd8) ? 4'd8 : atx_left[3:0];
    wire [63:0] atx_w8   = xs_word8(atx_state);
    wire [63:0] atx_word = atx_bad ? {8{8'hA5}} : rs8(atx_w8, atx_n);
    // 启动门必须看**队列里那一帧**的 sel/tid (atx_sel/atx_tid 是当前帧启动时
    // 才载入的寄存器 = 上一帧的残留值, 会让 sel=1 的帧也被 app_tx_ready 拦下)
    wire        atx_ready_now = atx_qsel ? 1'b1 : app_tx_ready[atx_qtid];
    // 呈交口 (组合; 与 app_pattern 同约定) — 显式声明, 杜绝隐式 1 位线网
    wire [63:0] atx_tdata;
    wire [7:0]  atx_tkeep;
    wire        atx_tlast;
    wire        atx_tvalid;
    wire        atx_tready;
    assign atx_tdata = atx_word;
    assign atx_tkeep = kmask8(atx_n);
    assign atx_tlast = ((atx_off + {12'b0, atx_n}) >= atx_len) && atx_run;
    assign      atx_tvalid = atx_run && (atx_off < atx_len);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            atx_len <= 0; atx_off <= 0; atx_state <= P5_SEED; atx_bad <= 0;
            atx_tid <= 0; atx_sel <= 0; atx_run <= 0; atx_qn <= 0; atx_qlen <= 0;
            atx_qbad <= 0; atx_qsel <= 0; atx_qtid <= 0;
            atx_frames <= 0; atx_bytes <= 0; atx_good_bytes <= 0;
            atx_last_len <= 0; atx_bad_frames <= 0;
        end else begin
            // 启动 (队列非空且当前无帧): 尊重 app_tx_ready 时等门开
            if (!atx_run && atx_qn != 0 && atx_ready_now) begin
                atx_run   <= 1'b1;
                atx_len   <= atx_qlen;
                atx_off   <= 16'd0;
                atx_bad   <= atx_qbad;
                atx_tid   <= atx_qtid;
                atx_sel   <= atx_qsel;
            end
            if (atx_run && atx_tready) begin
                // 消费一 beat
                if (!atx_bad) begin
                    atx_state <= xs_advn(atx_state, atx_n);
                    atx_good_bytes <= atx_good_bytes + {28'b0, atx_n};
                end
                atx_bytes <= atx_bytes + {28'b0, atx_n};
                if ((atx_off + {12'b0, atx_n}) >= atx_len) begin
                    atx_frames <= atx_frames + 32'd1;
                    if (atx_bad) atx_bad_frames <= atx_bad_frames + 32'd1;
                    atx_last_len <= atx_len;
                    if (atx_qn > 1) begin
                        atx_qn <= atx_qn - 32'd1;      // 背靠背: 保持 tvalid
                        atx_off <= 16'd0;
                    end else begin
                        atx_qn <= 32'd0;
                        atx_run <= 1'b0;
                        atx_off <= 16'd0;
                    end
                end else begin
                    atx_off <= atx_off + {12'b0, atx_n};
                end
            end
        end
    end

    // app TX -> 帧器 (1 拍流水寄存器; 组合呈交, 与 app_pattern 同约定)
    axis_pipe #(.W(77)) u_app_pipe (
        .clk(clk), .rst_n(rst_n),
        .s_data({atx_tkeep, atx_tlast, atx_tdata, atx_tid}),
        .s_valid(atx_tvalid), .s_ready(atx_tready),
        .m_data(app2_pack), .m_valid(app2_tvalid), .m_ready(app2_tready)
    );

    // ==================== PC 应答模型 ====================
    reg  [15:0] pc_sport [0:15];
    reg  [15:0] pc_dport [0:15];
    reg  [31:0] pc_peerip[0:15];
    reg  [31:0] pc_myip  [0:15];
    reg  [47:0] pc_mac   [0:15];
    reg  [15:0] pc_wnd   [0:15];
    reg         pc_en    [0:15];
    reg  [31:0] pc_hwm   [0:15];      // 已发出的最大 ack
    reg  [15:0] frm_data, frm_fin, frm_rst, frm_other;
    reg  [15:0] fin_cnt;
    reg  [31:0] fin_seq_first, fin_seq_last;
    reg  [15:0] ack_cnt;
    integer     ci;
    reg  [5:0]  txbc;
    reg         tx_en_d, tx_inf;
    reg         dbg_cap = 1'b0;
    reg  [7:0]  cap [0:63];
    reg  [5:0]  caplen;
    reg         cap_fin;

    // 应答播放器
    reg         ack_pend;
    reg  [3:0]  ack_conn;
    reg  [31:0] ack_seq, ack_ack;
    reg  [15:0] ack_wnd;
    reg  [8:0]  ack_i;              // 0..83
    reg  [31:0] ack_crc;
    // 待发帧队列 (16 深): 板侧一个窗口内可连续出多帧, 播放器追不上时不能丢
    reg  [3:0]  q_c [0:15];         // 连接
    reg  [31:0] q_s [0:15];         // seq
    reg  [31:0] q_a [0:15];         // ack
    reg  [15:0] q_w [0:15];         // wnd
    reg  [9:0]  q_p [0:15];         // 载荷字节数 (0 = 纯 ACK)
    reg  [31:0] q_o [0:15];         // 载荷在图案流中的偏移
    reg  [4:0]  q_h, q_t;           // 头/尾指针 (5 位防回绕歧义)
    wire [4:0]  q_n = q_t - q_h;
    // 播放器当前帧参数
    reg  [9:0]  pl_plen;
    reg  [31:0] pl_payofs;
    reg  [15:0] pl_body;            // 帧体字节数 (>= 60)
    wire        pl_isd = (pl_plen != 10'd0);
    // PC 侧图案表 (RTL 约定: 先取 s[31:24] 再推进; 预生成 4096B)
    reg  [7:0]  patmem [0:4095];
    reg  [31:0] pc_txoff;           // 全局载荷偏移 (app_pattern RX LFSR 是全局的)
    reg  [31:0] pc_seq   [0:15];    // 每连接 PC 发送 seq 计数
    integer     pi;

    // 图案载荷字节 (偏移 = pl_payofs + j)
    function [7:0] pay_at;
        input integer j;
        reg [31:0] o;
        begin
            o = pl_payofs + j[31:0];
            pay_at = patmem[o & 32'hFFF];
        end
    endfunction
    function [7:0] ack_byte;
        input [15:0] ix;
        integer pj;
        reg [15:0] tot;
        reg [31:0] s;
        reg [15:0] ics;
        reg [15:0] tcs;
        reg [3:0]  c;
        reg [31:0] sq, ak;
        begin
            c = ack_conn; sq = ack_seq; ak = ack_ack;
            tot = 16'd40 + {6'b0, pl_plen};
            s = 32'h4500 + {16'b0, tot} + 32'h7777 + 32'h0000 + 32'h4006 +
                pc_myip[c][31:16] + pc_myip[c][15:0] +
                pc_peerip[c][31:16] + pc_peerip[c][15:0];
            s = (s & 32'hFFFF) + (s >> 16);
            s = (s & 32'hFFFF) + (s >> 16);
            ics = ~s[15:0];
            s = 32'h0006 + {16'b0, tot - 16'd20} + pc_sport[c] + pc_dport[c] +
                sq[31:16] + sq[15:0] + ak[31:16] + ak[15:0] + 32'h5010 + ack_wnd;
            // 载荷按 16 位字累加 (上界 200B; 生成器保证 plen <= 200)
            for (pj = 0; pj < 200; pj = pj + 2)
                if (pj < pl_plen)
                    s = s + {16'b0, pay_at(pj)} +
                        ((pj + 1) < pl_plen ? {16'b0, pay_at(pj + 1)} : 32'd0);
            s = (s & 32'hFFFF) + (s >> 16);
            s = (s & 32'hFFFF) + (s >> 16);
            tcs = ~s[15:0];
            case (ix)
                // PC -> 板: dst = 板 MAC (00:0A:35:01:FE:C0), src = PC MAC
                6'd0:  ack_byte = 8'h00;   6'd1:  ack_byte = 8'h0A;
                6'd2:  ack_byte = 8'h35;   6'd3:  ack_byte = 8'h01;
                6'd4:  ack_byte = 8'hFE;   6'd5:  ack_byte = 8'hC0;
                6'd6:  ack_byte = pc_mac[c][47:40];
                6'd7:  ack_byte = pc_mac[c][39:32];
                6'd8:  ack_byte = pc_mac[c][31:24];
                6'd9:  ack_byte = pc_mac[c][23:16];
                6'd10: ack_byte = pc_mac[c][15:8];
                6'd11: ack_byte = pc_mac[c][7:0];
                6'd12: ack_byte = 8'h08;   6'd13: ack_byte = 8'h00;
                6'd14: ack_byte = 8'h45;   6'd15: ack_byte = 8'h00;
                6'd16: ack_byte = tot[15:8];  6'd17: ack_byte = tot[7:0];
                6'd18: ack_byte = 8'h77;   6'd19: ack_byte = 8'h77;
                6'd20: ack_byte = 8'h00;   6'd21: ack_byte = 8'h00;
                6'd22: ack_byte = 8'h40;   6'd23: ack_byte = 8'h06;
                6'd24: ack_byte = ics[15:8];  6'd25: ack_byte = ics[7:0];
                6'd26: ack_byte = pc_myip[c][31:24];
                6'd27: ack_byte = pc_myip[c][23:16];
                6'd28: ack_byte = pc_myip[c][15:8];
                6'd29: ack_byte = pc_myip[c][7:0];
                6'd30: ack_byte = pc_peerip[c][31:24];
                6'd31: ack_byte = pc_peerip[c][23:16];
                6'd32: ack_byte = pc_peerip[c][15:8];
                6'd33: ack_byte = pc_peerip[c][7:0];
                6'd34: ack_byte = pc_sport[c][15:8];
                6'd35: ack_byte = pc_sport[c][7:0];
                6'd36: ack_byte = pc_dport[c][15:8];
                6'd37: ack_byte = pc_dport[c][7:0];
                6'd38: ack_byte = sq[31:24]; 6'd39: ack_byte = sq[23:16];
                6'd40: ack_byte = sq[15:8];  6'd41: ack_byte = sq[7:0];
                6'd42: ack_byte = ak[31:24]; 6'd43: ack_byte = ak[23:16];
                6'd44: ack_byte = ak[15:8];  6'd45: ack_byte = ak[7:0];
                6'd46: ack_byte = 8'h50;
                6'd47: ack_byte = pl_isd ? 8'h18 : 8'h10;
                6'd48: ack_byte = ack_wnd[15:8]; 6'd49: ack_byte = ack_wnd[7:0];
                6'd50: ack_byte = tcs[15:8]; 6'd51: ack_byte = tcs[7:0];
                6'd52: ack_byte = 8'h00;     6'd53: ack_byte = 8'h00;
                default: begin
                    if (ix < (16'd54 + {6'b0, pl_plen}))
                        ack_byte = pay_at(ix - 16'd54);
                    else ack_byte = 8'h00;        // 补齐到 60B 最小帧
                end
            endcase
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

    // ---- GMII 接收驱动 (应答播放器) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_d <= 8'h07; rx_dv <= 0; rx_er <= 0;
            ack_i <= 9'd0; ack_pend <= 0; ack_crc <= 32'hFFFFFFFF;
            q_h <= 5'd0; q_t <= 5'd0;
        end else begin
            rx_er <= 1'b0;
            if (ack_i == 9'd0) begin
                rx_d <= 8'h07; rx_dv <= 1'b0;
                if (q_n != 0) begin
                    ack_i     <= 9'd1; ack_crc <= 32'hFFFFFFFF;
                    ack_conn  <= q_c[q_h[3:0]];
                    ack_seq   <= q_s[q_h[3:0]];
                    ack_ack   <= q_a[q_h[3:0]];
                    ack_wnd   <= q_w[q_h[3:0]];
                    pl_plen   <= q_p[q_h[3:0]];
                    pl_payofs <= q_o[q_h[3:0]];
                    // 帧体 = 54 + plen; 不足 60B 补零
                    pl_body   <= ((16'd54 + {6'b0, q_p[q_h[3:0]]}) < 16'd60) ?
                                 16'd60 : (16'd54 + {6'b0, q_p[q_h[3:0]]});
                    q_h       <= q_h + 5'd1;
                    if (dbg_cap)
                        $display("TXACK k=%0d conn=%0d seq=%08x ack=%08x wnd=%04x plen=%0d",
                                 k, q_c[q_h[3:0]], q_s[q_h[3:0]], q_a[q_h[3:0]],
                                 q_w[q_h[3:0]], q_p[q_h[3:0]]);
                end
            end else if (ack_i <= 9'd8) begin
                rx_d  <= (ack_i == 9'd8) ? 8'hD5 : 8'h55;
                rx_dv <= 1'b1;
                ack_i <= ack_i + 9'd1;
            end else if (ack_i <= (9'd8 + pl_body)) begin
                // 字节对齐: rx_d 是寄存器 (驱动拍 k 的字节在 k+1 出现在线上),
                // D5 占 ack_i=8 的驱动拍 (= 线上第 9 拍), 故帧体首字节 = ack_i=9
                // 驱动 ack_byte(0)。原先用 (ack_i-8) 使整帧前移 1 字节 (dst mac
                // 错 -> 板侧 mac_rx 全丢, 实测 rx_stat_pass=0)。
                rx_d  <= ack_byte(ack_i - 9'd9);
                rx_dv <= 1'b1;
                ack_crc <= crc32b(ack_crc, ack_byte(ack_i - 9'd9));
                ack_i <= ack_i + 9'd1;
            end else if (ack_i <= (9'd12 + pl_body)) begin
                // FCS 必须取反后 LSB-first 上线 (crc32b 是"无终值取反"的反射型
                // 更新; 工程约定线上 FCS = ~crc 的小端字节序)。原先漏取反 ->
                // 板侧 mac_rx 全部按 CRC 错丢弃 (实测 stat_drop_crc=3)。
                rx_d  <= ~ack_crc[(ack_i - 9'd9 - pl_body)*8 +: 8];
                rx_dv <= 1'b1;
                ack_i <= ack_i + 9'd1;
                if (ack_i == (9'd12 + pl_body))
                    ack_cnt <= ack_cnt + 16'd1;    // 已发帧数
            end else if (ack_i < (9'd28 + pl_body)) begin
                // 帧间 IFG 必须 >= 12 字节时间 (mac_rx_64 的 IFG 契约); 原先只留
                // 3 拍 -> 背靠背应答被 RX 侧丢弃 = ACK 全丢 -> 窗口闭死
                rx_d <= 8'h07; rx_dv <= 1'b0;
                ack_i <= ack_i + 9'd1;
            end else begin
                ack_i <= 9'd0; rx_d <= 8'h07; rx_dv <= 1'b0;
            end
        end
    end

    // ---- 板侧帧捕获: 数据/FIN 帧 -> 排一条应答 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_en_d <= 0; tx_inf <= 0; txbc <= 0; caplen <= 0;
            frm_data <= 0; frm_fin <= 0; frm_rst <= 0; frm_other <= 0;
            fin_cnt <= 0; fin_seq_first <= 0; fin_seq_last <= 0; ack_cnt <= 0;
            cap_fin <= 0;
            for (ci = 0; ci < 16; ci = ci + 1) pc_hwm[ci] <= 0;
        end else begin
            tx_en_d <= gmii_tx_en;
            if (gmii_tx_en) begin
                if (!tx_en_d) begin tx_inf <= 0; txbc <= 0; caplen <= 0; end
                else if (!tx_inf) begin
                    if (gmii_txd == 8'hD5) tx_inf <= 1;
                end else begin
                    // txbc/caplen 必须饱和 (6 位回绕会把帧尾字节覆写到 cap[0..])
                    if (txbc < 6'd48) cap[txbc] <= gmii_txd;
                    if (caplen < 6'd60) caplen <= caplen + 6'd1;
                    if (txbc < 6'd63) txbc <= txbc + 6'd1;
                end
            end else if (tx_en_d && tx_inf) begin
                if (dbg_cap)
                    $display("CAP k=%0d caplen=%0d eth=%02x%02x ip=%02x fl=%02x sb=%02x%02x/%02x%02x",
                             k, caplen, cap[12], cap[13], cap[23], cap[47],
                             cap[34], cap[35], cap[36], cap[37]);
                if (caplen >= 6'd48 && cap[12] == 8'h08 && cap[13] == 8'h00 &&
                    cap[23] == 8'h06) begin
                    if (cap[47] == 8'h18) begin
                        frm_data <= frm_data + 16'd1;
                        if (q_n < 5'd16 && pc_en[conn_of(cap[34], cap[35],
                                                        cap[36], cap[37])]) begin
                            q_c[q_t[3:0]] <= conn_of(cap[34], cap[35], cap[36], cap[37]);
                            q_s[q_t[3:0]] <= u_tcb.rcv_nxt_r[conn_of(cap[34], cap[35],
                                                                    cap[36], cap[37])];
                            q_a[q_t[3:0]] <= {cap[38], cap[39], cap[40], cap[41]} +
                                             ({16'b0, cap[16], cap[17]} - 32'd40);
                            q_w[q_t[3:0]] <= pc_wnd[conn_of(cap[34], cap[35],
                                                           cap[36], cap[37])];
                            q_p[q_t[3:0]] <= 10'd0;
                            q_o[q_t[3:0]] <= 32'd0;
                            q_t <= q_t + 5'd1;
                            pc_hwm[conn_of(cap[34], cap[35], cap[36], cap[37])] <=
                                {cap[38], cap[39], cap[40], cap[41]} +
                                ({16'b0, cap[16], cap[17]} - 32'd40);
                        end
                    end else if (cap[47] == 8'h11) begin
                        frm_fin <= frm_fin + 16'd1;
                        fin_cnt <= fin_cnt + 16'd1;
                        if (fin_cnt == 16'd0)
                            fin_seq_first <= {cap[38], cap[39], cap[40], cap[41]};
                        fin_seq_last <= {cap[38], cap[39], cap[40], cap[41]};
                        if (q_n < 5'd16 && pc_en[conn_of(cap[34], cap[35],
                                                        cap[36], cap[37])]) begin
                            q_c[q_t[3:0]] <= conn_of(cap[34], cap[35], cap[36], cap[37]);
                            q_s[q_t[3:0]] <= u_tcb.rcv_nxt_r[conn_of(cap[34], cap[35],
                                                                    cap[36], cap[37])];
                            q_a[q_t[3:0]] <= {cap[38], cap[39], cap[40], cap[41]} + 32'd1;
                            q_w[q_t[3:0]] <= pc_wnd[conn_of(cap[34], cap[35],
                                                           cap[36], cap[37])];
                            q_p[q_t[3:0]] <= 10'd0;
                            q_o[q_t[3:0]] <= 32'd0;
                            q_t <= q_t + 5'd1;
                            pc_hwm[conn_of(cap[34], cap[35], cap[36], cap[37])] <=
                                {cap[38], cap[39], cap[40], cap[41]} + 32'd1;
                        end
                    end else if (cap[47] == 8'h14) begin
                        frm_rst <= frm_rst + 16'd1;
                    end else frm_other <= frm_other + 16'd1;
                end else frm_other <= frm_other + 16'd1;
            end
        end
    end

    // 连接归属: 捕获帧 sport == pc_dport[c] && dport == pc_sport[c]
    function [3:0] conn_of;
        input [7:0] sphi, splo, dphi, dplo;
        integer m;
        reg [3:0] r;
        begin
            r = 4'hF;
            for (m = 0; m < 16; m = m + 1)
                if (pc_en[m] && sphi == pc_dport[m][15:8] && splo == pc_dport[m][7:0] &&
                    dphi == pc_sport[m][15:8] && dplo == pc_sport[m][7:0])
                    r = m[3:0];
            conn_of = r;
        end
    endfunction

    // ---- RX 注入字节落盘 (调试: 看 PC 侧真正发出去的帧) ----
    reg [7:0] rxd_buf [0:255];
    reg [7:0] rxd_n;
    reg       rx_dv_d;
    integer   rxdi;
    always @(posedge clk) begin
        rx_dv_d <= rx_dv;
        if (rx_dv) begin
            if (!rx_dv_d) rxd_n <= 8'd1;
            else if (rxd_n != 8'hFF) rxd_n <= rxd_n + 8'd1;
            if (rxd_n < 8'd200) rxd_buf[rxd_n] <= rx_d;
        end else if (rx_dv_d) begin
            if (dbg_cap) begin
                $write("ADVRXD n=%0d", rxd_n);
                for (rxdi = 0; rxdi < 200; rxdi = rxdi + 1)
                    if (rxdi < rxd_n) $write(" %02h", rxd_buf[rxdi]);
                $write("\n");
            end
            rxd_n <= 8'd0;
        end else rxd_n <= 8'd0;
    end

    // ---- resp 落盘 ----
    integer fd;
    integer fbi;
    reg [11:0] fcl;
    reg [7:0]  fcb [0:2047];
    reg        tx_en_dr;
    always @(posedge clk) begin
        if (rst_n) begin
            tx_en_dr <= gmii_tx_en;
            if (gmii_tx_en) begin
                if (!tx_en_dr) fcl <= 12'd1;
                else if (fcl != 12'hFFF) fcl <= fcl + 12'd1;
                if ((!tx_en_dr) || (fcl < 12'd2048))
                    fcb[(!tx_en_dr) ? 12'd0 : fcl] <= gmii_txd;
            end else if (tx_en_dr) begin
                for (fbi = 0; fbi < 2048; fbi = fbi + 1)
                    if (fbi < fcl) $fwrite(fd, "%02h 1\n", fcb[fbi]);
                $fwrite(fd, "00 0\n");
            end
            if (fend) $fwrite(fd, "FEND %0d %0d\n", k, ferr);
            if (ack_req) $fwrite(fd, "ACK %0d %0d %08h\n", k, ack_id, ack_val);
        end
    end

    task snapshot;
        begin
            $fwrite(fd, "ADVSTAT atx_frames=%0d atx_bytes=%0d atx_good=%0d atx_bad=%0d\n",
                    atx_frames, atx_bytes, atx_good_bytes, atx_bad_frames);
            $fwrite(fd, "ADVAPP run=%0d qn=%0d off=%0d len=%0d tid=%0d\n",
                    atx_run, atx_qn, atx_off, atx_len, atx_tid);
            $fwrite(fd, "ADVTX frames=%0d bytes=%0d ack=%0d drop_len=%0d fin=%0d rst=%0d eend=%0d\n",
                    tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_drop_len,
                    tx_stat_fin, tx_stat_rst, tx_stat_eend);
            $fwrite(fd, "ADVFRM data=%0d fin=%0d rst=%0d other=%0d ackcnt=%0d\n",
                    frm_data, frm_fin, frm_rst, frm_other, ack_cnt);
            $fwrite(fd, "ADVSTAT2 scfg_add=%0d scfg_del=%0d ev_up=%0d ev_down=%0d ev_drop=%0d\n",
                    scfg_add, scfg_del, ac_ev_up_c, ac_ev_down_c, ac_ev_drop);
            for (ci = 0; ci < 16; ci = ci + 1)
                if (ci < 4)
                    $fwrite(fd, "ADVTCB %0d %08h %08h %08h %04h %04h %0d %04h\n",
                            ci, u_tcb.rcv_nxt_r[ci], u_tcb.snd_nxt_r[ci],
                            u_tcb.snd_una_r[ci], u_tcb.rcv_wnd_r[ci],
                            u_tcb.snd_wnd_r[ci], u_tcb.state_r[ci],
                            tx_fin_sent[ci]);
            $fwrite(fd, "ADVRDY %04h fin1=%08h finN=%08h nfin=%0d qn=%0d\n",
                    app_tx_ready, fin_seq_first, fin_seq_last, fin_cnt, q_n);
            $fwrite(fd, "ADVDBG txst=%0d plen=%0d plen_r=%0d wndopen=%0d srdy=%0d sav=%0d pem=%0d pf=%0d sndwnd=%04h finreq=%04h finsent=%04h\n",
                    dbg_txstate, dbg_plen, dbg_plen_r, dbg_wnd_open, dbg_sready,
                    dbg_saxis_tvalid, dbg_pay_empty, dbg_pay_full,
                    u_tcb.snd_wnd_r[0], ac_fin_req, tx_fin_sent);
            dump_reg(8'h00);
            dump_reg(8'h07);
            dump_reg(8'h09);
            dump_reg(8'h90);
            dump_reg(8'h91);
            dump_reg(8'h92);
            dump_reg(8'h93);
            dump_reg(8'h94);
            dump_reg(8'h10);
            dump_reg(8'h11);
            dump_reg(8'h12);
            dump_reg(8'h13);
            dump_reg(8'h14);
            dump_reg(8'h15);
            dump_reg(8'h16);
            dump_reg(8'h17);
            $fwrite(fd, "ADVMDROP %0d\n", mac_stat_drop);
            $fwrite(fd, "ADVMAC frames=%0d abort=%0d\n",
                    mac_stat_frames, mac_stat_abort);
            $fwrite(fd, "ADVRX7 pass=%0d nonmatch=%0d ipcsum=%0d crc=%0d seq=%0d ack=%0d bytes=%0d trunc=%0d\n",
                    rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                    rx_stat_seq, rx_stat_ack, rx_stat_bytes, rx_stat_trunc);
            // P5b 必修4: 暴露编译进 DUT 的接受裕度 (与 u_rx 端口同一 localparam),
            // checker 用它断言 "接受裕度 <= 物理余量" + "TB 镜像 == wrapper"
            $fwrite(fd, "ADVCFG acc_margin=%0d\n", TB_ACC_MARGIN);
        end
    endtask

    task dump_reg;
        input [7:0] a;
        begin
            @(posedge clk); ac_addr <= a;
            @(posedge clk);
            $fwrite(fd, "ADVREG %0d %08h\n", a, ac_rdata);
        end
    endtask

    task cfg_record;
        input [31:0] w0, w1, w2, w3, w4, w5, w6, w7;
        begin
            @(posedge clk); cfg_tdata <= w0; cfg_tvalid <= 1'b1;
            @(posedge clk); cfg_tdata <= w1;
            @(posedge clk); cfg_tdata <= w2;
            @(posedge clk); cfg_tdata <= w3;
            @(posedge clk); cfg_tdata <= w4;
            @(posedge clk); cfg_tdata <= w5;
            @(posedge clk); cfg_tdata <= w6;
            @(posedge clk); cfg_tdata <= w7;
            @(posedge clk); cfg_tvalid <= 1'b0;
            repeat (24) @(posedge clk);
        end
    endtask

    task reg_write;
        input [7:0] a;
        input [31:0] d;
        begin
            @(posedge clk); ac_addr <= a; ac_wdata <= d; ac_wr <= 1'b1;
            @(posedge clk); ac_wr <= 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    task app_push;                    // 追加 a 帧到队列 (累加, 每帧 b 字节)
        input [31:0] n;
        input [15:0] len;
        input [3:0]  tid;
        input        sel;
        input        badf;
        begin
            // 累加语义: 连续多条 op5 必须排队 (绝对赋值会把前面的帧覆盖掉 ->
            // 只推最后 1 帧, 脚本等 3 帧上线就会挂死)
            atx_qn <= atx_qn + n; atx_qlen <= len;
            atx_qtid <= tid; atx_qsel <= sel; atx_qbad <= badf;
        end
    endtask

    // ---- 脚本 ----
    integer sfd, scode, sa, sb, sc, sd, se, sf, sg, sh, si;
    reg [255:0] sline;
    integer sret;
    reg [31:0] sw0, sw1, sw2, sw3, sw4, sw5, sw6, sw7;
    reg [31:0] wt0;

    initial begin
        clk = 0; rst_n = 0;
        cfg_tdata = 0; cfg_tvalid = 0;
        ac_addr = 8'h00; ac_wr = 0; ac_wdata = 0;
        atx_qn = 0; atx_run = 0; atx_off = 0; atx_len = 0;
        atx_tid = 0; atx_sel = 0; atx_bad = 0; atx_state = P5_SEED;
        tmo = 0; k = 0; pc_txoff = 0;
        pl_plen = 0; pl_payofs = 0; pl_body = 16'd60;
        for (ci = 0; ci < 16; ci = ci + 1) begin
            cfg_rcv_nxt[ci] = 32'h20000001; cfg_snd_nxt[ci] = 32'h12345679;
            pc_en[ci] = 0; pc_wnd[ci] = 16'h4000;
            pc_sport[ci] = 16'h3039; pc_dport[ci] = 16'h1F90;
            pc_peerip[ci] = TB_PEER_IP; pc_myip[ci] = TB_MY_IP;
            pc_mac[ci] = TB_PEER_MAC; pc_hwm[ci] = 0;
            pc_seq[ci] = PEER_ISN + 32'd1;
        end
        begin : pat_init
            reg [63:0] ps;
            ps = P5_SEED;
            for (pi = 0; pi < 4096; pi = pi + 1) begin
                patmem[pi] = ps[31:24];
                ps = xs_next(ps);
            end
        end
        fd = $fopen("resp_p5_adv.memh", "w");
        #200; rst_n = 1;
        repeat (200) @(posedge clk);
        sfd = $fopen("adv_cmds.memh", "r");
        if (sfd == 0) begin
            $display("P5ADV FATAL: adv_cmds.memh 打开失败");
            $finish;
        end
        while (!$feof(sfd)) begin
            sret = $fscanf(sfd, "%d %d %d %d %d %d %d %d %d %d\n",
                           scode, sa, sb, sc, sd, se, sf, sg, sh, si);
            if (sret == 10) begin
                $fwrite(fd, "ADVCMD %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                        scode, sa, sb, sc, sd, se, sf, sg, sh, si);
                case (scode)
                    1: repeat (sa) @(posedge clk);
                    2: begin wt0 = 0; while (frm_data < sa && wt0 < TMO_OP)
                              begin @(posedge clk); wt0 = wt0 + 1; end
                              if (frm_data < sa) begin tmo = 1;
                                  $fwrite(fd, "ADVTO op2 want=%0d\n", sa); end end
                    3: begin wt0 = 0; while (frm_fin < sa && wt0 < TMO_OP)
                              begin @(posedge clk); wt0 = wt0 + 1; end
                              if (frm_fin < sa) begin tmo = 1;
                                  $fwrite(fd, "ADVTO op3 want=%0d\n", sa); end end
                    13: begin wt0 = 0; while (frm_rst < sa && wt0 < TMO_OP)
                              begin @(posedge clk); wt0 = wt0 + 1; end
                              if (frm_rst < sa) begin tmo = 1;
                                  $fwrite(fd, "ADVTO op13 want=%0d\n", sa); end end
                    14: begin wt0 = 0; while (atx_frames < sa && wt0 < TMO_OP)
                              begin @(posedge clk); wt0 = wt0 + 1; end
                              if (atx_frames < sa) begin tmo = 1;
                                  $fwrite(fd, "ADVTO op14 want=%0d\n", sa); end end
                    15: begin wt0 = 0;
                              // 上限 = 参数 a (此前误用 TMO_OP=24M, 卡死时要烧 24M 拍)
                              while ((atx_qn != 0 || atx_run) && wt0 < sa)
                              begin @(posedge clk); wt0 = wt0 + 1; end
                              if (atx_qn != 0 || atx_run) begin tmo = 1;
                                  $fwrite(fd, "ADVTO op15\n"); end end
                    4: begin   // CFG 记录
                        // w0=(wscale<<16)|(cmd<<8)|slot; w1=peer_ip; w2=local_ip;
                        // w3=(peer_port<<16)|local_port; w4=peer_mac[47:16];
                        // w5=(peer_mac[15:0]<<16)|peer_wnd; w6=rcv_nxt; w7=snd_nxt
                        // w0 = (wscale<<16) | (cmd<<8) | slot — cmd 必须带上!
                        // (原先少打 cmd 字段: 所有 DEL 记录被当成 ADD, 同槽重连
                        //  用例从未真正删连 -> fin_sent_r 当然不清)
                        sw0 = {12'b0, sc[3:0], 4'b0, sb[3:0], 4'b0, sa[3:0]};
                        sw1 = sd; sw2 = se;
                        sw3 = sf;
                        sw4 = {sg[15:0], sh[31:16]};     // peer_mac[47:16]
                        sw5 = {sh[15:0], si[15:0]};      // {peer_mac[15:0], peer_wnd}
                        sw6 = cfg_rcv_nxt[sa[3:0]];
                        sw7 = cfg_snd_nxt[sa[3:0]];
                        cfg_record(sw0, sw1, sw2, sw3, sw4, sw5, sw6, sw7);
                    end
                    18: begin
                        cfg_rcv_nxt[sa[3:0]] = sb;
                        cfg_snd_nxt[sa[3:0]] = sc;
                    end
                    5: begin
                        // 必须隔一个时钟沿: 同一时间步内多条 op5 的 NBA 会互相覆盖
                        // (atx_qn <= atx_qn + n 三次都读到同一个旧值)
                        app_push(sa, sb[15:0], sc[3:0], sd[0], se[0]);
                        @(posedge clk);
                    end
                    6: begin pc_en[sa[3:0]] = (sb != 0); end
                    7: begin reg_write(sa[7:0], sb); end
                    8: begin dump_reg(sa[7:0]); end
                    9: begin pc_wnd[sa[3:0]] = sb[15:0]; end
                    10: begin
                        // 手工注入: b=ack 增量, c=载荷字节 (0=纯 ACK; 数据帧 seq=pc_seq)
                        q_c[q_t[3:0]] <= sa[3:0];
                        q_s[q_t[3:0]] <= (sc == 0) ? u_tcb.rcv_nxt_r[sa[3:0]] :
                                         pc_seq[sa[3:0]];
                        q_a[q_t[3:0]] <= pc_hwm[sa[3:0]] + sb;
                        q_w[q_t[3:0]] <= pc_wnd[sa[3:0]];
                        q_p[q_t[3:0]] <= sc[9:0];
                        q_o[q_t[3:0]] <= pc_txoff;
                        q_t <= q_t + 5'd1;
                        if (sc != 0) begin
                            pc_seq[sa[3:0]] = pc_seq[sa[3:0]] + sc;
                            pc_txoff = pc_txoff + sc;
                        end
                        repeat (140) @(posedge clk);
                    end
                    17: begin pc_seq[sa[3:0]] = sb; end
                    19: begin dbg_cap <= sa[0]; end
                    11: begin
                        pc_sport[sa[3:0]] = sb[15:0];
                        pc_dport[sa[3:0]] = sc[15:0];
                        pc_peerip[sa[3:0]] = sd;
                        pc_myip[sa[3:0]]  = se;
                        pc_mac[sa[3:0]]   = {sf[15:0], sg[31:0]};   // 48 位
                        pc_wnd[sa[3:0]]   = sh[15:0];
                        pc_en[sa[3:0]]    = (si != 0);
                    end
                    12: begin snapshot; end
                    16: begin atx_qn <= 0; atx_run <= 1'b0; end
                    default: ;
                endcase
            end
            if (k > K_MAX) begin
                $fwrite(fd, "ADVTO global k=%0d\n", k);
                $display("P5ADV TIMEOUT k=%0d", k);
                sret = 0;   // 退出循环
                sfd = 0;
            end
        end
        if (sfd != 0) $fclose(sfd);
        repeat (2000) @(posedge clk);
        snapshot;
        $fclose(fd);
        $display("P5ADV DONE: data=%0d fin=%0d rst=%0d drop_len=%0d eend=%0d atx_fr=%0d atx_by=%0d good=%0d tmo=%0d",
                 frm_data, frm_fin, frm_rst, tx_stat_drop_len, tx_stat_eend,
                 atx_frames, atx_bytes, atx_good_bytes, tmo);
        $finish;
    end

    // 周期计数
    always @(posedge clk) begin
        if (rst_n) k <= k + 1; else k <= 0;
        // 进度迹 (每 262144 拍一行; 长 WAIT 时用于定位卡点)
        if (rst_n && (k[17:0] == 18'd0))
            $display("AT %0d k=%0d frmD=%0d frmF=%0d txst=%0d atx(run=%0d qn=%0d off=%0d len=%0d tv=%0d tr=%0d) app2v=%0d rdy=%h drop=%0d",
                     $time, k, frm_data, frm_fin, u_tx.state, atx_run, atx_qn,
                     atx_off, atx_len, atx_tvalid, atx_tready, app2_tvalid,
                     app_tx_ready, tx_stat_drop_len);
        if (rst_n && (k[17:0] == 18'd0))
            $display("AT2 ackcnt=%0d qn=%0d rxp=%0d rxa=%0d su=%08x sn=%08x rn=%08x infl=%0d",
                     ack_cnt, q_n, rx_stat_pass, rx_stat_ack,
                     u_tcb.snd_una_r[0], u_tcb.snd_nxt_r[0], u_tcb.rcv_nxt_r[0],
                     u_tcb.snd_nxt_r[0] - u_tcb.snd_una_r[0]);
        if (rst_n && (k[17:0] == 18'd0))
            $display("AT3 txs=%0d plen=%0d plen_r=%0d wndopen=%0d srdy=%0d sav=%0d pem=%0d pf=%0d appfr=%0d appby=%0d",
                     dbg_txstate, dbg_plen, dbg_plen_r, dbg_wnd_open, dbg_sready,
                     dbg_saxis_tvalid, dbg_pay_empty, dbg_pay_full,
                     atx_frames, atx_bytes);
    end

    always #4 clk = ~clk;

endmodule
