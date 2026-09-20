`timescale 1ns/1ps
//=============================================================================
// tb_p5_multi: P5d D5 —— **多连接并发门** (信用分池 + 动态接受裕度 + 并发关闭)
//
// 被测的三条 P5d 修法:
//   D4  分池: app 在建连**之前**写 app_ctrl 寄存器 0x0C = WIN_POOL/N ⇒ 每条连接
//       的上限 = WIN_POOL/N (窗口不可撤销 ⇒ 必须预分配)。
//   H-fix 接受裕度按 ESTAB 数动态缩 (wrapper 查表 + 寄存器化, TB 侧镜像同一张表)。
//   D5  本门 (3 连接并发大流量 + 并发 close)。
//
// 骨架 = tb/tb_p5_adv.v (P5a 对抗集, 复制再改; 原文件不动)。相对骨架的改动:
//   ① 3 条真实连接 (conn0/1/2, 各自 ip/port/mac/ISN), 不是"2 条 + 1 条零配额"。
//   ② PC 侧从"只应答"升级为 **TCP 对端注水机**: 每连接持续发 L 字节数据段,
//      遵守"对端相信的通告窗" (in_flight < 板侧帧里见到的 window) —— 与真实协议栈
//      同规则 ⇒ 自然激励出 C1b 的通告漂移 Δ。停滞 STALL_LIM 拍后按最后一次 ACK
//      回卷重传 (go-back-N)。
//   ③ app RX 侧 = **可编程慢消费者** (op 22 控 RATE; 0 = 完全停) ⇒ 把零拷贝
//      frame_fifo 顶起来, 逼出窗口收缩/重开闭环 (单连接版见 flow 门)。
//   ④ 逐拍不变量断言 (池守恒 / 分池上限 / 物理界) + 每连接 FIN/RST 计数 +
//      FIN 的 dst MAC 核对 ⇒ 判据全部落盘给 checker (tools/gen_stim_p5_multi.py)。
//
// 与 tb_p5_adv 的关键区别: **板侧 app TX 全程空闲** (不推 op 5) ⇒ 板侧线上只有
// 纯 ACK / FIN / RST。这样 PC 模型只需"注水 + 观测", 不需要应答数据帧的复杂度,
// 判据也更干净 (FIN 计数不含慢路径/重传噪声)。
//
// 脚本 multi_cmds.memh: 每行 10 个十进制整数 (op a b c d e f g h i)
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
//   op 10 PC 手工注入: a=conn b=ack 增量 c=载荷字节 (0=纯 ACK)
//   op 11 PC 连接表: a=conn b=sport c=dport d=peer_ip e=my_ip f=mac_hi
//         g=mac_lo h=wnd i=en
//   op 12 落盘快照
//   op 13 WAIT 直到板侧 RST 帧数 >= a
//   op 14 WAIT 直到 app 已消费帧数 >= a
//   op 15 WAIT 直到 s_axis 空 (所有已推帧被消费) 上限 a 拍
//   op 16 APP 清空 (丢弃当前帧)
//   op 17 PC 连接 seq 基: a=conn b=seq
//   op 18 CFG seq: a=slot b=rcv_nxt c=snd_nxt
//   op 20 FLOOD 预算: a=conn b=字节数 (累加到该连接的可发预算)
//   op 21 WAIT 直到"静默": 所有连接预算耗尽 && 无在队帧 && 每连接 pc_seq == 板侧
//         rcv_nxt (即已发全部被接受), 上限 a 拍
//   op 22 SINK 消费率: a = 每 a 拍消费 1 字 (a=0 = 完全停; a=1 = 每拍 1 字)
//   op 23 WAIT 直到 sink 已消费字节 >= a
//   op 24 WAIT 直到 3 连接已发送字节合计 >= a
//   op 25 WAIT 直到"洪水结束": 预算耗尽 && 在队空 && 已发 == 已接受, 上限 a 拍
//=============================================================================
module tb_p5_multi;
    // ---- 3 连接身份 (conn c: c=0/1/2) ----
    // 板侧 ISS = 0x12345678 + c*0x1000;  对端 ISN = 0x20000000 + c*0x100000
    // 端口 = 0x1F90+c (板) / 0x3039+c (PC);  IP = C0A86402+c (板) / C0A86401+c
    localparam integer NCONN     = 3;
    localparam [31:0] TB_ISS      = 32'h12345678;
    localparam [31:0] TB_MY_IP    = 32'hC0A86402;
    localparam [63:0] P5_SEED      = 64'h9E3779B97F4A7C15;
    // 全局拍上限: 本门是大流量门 —— 预算 3x24576B + 慢消费者 ⇒ 拍数量级 1e5~1e6。
    // K_MAX 只作"死锁兜底" (异常时快速失败, 不要烧 24M 拍); 各 op 自带更小上限。
    localparam [31:0] K_MAX        = 32'd8_000_000;    // 全局死锁上限 (拍)
    localparam [31:0] TMO_OP       = 32'd2_000_000;    // 单 op 上限 (拍)
    localparam [31:0] FL_SEG       = 32'd1024;         // 注水段长 (字节; <= 1460)
    localparam [31:0] FL_STALL_LIM = 32'd30000;        // 停滞多久后按最后 ACK 回卷重传
    // ---- 信用分池 (D4) / 动态接受裕度 (H-fix) 的常量 ----
    localparam [15:0] TB_WIN_POOL  = 16'hC000;                 // app_ctrl.WIN_POOL
    localparam [15:0] TB_WQ_CAP    = TB_WIN_POOL / NCONN;      // = 0x4000 (16384)
    localparam [31:0] TB_FIFO_BYTES= 32'd65536;                // frame_fifo 8192 字 x 8B
    localparam [15:0] TB_DELTA     = 16'd2816;                 // C1b 的 1G Δ 上界
    localparam [15:0] TB_U_FRM     = 16'd1518;                 // 未判定帧 (54+1460+4)
    localparam [15:0] TB_SEG_MAX   = 16'd1500;                 // PLEN_MAX: 一段可整段被接受
    // ---- H-fix 镜像: 与 board/wrapper_p4.v 的 acc_margin_of 同表 (checker 静态比对) ----
    // N<=2 ⇒ 4096 (= 旧常量, 零回归); N=3 ⇒ 10550/3 = 3516; N>=4 ⇒ 钳 3328 (= Δ+512)。
    // 10550 = 65536 - WIN_POOL(49152) - Δ(2816) - U(1518) - SEG_MAX(1500)。
    function [15:0] acc_margin_of;
        input [4:0] n;
        begin
`ifdef P5D_NEG_MGN
            acc_margin_of = 16'd4096;      // 负向对照: 强制旧常量 (N=3 时超物理界 1738B)
`elsif P5D_NEG_MGN0
            acc_margin_of = 16'd0;         // 负向对照: 裕度关掉 (漂移判据必须响)
`else
            if (n <= 5'd2)      acc_margin_of = 16'd4096;
            else if (n == 5'd3) acc_margin_of = 16'd3516;
            else                acc_margin_of = 16'd3328;
`endif
        end
    endfunction

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
    // tkeep 合法性 (高连续掩码; 空字 0x00 非法) —— 同 tb_app_sink.v 的判据
    function ka_ok8;
        input [7:0] k;
        begin
            ka_ok8 = (k == 8'hFF) || (k == 8'hFE) || (k == 8'hFC) || (k == 8'hF8) ||
                     (k == 8'hF0) || (k == 8'hE0) || (k == 8'hC0) || (k == 8'h80);
        end
    endfunction
    // 字内第 i 字节 (i=0 为 tdata[63:56], 本工程 MAC 字流约定)
    function [7:0] byte_at8;
        input [63:0] d;
        input [3:0]  i;
        begin
            case (i)
                4'd0: byte_at8 = d[63:56];
                4'd1: byte_at8 = d[55:48];
                4'd2: byte_at8 = d[47:40];
                4'd3: byte_at8 = d[39:32];
                4'd4: byte_at8 = d[31:24];
                4'd5: byte_at8 = d[23:16];
                4'd6: byte_at8 = d[15:8];
                default: byte_at8 = d[7:0];
            endcase
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
    wire [15:0] ac_estab_cnt;        // app_ctrl.dbg_estab_cnt (H-fix 裕度的输入)
    wire [16:0] ac_pool;             // app_ctrl.dbg_pool (池守恒断言用)
    reg         tmo;                 // 脚本 WAIT 超时标志

    // =====================================================================
    // H-fix 镜像: 接受裕度 = min(4096, 10550/ESTAB数), 查表 + 打一拍寄存器
    // =====================================================================
    // **与 board/wrapper_p4.v 的 acc_margin_of 同式** —— checker 会静态解析两边
    // 的表项并比对 (C12: 板级配置必须被门逐位镜像)。N=3 是旧常量 4096 唯一出错的
    // 区间 (3*4096 = 12288 > 10550 ⇒ 超物理界 1738B), 也是本门存在的理由。
    wire [4:0]  tb_am_n   = (ac_estab_cnt[4:0] == 5'd0) ? 5'd1 : ac_estab_cnt[4:0];
    reg  [15:0] tb_am_eff;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tb_am_eff <= 16'd4096;
        else        tb_am_eff <= acc_margin_of(tb_am_n);
    end

    // =====================================================================
    // 注水机 (PC 侧 TCP 对端发送模型) + 逐拍不变量断言
    // =====================================================================
    // 每连接的发送规则 (真实协议栈同规则):
    //   in_flight = pc_seq[c] - pc_ack_seen[c]   (已发未确认)
    //   room      = 对端相信的通告窗 pc_wnd_seen[c] - in_flight
    //   段长 L    = min(FL_SEG, room, 剩余预算)
    //   L >= 1 ⇒ 可发 (每拍只推一帧进播放队列; 播放器 1 帧 ~1520 拍 ⇒ 天然限速)
    // 停滞 (room==0 或预算 0) 连续 FL_STALL_LIM 拍且仍有在飞 ⇒ 按最后一次 ACK
    // 回卷重传 (go-back-N; 覆盖"段被拒"与"窗口重开后 ACK 丢失"两种情形)。
    // pc_wnd_seen/pc_ack_seen 都来自**板侧线上帧** (捕获块更新) ⇒ 这是货真价实的
    // "对端视角", 通告漂移 Δ 由捕获/ACK 延迟自然产生 (C1b 的物理来源)。
    reg  [31:0] fl_budget  [0:15];   // 剩余可发字节
    reg  [31:0] fl_seg     [0:15];   // 本拍选中的段长
    reg  [31:0] fl_stall   [0:15];
    reg  [31:0] pc_ack_seen[0:15];   // 板侧帧里见到的最大 ack (= 板侧 rcv_nxt)
    reg  [15:0] pc_wnd_seen[0:15];   // 板侧帧里见到的 window 字段
    reg  [31:0] fl_rewind;           // 回卷重传次数 (判据: 正常工作应 == 0)
    reg  [31:0] fl_tx_frames;        // 注水帧数
    reg  [31:0] fl_tx_bytes;         // 注水字节数 (合计; 单调, 不受回卷影响)
    reg  [3:0]  fl_rr;               // 轮转起点
    reg  [15:0] fl_can;              // 本拍可发位图
    reg  [31:0] fl_room_c  [0:15];
    integer     fi;

    // ---- 逐拍不变量 (违反即计数; checker 断言计数为 0, 并打印首次现场) ----
    reg  [31:0] inv_pool_bad;        // Σwinq + pool != WIN_POOL
    reg  [31:0] inv_cap_bad;         // 某连接 winq > WIN_POOL/N (分池上限)
    reg  [31:0] inv_phys_bad;        // occ + Σwinq + N*margin + Δ + U + SEG_MAX > 65536
    reg  [31:0] inv_burst_bad;       // occ + Σ通告窗 > 65536 (字面判据 ④)
    reg  [31:0] inv_phys_tran_bad;   // 建连瞬态 (裕度未收敛) 的违反 — 只报告
    reg  [31:0] inv_real_bad;        // 物理界 (接受界推导) 违反次数
    reg  [31:0] inv_real_max;        // 物理界峰值 (留证: 离 65536 有多远)
    reg  [31:0] inv_first_k;         // 首次违反的拍号 (0 = 无)
    reg  [17:0] sum_winq;            // Σ winq[c] (全 16 槽)
    reg  [17:0] sum_wnd_e;           // Σ 通告窗 (仅 ESTAB 槽)
    reg  [4:0]  n_estab_c;           // 板侧 ESTAB 数 (由 state_r 数出)
    reg  [31:0] winq_rem;            // Σ 当前应然窗 = Σ max(0, winq_c - occ)
    reg  [15:0] wq_cap_now;          // 被测的 wq_cap_r (寄存器回读)
    reg  [31:0] occ_max;             // occ 峰值 (物理界的实测证据)
    reg  [15:0] winq_min;            // winq[0] 最小值 (分池判据 ①)
    integer     ii;
    reg  [17:0] inv_tmp;

    always @(*) begin
        sum_winq = 18'd0; sum_wnd_e = 18'd0; n_estab_c = 5'd0; winq_rem = 32'd0;
        for (ii = 0; ii < 16; ii = ii + 1) begin
            sum_winq = sum_winq + {2'b0, u_app_ctrl.winq[ii]};
            if (u_tcb.state_r[ii] == 4'd1) begin
                sum_wnd_e = sum_wnd_e + {2'b0, u_tcb.rcv_wnd_r[ii]};
                n_estab_c = n_estab_c + 5'd1;
                // 当前"应然"窗 = max(0, winq - occ) (与 app_ctrl 的 fq_calc 同式)
                winq_rem = winq_rem +
                           ((u_app_ctrl.winq[ii] > rx_occ) ?
                            ({16'b0, u_app_ctrl.winq[ii]} - {15'b0, rx_occ}) : 32'd0);
            end
        end
    end

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
        //  <= 物理余量"判据的**唯一绑定点** (checker 断言 MULCFG 行的 acc_margin
        //  <= 物理预算, 见 tools/gen_stim_p5_adv.py 的 ACC_BUDGET; 该 checker 按
        //  文本解析 `.ACC_MARGIN` 行 ⇒ 端口名保持大写, 见 rtl/tcp_rx.v 注释)。
        //  改这里 = 改 DUT 配置, 门会当场响。)
        .ACC_MARGIN(tb_am_eff),
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
        .dbg_estab_cnt(ac_estab_cnt), .dbg_ev_cnt(),
        .dbg_redge0(), .dbg_winq0(), .dbg_wu_mark0(), .dbg_pool(ac_pool),
        .stat_wu(), .stat_pool_exhaust()
    );

    // =====================================================================
    // app RX 侧: **可编程慢消费者** (op 22 控 RATE) —— 把零拷贝 frame_fifo 顶起来
    // =====================================================================
    // 语义: 每 RATE 拍消费 1 个 64 位字 (= 8 字节)。RATE=0 ⇒ 完全停 (窗口必收缩);
    // RATE=1 ⇒ 8B/拍 = 1GB/s (远大于线速, 快速排空); RATE=8 ⇒ 1B/拍 ≈ 1G 线速的一半。
    // 顺带做数据完整性检查 (P5d 简化版, 但**不是**静默放宽):
    //   ① tkeep 必须是高连续掩码; ② 空字 (tvalid && tkeep==0) 计数;
    //   ③ 逐连接 (tid) 字节流连续性: 载荷由注水机按 `byte = BASE_c + 流偏移` 生成 ⇒
    //      sink 侧对每个 tid 维护"期望的下一个字节值", 不连续即计数 (丢/重/串连接)。
    //      注意: 值域只有 256 ⇒ 只能抓非 256 倍数的缺口; 字节总数守恒由 CHECK 里
    //      "sink 字节 + occ == 板侧 rcv_nxt 推进量" 的**逐连接**对账另行覆盖。
    reg  [31:0] sink_rate;                // 每 sink_rate 拍消费 1 字 (0 = 停)
    reg  [31:0] sink_cyc;
    reg  [31:0] sink_bytes [0:15];        // 逐 tid 已消费字节
    reg  [7:0]  sink_exp   [0:15];        // 逐 tid 期望的下一个字节值
    reg  [31:0] sink_mismatch [0:15];
    reg  [31:0] sink_kaerr, sink_evfrm, sink_words;
    reg  [31:0] sink_mm_ev;
    reg  [7:0]  SINIT;                    // 期望初值 (常量, 见下 BASE 定义)
    wire        sink_cons = eco2_tvalid && eco2_tready;
    wire [3:0]  sink_nk   = pop8(eco2_tkeep);
    integer     sbi, smi;
    reg [7:0]   sink_got;
    reg [3:0]   sink_mmw;            // 本字失配字节数 (循环内累加, 出循环一次 NBA:
                                     // 循环里直接对 sink_mismatch 做 NBA 只落最后一次)
    // 每连接载荷基值 (注水机同源: 第 c 连接第 k 字节 = (BASE_c + k))
    function [7:0] pay_base;
        input [3:0] c;
        begin
            pay_base = 8'h10 + {c, 4'd0};    // conn0=0x10, conn1=0x20, conn2=0x30 ...
        end
    endfunction
    function [7:0] pay_byte;                 // 连接 c 的流偏移 k 处的字节值
        input [3:0]  c;
        input [31:0] k;
        begin
            pay_byte = pay_base(c) + k[7:0];
        end
    endfunction

    assign eco2_tready = (sink_rate != 32'd0) && (sink_cyc == 32'd0);
    assign rx_occ = {(eco_wptr - eco_rptr), 3'b0};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // sink_rate 的复位与写入统一由"分级非阻塞落地"块负责 (单一写者)
            sink_cyc <= 32'd0;
            sink_kaerr <= 32'd0; sink_evfrm <= 32'd0; sink_words <= 32'd0;
            sink_mm_ev <= 32'd0;
            for (sbi = 0; sbi < 16; sbi = sbi + 1) begin
                sink_bytes[sbi] <= 32'd0; sink_exp[sbi] <= pay_base(sbi[3:0]);
                sink_mismatch[sbi] <= 32'd0;
            end
        end else begin
            if (sink_cyc != 32'd0) sink_cyc <= sink_cyc - 32'd1;
            if (sink_cons) begin
                sink_cyc   <= (sink_rate == 32'd0) ? 32'd0 : (sink_rate - 32'd1);
                sink_words <= sink_words + 32'd1;
                // 逐字诊断 (前 24 字): 帧边界/tid/有效字节/首字节 —— 判"跨连接串扰"
                // 还是"同连接内 8 字节错位"
                if (sink_words < 32'd24)
                    $display("SINKW k=%0d w=%0d tid=%0d nk=%0d last=%0d fst=%02x exp=%02x",
                             k, sink_words, eco2_tid, sink_nk, eco2_tlast,
                             byte_at8(eco2_tdata, 4'd0), sink_exp[eco2_tid]);
                sink_bytes[eco2_tid] <= sink_bytes[eco2_tid] + {28'b0, sink_nk};
                if (!ka_ok8(eco2_tkeep)) sink_kaerr <= sink_kaerr + 32'd1;
                if (sink_nk == 4'd0)     sink_evfrm <= sink_evfrm + 32'd1;
                sink_mmw = 4'd0;
                for (smi = 0; smi < 8; smi = smi + 1) begin
                    if (smi < sink_nk) begin
                        sink_got = byte_at8(eco2_tdata, smi[3:0]);
                        // 期望值必须**字内推进** (字首期望 + 字内偏移): 用寄存器值比
                        // 字内每个字节会让第 2..n 字节恒失配 (实测假失配 9216)
                        if (sink_got != (sink_exp[eco2_tid] + smi[7:0])) begin
                            sink_mmw = sink_mmw + 4'd1;
                            if (sink_mm_ev < 32'd8) begin
                                $display("SINKMM k=%0d tid=%0d byte=%0d word=%0d exp=%02x got=%02x",
                                         k, eco2_tid, sink_bytes[eco2_tid] + smi[31:0],
                                         sink_words, sink_exp[eco2_tid] + smi[7:0], sink_got);
                                sink_mm_ev <= sink_mm_ev + 32'd1;
                            end
                        end
                    end
                end
                if (sink_mmw != 4'd0)
                    sink_mismatch[eco2_tid] <= sink_mismatch[eco2_tid] +
                                               {28'b0, sink_mmw};
                sink_exp[eco2_tid] <= sink_exp[eco2_tid] + sink_nk;
            end
        end
    end

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
    // P5d 判据 ⑤: 逐连接 FIN/RST 计数 + FIN 帧的 dst/src MAC 核对 (互不串扰)
    reg  [15:0] frm_fin_c [0:15];
    reg  [15:0] frm_rst_c [0:15];
    reg  [15:0] frm_fin_macbad, frm_fin_smacbad;
    wire [3:0]  cx = conn_of(cap[34], cap[35], cap[36], cap[37]);
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
    // P5d: 载荷最长 1460B ⇒ 帧长 (28+54+1460) = 1542 拍 > 511 ⇒ 必须 12 位
    // (9 位在 payload > ~480B 时回绕: 帧后半段错位 = FCS 错 + 板侧按乱序丢)
    reg  [11:0] ack_i;
    reg  [31:0] ack_crc;
    // 待发帧队列 (16 深): 板侧一个窗口内可连续出多帧, 播放器追不上时不能丢
    reg  [3:0]  q_c [0:15];         // 连接
    reg  [31:0] q_s [0:15];         // seq
    reg  [31:0] q_a [0:15];         // ack
    reg  [15:0] q_w [0:15];         // wnd
    reg  [10:0] q_p [0:15];         // 载荷字节数 (0 = 纯 ACK; <=1460 ⇒ 11 位)
    reg  [31:0] q_o [0:15];         // 载荷在图案流中的偏移
    reg  [4:0]  q_h, q_t;           // 头/尾指针 (5 位防回绕歧义)
    wire [4:0]  q_n = q_t - q_h;
    // 播放器当前帧参数
    reg  [10:0] pl_plen;
    reg  [31:0] pl_payofs;
    reg  [15:0] pl_body;            // 帧体字节数 (>= 60)
    wire        pl_isd = (pl_plen != 11'd0);
    reg  [15:0] pl_tcs;             // 本帧 TCP 校验和 (装载拍一次性算好)
    // PC 侧图案表 (RTL 约定: 先取 s[31:24] 再推进; 预生成 4096B)
    reg  [7:0]  patmem [0:4095];
    reg  [31:0] pc_txoff;           // 全局载荷偏移 (app_pattern RX LFSR 是全局的)
    reg  [31:0] pc_seq   [0:15];    // 每连接 PC 发送 seq 计数 (下一段的起始 seq)
    reg  [31:0] pc_seq0  [0:15];    // 每连接 PC 的起始 seq (= 板侧该连接 ADD 的 rcv_nxt)
                                    // 载荷流偏移 k = pc_seq - pc_seq0 (sink 侧同源)
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
    // TCP 校验和: **一次性按帧算** (载荷 <= 1460B ⇒ <= 730 次循环/帧)。绝不能放进
    // ack_byte —— 它每字节被调用一次 ⇒ 1024B 段会变成 512K 次循环/帧 (xsim 慢到不可用;
    // tb_p5_adv 的 200B 上限注释说的就是这个)。字段全部由入参传入: 装载拍 ack_seq/
    // ack_ack/ack_wnd 还是**旧帧**的值 (非阻塞), 读它们会把校验和算错。
    function [15:0] tcs_calc;
        input [3:0]  c;
        input [10:0] plen;
        input [31:0] pofs;              // 载荷流偏移 k (pay_byte 的 k)
        input [31:0] sq;
        input [31:0] ak;
        input [15:0] wnd;
        reg [31:0] s;
        reg [15:0] hfw;                 // {0x50, flags}
        integer pj;
        reg [7:0] b0, b1;
        begin
            hfw = {8'h50, (plen != 11'd0) ? 8'h18 : 8'h10};
            s = 32'h0006 + {16'b0, (16'd40 + {5'b0, plen}) - 16'd20} +
                pc_sport[c] + pc_dport[c] +
                sq[31:16] + sq[15:0] + ak[31:16] + ak[15:0] +
                {16'b0, hfw} + {16'b0, wnd};
            for (pj = 0; pj < plen; pj = pj + 2) begin
                b0 = pay_byte(c, pofs + pj[31:0]);
                b1 = ((pj + 1) < plen) ? pay_byte(c, pofs + pj[31:0] + 32'd1) : 8'h00;
                s = s + {16'b0, b0} + {16'b0, b1};
            end
            s = (s & 32'hFFFF) + (s >> 16);
            s = (s & 32'hFFFF) + (s >> 16);
            tcs_calc = ~s[15:0];
        end
    endfunction

    function [7:0] ack_byte;
        input [15:0] ix;
        reg [15:0] tot;
        reg [31:0] s;
        reg [15:0] ics;
        reg [3:0]  c;
        reg [31:0] sq, ak;
        begin
            c = ack_conn; sq = ack_seq; ak = ack_ack;
            tot = 16'd40 + {5'b0, pl_plen};
            s = 32'h4500 + {16'b0, tot} + 32'h7777 + 32'h0000 + 32'h4006 +
                pc_myip[c][31:16] + pc_myip[c][15:0] +
                pc_peerip[c][31:16] + pc_peerip[c][15:0];
            s = (s & 32'hFFFF) + (s >> 16);
            s = (s & 32'hFFFF) + (s >> 16);
            ics = ~s[15:0];
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
                6'd50: ack_byte = pl_tcs[15:8]; 6'd51: ack_byte = pl_tcs[7:0];
                6'd52: ack_byte = 8'h00;     6'd53: ack_byte = 8'h00;
                default: begin
                    if (ix < (16'd54 + {5'b0, pl_plen}))
                        ack_byte = pay_byte(ack_conn, pl_payofs + (ix - 16'd54));
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
            ack_i <= 12'd0; ack_pend <= 0; ack_crc <= 32'hFFFFFFFF;
            q_h <= 5'd0; q_t <= 5'd0;
        end else begin
            rx_er <= 1'b0;
            if (ack_i == 12'd0) begin
                rx_d <= 8'h07; rx_dv <= 1'b0;
                if (q_n != 0) begin
                    ack_i     <= 12'd1; ack_crc <= 32'hFFFFFFFF;
                    ack_conn  <= q_c[q_h[3:0]];
                    ack_seq   <= q_s[q_h[3:0]];
                    ack_ack   <= q_a[q_h[3:0]];
                    ack_wnd   <= q_w[q_h[3:0]];
                    pl_plen   <= q_p[q_h[3:0]];
                    pl_payofs <= q_o[q_h[3:0]];
                    // 本帧 TCP 校验和 (一次性; 必须用本帧入参, 不能读旧 ack_*)
                    pl_tcs    <= tcs_calc(q_c[q_h[3:0]], q_p[q_h[3:0]],
                                          q_o[q_h[3:0]], q_s[q_h[3:0]],
                                          q_a[q_h[3:0]], q_w[q_h[3:0]]);
                    // 帧体 = 54 + plen; 不足 60B 补零
                    pl_body   <= ((16'd54 + {5'b0, q_p[q_h[3:0]]}) < 16'd60) ?
                                 16'd60 : (16'd54 + {5'b0, q_p[q_h[3:0]]});
                    q_h       <= q_h + 5'd1;
                    if (dbg_cap)
                        $display("TXACK k=%0d conn=%0d seq=%08x ack=%08x wnd=%04x plen=%0d",
                                 k, q_c[q_h[3:0]], q_s[q_h[3:0]], q_a[q_h[3:0]],
                                 q_w[q_h[3:0]], q_p[q_h[3:0]]);
                end
            end else if (ack_i <= 12'd8) begin
                rx_d  <= (ack_i == 12'd8) ? 8'hD5 : 8'h55;
                rx_dv <= 1'b1;
                ack_i <= ack_i + 12'd1;
            end else if (ack_i <= (12'd8 + pl_body)) begin
                // 字节对齐: rx_d 是寄存器 (驱动拍 k 的字节在 k+1 出现在线上),
                // D5 占 ack_i=8 的驱动拍 (= 线上第 9 拍), 故帧体首字节 = ack_i=9
                // 驱动 ack_byte(0)。原先用 (ack_i-8) 使整帧前移 1 字节 (dst mac
                // 错 -> 板侧 mac_rx 全丢, 实测 rx_stat_pass=0)。
                rx_d  <= ack_byte(ack_i - 12'd9);
                rx_dv <= 1'b1;
                ack_crc <= crc32b(ack_crc, ack_byte(ack_i - 12'd9));
                ack_i <= ack_i + 12'd1;
            end else if (ack_i <= (12'd12 + pl_body)) begin
                // FCS 必须取反后 LSB-first 上线 (crc32b 是"无终值取反"的反射型
                // 更新; 工程约定线上 FCS = ~crc 的小端字节序)。原先漏取反 ->
                // 板侧 mac_rx 全部按 CRC 错丢弃 (实测 stat_drop_crc=3)。
                rx_d  <= ~ack_crc[(ack_i - 12'd9 - pl_body)*8 +: 8];
                rx_dv <= 1'b1;
                ack_i <= ack_i + 12'd1;
                if (ack_i == (12'd12 + pl_body))
                    ack_cnt <= ack_cnt + 16'd1;    // 已发帧数
            end else if (ack_i < (12'd28 + pl_body)) begin
                // 帧间 IFG 必须 >= 12 字节时间 (mac_rx_64 的 IFG 契约); 原先只留
                // 3 拍 -> 背靠背应答被 RX 侧丢弃 = ACK 全丢 -> 窗口闭死
                rx_d <= 8'h07; rx_dv <= 1'b0;
                ack_i <= ack_i + 12'd1;
            end else begin
                ack_i <= 12'd0; rx_d <= 8'h07; rx_dv <= 1'b0;
            end
        end
    end

    // ---- 板侧帧捕获: 数据/FIN 帧 -> 排一条应答 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_en_d <= 0; tx_inf <= 0; txbc <= 0; caplen <= 0;
            frm_data <= 0; frm_fin <= 0; frm_rst <= 0; frm_other <= 0;
            fin_cnt <= 0; fin_seq_first <= 0; fin_seq_last <= 0; ack_cnt <= 0;
            cap_fin <= 0; frm_fin_macbad <= 0; frm_fin_smacbad <= 0;
            for (ci = 0; ci < 16; ci = ci + 1) begin
                pc_hwm[ci] <= 0; frm_fin_c[ci] <= 0; frm_rst_c[ci] <= 0;
                // pc_ack_seen 必须等于**该连接的起始 seq** (= 板侧 ADD 时的
                // rcv_nxt): 置 0 会让 in_flight 看起来是 0x20000001 (巨大) ⇒
                // 注水机永远发不出, 直到回卷把它清成 0 ⇒ 那时发的是 seq=0 的
                // 垃圾帧 (板侧全按旧段丢 = stat_drop_seq 暴涨)。实测踩过。
                pc_ack_seen[ci] <= cfg_rcv_nxt[ci];
                pc_wnd_seen[ci] <= TB_WQ_CAP;
            end
        end else begin
            tx_en_d <= gmii_tx_en;
            if (gmii_tx_en) begin
                if (!tx_en_d) begin tx_inf <= 0; txbc <= 0; caplen <= 0; end
                else if (!tx_inf) begin
                    if (gmii_txd == 8'hD5) tx_inf <= 1;
                end else begin
                    // txbc/caplen 必须饱和 (6 位回绕会把帧尾字节覆写到 cap[0..])
                    // 捕获到 cap[55]: P5d 需要 window 字段 (字节 48/49) —— 原 48 字节
                    // 截断读不到它 (板侧通告窗是注水机 pacing 的唯一依据)
                    if (txbc < 6'd56) cap[txbc] <= gmii_txd;
                    if (caplen < 6'd60) caplen <= caplen + 6'd1;
                    if (txbc < 6'd63) txbc <= txbc + 6'd1;
                end
            end else if (tx_en_d && tx_inf) begin
                if (dbg_cap)
                    $display("CAP k=%0d caplen=%0d eth=%02x%02x ip=%02x fl=%02x sb=%02x%02x/%02x%02x win=%02x%02x",
                             k, caplen, cap[12], cap[13], cap[23], cap[47],
                             cap[34], cap[35], cap[36], cap[37],
                             cap[48], cap[49]);
                if (caplen >= 6'd52 && cap[12] == 8'h08 && cap[13] == 8'h00 &&
                    cap[23] == 8'h06) begin
                    // ---- P5d: 板侧通告窗 / ack 采样 (注水机 pacing 的"对端视角") ----
                    // 对**任何** TCP 帧都采 (纯 ACK/数据/FIN 都带 window 字段): 这是
                    // 对端相信的窗口; 其滞后 (Δ) 正是 C1b 分析的对象。
                    // 只用 pc_en 的连接 (测试连接) 更新, 且只前进不后退 (ack 单调)。
                    if (pc_en[cx]) begin
                        if ($signed({cap[42],cap[43],cap[44],cap[45]} - pc_ack_seen[cx]) > 0)
                            pc_ack_seen[cx] <= {cap[42],cap[43],cap[44],cap[45]};
                        pc_wnd_seen[cx] <= {cap[48], cap[49]};
                    end
                    if (cap[47] == 8'h18) begin
                        frm_data <= frm_data + 16'd1;
                        if (q_n < 5'd16 && pc_en[cx]) begin
                            q_c[q_t[3:0]] <= cx;
                            q_s[q_t[3:0]] <= u_tcb.rcv_nxt_r[cx];
                            q_a[q_t[3:0]] <= {cap[38], cap[39], cap[40], cap[41]} +
                                             ({16'b0, cap[16], cap[17]} - 32'd40);
                            q_w[q_t[3:0]] <= pc_wnd[cx];
                            q_p[q_t[3:0]] <= 11'd0;
                            q_o[q_t[3:0]] <= 32'd0;
                            q_t <= q_t + 5'd1;
                            pc_hwm[cx] <= {cap[38], cap[39], cap[40], cap[41]} +
                                          ({16'b0, cap[16], cap[17]} - 32'd40);
                        end
                    end else if (cap[47] == 8'h11) begin
                        // ---- P5d 判据 ⑤: 逐连接 FIN 计数 + FIN 的 dst MAC 核对 ----
                        // "互不串扰" = 该连接的 FIN 帧 dst MAC 必须是**该对端**的 MAC
                        // (CAM 查表结果) 且端口方向正确 (conn_of 已按端口定连接)。
                        // dst mac = cap[0..5]: 板侧 CAM 存的 dmac = CFG 的 peer_mac[c]。
                        frm_fin <= frm_fin + 16'd1;
                        fin_cnt <= fin_cnt + 16'd1;
                        frm_fin_c[cx] <= frm_fin_c[cx] + 16'd1;
                        if ({cap[0],cap[1],cap[2],cap[3],cap[4],cap[5]} != pc_mac[cx])
                            frm_fin_macbad <= frm_fin_macbad + 16'd1;
                        if ({cap[6],cap[7],cap[8],cap[9],cap[10],cap[11]} !=
                            48'h000A3501FEC0)
                            frm_fin_smacbad <= frm_fin_smacbad + 16'd1;
                        if (fin_cnt == 16'd0)
                            fin_seq_first <= {cap[38], cap[39], cap[40], cap[41]};
                        fin_seq_last <= {cap[38], cap[39], cap[40], cap[41]};
                        if (q_n < 5'd16 && pc_en[cx]) begin
                            q_c[q_t[3:0]] <= cx;
                            q_s[q_t[3:0]] <= u_tcb.rcv_nxt_r[cx];
                            q_a[q_t[3:0]] <= {cap[38], cap[39], cap[40], cap[41]} + 32'd1;
                            q_w[q_t[3:0]] <= pc_wnd[cx];
                            q_p[q_t[3:0]] <= 11'd0;
                            q_o[q_t[3:0]] <= 32'd0;
                            q_t <= q_t + 5'd1;
                            pc_hwm[cx] <= {cap[38], cap[39], cap[40], cap[41]} + 32'd1;
                        end
                    end else if (cap[47] == 8'h14) begin
                        frm_rst <= frm_rst + 16'd1;
                        frm_rst_c[cx] <= frm_rst_c[cx] + 16'd1;
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

    // =====================================================================
    // 脚本 -> DUT/TB 激励的**分级非阻塞落地** (工程坑 3)
    // =====================================================================
    // 脚本进程用 `@(posedge clk)` 逐条恢复执行; 命令若直接**阻塞赋值**到 DUT 可见
    // 信号 (或喂给它们组合逻辑的信号), 该信号就在时钟沿**同一仿真时间步**改变 ⇒
    // 同一步内不同进程采到的值不一致 (xsim 进程顺序决定谁赢)。P5d 实例:
    //   `22: sink_rate = sa;` 阻塞写 → eco2_tready 组合变 → eco_tready → fwd_rd →
    //   frame_fifo 的组合读址 r_ad = rptr + rd_ok 沿后变化; unisim BRAM (SDP,
    //   DOA_REG=0) 在沿上采到"沿后"地址 (rptr+1) 而 frame_fifo 自己的 rptr 寄存器
    //   采到"沿前" rd_ok ⇒ DOA 提前一个字; 下游 1-deep 流水 (axis_pipe,
    //   s_ready = m_ready || !m_valid) 采到的又是沿前值 ⇒ 呈现流**丢/重 1 个字**
    //   (8B 错位) 且字内自洽 (kaerr=0)。实测 (同一 RTL, 只改这行): miss 8 -> 0。
    //   独立复核桩见 sim/p5d_multi/p5dmech/ (MEMMON: 恒等 dout(N) === mem[rptr(N)]
    //   恰在 RATE 变化的**同拍**被破坏, 且只破坏 1 拍)。
    // 本节形态 (统一): 脚本只写 `*_rq_*` 请求 (阻塞, 纯 TB 局部, DUT 不可见); 落地
    // 块在**下一个沿**用非阻塞转正; 命令结束前 land_wait 等所有 *_rq_v 回 0
    // (v 由落地块 NBA 清, 要"落地沿 + 1 沿"才观测得到) ⇒ DUT 可见信号只在沿上
    // 变化, 且同一命令的多个字段同拍落地。与自动更新共享寄存器 (pc_seq /
    // fl_budget) 的落地写在各自 owning 块内, 并对"同拍同槽"做合并 (见注水机块)。
    reg        pc_en_rq_v;     reg [3:0]  pc_en_rq_i;     reg        pc_en_rq_d;
    reg        pc_wnd_rq_v;    reg [3:0]  pc_wnd_rq_i;    reg [15:0] pc_wnd_rq_d;
    reg        pc_sport_rq_v;  reg [3:0]  pc_sport_rq_i;  reg [15:0] pc_sport_rq_d;
    reg        pc_dport_rq_v;  reg [3:0]  pc_dport_rq_i;  reg [15:0] pc_dport_rq_d;
    reg        pc_peerip_rq_v; reg [3:0]  pc_peerip_rq_i; reg [31:0] pc_peerip_rq_d;
    reg        pc_myip_rq_v;   reg [3:0]  pc_myip_rq_i;   reg [31:0] pc_myip_rq_d;
    reg        pc_mac_rq_v;    reg [3:0]  pc_mac_rq_i;    reg [47:0] pc_mac_rq_d;
    reg        cfg_rcv_rq_v;   reg [3:0]  cfg_rcv_rq_i;   reg [31:0] cfg_rcv_rq_d;
    reg        cfg_snd_rq_v;   reg [3:0]  cfg_snd_rq_i;   reg [31:0] cfg_snd_rq_d;
    reg        pc_txoff_rq_v;  reg [31:0] pc_txoff_rq_d;
    reg        sink_rate_rq_v; reg [31:0] sink_rate_rq_d;
    // pc_seq / fl_budget 的请求 (落地在注水机块内, 与自动推进同一 NBA 表达式)
    reg        pc_seq_rq_v;    reg        pc_seq_rq_abs;  reg [3:0]  pc_seq_rq_i;
    reg [31:0] pc_seq_rq_d;
    reg        fl_add_rq_v;    reg [3:0]  fl_add_rq_i;    reg [31:0] fl_add_rq_d;

    wire sync_rq_v = pc_en_rq_v | pc_wnd_rq_v | pc_sport_rq_v | pc_dport_rq_v |
                     pc_peerip_rq_v | pc_myip_rq_v | pc_mac_rq_v |
                     cfg_rcv_rq_v | cfg_snd_rq_v | pc_txoff_rq_v |
                     sink_rate_rq_v | pc_seq_rq_v | fl_add_rq_v;

    task land_wait;      // 等本命令落地完成 (v 回 0 需"落地沿 + 1 沿"才可见)
        begin
            @(posedge clk);
            while (sync_rq_v != 1'b0) @(posedge clk);
        end
    endtask

    // 单槽标量/数组落地 (sink_rate 的唯一写者 = 本块; 复位值同旧)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_en_rq_v <= 1'b0; pc_wnd_rq_v <= 1'b0; pc_sport_rq_v <= 1'b0;
            pc_dport_rq_v <= 1'b0; pc_peerip_rq_v <= 1'b0; pc_myip_rq_v <= 1'b0;
            pc_mac_rq_v <= 1'b0; cfg_rcv_rq_v <= 1'b0; cfg_snd_rq_v <= 1'b0;
            pc_txoff_rq_v <= 1'b0; sink_rate_rq_v <= 1'b0;
            sink_rate <= 32'd0;
        end else begin
            if (pc_en_rq_v)
                begin pc_en[pc_en_rq_i] <= pc_en_rq_d; pc_en_rq_v <= 1'b0; end
            if (pc_wnd_rq_v)
                begin pc_wnd[pc_wnd_rq_i] <= pc_wnd_rq_d; pc_wnd_rq_v <= 1'b0; end
            if (pc_sport_rq_v)
                begin pc_sport[pc_sport_rq_i] <= pc_sport_rq_d; pc_sport_rq_v <= 1'b0; end
            if (pc_dport_rq_v)
                begin pc_dport[pc_dport_rq_i] <= pc_dport_rq_d; pc_dport_rq_v <= 1'b0; end
            if (pc_peerip_rq_v)
                begin pc_peerip[pc_peerip_rq_i] <= pc_peerip_rq_d; pc_peerip_rq_v <= 1'b0; end
            if (pc_myip_rq_v)
                begin pc_myip[pc_myip_rq_i] <= pc_myip_rq_d; pc_myip_rq_v <= 1'b0; end
            if (pc_mac_rq_v)
                begin pc_mac[pc_mac_rq_i] <= pc_mac_rq_d; pc_mac_rq_v <= 1'b0; end
            if (cfg_rcv_rq_v)
                begin cfg_rcv_nxt[cfg_rcv_rq_i] <= cfg_rcv_rq_d; cfg_rcv_rq_v <= 1'b0; end
            if (cfg_snd_rq_v)
                begin cfg_snd_nxt[cfg_snd_rq_i] <= cfg_snd_rq_d; cfg_snd_rq_v <= 1'b0; end
            if (pc_txoff_rq_v)
                begin pc_txoff <= pc_txoff_rq_d; pc_txoff_rq_v <= 1'b0; end
            if (sink_rate_rq_v)
                begin sink_rate <= sink_rate_rq_d; sink_rate_rq_v <= 1'b0; end
        end
    end

    // =====================================================================
    // 注水机: 逐连接的可发空间 / 轮转选择 / 入队
    // =====================================================================
    // 每拍最多推**一帧** (且队列空时才推) —— 播放器一帧要 ~1030+ 拍 (GMII 字节流),
    // 若允许多帧入队会立刻塞满 16 深队列并让三条连接互相抢; 一帧一推 + 轮转 =
    // 三条连接天然交织 (与真实网卡上的三个并发流等价)。
    function [4:0] fl_pick;              // {valid, id} (同 fc_pick 的轮转惯用法)
        input [15:0] can;
        input [3:0]  rr;
        integer i;
        reg [3:0]  cand;
        reg        found;
        begin
            cand = rr; found = 1'b0;
            for (i = 15; i >= 0; i = i - 1) begin
                if (can[rr + i[3:0]]) begin
                    cand = rr + i[3:0];
                    found = 1'b1;
                end
            end
            fl_pick = {found, cand};
        end
    endfunction

    always @(*) begin
        fl_can = 16'd0;
        for (fi = 0; fi < 16; fi = fi + 1) begin
            fl_room_c[fi] = 32'd0;
            fl_seg[fi]    = 32'd0;
        end
        for (fi = 0; fi < 16; fi = fi + 1) begin
            if (pc_en[fi] && (fl_budget[fi] != 32'd0)) begin
                // 在飞 = 已发 seq - 板侧最近 ACK (= 板侧 rcv_nxt); 只前向 (无回绕假设)
                fl_room_c[fi] = (pc_wnd_seen[fi] > (pc_seq[fi] - pc_ack_seen[fi])) ?
                                ({16'b0, pc_wnd_seen[fi]} -
                                 (pc_seq[fi] - pc_ack_seen[fi])) : 32'd0;
                if (fl_room_c[fi] > FL_SEG)     fl_seg[fi] = FL_SEG;
                else                            fl_seg[fi] = fl_room_c[fi];
                if (fl_seg[fi] > fl_budget[fi]) fl_seg[fi] = fl_budget[fi];
                if (fl_seg[fi] != 32'd0)        fl_can[fi] = 1'b1;
            end
        end
    end

    wire [4:0] fl_sel5 = fl_pick(fl_can, fl_rr);
    // 入队条件: 有可发连接 && 队列空 && 播放器当前不在帧中 (一帧一推)。
    // rst_n 直接进判据: 复位期不得入队 (否则 q_t 与 pc_seq 记账错位)。
    wire       fl_go   = rst_n && fl_sel5[4] && (q_n == 5'd0) && (ack_i == 12'd0);
    wire [3:0] fl_c    = fl_sel5[3:0];
    // 脚本 pc_seq **绝对 re-base** 与自动推进同拍撞同一连接时: 抑制本拍推进
    // (q_t/预算都不动 ⇒ 下一拍自然重推), 保证"同拍两条 NBA 写同一 pc_seq 槽"不可能。
    wire       pc_seq_abs_hit = pc_seq_rq_v && pc_seq_rq_abs && (pc_seq_rq_i == fl_c);
    wire       fl_go_g = fl_go && !pc_seq_abs_hit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (fi = 0; fi < 16; fi = fi + 1) begin
                fl_budget[fi] <= 32'd0; fl_seg[fi] <= 32'd0; fl_stall[fi] <= 32'd0;
                fl_room_c[fi] <= 32'd0;
            end
            fl_rr <= 4'd0; fl_rewind <= 32'd0;
            fl_tx_frames <= 32'd0; fl_tx_bytes <= 32'd0;
            pc_seq_rq_v <= 1'b0; fl_add_rq_v <= 1'b0;
        end else begin
            // ---- 脚本落地 (分级非阻塞): 与自动推进同块 ⇒ NBA 顺序确定 ----
            if (pc_seq_rq_v) begin
                pc_seq[pc_seq_rq_i] <= pc_seq_rq_abs ? pc_seq_rq_d
                                                     : (pc_seq[pc_seq_rq_i] + pc_seq_rq_d);
                pc_seq_rq_v <= 1'b0;
            end
            if (fl_add_rq_v) begin
                fl_budget[fl_add_rq_i] <= fl_budget[fl_add_rq_i] + fl_add_rq_d;
                fl_add_rq_v <= 1'b0;
            end
            if (fl_go_g) begin
                q_c[q_t[3:0]] <= fl_c;
                q_s[q_t[3:0]] <= pc_seq[fl_c];
                // ack 字段 = **对端自己的** rcv_nxt = 板侧 snd_nxt (本门板侧 app 不发
                // 数据 ⇒ 恒 = cfg_snd_nxt[c] = iss+1)。用板侧 rcv_nxt 当 ack 是错的
                // (那是"确认了板侧从未发出的字节"), 会让 ack_ok 判据无意义。
                q_a[q_t[3:0]] <= cfg_snd_nxt[fl_c];
                q_w[q_t[3:0]] <= pc_wnd[fl_c];
                q_p[q_t[3:0]] <= fl_seg[fl_c][10:0];
                q_o[q_t[3:0]] <= pc_seq[fl_c] - pc_seq0[fl_c];   // 该连接的载荷流偏移 k
                q_t <= q_t + 5'd1;
                // pc_seq: 本拍脚本增量 (op10 同连接) 必须并进**同一条** NBA
                pc_seq[fl_c]    <= pc_seq[fl_c] + fl_seg[fl_c] +
                                   ((pc_seq_rq_v && !pc_seq_rq_abs &&
                                     (pc_seq_rq_i == fl_c)) ? pc_seq_rq_d : 32'd0);
                fl_budget[fl_c] <= fl_budget[fl_c] - fl_seg[fl_c] +
                                   ((fl_add_rq_v && (fl_add_rq_i == fl_c)) ?
                                    fl_add_rq_d : 32'd0);
                fl_tx_frames    <= fl_tx_frames + 32'd1;
                fl_tx_bytes     <= fl_tx_bytes + fl_seg[fl_c];
                fl_rr           <= fl_c + 4'd1;
            end
            // ---- 停滞计数 + go-back-N 回卷 ----
            // 停滞 = "还有预算但发不出去" (对端相信的窗已关) 或 "预算耗尽"(不算停滞)。
            // 到 FL_STALL_LIM 仍有在飞未确认 ⇒ 按最后 ACK 回卷重传。正常工况 (裕度
            // 足够覆盖漂移) 下不应发生 ⇒ fl_rewind 是"裕度是否够用"的判据。
            // 脚本 pc_seq 落地拍让位一拍 (避免同槽双写; 只影响该拍的回卷判定)。
            for (fi = 0; fi < 16; fi = fi + 1) begin
                if (!pc_en[fi] || (fl_budget[fi] == 32'd0) || fl_can[fi]) begin
                    fl_stall[fi] <= 32'd0;
                end else if (fl_stall[fi] < FL_STALL_LIM) begin
                    fl_stall[fi] <= fl_stall[fi] + 32'd1;
                end else if (!pc_seq_rq_v && (pc_seq[fi] != pc_ack_seen[fi])) begin
                    pc_seq[fi]    <= pc_ack_seen[fi];      // 回卷到板侧 rcv_nxt
                    fl_stall[fi]  <= 32'd0;
                    fl_rewind     <= fl_rewind + 32'd1;
                end
            end
        end
    end

    // =====================================================================
    // 逐拍不变量断言 (违反即计数; 首次现场打印 k; checker 断言计数为 0)
    // =====================================================================
    // ① 池守恒 (D4 的核心): Σwinq + pool == WIN_POOL —— **逐拍**成立 (构造保证)。
    //    这条抓的是"归还/授予记账分叉"(P5c R8 的 2x 超发形态)。
    // ② 分池上限: 每连接 winq[c] <= WIN_POOL/N。D4 缺省 (wq_cap 仍是 0xC000) 时
    //    第一条连接 winq=0xC000 > 0x4000 ⇒ 本判据响 (负向对照 ①)。
    // ③ 物理界 (H-fix 的推导): occ + Σwinq + N*ACC_MARGIN + Δ + U + SEG_MAX <= 65536。
    //    裕度被强制 4096 (N=3) 时右边超 1738 ⇒ 本判据响 (负向对照 ②)。
    // ④ 字面判据: occ + Σ通告窗 (仅 ESTAB) <= 65536 (TL 原文; 比 ③ 松, 一并留证)。
    wire [18:0] inv_sum = {1'b0, sum_winq} + {2'b0, ac_pool};
    wire [18:0] inv_ref = {3'b0, TB_WIN_POOL};
    wire        inv_pool_viol = (inv_sum != inv_ref);
    wire [31:0] inv_nmgn = {27'b0, n_estab_c} * {16'b0, tb_am_eff};
    // 契约式物理界 (TL 的 H-fix 公式, **不含 occ**): Σwinq + N*margin + Δ + U + SEG_MAX
    // 推导: 接受界 = 当前通告窗 + margin, 而 Σ当前窗 = Σ_c max(0, winq_c - occ)
    //   <= Σwinq - (N-1)*occ (N 条等配额连接) ⇒ FIFO 内容上界在 occ=0 取到最大值
    //   ⇒ **occ 越大越安全** (occ 与"未收回的旧窗"不能同时计入)。
    wire [31:0] inv_phys = {14'b0, sum_winq} + inv_nmgn +
                           {16'b0, TB_DELTA} + {16'b0, TB_U_FRM} + {16'b0, TB_SEG_MAX};
    // 物理界 (接受界推导, 独立复算): occ + Σ当前窗 + N*margin + U + SEG_MAX
    // (Δ 已由"当前窗"的滞后体现, 不再重复计) —— 恒 <= 契约式, 单独留证。
    // 稳态 = 三条连接都 ESTAB (裕度表已收敛到 N=3 档)。建连瞬态 (配额已授予而
    // ESTAB 计数未跟上, 裕度仍是 N<=2 档) 的违反**另计, 只作报告**: 那 <=1 个扫描轮
    // (256 拍) 里对端还没收到任何窗口通告, 物理上不可能有数据在飞 (实测首帧前的
    // 12 拍就是这种瞬态)。判据 ④ 的语义 = **稳态**聚合物理界。
    // 稳态 = ESTAB 数已达 NCONN **且裕度寄存器已收敛到该档** (acc_margin_of(NCONN)):
    // 裕度是寄存器 (TL 的时序要求), ESTAB 计数变化后 1 拍才跟上 —— 那 1~2 拍的
    // "旧档裕度" 期间契约式的右端会短暂超界 (实测 12 拍, 峰值 67274, 此时对端
    // 尚无任何在飞数据)。判据 ④ 的语义 = **收敛后的稳态契约**。
    wire        inv_phys_viol = (n_estab_c == NCONN) &&
                                (tb_am_eff == acc_margin_of(NCONN)) &&
                                (inv_phys > TB_FIFO_BYTES);
    wire        inv_phys_tran = (n_estab_c != NCONN) && (n_estab_c != 5'd0) &&
                                (inv_phys > TB_FIFO_BYTES);
    wire        inv_burst_viol = ({15'b0, rx_occ} + {14'b0, sum_wnd_e}) > TB_FIFO_BYTES;
    wire [31:0] inv_real = {15'b0, rx_occ} + winq_rem + inv_nmgn +
                           {16'b0, TB_U_FRM} + {16'b0, TB_SEG_MAX};
    wire        inv_real_viol = (n_estab_c != 5'd0) && (inv_real > TB_FIFO_BYTES);
    wire        inv_cap_viol = (u_app_ctrl.winq[0] > TB_WQ_CAP) ||
                               (u_app_ctrl.winq[1] > TB_WQ_CAP) ||
                               (u_app_ctrl.winq[2] > TB_WQ_CAP) ||
                               (u_app_ctrl.winq[3] > TB_WQ_CAP);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inv_pool_bad <= 32'd0; inv_cap_bad <= 32'd0; inv_phys_bad <= 32'd0;
            inv_burst_bad <= 32'd0; inv_phys_tran_bad <= 32'd0; inv_first_k <= 32'd0;
            inv_real_bad <= 32'd0; inv_real_max <= 32'd0;
            occ_max <= 32'd0; winq_min <= 16'hFFFF; wq_cap_now <= 16'd0;
        end else begin
            // wq_cap_r 是 app_ctrl 内部寄存器 (无输出端口) ⇒ 层次引用读回 (TB 专用)
            wq_cap_now <= u_app_ctrl.wq_cap_r;
            if (inv_pool_viol) begin
                inv_pool_bad <= inv_pool_bad + 32'd1;
                if (inv_first_k == 32'd0) begin
                    inv_first_k <= k;
                    $display("P5D INV POOL k=%0d sum_winq=%0d pool=%0d (期望和=%0d)",
                             k, sum_winq, ac_pool, TB_WIN_POOL);
                end
            end
            if (inv_cap_viol)  inv_cap_bad  <= inv_cap_bad + 32'd1;
            if (inv_phys_viol) begin
                inv_phys_bad <= inv_phys_bad + 32'd1;
                if (inv_phys_bad == 32'd0)
                    $display("P5D INV PHYS k=%0d sum_winq=%0d n_estab=%0d mgn=%0d tot=%0d",
                             k, sum_winq, n_estab_c, tb_am_eff, inv_phys);
            end
            if (inv_phys_tran) inv_phys_tran_bad <= inv_phys_tran_bad + 32'd1;
            if (inv_real_viol) inv_real_bad <= inv_real_bad + 32'd1;
            if (inv_real > inv_real_max) inv_real_max <= inv_real;
            if (inv_burst_viol) inv_burst_bad <= inv_burst_bad + 32'd1;
            if ({15'b0, rx_occ} > occ_max) occ_max <= {15'b0, rx_occ};
            if (u_app_ctrl.winq[0] < winq_min) winq_min <= u_app_ctrl.winq[0];
        end
    end

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
                $write("MULRXD n=%0d", rxd_n);
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
            $fwrite(fd, "MULSTAT atx_frames=%0d atx_bytes=%0d atx_good=%0d atx_bad=%0d\n",
                    atx_frames, atx_bytes, atx_good_bytes, atx_bad_frames);
            $fwrite(fd, "MULAPP run=%0d qn=%0d off=%0d len=%0d tid=%0d\n",
                    atx_run, atx_qn, atx_off, atx_len, atx_tid);
            $fwrite(fd, "MULTX frames=%0d bytes=%0d ack=%0d drop_len=%0d fin=%0d rst=%0d eend=%0d\n",
                    tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_drop_len,
                    tx_stat_fin, tx_stat_rst, tx_stat_eend);
            $fwrite(fd, "MULFRM data=%0d fin=%0d rst=%0d other=%0d ackcnt=%0d\n",
                    frm_data, frm_fin, frm_rst, frm_other, ack_cnt);
            $fwrite(fd, "MULSTAT2 scfg_add=%0d scfg_del=%0d ev_up=%0d ev_down=%0d ev_drop=%0d\n",
                    scfg_add, scfg_del, ac_ev_up_c, ac_ev_down_c, ac_ev_drop);
            for (ci = 0; ci < 16; ci = ci + 1)
                if (ci < 4)
                    $fwrite(fd, "MULTCB %0d %08h %08h %08h %04h %04h %0d %04h\n",
                            ci, u_tcb.rcv_nxt_r[ci], u_tcb.snd_nxt_r[ci],
                            u_tcb.snd_una_r[ci], u_tcb.rcv_wnd_r[ci],
                            u_tcb.snd_wnd_r[ci], u_tcb.state_r[ci],
                            tx_fin_sent[ci]);
            $fwrite(fd, "MULRDY %04h fin1=%08h finN=%08h nfin=%0d qn=%0d\n",
                    app_tx_ready, fin_seq_first, fin_seq_last, fin_cnt, q_n);
            $fwrite(fd, "MULDBG txst=%0d plen=%0d plen_r=%0d wndopen=%0d srdy=%0d sav=%0d pem=%0d pf=%0d sndwnd=%04h finreq=%04h finsent=%04h\n",
                    dbg_txstate, dbg_plen, dbg_plen_r, dbg_wnd_open, dbg_sready,
                    dbg_saxis_tvalid, dbg_pay_empty, dbg_pay_full,
                    u_tcb.snd_wnd_r[0], ac_fin_req, tx_fin_sent);
            dump_reg(8'h00);
            dump_reg(8'h07);
            dump_reg(8'h09);
            dump_reg(8'h0C);   // P5d D4: 单连接配额上限 (回读)
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
            $fwrite(fd, "MULMDROP %0d\n", mac_stat_drop);
            $fwrite(fd, "MULMAC frames=%0d abort=%0d\n",
                    mac_stat_frames, mac_stat_abort);
            $fwrite(fd, "MULRX7 pass=%0d nonmatch=%0d ipcsum=%0d crc=%0d seq=%0d ack=%0d bytes=%0d trunc=%0d\n",
                    rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                    rx_stat_seq, rx_stat_ack, rx_stat_bytes, rx_stat_trunc);
            // P5b 必修4: 暴露编译进 DUT 的接受裕度 (与 u_rx 端口同一 localparam),
            // checker 用它断言 "接受裕度 <= 物理余量" + "TB 镜像 == wrapper"
            // 接受裕度: 动态镜像值 (N<=2 ⇒ 4096; N=3 ⇒ 3516) + ESTAB 数快照。
            // checker 断言: ① 本行 == 由 ESTAB 数与该表算出的期望值 (门确实按表跑);
            // ② 表项与 board/wrapper_p4.v 的 acc_margin_of **逐项相同** (C12 镜像)。
            $fwrite(fd, "MULCFG acc_margin=%0d n_estab=%0d wq_cap=%0d\n",
                    tb_am_eff, n_estab_c, wq_cap_now);
            // ---- P5d D5 判据落盘 ----
            // MULPOOL: 逐连接配额/通告窗/池/占用 + 逐拍不变量违反计数
            //   ① winq[c]/rcv_wnd[c] 必须符合 WIN_POOL/N 语义
            //   ② Σwinq + pool == WIN_POOL (inv_pool_bad 必须 0)
            //   ④ occ/Σwinq/N*margin 的物理界 (inv_phys_bad 必须 0)
            $fwrite(fd, "MULPOOL wq_cap=%0d pool=%0d sum_winq=%0d occ=%0d occ_max=%0d n_estab=%0d sum_wnd=%0d\n",
                    wq_cap_now, ac_pool, sum_winq, rx_occ, occ_max, n_estab_c,
                    sum_wnd_e);
            for (ci = 0; ci < NCONN; ci = ci + 1)
                $fwrite(fd, "MULWQ %0d winq=%0d rcv_wnd=%0d state=%0d\n",
                        ci, u_app_ctrl.winq[ci], u_tcb.rcv_wnd_r[ci],
                        u_tcb.state_r[ci]);
            $fwrite(fd, "MULINV pool_bad=%0d cap_bad=%0d phys_bad=%0d burst_bad=%0d phys_tran=%0d real_bad=%0d real_max=%0d first_k=%0d winq_min=%0d\n",
                    inv_pool_bad, inv_cap_bad, inv_phys_bad, inv_burst_bad, inv_phys_tran_bad,
                    inv_real_bad, inv_real_max,
                    inv_first_k, winq_min);
            // 逐连接 FIN/RST (判据 ⑤: 并发关闭各恰一 FIN, 互不串扰) + FIN 帧 MAC 核对
            for (ci = 0; ci < NCONN; ci = ci + 1)
                $fwrite(fd, "MULCLS %0d fin=%0d rst=%0d fin_sent=%0d rst_sent=%0d\n",
                        ci, frm_fin_c[ci], frm_rst_c[ci], tx_fin_sent[ci],
                        tx_rst_sent[ci]);
            $fwrite(fd, "MULCLSUM fin_macbad=%0d fin_smacbad=%0d\n",
                    frm_fin_macbad, frm_fin_smacbad);
            // 注水机 / sink 观测 (物理事件的实测证据)
            $fwrite(fd, "MULFL tx_frames=%0d tx_bytes=%0d rewind=%0d\n",
                    fl_tx_frames, fl_tx_bytes, fl_rewind);
            $fwrite(fd, "MULSINK rate=%0d words=%0d bytes0=%0d bytes1=%0d bytes2=%0d miss=%0d kaerr=%0d evfrm=%0d\n",
                    sink_rate, sink_words, sink_bytes[0], sink_bytes[1],
                    sink_bytes[2],
                    sink_mismatch[0] + sink_mismatch[1] + sink_mismatch[2],
                    sink_kaerr, sink_evfrm);
            for (ci = 0; ci < NCONN; ci = ci + 1)
                $fwrite(fd, "MULPEER %0d seq=%08h ack_seen=%08h wnd_seen=%04h budget=%0d\n",
                        ci, pc_seq[ci], pc_ack_seen[ci], pc_wnd_seen[ci],
                        fl_budget[ci]);
        end
    endtask

    task dump_reg;
        input [7:0] a;
        begin
            @(posedge clk); ac_addr <= a;
            @(posedge clk);
            $fwrite(fd, "MULREG %0d %08h\n", a, ac_rdata);
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
        // ---- P5d: 3 条**真实**连接 (conn c: 端口 +c / IP +c / MAC 尾字节 +c) ----
        // 与单连接版 (tb_p5_adv) 的区别: 三条连接各自独立四元组 + 独立 ISN, 且
        // wq_cap 在建连前由脚本写 0x0C = WIN_POOL/N ⇒ 三条各拿 WIN_POOL/N。
        for (ci = 0; ci < 16; ci = ci + 1) begin
            pc_en[ci] = 0; pc_wnd[ci] = 16'h4000;
            pc_sport[ci] = 16'h3039; pc_dport[ci] = 16'h1F90;
            pc_peerip[ci] = 32'hC0A86401; pc_myip[ci] = 32'hC0A86402;
            pc_mac[ci] = 48'h112233445566; pc_hwm[ci] = 0;
            pc_seq[ci] = 32'h20000001; pc_seq0[ci] = 32'h20000001;
            cfg_rcv_nxt[ci] = 32'h20000001;
            cfg_snd_nxt[ci] = TB_ISS + 32'd1;
            pc_ack_seen[ci] = 32'h20000001;   // 板侧 rcv_nxt (注水 pacing 的起手值)
            pc_wnd_seen[ci] = 16'd0;          // 建连前板侧没通告过窗口 ⇒ 0 (等首帧)
        end
        for (ci = 0; ci < NCONN; ci = ci + 1) begin
            pc_sport[ci] = 16'h3039 + ci[15:0];
            pc_dport[ci] = 16'h1F90 + ci[15:0];
            pc_peerip[ci] = 32'hC0A86401 + ci[31:0];
            pc_myip[ci]   = 32'hC0A86402 + ci[31:0];
            pc_mac[ci]    = 48'h112233445566 + ci[47:0];   // MAC 尾字节 = 连接号
            pc_wnd[ci]    = 16'h4000;
            cfg_rcv_nxt[ci] = 32'h20000001 + (ci[31:0] << 20);   // pcis+1
            cfg_snd_nxt[ci] = TB_ISS + 32'd1 + (ci[31:0] << 12); // iss+1
            pc_seq[ci]  = cfg_rcv_nxt[ci];
            pc_seq0[ci] = cfg_rcv_nxt[ci];
            pc_ack_seen[ci] = cfg_rcv_nxt[ci];   // 注水 pacing 起手值 = 起始 seq
        end
        begin : pat_init
            reg [63:0] ps;
            ps = P5_SEED;
            for (pi = 0; pi < 4096; pi = pi + 1) begin
                patmem[pi] = ps[31:24];
                ps = xs_next(ps);
            end
        end
        fd = $fopen("resp_p5_multi.memh", "w");
        #200; rst_n = 1;
        repeat (200) @(posedge clk);
        sfd = $fopen("multi_cmds.memh", "r");
        if (sfd == 0) begin
            $display("P5MUL FATAL: multi_cmds.memh 打开失败");
            $finish;
        end
        while (!$feof(sfd)) begin
            sret = $fscanf(sfd, "%d %d %d %d %d %d %d %d %d %d\n",
                           scode, sa, sb, sc, sd, se, sf, sg, sh, si);
            if (sret == 10) begin
                $fwrite(fd, "MULCMD %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                        scode, sa, sb, sc, sd, se, sf, sg, sh, si);
                case (scode)
                    1: repeat (sa) @(posedge clk);
                    2: begin wt0 = 0; while (frm_data < sa && wt0 < TMO_OP)
                              begin @(posedge clk); wt0 = wt0 + 1; end
                              if (frm_data < sa) begin tmo = 1;
                                  $fwrite(fd, "MULTO op2 want=%0d\n", sa); end end
                    3: begin wt0 = 0; while (frm_fin < sa && wt0 < TMO_OP)
                              begin @(posedge clk); wt0 = wt0 + 1; end
                              if (frm_fin < sa) begin tmo = 1;
                                  $fwrite(fd, "MULTO op3 want=%0d\n", sa); end end
                    13: begin wt0 = 0; while (frm_rst < sa && wt0 < TMO_OP)
                              begin @(posedge clk); wt0 = wt0 + 1; end
                              if (frm_rst < sa) begin tmo = 1;
                                  $fwrite(fd, "MULTO op13 want=%0d\n", sa); end end
                    14: begin wt0 = 0; while (atx_frames < sa && wt0 < TMO_OP)
                              begin @(posedge clk); wt0 = wt0 + 1; end
                              if (atx_frames < sa) begin tmo = 1;
                                  $fwrite(fd, "MULTO op14 want=%0d\n", sa); end end
                    15: begin wt0 = 0;
                              // 上限 = 参数 a (此前误用 TMO_OP=24M, 卡死时要烧 24M 拍)
                              while ((atx_qn != 0 || atx_run) && wt0 < sa)
                              begin @(posedge clk); wt0 = wt0 + 1; end
                              if (atx_qn != 0 || atx_run) begin tmo = 1;
                                  $fwrite(fd, "MULTO op15\n"); end end
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
                        cfg_rcv_rq_i = sa[3:0]; cfg_rcv_rq_d = sb; cfg_rcv_rq_v = 1'b1;
                        cfg_snd_rq_i = sa[3:0]; cfg_snd_rq_d = sc; cfg_snd_rq_v = 1'b1;
                        land_wait;
                    end
                    5: begin
                        // 必须隔一个时钟沿: 同一时间步内多条 op5 的 NBA 会互相覆盖
                        // (atx_qn <= atx_qn + n 三次都读到同一个旧值)
                        app_push(sa, sb[15:0], sc[3:0], sd[0], se[0]);
                        @(posedge clk);
                    end
                    6: begin
                        pc_en_rq_i = sa[3:0]; pc_en_rq_d = (sb != 0); pc_en_rq_v = 1'b1;
                        land_wait;
                    end
                    // ---- P5d: 注水 / 慢消费者 / 静默等待 ----
                    20: begin   // FLOOD 预算: a=conn b=字节数 (累加; 增量式落地)
                        fl_add_rq_i = sa[3:0]; fl_add_rq_d = sb[31:0]; fl_add_rq_v = 1'b1;
                        land_wait;
                    end
                    22: begin   // 消费率: 每 a 拍 1 字 (分级落地: 见本节头注释)
                        sink_rate_rq_d = sa[31:0]; sink_rate_rq_v = 1'b1;
                        land_wait;
                    end
                    21: begin   // WAIT 静默 (上限 a 拍): 预算空 && 在队空 && 已发==已接受
                        wt0 = 0;
                        while (!(fl_budget[0] == 32'd0 && fl_budget[1] == 32'd0 &&
                                 fl_budget[2] == 32'd0 && q_n == 5'd0 &&
                                 ack_i == 12'd0 &&
                                 pc_seq[0] == u_tcb.rcv_nxt_r[0] &&
                                 pc_seq[1] == u_tcb.rcv_nxt_r[1] &&
                                 pc_seq[2] == u_tcb.rcv_nxt_r[2]) && wt0 < sa)
                        begin @(posedge clk); wt0 = wt0 + 1; end
                        if (wt0 >= sa) begin tmo = 1;
                            $fwrite(fd, "MULTO op21 want=quiesce\n"); end
                    end
                    23: begin   // WAIT sink 已消费字节 >= a
                        wt0 = 0;
                        while ((sink_bytes[0] + sink_bytes[1] + sink_bytes[2]) < sa &&
                               wt0 < TMO_OP) begin @(posedge clk); wt0 = wt0 + 1; end
                        if ((sink_bytes[0] + sink_bytes[1] + sink_bytes[2]) < sa) begin
                            tmo = 1; $fwrite(fd, "MULTO op23 want=%0d\n", sa); end
                    end
                    24: begin   // WAIT 注水已发字节 >= a
                        wt0 = 0;
                        while ((fl_tx_bytes < sa) && wt0 < TMO_OP)
                        begin @(posedge clk); wt0 = wt0 + 1; end
                        if (fl_tx_bytes < sa) begin tmo = 1;
                            $fwrite(fd, "MULTO op24 want=%0d\n", sa); end
                    end
                    25: begin   // WAIT 洪水结束 (同 op21, 但语义名分开便于 checker 读)
                        wt0 = 0;
                        while (!(fl_budget[0] == 32'd0 && fl_budget[1] == 32'd0 &&
                                 fl_budget[2] == 32'd0 && q_n == 5'd0 &&
                                 ack_i == 12'd0 &&
                                 pc_seq[0] == u_tcb.rcv_nxt_r[0] &&
                                 pc_seq[1] == u_tcb.rcv_nxt_r[1] &&
                                 pc_seq[2] == u_tcb.rcv_nxt_r[2]) && wt0 < sa)
                        begin @(posedge clk); wt0 = wt0 + 1; end
                        if (wt0 >= sa) begin tmo = 1;
                            $fwrite(fd, "MULTO op25 want=quiesce\n"); end
                    end
                    7: begin reg_write(sa[7:0], sb); end
                    8: begin dump_reg(sa[7:0]); end
                    9: begin
                        pc_wnd_rq_i = sa[3:0]; pc_wnd_rq_d = sb[15:0]; pc_wnd_rq_v = 1'b1;
                        land_wait;
                    end
                    10: begin
                        // 手工注入: b=ack 增量, c=载荷字节 (0=纯 ACK; 数据帧 seq=pc_seq)
                        q_c[q_t[3:0]] <= sa[3:0];
                        q_s[q_t[3:0]] <= (sc == 0) ? u_tcb.rcv_nxt_r[sa[3:0]] :
                                         pc_seq[sa[3:0]];
                        q_a[q_t[3:0]] <= pc_hwm[sa[3:0]] + sb;
                        q_w[q_t[3:0]] <= pc_wnd[sa[3:0]];
                        q_p[q_t[3:0]] <= sc[10:0];
                        q_o[q_t[3:0]] <= pc_txoff;
                        q_t <= q_t + 5'd1;
                        if (sc != 0) begin
                            // 增量式 (落地时读寄存器再相加 ⇒ 不会丢并发推进)
                            pc_seq_rq_i = sa[3:0]; pc_seq_rq_d = sc;
                            pc_seq_rq_abs = 1'b0;  pc_seq_rq_v = 1'b1;
                            pc_txoff_rq_d = pc_txoff + sc; pc_txoff_rq_v = 1'b1;
                        end
                        land_wait;
                        repeat (140) @(posedge clk);
                    end
                    17: begin
                        pc_seq_rq_i = sa[3:0]; pc_seq_rq_d = sb; pc_seq_rq_abs = 1'b1;
                        pc_seq_rq_v = 1'b1;
                        land_wait;
                    end
                    19: begin dbg_cap <= sa[0]; end
                    11: begin
                        pc_sport_rq_i  = sa[3:0]; pc_sport_rq_d  = sb[15:0];
                        pc_sport_rq_v  = 1'b1;
                        pc_dport_rq_i  = sa[3:0]; pc_dport_rq_d  = sc[15:0];
                        pc_dport_rq_v  = 1'b1;
                        pc_peerip_rq_i = sa[3:0]; pc_peerip_rq_d = sd;
                        pc_peerip_rq_v = 1'b1;
                        pc_myip_rq_i   = sa[3:0]; pc_myip_rq_d   = se;
                        pc_myip_rq_v   = 1'b1;
                        pc_mac_rq_i    = sa[3:0]; pc_mac_rq_d    = {sf[15:0], sg[31:0]};
                        pc_mac_rq_v    = 1'b1;      // 48 位
                        pc_wnd_rq_i    = sa[3:0]; pc_wnd_rq_d    = sh[15:0];
                        pc_wnd_rq_v    = 1'b1;
                        pc_en_rq_i     = sa[3:0]; pc_en_rq_d     = (si != 0);
                        pc_en_rq_v     = 1'b1;
                        land_wait;
                    end
                    12: begin snapshot; end
                    16: begin atx_qn <= 0; atx_run <= 1'b0; end
                    default: ;
                endcase
            end
            if (k > K_MAX) begin
                $fwrite(fd, "MULTO global k=%0d\n", k);
                $display("P5MUL TIMEOUT k=%0d", k);
                sret = 0;   // 退出循环
                sfd = 0;
            end
        end
        if (sfd != 0) $fclose(sfd);
        repeat (2000) @(posedge clk);
        snapshot;
        $fwrite(fd, "MULDONE tmo=%0d k=%0d%c", tmo, k, 8'd10);

        $fclose(fd);
        $display("P5MUL DONE: data=%0d fin=%0d rst=%0d drop_len=%0d eend=%0d atx_fr=%0d atx_by=%0d good=%0d tmo=%0d",
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
