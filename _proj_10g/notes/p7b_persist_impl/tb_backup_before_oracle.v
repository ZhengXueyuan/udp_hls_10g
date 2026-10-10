`timescale 1ns/1ps
// ===========================================================================
// tb_tcp_tx_ovl.v -- P7b Stage C / tcp_tx_frame 乒乓 (宏 TCP_TX_OVL) 的**判据门**
// ---------------------------------------------------------------------------
// 自检式 (无 Python 依赖): TB 扮演 对端 + TCB(真 rtl/tcb.v) + CAM + snd_una 记账;
// 判据全是 "TB 侧独立复算" 的计数器, 末尾打印 SUMMARY/REDS/TB_TCP_TX_OVL, 非零即红。
// 独立 oracle:
//   J1 J_parse   每帧结构合法 (ethertype / ip total_len == 帧字节数 / ver-ihl /
//                proto / 地址 / MAC / 窗口字段 / ack 字段 / TCP flags 精确值)
//   J2 J_csum    从**线上字节**独立复算 IP 校验和 (偏移 24) 与 TCP 校验和 (偏移 50,
//                含伪头) — 逐帧断言相等 (抓共享 checksum16 被控制帧污染)
//   J3 J_payload 载荷**逐字节** = TB 的无状态字节函数 fb(流偏移);
//                流偏移 = seq - ISN ⇒ 重放帧同偏移, 天然幂等
//   J4 J_seqcont 数据帧 [seq,seq+plen): 接上前沿 (新数据) / 整段落在已发区间
//                (重放); 部分重叠 与 空洞 都记红 — 抓"少推进/复用 seq" (C1/C3)
//   J5 J_seqmono 影子账本 (从写口逐拍重建, 含 rx/cfg 写口): snd_nxt 只准前向,
//                后退只准 = 该连接 snd_una (回卷) 或非 tx 写口 (cfg 建连沿);
//                tx 写口永不低于 snd_una — M-C2 的判据
//   J6 J_ctrl    控制帧守恒 issued==transmitted (transmitted>issued 也算红) + 超时
//   J7 J_onehot0 (OVL) 每拍 $onehot0({upd_wr_data,upd_wr_ctrl,upd_wr_rew}) + 三源>0
//   J8 J_pendbusy(OVL) 每拍 pend ⊆ busy; pend 清位拍 ∈ T_HDR 及之后
//   J9 J_replay  重放覆盖到 retx_hi + 会话有界
//   J10 J_ovf    两个 bank FIFO ovf_pulse ≡ 0 (静默丢字哨兵) + stat_eend ≡ 0
// 覆盖见证 (T5) / 拍/帧 (T8, OVL) 见末尾 SUMMARY。
// 两种宏态都能编 (宏关 = 现役串行 RTL; OVL-only 判据在 `ifdef 内)。
// ===========================================================================
module tb_tcp_tx_ovl;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                 // 6.4 ns = 156.25 MHz

    localparam integer NCONN  = 4;
`ifdef TCP_TX_OVL
    localparam integer CY_MAX = 700000;
    localparam integer NF_TGT = 2100;      // 设计 §4.2 的覆盖见证: cov_frames >= 2000
`else
    // 默认 (串行) 构建: 帧周期 ~380 拍 ⇒ 2000 帧放不进预算。此档的目的是
    // **灵敏度证明** (打等价变异必须变红), 不是覆盖见证 ⇒ 目标降为 400。
    localparam integer CY_MAX = 700000;
    localparam integer NF_TGT = 400;
`endif
    localparam [15:0]  RCV_WND = 16'h4000;
    localparam [31:0]  RCV_NXT = 32'h0000_4000;
    localparam [15:0]  SND_WND = 16'hC000;
    localparam [31:0]  CBASE   = 32'h0010_0000;
    // ⭐ 构建 F: **窗帽档位** (TB 与 DUT 必须同值 —— 生产里两者同源于 wrapper 的 `WIN_CAP_5`)。
    //   `-d W67_CAP_SMALL`: 把帽压到 **8192 B**。为什么需要这一臂 (结构性, 不是调参):
    //     W67 的判据 = `win_wnd_eff >= RING_CAP`, 而 `!wnd_open` 要求在飞 >= min(snd_wnd, 帽)。
    //     默认帽 0xBFFE=49150 下本 TB 的**在飞到不了** (ack_lag=8192) ⇒ 板帽侧**恒 0**
    //     = 空判据 (判据会退化成"两个 0 相等"); 压到 8192 后每个 ACK 周期都自然越过
    //     ⇒ 板帽侧有靶; 而关窗插曲 (snd_wnd=1460) 仍是**对端侧** ⇒ 同一臂里**两侧都激励**。
    //   ⚠️ 默认档 (无该宏) = `0xBFFE` = 今天的取值 ⇒ 既有 A..M 各臂**逐位不变**。
`ifdef W67_CAP_SMALL
    localparam [15:0] TB_WIN_CAP = 16'd8192;
`else
    localparam [15:0] TB_WIN_CAP = 16'hBFFE;
`endif

    // ⭐ P7B-PERSIST (设计件 §5.2-Ⅰ / §5.3): DUT 参数注入 = **宏 + 双跑** 形态
    //   (D-10-2 定型: 取值机制 = TB 内 `ifdef` 选 localparam)。
    //   ⚠️ **非 persist 臂的取值 = DUT 自己的默认值** ⇒ 例化处那些参数覆盖是**恒等
    //      覆盖** ⇒ 既有 A..R 臂的读数逐字不变 (L2 的**结构性**保证, 不靠"我记得没改")。
    //   ⚠️ `RTO_LIM` 在 ARM_PERSIST 臂**必须显式覆盖** (设计件原话): 门不定义
    //      `DP_156MHZ` ⇒ DUT 默认 48828 visits ≈ 12.5M 拍 ≫ 本 TB 的观察窗。
    //   档值选择 (观察窗预算 = 70 万拍; 阶梯窗 = RTO + 3×PS_BASE 档):
    //     TB_RTO_LIM = 8 visits × 256 拍 = 2048 拍 ≈ 13.1 µs (首档)
    //     TB_PS_BASE = 24 visits × 256 拍 = 6144 拍 (阶梯第 1 档; 其后 ×2/×4)
    //     TB_PS_MAX  = 8192 visits (封顶档; 本 TB 结构性够不到 ⇒ 只作守卫值)
`ifdef ARM_PERSIST
    localparam integer TB_RTO_LIM = 8;
    localparam [25:0]  TB_PS_BASE = 26'd24;
    localparam [25:0]  TB_PS_MAX  = 26'd8192;
`ifdef PERSIST_NEGCTL
    localparam TB_PERSIST_EN = 1'b0;   // 臂 T (负对照): 同一刺激、DUT 门关 ⇒ 新判据必红
`else
    localparam TB_PERSIST_EN = 1'b1;   // 臂 S
`endif
`else
    localparam integer TB_RTO_LIM = 48828;            // = DUT 默认 (逐位等价)
    localparam [25:0]  TB_PS_BASE = 26'd3_051_758;    // = DUT 默认
    localparam [25:0]  TB_PS_MAX  = 26'd36_621_094;   // = DUT 默认
    localparam TB_PERSIST_EN = 1'b0;                  // = DUT 默认
`endif
    localparam integer TB_VISIT   = 256;              // 1 visit = 256 拍 (§3.1)
    // ⭐ P7B-PERSIST episode 时间尺度 (单位 = 拍; 总额 ≈ 9 万拍 ⇒ 与 70 万拍预算相容)
    localparam integer PE_AT         = 150000;   // 起点 (在既有 wc 窗口关闭插曲之后)
    localparam integer PE_LAD_WAIT   = 90000;    // E1 阶梯窗上限 (3 档 = 80 visits = 20480 拍)
    localparam integer PE_AFTER      = 2500;     // "恢复后 0 新探询" 观察窗
    localparam integer PE_E2_DRAIN   = 8000;     // E2 排空窗
    localparam integer PE_HOLD_SHORT = 16000;    // E2/E5/E6 的关窗观察窗
    //   [!!] 必须 >= 一次 fire 的 visit 时间: `ps_timer` 数的是**该连接自己的扫描访问**,
    //   16 连接轮扫 + 扫描被 ACK/重放挤稀 => 1 visit ~ 840 拍 (实测) => 8 visits ~ 7000 拍。
    //   首版 5200 拍 **小于**它 => 观察窗在 fire 之前就结束 => E5/E6 的"0 探询"是**空判据**,
    //   且 PS-MUT-1/2 (撤 !fin_sent_r / !rst_sent_r) 也因此抓不到。
    //   ⛔ 订正记录: 本条曾以为已改成 16000 —— 实际**没落地** (补丁锚点把源文件的 `×` 写成
    //      了 ASCII `x` 而 assert 在后台任务里静默失败), 现盘一度仍是 5200。
    localparam integer PE_E3_SESS    = 14000;    // E3 epoch 饱和窗
    localparam integer PE_E3_HOLD    = 34000;     // E3 关窗观察窗
    localparam integer PE_E4_WAIT    = 30000;     // E4 等 fire 窗
    localparam integer PE_E4_OBS     = 1500;     // E4 清位观察窗 (< RTO'=2048, 见 step 30 注)
    localparam integer PE_E4_PC      = 16000;     // E4 正控 (再关窗 ⇒ 探询应出现)
    localparam integer PE_COLL_WAIT  = 30000;     // E7 等 fire 窗
    localparam integer PE_COLL_OBS   = 6000;     // E7 释放后观察窗
    localparam integer PE_TAIL       = 1500;     // 通用尾窗
    // 期望间隔 (拍) = 档值 × 256: 首档 / PS_BASE / 2×PS_BASE
    localparam integer TB_T_RTO    = TB_RTO_LIM * TB_VISIT;
    localparam integer TB_T_BASE   = TB_PS_BASE * TB_VISIT;
    localparam integer TB_T_BASE2  = TB_T_BASE * 2;

    // ===================== 函数 =====================
    function [7:0] fb;                      // 无状态字节函数
        input [31:0] i;
        reg [31:0] x;
        begin
            x = (i * 32'h9E3779B1) ^ 32'h5A5A5A5A;
            x = x ^ (x >> 15);
            x = x * 32'h85EBCA6B;
            x = x ^ (x >> 13);
            x = x * 32'hC2B2AE35;
            x = x ^ (x >> 16);
            fb = x[23:16];
        end
    endfunction
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
    function [15:0] csum16;
        input [31:0] acc;
        reg [16:0] f1;
        begin
            f1 = {1'b0, acc[15:0]} + {1'b0, acc[31:16]};
            csum16 = ~(f1[15:0] + {15'b0, f1[16]});
        end
    endfunction
    function [7:0] kmask;
        input [3:0] n;
        begin
            case (n)
                4'd0: kmask = 8'h00; 4'd1: kmask = 8'h80; 4'd2: kmask = 8'hC0;
                4'd3: kmask = 8'hE0; 4'd4: kmask = 8'hF0; 4'd5: kmask = 8'hF8;
                4'd6: kmask = 8'hFC; 4'd7: kmask = 8'hFE; default: kmask = 8'hFF;
            endcase
        end
    endfunction
    function [63:0] beat_word;              // n 字节 (高字节 = 流里的先出字节)
        input [3:0]  c;
        input [31:0] off;
        input [3:0]  n;
        reg [63:0] w;
        integer j;
        begin
            w = 64'd0;
            for (j = 0; j < 8; j = j + 1)
                if (j < n) w[63 - 8*j -: 8] = fb(CBASE*c + off + j);
            beat_word = w;
        end
    endfunction
    function [11:0] seg_len_for;
        input [31:0] n;
        input [3:0]  c;
        begin
            case (n % 12)
                0:  seg_len_for = 12'd1460;
                1:  seg_len_for = 12'd1460;
                2:  seg_len_for = 12'd8;
                3:  seg_len_for = 12'd1460;
                4:  seg_len_for = 12'd1;
                5:  seg_len_for = 12'd63;
                6:  seg_len_for = (c == 4'd1) ? 12'd1501 : 12'd1460;
                7:  seg_len_for = 12'd0;
                8:  seg_len_for = 12'd1460;
                9:  seg_len_for = 12'd7;
                10: seg_len_for = (c == 4'd1) ? 12'd4096 : 12'd1460;
                default: seg_len_for = 12'd1460;
            endcase
        end
    endfunction

    // ===================== TB 状态声明 =====================
    reg  [7:0]  fr [0:1663];                // 线上帧缓冲 (最大 54+1500)
    reg  [11:0] fpos;
    integer e_idem, e_below_retx, e_replay_tail, e_f1, e_f1_ring, e_cov, e_j9;
    integer cov_aborts, cov_cdadj, cov_ctrlblock_real, c6_gated;
    integer c6_req_win, e_c6, e_c6_grant;   // M-C6 定向窗口 (审查构造)
    integer e_f1_delta, e_f1_cyc;           // F1: delta 非负 / 每拍 wrap-safe
    // ⭐ P7B-RETXFIX 判据 (2026-10-07): 重放预算跨度 / 收尾跳写 / 控制预留同拍
    integer e_replay_span, e_replay_jump, e_c2_resv, cov_c2_resv, rep_f0, rep_smax;
    // ⭐ r6 (L-A, 2026-10-08): ARM_ACKGATE 专项臂 (ack_seen 数据启动门) 计数器
    integer e_ag_block, e_ag_resume;
    integer cov_jump_ev;   // 跳写事件数 (覆盖见证: 预算被撞到时 replay_jump 拍数)
    reg     rep_full;      // ⭐ r4: 本会话 = RTO 全会话 (replay_full) ⇒ 跨度判据豁免
    reg     stuck_r;                        // 自锁会话去重 (每会话只计一次)
    reg     win_prev, c6_hold;              // 窗口上升沿检测 / 窗口内持请求
`ifdef TCP_TX_OVL
    wire    d_ctrl_win = u_dut.ctrl_slot_busy && (|u_dut.ctrl_is) && !u_dut.tx_is_ctrl;
    wire [31:0] d_ring_delta = u_dut.ring_delta;
    wire        d_ring_act   = u_dut.ring_act;
    wire [11:0] d_plen_preset= u_dut.plen_preset;
    wire    d_svc_rew  = u_dut.svc_rewind;
    wire    d_adv_infl = u_dut.ctrl_adv_inflight;
`else
    wire    d_ctrl_win = 1'b0;
    wire    d_svc_rew  = 1'b0;
    wire    d_adv_infl = 1'b0;
    wire [31:0] d_ring_delta = 32'd0;
    wire        d_ring_act   = 1'b0;
    wire [11:0] d_plen_preset= 12'd0;
`endif
    integer ctrlp_cyc;       // task(帧上线清看门狗) 与 OVL 块共用: 提前声明
    integer last_fin_w_cyc, min_wr_gap;
    reg [31:0] rep_hi, rep_max, rep_hi_w;   // J9 覆盖记账 (task 也写)
    reg [31:0] j9_hi;
    reg [3:0]  j9_conn;
    integer    j9_dl;
    reg        rep_lo_ok;
    integer    rep_fcnt, rep_wcnt;
`ifdef TBDBG
    reg dbg_on = 1'b1;
`else
    reg dbg_on = 1'b0;
`endif
    integer dbg_d, dbg_c, dbg_s, dbg_n, dbg_ar, dbg_w, dbg_e, dbg_p, dbg_q;
    initial begin dbg_d=0; dbg_c=0; dbg_s=0; dbg_n=0; dbg_ar=0; dbg_w=0; dbg_e=0; dbg_p=0; dbg_q=0; end
    integer e_parse, e_csum, e_payload, e_seqcont, e_seqmono, e_ctrl, e_ctrl_to,
            e_onehot, e_pendbusy, e_replay, e_replay_stuck, e_ovf, e_ackf, e_replay_gap;
    integer n_frames, n_data, n_ctrl, n_dead_skip;
    integer cov_replay_sessions, cov_replay_frames, cov_plen0, cov_singlebeat,
            cov_ctrlblock, cov_conns, cov_fin_min, min_fin_gap, cov_rewinds;
    integer rx_cyc_min, rx_cyc_sum, rx_cyc_n, tx_cyc_min, tx_cyc_sum, tx_cyc_n;
    integer fp_min, fp_sum, fp_n, last_tx_done_cyc, cyc;
    integer i, j, kk, cc, t_conn;
    reg [31:0] isn    [0:15];
    reg [31:0] peer_rcv[0:15];
    reg [31:0] exp_new [0:15];              // 已上线新数据前沿 (peer 视角)
    reg [31:0] sh_nxt  [0:15];
    reg [31:0] sh_una  [0:15];
    reg        live   [0:15], dead[0:15], fin_seen[0:15], rst_seen[0:15];
    reg        syn_seen[0:15], haddata[0:15];
    reg [31:0] nseg   [0:15];
    reg        win_open_dly [0:15];
    integer    ack_lag[0:15];
    integer    w_data[0:15], w_ctrl[0:15], w_fin[0:15], w_syn[0:15], w_rst[0:15];
    reg        stall [0:15];
    reg        ack_first [0:15];
    integer    stall_cyc [0:15];

    initial begin
        e_parse=0; e_csum=0; e_payload=0; e_seqcont=0; e_seqmono=0; e_ctrl=0;
        e_ctrl_to=0; e_onehot=0; e_pendbusy=0; e_replay=0; e_replay_stuck=0;
        e_ovf=0; e_ackf=0; e_idem=0; e_replay_gap=0; e_below_retx=0; e_replay_tail=0;
        e_f1=0; e_f1_ring=0; e_cov=0; e_j9=0;
        cov_aborts=0; cov_cdadj=0; cov_ctrlblock_real=0; c6_gated=0;
        c6_req_win=0; e_c6=0; e_c6_grant=0; win_prev=1'b0; c6_hold=1'b0;
        e_f1_delta=0; e_f1_cyc=0; stuck_r=1'b0;
        e_replay_span=0; e_replay_jump=0; e_c2_resv=0; cov_c2_resv=0;
        e_ag_block=0; e_ag_resume=0;
        rep_f0=0; rep_smax=0; cov_jump_ev=0; rep_full=1'b0;
        n_frames=0; n_data=0; n_ctrl=0; n_dead_skip=0;
        cov_replay_sessions=0; cov_replay_frames=0; cov_plen0=0; cov_singlebeat=0;
        cov_ctrlblock=0; cov_conns=0; cov_fin_min=0; min_fin_gap=1000000;
        cov_rewinds=0;
        rx_cyc_min=1000000; rx_cyc_sum=0; rx_cyc_n=0;
        tx_cyc_min=1000000; tx_cyc_sum=0; tx_cyc_n=0;
        fp_min=1000000; fp_sum=0; fp_n=0; last_tx_done_cyc=-1; cyc=0;
        last_fin_w_cyc=-1; min_wr_gap=1000000; j9_dl=0; j9_hi=0; j9_conn=0;
        for (i = 0; i < 16; i = i + 1) begin
            isn[i]=0; peer_rcv[i]=0; exp_new[i]=0; sh_nxt[i]=0; sh_una[i]=0;
            live[i]=0; dead[i]=0; fin_seen[i]=0; rst_seen[i]=0; syn_seen[i]=0;
            haddata[i]=0; nseg[i]=0; win_open_dly[i]=0; ack_lag[i]=8192;
            w_data[i]=0; w_ctrl[i]=0; w_fin[i]=0; w_syn[i]=0; w_rst[i]=0;
            stall[i]=0; stall_cyc[i]=0; ack_first[i]=0;
        end
        isn[0]=32'h0000_F100; isn[1]=32'h0001_2300;
        isn[2]=32'h7FFF_FC00; isn[3]=32'h0000_0800;
    end
    always @(posedge clk) cyc <= cyc + 1;

    // ===================== 常量/激励寄存器 =====================
    reg  [47:0] cfg_src_mac = 48'h02_00_00_00_00_01;
    reg  [31:0] cfg_src_ip  = 32'hC0A8_6402;
    wire [63:0] s_tdata; wire [7:0] s_tkeep; wire s_tvalid, s_tready, s_tlast;
    wire [3:0]  s_tid;
    reg         ack_req; reg [3:0] ack_id; reg [31:0] ack_val;
    reg         ack_syn, ack_fin, ack_rst;
    reg  [15:0] fin_req, rst_req;
    // ⭐ P7B-PERSIST 激励钩子 (默认全 0 ⇒ 既有臂零影响; 只有 ARM_PERSIST 的那段 FSM 写它们):
    //   · `src_skip[c]`   = 源侧不启动 c 的帧 (can_start 里加一项)
    //   · `psc_ack_hold[c]` = TB 不给 c 发 rx ACK (冻结其 snd_una —— 探询的 seq 见证量)
    //   · `pe_no_retx`    = 暂停 TB 的周期 retx_req 注入 (让 episode 时序确定)
    reg  [15:0] src_skip, psc_ack_hold;
    reg         pe_no_retx;
    reg         cfg_up; reg [3:0] cfg_up_id;
    wire [15:0] o_fin_sent, o_rst_sent;
    reg         wu_req; reg [3:0] wu_id; reg [31:0] wu_val; wire wu_gnt;
    reg         retx_req; reg [3:0] retx_id; wire retx_gnt;
    reg         m_tready;
    reg [63:0]  beat_d; reg [7:0] beat_k; reg beat_l, beat_v; reg [3:0] beat_id;
    reg [1:0]   cur_c, rr, phase, ack_sch;
    reg [11:0]  cur_len, cur_pos;
    reg [31:0]  cur_kb;
    reg [3:0]   cur_n;
    reg [3:0]   setup_c;
    reg [3:0]   setup_st [0:15];   // note: 4-bit, state goes to 10
    reg [15:0]  tmp_sel;
    reg [31:0]  trq_next;
    reg [8:0]   c6_tmr;
    integer     c6_n;
    reg         rx_upd_wr; reg [3:0] rx_upd_id; reg [2:0] rx_upd_sel;
    reg  [31:0] rx_upd_val;
    reg         scfg_upd_wr; reg [3:0] scfg_upd_id; reg [2:0] scfg_upd_sel;
    reg  [31:0] scfg_upd_val;
    initial begin
        ack_req=0; ack_id=0; ack_val=RCV_NXT; ack_syn=0; ack_fin=0; ack_rst=0;
        fin_req=0; rst_req=0; cfg_up=0; cfg_up_id=0;
        wu_req=0; wu_id=0; wu_val=0; retx_req=0; retx_id=0;
        m_tready=1; rx_upd_wr=0; rx_upd_id=0; rx_upd_sel=0; rx_upd_val=0;
        src_skip=16'h0; psc_ack_hold=16'h0; pe_no_retx=1'b0;   // P7B-PERSIST 钩子
        scfg_upd_wr=0; scfg_upd_id=0; scfg_upd_sel=0; scfg_upd_val=0;
        beat_d=0; beat_k=8'h00; beat_l=0; beat_v=0; beat_id=0;
        cur_c=0; rr=0; phase=0; ack_sch=0; cur_len=0; cur_pos=0; cur_kb=0; cur_n=0;
        setup_c=0; trq_next=32'd20000; tmp_sel=0; c6_tmr=9'd0; c6_n=0;
        for (i = 0; i < 16; i = i + 1) setup_st[i] = 4'd0;
    end

`ifdef ARM_PERSIST
    // ================= ⭐ P7B-PERSIST 判据组状态 (设计件 §5.2; 只在 ARM_PERSIST 臂) ====
    //   单写者纪律: FSM 写 `pe_st/pe_t/pe_holdb/psc_win_closed/pe_exp_*/pe_clr_pc/…`;
    //   观察块写计数器 (`pe_probe_ep/out/cur/pn/pe_pt[]/判决计数器`);
    //   `frame_check` 只写事件记录 (`pe_probe_ev/pe_probe_bad/pe_rec_*`)。
    // ---- FSM ----
    reg  [6:0]  pe_st;              // 主状态 (0 = 空闲; 见建连 FSM 块末的 episode 驱动)
    integer     pe_t;               // 步内计时
    reg  [3:0]  pe_ep;              // 当前 episode 编号 (1..7)
    reg  [6:0]  pe_ret;             // "静默例程"的返回状态 (见 7'd70 起的 Q 段)
    integer     pe_x;               // 初始化/复位循环变量 (两处共用, 唯一一处声明)
`ifdef ARM_PERSIST
    // ==== PERSIST 归因探针 (声明处; always 体在源声明之后) ====
    reg [3:0]  dbg_sd_c;  reg [31:0] dbg_sd_kb;  reg [11:0] dbg_sd_pos;
    reg [7:0]  dbg_sd_b0; reg         dbg_sd_op;
    initial begin dbg_sd_c=0; dbg_sd_kb=0; dbg_sd_pos=0; dbg_sd_b0=0; dbg_sd_op=0; end
`endif
    reg  [3:0]  pe_conn;            // 当前 episode 的目标连接
    reg         pe_holdb;           // E4/E7: 按住 conn0 的 data-start 门 (tx_blk_sid)
    reg         pe_clr_pc;          // 1 拍脉冲: 观察块清"当前 episode 探询计数/时刻表"
    reg  [15:0] psc_win_closed;     // "TB 自己关的窗" 位图 (探询分类器的末项)
    reg  [31:0] pe_exp_seq [0:15];  // 关窗时刻的 snd_una 快照 (探询 seq 的期望值)
    reg  [3:0]  pe_exp_conn;        // 当前 episode 期望的探询连接 (A)
    // ---- 事件记录 (写者 = frame_check) ----
    integer     pe_probe_ev, pe_probe_bad;
    integer     pe_rec_cyc; reg [3:0] pe_rec_conn; reg [31:0] pe_rec_seq;
    reg [11:0]  pe_rec_plen; reg [15:0] pe_rec_iplen;
    reg [7:0]   pe_rec_flags, pe_rec_pay;
    // ---- 观察块状态 ----
    integer     pe_probe_seen, pe_probe_ep, pe_probe_out, pe_probe_cur, pe_pn;
    integer     pe_pt [0:7];        // 当前 episode 内的探询时刻表 (≤8 条, 单位 = 拍)
    integer     pe_pv [0:7];        // 同上, 但单位 = **conn1 的扫描访问数 (visits)**
    integer     w_vis1, w_vis1_cyc; // conn1 的扫描访问计数 / 最近一次访问拍号
    integer     w_leak1;            // 关窗期仍上线 conn1 数据帧数 (既存偏斜的泄漏见证)
    integer     pe_d_seen;          // 数据帧事件消费游标
    // E1 阶梯的 visit 口径快照 (FSM 写)
    integer     pe_lad_vc, pe_lad_vo, pe_lad_vr, pe_f_gap4_v;
    integer     pe_lad_dc, pe_lad_d1, pe_lad_d2;   // 阶梯三档的 visit 间隔 (判据主口径)
    integer     pe_sn_first, pe_sn_last;            // j3: 探询序列首/末的 snd_nxt 快照
    integer     w_ps_rst1;          // E6' 的 rst_sent_r[1] 见证
    integer     w_ps_quiet_to;      // 静默例程超时次数 (见证: 重放机没压静)
    integer     w_ps_dbg;           // E7 诊断打印计数 (≤10 行)
    integer     w_ps_dbg4;          // E3 观察窗诊断计数 (≤10 行)
    integer     w_ps_dbg2;          // conn1 数据帧诊断计数 (≤14 行)
    integer     w_ps_e5ok, w_ps_e6ok;   // E5/E6 粘滞见证: 除 !fin/!rst 外武装条件全真过
    // ---- 各 episode 的判决计数器 (0 = 绿) ----
    integer     e_ps_ladder, e_ps_stop, e_ps_field, e_ps_side, e_ps_sndnxt;
    integer     e_ps_e2, e_ps_e3, e_ps_e4, e_ps_e5, e_ps_e6, e_ps_coll;
    integer     e_ps_negctl;        // 臂 T 专用: "门关 ⇒ 该有的现象没出现" 计数
    // ---- 见证 (非空判据) ----
    integer     w_ps_lad, w_ps_drain, w_ps_blocked, w_ps_rdy, w_ps_cfgu_pc;
    integer     w_ps_fin, w_ps_rst, w_ps_coll, w_ps_posctrl, w_ps_out_cyc;
    integer     w_ps_retx_req;      // 窗口内 TB 自己发的 retx_req 数 (j9/j3 的比较基准)
    // ---- E1 阶梯的时刻快照 (FSM 在 episode 尾拷贝; 观察块不再动) ----
    integer     pe_lad_n, pe_lad_t0, pe_lad_t1, pe_lad_t2;
    integer     pe_lad_close, pe_lad_reclose, pe_lad_reopen;
    integer     pe_f_reclose_gap;   // 再关窗 ⇒ 首探询的间隔 (应 ≈ RTO 档)
    // ---- 各 episode 的判决输入 (FSM 在 episode 尾快照) ----
    integer     pe_f_e2_probe, pe_f_e3_probe, pe_f_e4_probe;
    integer     pe_f_e5_probe, pe_f_e6_probe, pe_f_e7_wit;
    integer     pe_lad_n2;          // E1b 关窗前的累计探询数 (j7a: 恢复窗内新增 = 0)
    integer     w_ps_e5win, w_ps_e6win;   // E5/E6 观察窗内 "该连接 snd_wnd==0" 拍数 (见证)
    integer     pe_de0, pe_de1;     // E7 观察窗内数据帧计数 (见证: 窗内确有数据流)
    reg  [2:0]  pe_f_e5_state, pe_f_e6_state;   // {fin_sent, rst_sent, snd_nxt != snd_una}
    integer     pe_stat0, pe_stat1, pe_req0, pe_req1, pe_sndnxt0, pe_sndnxt1;
    reg         pe_done;
    // ---- 多连接相撞 episode (E7) ----
    reg         pe_coll_arm;
    integer     pe_coll_wit;        // 相撞见证 (psc_coll 成立拍数)
    integer     pe_coll_seq, pe_coll_conn;
    integer     e_coll_bad, w_coll_frame;
    // ---- 帧事件记录 (写者 = frame_check; 观察块按事件变化消费) ----
    integer     pe_d_ev;  reg [3:0] pe_d_conn;  reg [31:0] pe_d_seq;
    // (相撞判据的三根 wire 见下方 "DUT 例化之后" —— 它们要引用 win_open 等线网)

    // ⚠️ 必须初始化 (实测踩过): 这些 reg 若为 X ⇒ `case (pe_st)` 永不匹配 ⇒ episode 全不跑;
    //    且 `ack_seen_tb` 的三目在 `pe_holdb = X` 下出 `16'hFFFX` ⇒ **conn0 的数据门被 X
    //    卡住** (相位卡在 0 ⇒ 无 FIN/RST ⇒ 跑满 CY_MAX)。初始值与既有 TB 计数器同款:
    //    在 `initial` 里给初值 (rst_n 只在 t=0 断言一次)。
    initial begin
        pe_st = 7'd0; pe_t = 0; pe_ep = 4'd0; pe_conn = 4'd0;
        pe_holdb = 1'b0; pe_clr_pc = 1'b0; psc_win_closed = 16'h0; pe_exp_conn = 4'd0;
        pe_lad_n = 0; pe_lad_t0 = 0; pe_lad_t1 = 0; pe_lad_t2 = 0; pe_lad_n2 = 0;
        pe_lad_close = 0; pe_lad_reclose = 0; pe_lad_reopen = 0; pe_f_reclose_gap = 0;
        pe_lad_vc = 0; pe_lad_vo = 0; pe_lad_vr = 0; pe_f_gap4_v = 0;
        pe_lad_dc = 0; pe_lad_d1 = 0; pe_lad_d2 = 0; w_ps_rst1 = 0;
        w_ps_quiet_to = 0; w_ps_e5ok = 0; w_ps_e6ok = 0; pe_ret = 7'd1; w_ps_dbg = 0;
        w_ps_dbg2 = 0;
        w_ps_dbg4 = 0;   // ⚠️ 必须初始化: 未初始化 = X ⇒ `w_ps_dbg4 < 10` 为 X ⇒ 诊断不打
                         //    (实测踩过: E3 观察窗的诊断因此静默一整个 episode)
        pe_f_e2_probe = 0; pe_f_e3_probe = 0; pe_f_e4_probe = 0;
        pe_f_e5_probe = 0; pe_f_e6_probe = 0; pe_f_e7_wit = 0;
        pe_f_e5_state = 3'b0; pe_f_e6_state = 3'b0;
        pe_stat0 = 0; pe_stat1 = 0; pe_req0 = 0; pe_req1 = 0;
        pe_sndnxt0 = 0; pe_sndnxt1 = 0; pe_done = 1'b0;
        w_ps_e5win = 0; w_ps_e6win = 0; pe_de0 = 0; pe_de1 = 0;
        w_ps_lad = 0; w_ps_drain = 0; w_ps_blocked = 0; w_ps_rdy = 0;
        w_ps_cfgu_pc = 0; w_ps_fin = 0; w_ps_rst = 0; w_ps_coll = 0;
        w_ps_posctrl = 0; w_ps_out_cyc = 0; w_ps_retx_req = 0;
        // 事件记录 (写者 = frame_check) 与判决计数器 (写者 = summary)
        pe_probe_ev = 0; pe_probe_bad = 0; pe_d_ev = 0;
        pe_rec_cyc = 0; pe_rec_conn = 4'd0; pe_rec_seq = 0; pe_rec_plen = 0;
        pe_rec_iplen = 0; pe_rec_flags = 8'h00; pe_rec_pay = 8'h00;
        pe_coll_arm = 1'b0; pe_coll_seq = 0; pe_coll_conn = 0;
        e_coll_bad = 0; w_coll_frame = 0;
        e_ps_ladder = 0; e_ps_stop = 0; e_ps_field = 0; e_ps_side = 0;
        e_ps_sndnxt = 0; e_ps_e2 = 0; e_ps_e3 = 0; e_ps_e4 = 0;
        e_ps_e5 = 0; e_ps_e6 = 0; e_ps_coll = 0; e_ps_negctl = 0;
        for (pe_x = 0; pe_x < 8; pe_x = pe_x + 1) pe_pt[pe_x] = 0;
    end
`endif

    // ===================== TCB + CAM + 仲裁 =====================
    wire [3:0]  rb_id, cam_rd_id;
    wire [31:0] rb_snd_nxt, rb_rcv_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;
    wire        win_open;
    wire [15:0] win_inflight, win_wnd_eff;
    wire        tx_upd_wr; wire [3:0] tx_upd_id; wire [2:0] tx_upd_sel;
    wire [31:0] tx_upd_val;
    wire        sel_tx = tx_upd_wr;
    wire        sel_rx = !sel_tx && rx_upd_wr;
    wire        rx_upd_gnt = sel_rx;
    wire        scfg_gnt = !sel_tx && !sel_rx;
    wire        tcb_wr  = sel_tx || sel_rx || (scfg_upd_wr && scfg_gnt);
    wire [2:0]  tcb_sel = sel_tx ? tx_upd_sel : (sel_rx ? rx_upd_sel : scfg_upd_sel);
    wire [3:0]  tcb_id  = sel_tx ? tx_upd_id  : (sel_rx ? rx_upd_id  : scfg_upd_id);
    wire [31:0] tcb_val = sel_tx ? tx_upd_val : (sel_rx ? rx_upd_val : scfg_upd_val);

    tcb #(.N(16), .WIN_CAP(TB_WIN_CAP)) u_tcb (   // 构建 F: 与 DUT 的 RING_CAP 同值 (见 TB_WIN_CAP 注)
        .clk(clk), .rst_n(rst_n),
        .ra_id(4'd0), .ra_rcv_nxt(), .ra_snd_nxt(), .ra_snd_una(),
        .ra_rcv_wnd(), .ra_snd_wnd(), .ra_state(), .ra_wscale(),
        .rb_id(rb_id), .rb_rcv_nxt(rb_rcv_nxt), .rb_snd_nxt(rb_snd_nxt),
        .rb_snd_una(rb_snd_una), .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
        .win_id(rb_id), .win_open(win_open), .win_inflight(win_inflight),
        .win_wnd_eff(win_wnd_eff),
        .rc_id(4'd0), .rc_rcv_nxt(), .rc_snd_nxt(), .rc_snd_una(), .rc_rcv_wnd(),
        .rc_snd_wnd(), .rc_state(),
        .dbg_snd_nxt0(), .dbg_snd_una0(), .dbg_rcv_nxt0(), .dbg_snd_wnd0(),
        .dbg_wscale0(), .dbg_state0(),
        .upd_wr(tcb_wr), .upd_id(tcb_id), .upd_sel(tcb_sel), .upd_val(tcb_val)
    );

    reg  [47:0] cam_dmac [0:15];
    reg  [31:0] cam_sip  [0:15];
    reg  [15:0] cam_sport[0:15];
    reg  [15:0] cam_dport[0:15];
    wire [47:0] cam_rd_dmac  = cam_dmac [cam_rd_id];
    wire [31:0] cam_rd_sip   = cam_sip  [cam_rd_id];
    wire [15:0] cam_rd_sport = cam_sport[cam_rd_id];
    wire [15:0] cam_rd_dport = cam_dport[cam_rd_id];
    initial for (i = 0; i < 16; i = i + 1) begin
        cam_dmac[i]  = 48'hAA_BB_CC_DD_EE_00 + i;
        cam_sip[i]   = 32'hC0A8_6400 + (i + 10);
        cam_sport[i] = 16'd40000 + i;
        cam_dport[i] = 16'd8080;
    end

    // ===================== DUT =====================
    wire [63:0] m_tdata; wire [7:0] m_tkeep; wire m_tvalid, m_tlast;
    wire [31:0] stat_retx;
    // ⭐ 构建 E: W66 = tcp_tx_frame.stat_winstall (帧器侧窗口门停顿拍数)
    wire [31:0] w_stat_winstall;
    // ⭐ 构建 F: W67 = 板帽侧等窗拍数 / W69 = 等窗拍操作点锁存 (源同模块, 纯观测)
    wire [31:0] w_stat_winstall_cap;
    wire [31:0] w_win_at_winstall;
    //   定向窗口关闭插曲 (见下方激励块) 的参数与状态
    localparam integer WC_AT   = 120000;   // 关窗起始拍 (远早于覆盖率目标)
    localparam integer WC_HOLD = 12000;    // 关窗保持拍 (≈6 个 ACK 周期)
    localparam [3:0]   WC_CONN = 4'd1;     // 目标连接 (避开 conn0 的 SYN 特例 / conn2·3 的 FIN·RST 臂)
    reg  [2:0]  wc_st;                     // 0=等触发 1=写关窗中 2=保持 3=写回中 4=完
                                           //   ⚠️ 必须 3 位: 终态 4 大于 2 位满量程 ⇒
                                           //   2 位时会被截断回 0 (读数看着像"插曲没跑")
    reg  [31:0] wc_cyc;                    // 关窗保持计时
    // ⭐ W66 的 **TB 侧独立复算** (逐拍; 与 RTL 判据同源但**独立实现**):
    //   ⚠️ 刻意**不引用** `u_dut.stat_winstall_ev` —— 引用它会让判据变成环路恒等式
    //      (变异体改判据时 oracle 跟着改 ⇒ 永远相等 = 没牙)。这里逐项自写:
    //      rx_state/recv_first/ack_pend_r/svc/ring_eval/scan_now/rx_flush/fifo_full/
    //      bank_rdy/tx_blk_sid 全是读 DUT 的**状态线**, 判据表达式由本 TB 写。
    integer     exp_winstall_cyc;          // TB 复算的窗口门停顿拍数
    // ⭐ 构建 F 的 TB 侧复算 (与 W66 同款: **逐项自写**, 不引用 DUT 的判据线)
    integer     exp_winstall_cap_cyc;      // TB 复算: 其中"板帽侧"那一份 (W67 的期望值)
    reg  [31:0] exp_win_at_winstall;       // TB 复算: 最近一次等窗拍的 {在飞, 有效窗} (W69)
    reg         wc_seen;                   // 见证: 窗口确实被观察到关过 (!wnd_open)
    wire [31:0] o_retx_hi; wire o_retx_active; wire [3:0] o_retx_id;
    wire [31:0] stat_frames, stat_bytes, stat_ack, stat_ack_drop, stat_eend,
                stat_drop_len, stat_fin, stat_rst, stat_tlast_in;

    // ⭐ r6 (L-A, 2026-10-08): ack_seen 驱动源 —— 声明必须在 u_dut 例化**之前**
    //   (坑 24: 例化处先用会隐式声明 1 位网, 与下方显式声明冲突 ⇒ xvlog 硬错)
`ifdef ARM_ACKGATE
    reg [15:0] ack_seen_tb;
    reg  [1:0] ag_st;
    integer    ag_cyc, ag_wit_sv;
    reg        ag_seen_sd;
`elsif ARM_PERSIST
    // ⭐ P7B-PERSIST 臂: 本臂**自己驱动** ack_seen_tb —— E7 的 "data-start 门 hold":
    //   `tx_blk_sid = tx_blk | ~st_ok | ~acks_ok`, 拉低 `acks_ok[B]` 只按住 **B 的**
    //   数据帧启动门 (start_data / s_axis_tready 逐字同门 ⇒ 只延迟, 不变语义),
    //   而**不动任何探询门槛** ⇒ 这正是 E7 要的"探询待发 + 数据帧就绪"的可控相位。
    reg [15:0] ack_seen_tb;
    initial ack_seen_tb = 16'hFFFF;   // ⚠️ 必须给初值 (X 会长到 tx_blk_sid 上卡住数据门)
`else
    wire [15:0] ack_seen_tb = 16'hFFFF;   // 既有臂: 门恒开 (本刀不动既有判据)
`endif

    // ⭐ P7B-PERSIST: 参数注入 (取值 = 上面的 localparam; 非 persist 臂 = DUT 默认值
    //   ⇒ 恒等覆盖, 逐位等价)。`.RTO_LIM` 覆盖是**必须**的 (见上)。
    tcp_tx_frame #(.RING_CAP(TB_WIN_CAP), .RTO_LIM(TB_RTO_LIM),
                   .PERSIST_EN(TB_PERSIST_EN), .PS_BASE(TB_PS_BASE),
                   .PS_MAX(TB_PS_MAX)) u_dut (   // 构建 F: 与 u_tcb.WIN_CAP 同值
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tid(s_tid),
        .ack_req(ack_req), .ack_id(ack_id), .ack_val(ack_val), .ack_syn(ack_syn),
        .ack_seen_i(ack_seen_tb),   // ⭐ r6 (L-A): 宏外恒 FFFF (见下方驱动块)
        .ack_fin(ack_fin), .ack_rst(ack_rst),
        .fin_req(fin_req), .rst_req(rst_req),
        .cfg_up(cfg_up), .cfg_up_id(cfg_up_id),
        .o_fin_sent(o_fin_sent), .o_rst_sent(o_rst_sent),
        .wu_req(wu_req), .wu_id(wu_id), .wu_val(wu_val), .wu_gnt(wu_gnt),
        .rb_id(rb_id), .rb_snd_nxt(rb_snd_nxt), .rb_rcv_nxt(rb_rcv_nxt),
        .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_una(rb_snd_una), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
        .win_open(win_open), .win_inflight(win_inflight), .win_wnd_eff(win_wnd_eff),
        .retx_req(retx_req), .retx_id(retx_id), .retx_gnt(retx_gnt),
        .stat_retx(stat_retx),
        .stat_winstall(w_stat_winstall),
        .stat_winstall_cap(w_stat_winstall_cap),   // 构建 F: W67
        .o_win_at_winstall(w_win_at_winstall),     // 构建 F: W69
        .o_retx_hi(o_retx_hi), .o_retx_active(o_retx_active), .o_retx_id(o_retx_id),
        .upd_wr(tx_upd_wr), .upd_id(tx_upd_id), .upd_sel(tx_upd_sel),
        .upd_val(tx_upd_val),
        .cam_rd_id(cam_rd_id), .cam_rd_dmac(cam_rd_dmac), .cam_rd_sip(cam_rd_sip),
        .cam_rd_sport(cam_rd_sport), .cam_rd_dport(cam_rd_dport),
        .cfg_src_mac(cfg_src_mac), .cfg_src_ip(cfg_src_ip),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .stat_frames(stat_frames), .stat_bytes(stat_bytes), .stat_ack(stat_ack),
        .stat_ack_drop(stat_ack_drop), .stat_eend(stat_eend),
        .stat_drop_len(stat_drop_len), .stat_fin(stat_fin), .stat_rst(stat_rst),
        .stat_tlast_in(stat_tlast_in),
        .dbg_wnd_open(), .dbg_pay_full(), .dbg_sready(), .dbg_saxis_tvalid(),
        .dbg_plen_r(), .dbg_state(), .dbg_pay_wptr(), .dbg_pay_rptr(),
        .dbg_pay_full2(), .dbg_pay_empty(), .dbg_plen()
    );
    // (s_tready 由 DUT 输出端口驱动; 再加 assign 会形成自环网 => X)

`ifdef ARM_PERSIST
    // ---- ⭐ P7B-PERSIST E7 的相撞判据 (TB **自写**; 与 RTL 的 ds_guard 同式不同源) ----
    //   三根 wire 逐项取自 DUT 的**状态线/输入**与 TB 自己的 `s_tvalid/s_tid`:
    //     · `pe_probe_gates` = `probe_sel` 里**除 ds_guard 之外**的全部正项 (逐项自写);
    //     · `pe_dsg` = 与 RTL `ds_guard` **同值** (取反的 6 项合取) —— 即 "guard 开着";
    //     · `pe_startdata_nodsg` = "**没有** ds_guard 时, 探询槽上线 **∧** 数据帧同时启动"
    //       = 这一拍就是**那条缺陷拍** (数据帧带探询连接的四元组 + seq 上线);
    //     · `psc_coll` = 同上, 且**呈交的帧属于别的连接** (跨连接可判; A==B 时自洽不可判)。
    //   ⛔ 刻意**不引用** `u_dut.ds_guard / u_dut.probe_sel` (否则判据成环路恒等式)。
    wire pe_probe_gates = u_dut.ps_stage_rdy && u_dut.ps_stage_estab &&
                          u_dut.rx_idle && !u_dut.rx_flush && !u_dut.ctrl_slot_busy &&
                          u_dut.ackq_empty && !u_dut.svc && !u_dut.ring_eval &&
                          !u_dut.scan_now && !u_dut.retx_active;
    wire pe_dsg = ~(u_dut.recv_first && s_tvalid && !u_dut.ack_pend_r &&
                    !u_dut.fifo_full && !u_dut.bank_rdy[u_dut.rx_bank] && win_open);
    wire pe_startdata_nodsg = pe_probe_gates && !pe_dsg && !u_dut.tx_blk_sid;
    wire psc_coll = pe_probe_gates && !pe_dsg && !u_dut.tx_blk_sid &&
                    (s_tid != pe_exp_conn);
`endif

    // ===================== 帧内字访问 (读 fr) =====================
    function [15:0] fw;
        input [11:0] o;
        begin
            fw = {fr[o], fr[o + 12'd1]};
        end
    endfunction

    // ===================== 帧解析/判据 =====================
    task frame_check;
        reg [7:0]  flags;
        reg [11:0] plen;
        reg [31:0] fseq, ip_acc, tcp_acc;
        reg [15:0] ip_len;
        reg        is_probe;   // ⭐ P7B-PERSIST: 线上字段分类器 (见下; 非该臂恒 0)
        integer    c;
        begin
            n_frames = n_frames + 1;
            t_conn = -1;
            for (c = 0; c < NCONN; c = c + 1)
                if ((cam_dport[c] == fw(34)) && (cam_sport[c] == fw(36))) t_conn = c;
            if ((fpos < 54) || (t_conn < 0)) begin
                e_parse = e_parse + 1;
                $display("[FAIL] parse fpos=%0d conn=%0d @%0d", fpos, t_conn, cyc);
            end else begin
                ip_len = fw(16);
                flags  = fr[47];
                plen   = fpos - 12'd54;
                // ---- 结构 ----
                if (fw(12) !== 16'h0800) begin
                    e_parse = e_parse + 1; $display("[FAIL] ethertype @%0d", cyc); end
                if (ip_len !== (fpos - 12'd14)) begin
                    e_parse = e_parse + 1;
                    $display("[FAIL] total_len=%0d fpos=%0d @%0d", ip_len, fpos, cyc); end
                if ((fr[14] !== 8'h45) || (fr[23] !== 8'd6)) begin
                    e_parse = e_parse + 1; $display("[FAIL] ip hdr @%0d", cyc); end
                if (fr[46][7:4] !== 4'h5) begin
                    e_parse = e_parse + 1; $display("[FAIL] tcp doff @%0d", cyc); end
                if ((fw(26) !== cfg_src_ip[31:16]) || (fw(28) !== cfg_src_ip[15:0]) ||
                    (fw(30) !== cam_sip[t_conn][31:16]) ||
                    (fw(32) !== cam_sip[t_conn][15:0])) begin
                    e_parse = e_parse + 1; $display("[FAIL] ip addr @%0d", cyc); end
                if ((fw(0) !== cam_dmac[t_conn][47:32]) ||
                    (fw(2) !== cam_dmac[t_conn][31:16]) ||
                    (fw(4) !== cam_dmac[t_conn][15:0])) begin
                    e_parse = e_parse + 1; $display("[FAIL] dmac @%0d", cyc); end
                if ((fw(6) !== cfg_src_mac[47:32]) || (fw(8) !== cfg_src_mac[31:16]) ||
                    (fw(10) !== cfg_src_mac[15:0])) begin
                    e_parse = e_parse + 1; $display("[FAIL] smac @%0d", cyc); end
                if (fw(48) !== RCV_WND) begin
                    e_parse = e_parse + 1; $display("[FAIL] wnd=%h @%0d", fw(48), cyc); end
                fseq = {fw(38), fw(40)};
`ifdef ARM_PERSIST
                // ⭐ P7B-PERSIST 判据组: 探询段的**线上字段**分类器 (设计件 v3 #12)。
                //   ⛔ **不许从 `u_dut.tx_is_probe` 取样** —— 否则"两计数相等"是恒等式,
                //      不是独立见证。四要素全部来自**线上帧字段 + TB 自维护模型**:
                //     flags == 0x18 (与数据段同形) ∧ plen == 1 (55-54)
                //     ∧ fseq == TB 的 `snd_una` 影子 (`sh_una`, 由 tcb 写口逐拍重建)
                //     ∧ 该连接此刻落在"TB 自己关的窗"里 (`psc_win_closed`)。
                //   末项是**必要**的: 健康态下"1 字节数据帧恰落在自己 snd_una 上"结构性
                //   存在 (无在飞时的首帧) ⇒ 只用前三项会误分类。
                is_probe = (flags == 8'h18) && (plen == 12'd1) &&
                           (fseq == sh_una[t_conn]) && psc_win_closed[t_conn];
`else
                is_probe = 1'b0;
`endif
                if ({fw(42), fw(44)} !== RCV_NXT) begin
                    e_ackf = e_ackf + 1;
                    if (e_ackf < 6) $display("[FAIL] ack=%h @%0d", {fw(42), fw(44)}, cyc); end
                // ---- IP 校验和 ----
                ip_acc = 32'd0;
                for (kk = 14; kk < 34; kk = kk + 2)
                    if (kk == 24) ip_acc = ip_acc + 32'd0;
                    else          ip_acc = ip_acc + {16'b0, fw(kk)};
                if (csum16(ip_acc) !== fw(24)) begin
                    e_csum = e_csum + 1;
                    if (e_csum < 8)
                        $display("[FAIL] ip csum conn=%0d seq=%h @%0d", t_conn, fseq, cyc); end
                // ---- TCP 校验和 (伪头 + 头 + 载荷) ----
                tcp_acc = {16'b0, fw(26)} + {16'b0, fw(28)} +     // 伪头: src ip
                          {16'b0, fw(30)} + {16'b0, fw(32)} +     //         dst ip
                          32'h0000_0006 + {16'b0, ip_len - 16'd20};
                for (kk = 34; kk < fpos; kk = kk + 2) begin
                    if (kk == 50) tcp_acc = tcp_acc + 32'd0;
                    else if (kk + 1 < fpos) tcp_acc = tcp_acc + {16'b0, fw(kk)};
                    else            tcp_acc = tcp_acc + {16'b0, fr[kk], 8'h00};
                end
                if (csum16(tcp_acc) !== fw(50)) begin
                    e_csum = e_csum + 1;
                    if (e_csum < 8)
                        $display("[FAIL] tcp csum conn=%0d seq=%h got=%h exp=%h plen=%0d @%0d",
                                 t_conn, fseq, fw(50), csum16(tcp_acc), plen, cyc); end
                // ---- 分类 ----
                if (flags[0]) begin fin_seen[t_conn] <= 1'b1; w_fin[t_conn] = w_fin[t_conn]+1; end
                if (flags[1]) begin
                    syn_seen[t_conn] <= 1'b1;
                    w_syn[t_conn] = w_syn[t_conn]+1;
                    // SYN 消耗 1 个 seq => 发侧前沿 (exp_new) 与对端前沿都要 +1
                    if ((fseq - exp_new[t_conn]) < 32'h8000_0000) begin
                        exp_new[t_conn]  = fseq + 32'd1;
                        peer_rcv[t_conn] = fseq + 32'd1;
                    end
                end
                if (flags[2]) begin rst_seen[t_conn] <= 1'b1; w_rst[t_conn] = w_rst[t_conn]+1; end
                if (flags[3]) begin
                    w_data[t_conn] = w_data[t_conn] + 1;
                    n_data = n_data + 1;
                    if (!haddata[t_conn]) begin cov_conns = cov_conns + 1; haddata[t_conn] = 1'b1; end
                    if (plen == 12'd0) cov_plen0 = cov_plen0 + 1;
                    if (plen <= 12'd8) cov_singlebeat = cov_singlebeat + 1;
                    if (flags !== 8'h18) begin
                        e_parse = e_parse + 1;
                        $display("[FAIL] data flags=%h @%0d", flags, cyc); end
`ifdef ARM_PERSIST
                    // ---- ⭐ P7B-PERSIST: 探询段逐帧取证 (计数归观察块所有 ⇒ 本处只
                    //      **记录事件**并累加事件数; 单写者规则与 sh_una/stat_drop_len 同款) --
                    if (is_probe) begin
                        pe_probe_ev   = pe_probe_ev + 1;
                        pe_rec_cyc    = cyc;
                        pe_rec_conn   = t_conn;
                        pe_rec_seq    = fseq;
                        pe_rec_plen   = plen;
                        pe_rec_iplen  = ip_len;
                        pe_rec_flags  = flags;
                        pe_rec_pay    = fr[54];
                        // j2 字段判据: IP total_len == 41 / plen == 1 / flags == 0x18 /
                        //              seq == TB 的 snd_una 影子 (四要素同上, 独立复算)
                        if ((ip_len !== 16'd41) || (plen !== 12'd1) ||
                            (flags !== 8'h18) || (fseq !== sh_una[t_conn]))
                            pe_probe_bad = pe_probe_bad + 1;
                        // tuple 归属 (j13 后半"探询仍带 A 的字段"): 帧的 dmac/ip/端口/窗口
                        // 已由 J1 按**端口识别的连接**逐字校验 ⇒ 这里只再钉一条**顺序**:
                        // 探询帧的连接必须 == 所记录事件连接的期望值 (TB 自维护)。
                        if (t_conn !== pe_exp_conn) pe_probe_bad = pe_probe_bad + 1;
                    end
                    // ---- ⭐ j13 的核心判据: E7 相撞窗内**不得出现非 B 的数据帧** ----
                    //   签名: 变异臂 (无 ds_guard) 下, 数据帧带 **conn1 的端口** + conn1
                    //   的 snd_nxt 上线 ⇒ `t_conn = 1 != 0` 且**不是探询段** (seq 不是
                    //   snd_una ⇒ 分类器不认) ⇒ 命中。clean 臂里 conn1 的窗是关的 ⇒
                    //   结构性不可能出现 ⇒ 该判据在 clean 臂上由"臂的构造"保证为 0。
                    pe_d_ev   = pe_d_ev + 1;
                    pe_d_conn = t_conn;
                    pe_d_seq  = fseq;
                    if ((t_conn == 4'd1) && (pe_st != 7'd0) && !is_probe &&
                        (w_ps_dbg2 < 14)) begin
                        w_ps_dbg2 = w_ps_dbg2 + 1;
                        $display("DBG C1DATA @%0d ps=%0d fseq=%h plen=%0d wcl=%b nxt=%h una=%h",
                                 cyc, pe_st, fseq, plen, psc_win_closed[1],
                                 u_tcb.snd_nxt_r[1], u_tcb.snd_una_r[1]);
                    end
                    if (((pe_st == 7'd51) || (pe_st == 7'd52)) && !is_probe && (t_conn != 4'd0))
                        e_coll_bad = e_coll_bad + 1;
`endif
`ifdef TCP_TX_OVL
                    // J9: 会话内**落在重放窗口 [rep_lo, retx_hi) 内**的数据帧必须逐段
                    // 连续覆盖 (含"对端尚未见过"的那些 —— 它们与重放帧一起构成覆盖)
                    if (u_dut.retx_active && (u_dut.retx_id_r == t_conn) &&
                        ((fseq - rep_hi_w) >= 32'h8000_0000) && !is_probe) begin
                        // ⭐ P7B-PERSIST §5.2-Ⅳ: 探询段**不进 J9 的重放覆盖窗口**
                        //   (`is_probe` = 线上字段分类器; 非该臂恒 0 ⇒ 既有臂逐位不变)。
                        //   ⚠️ 这里是"状态线口径"的**唯一**允许处 (与同分支已用的
                        //      `u_dut.retx_active/retx_id_r` 同类); 计数面仍禁用。
                        if (!rep_lo_ok) begin
                            rep_max   = fseq;              // 首帧自锚 = 重放起点
                            rep_lo_ok = 1'b1;
                        end else if (((fseq - rep_max) != 32'd0) &&
                                     ((fseq - rep_max) < 32'h8000_0000))
                            e_replay_gap = e_replay_gap + 1;
                        if (((fseq + {20'b0, plen}) - rep_max) < 32'h8000_0000)
                            rep_max = fseq + {20'b0, plen};
                        rep_fcnt = rep_fcnt + 1;
                        if (dbg_on && (dbg_q < 40)) begin
                            dbg_q = dbg_q + 1;
                            $display("DBG inwin @%0d c=%0d seq=%h plen=%0d max=%h hi=%h",
                                     cyc, t_conn, fseq, plen, rep_max, rep_hi_w);
                        end
                    end
`endif
                    if (!dead[t_conn]) begin
                        if (!live[t_conn]) begin exp_new[t_conn] = fseq; live[t_conn] = 1'b1; end
                        if (fseq == exp_new[t_conn]) begin
                            exp_new[t_conn]  = fseq + {20'b0, plen};
                            peer_rcv[t_conn] = fseq + {20'b0, plen};
                        end else if ((fseq - exp_new[t_conn]) >= 32'h8000_0000) begin
                            cov_replay_frames = cov_replay_frames + 1;
                            if ((((fseq + {20'b0, plen}) - exp_new[t_conn]) != 32'd0) &&
                                (((fseq + {20'b0, plen}) - exp_new[t_conn]) < 32'h8000_0000)) begin
                                e_seqcont = e_seqcont + 1;
                                if (e_seqcont < 6)
                                    $display("[FAIL] seq partial conn=%0d seq=%h plen=%0d exp=%h @%0d",
                                             t_conn, fseq, plen, exp_new[t_conn], cyc); end
                        end else begin
                            e_seqcont = e_seqcont + 1;
                            if (e_seqcont < 6)
                                $display("[FAIL] seq hole conn=%0d seq=%h plen=%0d exp=%h @%0d",
                                         t_conn, fseq, plen, exp_new[t_conn], cyc);
                        end
                        for (kk = 0; kk < 1536; kk = kk + 1) begin
                            if ((kk < plen) && (fr[54 + kk] !==
                                 fb(CBASE*t_conn + (fseq - isn[t_conn]) + kk))) begin
                                e_payload = e_payload + 1;
                                if (e_payload < 4) begin
                                    $display("[FAIL] payload conn=%0d seq=%h off=%0d got=%h exp=%h @%0d",
                                             t_conn, fseq, kk, fr[54+kk],
                                             fb(CBASE*t_conn + (fseq-isn[t_conn]) + kk), cyc);
`ifdef ARM_PERSIST
                                    $display("   APP-SNAP c=%0d kw=%0d pos=%0d b0=%h op=%b (frame conn=%0d fseq=%h plen=%0d)",
                                             dbg_sd_c, dbg_sd_kb, dbg_sd_pos, dbg_sd_b0, dbg_sd_op,
                                             t_conn, fseq, plen);
`endif
                                    $display("   dump54..69: %h %h %h %h %h %h %h %h  %h %h %h %h %h %h %h %h",
                                             fr[54],fr[55],fr[56],fr[57],fr[58],fr[59],fr[60],fr[61],
                                             fr[62],fr[63],fr[64],fr[65],fr[66],fr[67],fr[68],fr[69]);
                                    $display("   exp0..7  : %h %h %h %h %h %h %h %h   (fseq-isn=%0d)",
                                             fb(CBASE*t_conn+(fseq-isn[t_conn])+0),
                                             fb(CBASE*t_conn+(fseq-isn[t_conn])+1),
                                             fb(CBASE*t_conn+(fseq-isn[t_conn])+2),
                                             fb(CBASE*t_conn+(fseq-isn[t_conn])+3),
                                             fb(CBASE*t_conn+(fseq-isn[t_conn])+4),
                                             fb(CBASE*t_conn+(fseq-isn[t_conn])+5),
                                             fb(CBASE*t_conn+(fseq-isn[t_conn])+6),
                                             fb(CBASE*t_conn+(fseq-isn[t_conn])+7),
                                             fseq-isn[t_conn]);
                                end
                                kk = 1536;
                            end
                        end
                    end else n_dead_skip = n_dead_skip + 1;
                end else begin
                    n_ctrl = n_ctrl + 1;
`ifdef TCP_TX_OVL
                    ctrlp_cyc = -1;             // 该 ctrl 条目已上线 (看门狗复位)
`endif
                    if (plen !== 12'd0) begin
                        e_parse = e_parse + 1;
                        $display("[FAIL] ctrl w/ payload flags=%h @%0d", flags, cyc); end
                    if ((flags[4] !== 1'b1) || (flags[5] !== 1'b0) || (flags[6] !== 1'b0) ||
                        (flags[7] !== 1'b0)) begin
                        e_parse = e_parse + 1;
                        $display("[FAIL] ctrl flags=%h @%0d", flags, cyc); end
                end
            end
        end
    endtask

    // ---- 帧接收 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fpos <= 12'd0;
        end else begin
            if (m_tvalid && m_tready) begin
                if (dbg_on && (dbg_w < 32)) begin
                    dbg_w = dbg_w + 1;
                    $display("DBG word #%0d fpos=%0d td=%h tk=%h tl=%b txs=%0d hpl=%0d",
                             dbg_w, fpos, m_tdata, m_tkeep, m_tlast,
                             `ifdef TCP_TX_OVL u_dut.tx_state `else 3'd0 `endif,
                         `ifdef TCP_TX_OVL u_dut.h_plen `else 12'd0 `endif);
                end
                if (m_tkeep[7]) begin fr[fpos] = m_tdata[63:56]; fpos = fpos + 1; end
                if (m_tkeep[6]) begin fr[fpos] = m_tdata[55:48]; fpos = fpos + 1; end
                if (m_tkeep[5]) begin fr[fpos] = m_tdata[47:40]; fpos = fpos + 1; end
                if (m_tkeep[4]) begin fr[fpos] = m_tdata[39:32]; fpos = fpos + 1; end
                if (m_tkeep[3]) begin fr[fpos] = m_tdata[31:24]; fpos = fpos + 1; end
                if (m_tkeep[2]) begin fr[fpos] = m_tdata[23:16]; fpos = fpos + 1; end
                if (m_tkeep[1]) begin fr[fpos] = m_tdata[15:8];  fpos = fpos + 1; end
                if (m_tkeep[0]) begin fr[fpos] = m_tdata[7:0];   fpos = fpos + 1; end
                if (m_tlast) begin
                    frame_check;
                    fpos = 12'd0;
                end
            end
        end
    end

    // ===================== app 源 (单呈现口, 轮转, 一次一帧) =====================
    reg can_start_v;
    // ⭐ P7B-PERSIST: `src_skip` = 源侧禁止启动某连接的帧 (只在 ARM_PERSIST 臂被置位;
    //   默认全 0 ⇒ 本函数逐位不变 ⇒ 既有臂零影响)。
    function can_start;
        input [3:0] c;
        begin
            can_start = (setup_st[c] == 4'd10) && !dead[c] && !fin_req[c] &&
                        !rst_req[c] && !o_fin_sent[c] && !o_rst_sent[c] && !src_skip[c];
        end
    endfunction

    // ⚠️ 字节基址必须与 DUT **接受拍** 的 snd_nxt 同源 (帧首 beat 可能被 tx_blk/
    //    窗门挡若干拍, 期间 svc 回卷可能改 snd_nxt) ⇒ 载荷字**组合**由 live snd_nxt
    //    算出; 帧内 snd_nxt 恒定 (推进写在 RX_FIN, 而本帧接收期 rx_idle=0) ⇒ 稳定。
    // 每帧首拍 = 0 载荷 opener (tkeep=0, tlast=0; 与真 app_pattern 同构 ⇒ 与设计件
    // 的 "1 opener + 183/184 beat" 拍数口径可比)。cur_len==0 时 opener 直接带 tlast。
    reg        cur_op;
    wire [31:0] kw_live = u_tcb.snd_nxt_r[cur_c] - isn[cur_c];
    assign s_tdata = cur_op ? 64'd0 :
                     ((cur_pos == 12'd0) ?
                      beat_word(cur_c, u_tcb.snd_nxt_r[cur_c] - isn[cur_c], cur_n) :
                      beat_word(cur_c, kw_live + cur_pos, cur_n));
    assign s_tkeep = cur_op ? 8'h00 : beat_k;
    assign s_tvalid = beat_v;
    assign s_tlast = cur_op ? (cur_len == 12'd0) : beat_l;
    assign s_tid = beat_id;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat_v <= 1'b0; beat_d <= 64'd0; beat_k <= 8'h00; beat_l <= 1'b0;
            cur_c <= 2'd0; cur_len <= 12'd0; cur_pos <= 12'd0; cur_n <= 4'd0;
            cur_kb <= 32'd0; beat_id <= 4'd0; rr <= 3'd0; cur_op <= 1'b0;
        end else begin
            if (beat_v) begin
                if (s_tready) begin
                    if (cur_op) begin
                        // opener 交付 -> 呈现首个载荷 beat
                        cur_op <= 1'b0;
                        if (cur_len == 12'd0) begin
                            beat_v <= 1'b0;
                            nseg[cur_c] <= nseg[cur_c] + 1;
                        end else begin
                            cur_pos <= 12'd0;
                            cur_n   <= (cur_len >= 12'd8) ? 4'd8 : cur_len[3:0];
                            beat_k  <= kmask((cur_len >= 12'd8) ? 4'd8 : cur_len[3:0]);
                            beat_l  <= (cur_len <= 12'd8);
                        end
                    end else if ((cur_pos + {8'b0, cur_n}) >= cur_len) begin
                        beat_v <= 1'b0;
                        nseg[cur_c] <= nseg[cur_c] + 1;
                    end else begin
                        cur_pos <= cur_pos + {8'b0, cur_n};
                        cur_n   <= ((cur_len - (cur_pos + {8'b0, cur_n})) >= 12'd8) ?
                                   4'd8 : (cur_len - (cur_pos + {8'b0, cur_n}));
                        beat_k  <= kmask(((cur_len - (cur_pos + {8'b0, cur_n})) >= 12'd8) ?
                                    4'd8 : (cur_len - (cur_pos + {8'b0, cur_n})));
                        beat_l  <= (((cur_pos + {8'b0, cur_n}) +
                                     (((cur_len - (cur_pos + {8'b0, cur_n})) >= 12'd8) ?
                                      12'd8 : (cur_len - (cur_pos + {8'b0, cur_n}))) >= cur_len));
                    end
                end
            end else begin
                if (can_start(rr)) begin
                    if (dbg_on && (dbg_d < 12)) begin
                        dbg_d = dbg_d + 1;
                        $display("DBG srcstart @%0d c=%0d len=%0d tcb=%h/%h", cyc, rr,
                                 seg_len_for(nseg[{2'b0, rr}], {2'b0, rr}),
                                 u_tcb.snd_nxt_r[{2'b0, rr}], u_tcb.snd_una_r[{2'b0, rr}]);
                    end
                    cur_c   <= rr;
                    cur_len <= seg_len_for(nseg[{2'b0, rr}], {2'b0, rr});
                    cur_pos <= 12'd0;
                    beat_id <= {2'b0, rr};
                    cur_op  <= 1'b1;
                    beat_v  <= 1'b1;
                    rr      <= rr + 2'd1;      // 轮转: 否则 conn0 垄断
                    if (seg_len_for(nseg[{2'b0, rr}], {2'b0, rr}) == 12'd0) begin
                        cur_n <= 4'd0; beat_k <= 8'h00; beat_l <= 1'b0;
                    end else begin
                        cur_n  <= (seg_len_for(nseg[{2'b0, rr}], {2'b0, rr}) >= 12'd8) ?
                                  4'd8 : seg_len_for(nseg[{2'b0, rr}], {2'b0, rr})[3:0];
                        beat_k <= kmask((seg_len_for(nseg[{2'b0, rr}], {2'b0, rr}) >= 12'd8) ?
                                   4'd8 : seg_len_for(nseg[{2'b0, rr}], {2'b0, rr})[3:0]);
                        beat_l <= (seg_len_for(nseg[{2'b0, rr}], {2'b0, rr}) <= 12'd8);
                    end
                end else rr <= rr + 2'd1;
            end
        end
    end

`ifdef ARM_PERSIST
    // ==== 归因探针 Q1: **帧中** snd_nxt 是否变过 (app 的每拍基址 kw_live 是组合取
    //      u_tcb.snd_nxt_r[cur_c], 而 DUT 的帧 seq 是帧首拍锁存 => 帧中一变就错位) ====
    integer    dbg_st_n;
    reg [31:0] dbg_st_prev;
    reg        dbg_st_v;
    initial begin dbg_st_n = 0; dbg_st_prev = 0; dbg_st_v = 0; end
    always @(posedge clk) begin
        // 只抓**收帧进行中** (rx_state==RX_IDLE 且 recv_first==0): 帧尾 RX_FIN 的推进写
        // (upd_wr_data) 是合法帧末事件, 不是帧中错位
        if (dbg_st_v && (u_dut.rx_state == 2'd0) && !u_dut.recv_first &&
            (u_tcb.snd_nxt_r[cur_c] != dbg_st_prev) && (dbg_st_n < 12)) begin
            dbg_st_n = dbg_st_n + 1;
            $display("DBG SNMID c=%0d %h -> %h @%0d rxst=%0d f_conn=%0d f_seq=%h",
                     cur_c, dbg_st_prev, u_tcb.snd_nxt_r[cur_c], cyc,
                     u_dut.rx_state, u_dut.f_conn[u_dut.rx_bank], u_dut.f_seq[u_dut.rx_bank]);
        end
        dbg_st_prev <= u_tcb.snd_nxt_r[cur_c]; dbg_st_v <= 1'b1;
    end
    // ==== 归因探针 Q1b: 每连接**在飞最大值** (snd_nxt - snd_una) ====
    //   判据: 环 = 每连接 64KB (retx_ram 13 位 ring idx); 窗帽 = WIN_CAP_5 = 0xF000 = 61440;
    //   设计件 §2.2-3 的余量前提 = 在飞 <= 61440 + 1508 = 62948 < 65536。
    //   若实测 maxd >= 65536 => 环形窗口越界 (读点会被早一圈的数据覆盖)。
    reg [31:0] dbg_maxd [0:15];      // 32 位无符号 (用 integer 会被符号位毁掉: 实测踩过)
    integer    dbg_c2;
    initial for (dbg_c2 = 0; dbg_c2 < 16; dbg_c2 = dbg_c2 + 1) dbg_maxd[dbg_c2] = 32'd0;
    always @(posedge clk)
        for (dbg_c2 = 0; dbg_c2 < 16; dbg_c2 = dbg_c2 + 1)
            // 只在 ESTAB 且差值 < 2^31 时计 (建连期 snd_nxt=isn / snd_una=0 的瞬态要排除)
            if ((u_tcb.state_r[dbg_c2] == 4'd1) &&
                ((u_tcb.snd_nxt_r[dbg_c2] - u_tcb.snd_una_r[dbg_c2]) < 32'h8000_0000) &&
                ((u_tcb.snd_nxt_r[dbg_c2] - u_tcb.snd_una_r[dbg_c2]) > dbg_maxd[dbg_c2]))
                dbg_maxd[dbg_c2] <= u_tcb.snd_nxt_r[dbg_c2] - u_tcb.snd_una_r[dbg_c2];

    // ==== PERSIST 归因探针 (体; 只读 TB 自己的源状态) ====
    always @(posedge clk) if (u_dut.start_data) begin
        dbg_sd_c <= cur_c; dbg_sd_kb <= kw_live; dbg_sd_pos <= cur_pos;
        dbg_sd_b0 <= s_tdata[63:56]; dbg_sd_op <= cur_op;
    end
`endif

    // ===================== 建连 FSM + rx ACK + 激励 =====================
    reg [7:0] tmp8;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            setup_c <= 4'd0; ack_req <= 1'b0; cfg_up <= 1'b0;
            wc_st <= 2'd0; wc_cyc <= 32'd0;   // 构建 E: 窗口关闭插曲 FSM
        end else begin
            ack_req <= 1'b0; cfg_up <= 1'b0;
            if (setup_c < NCONN) begin
                case (setup_st[setup_c])
                4'd0: begin
                    scfg_upd_wr <= 1'b1; scfg_upd_id <= setup_c;
                    scfg_upd_sel <= 3'd2; scfg_upd_val <= isn[setup_c];
                    setup_st[setup_c] <= 4'd1;
                end
                4'd1: if (tcb_wr && (tcb_sel==3'd2) && (tcb_id==setup_c)) begin
                    scfg_upd_sel <= 3'd1; scfg_upd_val <= isn[setup_c];
                    setup_st[setup_c] <= 4'd2; end
                4'd2: if (tcb_wr && (tcb_sel==3'd1) && (tcb_id==setup_c)) begin
                    scfg_upd_sel <= 3'd0; scfg_upd_val <= RCV_NXT;
                    setup_st[setup_c] <= 4'd3; end
                4'd3: if (tcb_wr && (tcb_sel==3'd0) && (tcb_id==setup_c)) begin
                    scfg_upd_sel <= 3'd3; scfg_upd_val <= {16'b0, RCV_WND};
                    setup_st[setup_c] <= 4'd4; end
                4'd4: if (tcb_wr && (tcb_sel==3'd3) && (tcb_id==setup_c)) begin
                    scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND};
                    setup_st[setup_c] <= 4'd5; end
                4'd5: if (tcb_wr && (tcb_sel==3'd4) && (tcb_id==setup_c)) begin
                    scfg_upd_sel <= 3'd5; scfg_upd_val <= 32'd1;
                    setup_st[setup_c] <= 4'd6; end
                4'd6: if (tcb_wr && (tcb_sel==3'd5) && (tcb_id==setup_c)) begin
                    scfg_upd_wr <= 1'b0; cfg_up <= 1'b1; cfg_up_id <= setup_c;
                    setup_st[setup_c] <= 4'd7; end
                4'd7: begin
                    ack_req <= 1'b1; ack_id <= setup_c; ack_syn <= 1'b1;
                    ack_val <= RCV_NXT;
                    setup_st[setup_c] <= 4'd8; end
                4'd8: begin
                    ack_syn <= 1'b0;
                    setup_st[setup_c] <= 4'd9; end
                4'd9: if (syn_seen[setup_c]) begin
                    peer_rcv[setup_c] <= isn[setup_c] + 32'd1;
                    exp_new[setup_c]  <= isn[setup_c] + 32'd1;
                    ack_first[setup_c] <= 1'b1;
                    setup_st[setup_c] <= 4'd10;
                    if (setup_c < NCONN - 1) setup_c <= setup_c + 4'd1;
                end
                default: ;
                endcase
            end
            // ---- rx ACK 调度 ----
            if (!rx_upd_wr) begin
                if (ack_sch < NCONN) begin
                    if ((setup_st[ack_sch] == 4'd10) && !psc_ack_hold[ack_sch] &&
                        ((peer_rcv[ack_sch] > (sh_una[ack_sch] + ack_lag[ack_sch])) ||
                         (ack_first[ack_sch] && (peer_rcv[ack_sch] > sh_una[ack_sch])) ||
                         ((cyc % 2048) == 0 && (peer_rcv[ack_sch] > sh_una[ack_sch])))) begin
                        rx_upd_wr  <= 1'b1; rx_upd_id <= ack_sch;
                        rx_upd_sel <= 3'd2; rx_upd_val <= peer_rcv[ack_sch];
                    end
                    ack_sch <= ack_sch + 2'd1;
                end else ack_sch <= 2'd0;
            end else if (rx_upd_gnt) begin
                rx_upd_wr <= 1'b0;
                ack_first[rx_upd_id] <= 1'b0;
            end
            // ---- 关闭语义 (phase>=1) ----
            if (phase >= 2'd1) begin
                if (!fin_req[2] && (setup_st[2] == 4'd10) && !o_fin_sent[2] &&
                    (u_tcb.snd_nxt_r[2] == u_tcb.snd_una_r[2])) fin_req[2] <= 1'b1;
                if (o_fin_sent[2]) fin_req[2] <= 1'b0;
                if (!rst_req[3] && !o_rst_sent[3] && !rst_seen[3]) rst_req[3] <= 1'b1;
                if (o_rst_sent[3]) rst_req[3] <= 1'b0;
                // 流中 SYN+ACK (纯 seq 消耗, 对端以 fseq+1 续) —— 专门给 M-C2 制造
                // "预留值被 8 拍后落地的更晚数据推进顶掉" 的窗口
                if ((cyc % 50000) == 12345) begin
                    ack_req <= 1'b1; ack_id <= 4'd0; ack_syn <= 1'b1;
                    ack_val <= RCV_NXT; ack_fin <= 1'b0; ack_rst <= 1'b0;
                end
                if ((cyc % 8192) > 8184) begin
                    ack_req <= 1'b1; ack_id <= cyc[3:0] % NCONN;
                    ack_syn <= 1'b0; ack_fin <= 1'b0; ack_rst <= 1'b0;
                    ack_val <= RCV_NXT;
                end
                if ((cyc % 8192) == 101) begin wu_req <= 1'b1; wu_id <= 4'd0;
                    wu_val <= RCV_NXT; end
                if (wu_req && wu_gnt) wu_req <= 1'b0;
            end
            // ---- retx_req 脉冲 (周期性, 逼出回卷会话) ----
            if ((phase >= 2'd1) && (cyc >= trq_next) && !retx_req && !pe_no_retx) begin
                retx_req <= 1'b1;
                retx_id  <= (trq_next / 32'd20000) % NCONN;
                trq_next <= trq_next + 32'd20000;
            end else if (retx_req && retx_gnt) retx_req <= 1'b0;
`ifdef TCP_TX_OVL
            // ---- 定向窗口 (对抗审查 B2/M-C6): 逐字复刻审查探针的构造 ----
            //  窗口 = `ctrl_slot_busy && |ctrl_is && !tx_is_ctrl`
            //        = FIN/RST/SYN **已由 start_ack 预留 (+1)** 但**还没发上线**;
            //  窗口内对**同一个 conn** (retx_id = ctrl_id) 持续拉 retx_req (电平,
            //  与 tcp_rx 的 dup-ACK 触发同为电平型):
            //    - 有 `!ctrl_adv_inflight` 门 ⇒ svc 被挡 (c6_gated 见证), 回卷不被服务;
            //    - 无门 (M-C6) ⇒ 回卷吃掉预留的 +1 ⇒ **1 字节重放 @seq=snd_una** 上线
            //      (审查实测 onebyte_seqF=2)。
            //  判据在 OVL-only 段: e_c6 必须 = 0, 而 c6_req_win/c6_gated 必须 >= 1。
            if (d_ctrl_win) begin
                if (!win_prev) begin c6_n = c6_n + 1; end
                retx_req <= 1'b1;
                retx_id  <= u_dut.ctrl_id;
                c6_hold  <= 1'b1;
                c6_req_win = c6_req_win + 1;
            end else if (c6_hold) begin
                retx_req <= 1'b0;               // 窗口关闭: 立即撤请求 (只测窗口内那一段)
                c6_hold  <= 1'b0;
            end
            win_prev <= d_ctrl_win;
`endif
            // ---- ⭐ 构建 E: 定向窗口关闭插曲 (给 W66 = stat_winstall 造靶) ----
            //   动机: 本 TB 的 snd_wnd = 0xC000 (49152) 而 ACK 每 8192 B 一次 ⇒ 在飞
            //   常年 <10 KB ⇒ `wnd_open` **结构性恒 1**; 不加激励的话新计数器是
            //   空判据 (永远 0, 变异体也照不出来)。
            //   做法: 把 conn1 的 snd_wnd 压到 **1 MSS (1460)**, 保持 WC_HOLD 拍,
            //   再写回 0xC000。在飞一旦 >=1460 ⇒ 帧器启动点的 `wnd_open` 落 0 ⇒
            //   只要 TB 还在给 conn1 喂帧 (round-robin), 就必然出现"启动点 + 有字 +
            //   其余门全开 + 只有窗口关着"的拍 = 本字的靶。
            //   ⚠️ 自恢复 (不靠 ack_lag 那条路 —— snd_wnd=1460 下它够不着):
            //      本 TB 的 rx ACK 调度含**周期支** (`cyc % 2048 == 0 &&
            //      peer_rcv > sh_una`) ⇒ 关窗期间 snd_una 照常被推进 ⇒ 窗口自行重开。
            //   ⚠️ 与 setup FSM 的多写者风险: 出发条件含 `setup_c >= NCONN`, 而 setup
            //      FSM 整段在 `if (setup_c < NCONN)` 里 ⇒ 两者**结构性互斥**;
            //      本块又写在同一个 always 块的**最后** ⇒ 顺序上也安全。
            case (wc_st)
            //   ⚠️ 出发条件 (2026-10-10 自查订正): 原写 `(setup_c >= NCONN)` —— **结构性恒假**:
            //      setup FSM 只在 `setup_c < NCONN-1` 时自增 ⇒ 它**停在 NCONN-1 = 3**,
            //      永远到不了 NCONN=4。第一次跑因此**根本没注入**(213 拍是 TB 自己
            //      天然关窗挣来的; `wc_st=0` 那个读数就是它在说"插曲没跑", 但当时被
            //      我读成"无害" —— 记在这里)。现改成 **`phase >= 1` (= 四连均已建连且在
            //      发流) + `cyc >= WC_AT`** (下界而非相等, 不吃绝对拍号)。
            3'd0: if ((phase >= 2'd1) && (cyc >= WC_AT)) begin
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= WC_CONN;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= 32'd1460;
                      wc_st <= 3'd1;
                  end
            3'd1: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == WC_CONN)) begin
                      scfg_upd_wr <= 1'b0; wc_cyc <= 32'd0; wc_st <= 3'd2;
                  end
            3'd2: begin
                      wc_cyc <= wc_cyc + 32'd1;
                      if (wc_cyc == WC_HOLD) begin
                          scfg_upd_wr <= 1'b1; scfg_upd_id <= WC_CONN;
                          scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND};
                          wc_st <= 3'd3;
                      end
                  end
            3'd3: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == WC_CONN)) begin
                      scfg_upd_wr <= 1'b0; wc_st <= 3'd4;
                  end
            default: ;
            endcase
`ifdef ARM_PERSIST
            // ============== ⭐ P7B-PERSIST episode 驱动 (设计件 §5.2-Ⅲ) =============
            //   为什么在本块内: `scfg_upd_*` 是**本 always 块**独有的写者 (与 setup FSM /
            //   wc 窗口插曲同源) —— 另起一个 always 写它就是多驱动。本段写在块尾, 且
            //   只在 `wc_st == 4` 之后出发 (既有两个写者此时结构性静止: setup FSM 停在
            //   `setup_st[3] == 10` ⇒ 其 case 走 default; wc FSM 停在 3'd4 ⇒ 无写)。
            //   每个 episode 的判据见 summary 段与 tb 头注; 计数/见证全部落在 ARM_PERSIST。
            ack_seen_tb <= pe_holdb ? 16'hFFFE : 16'hFFFF;   // 单写者 = 本块
            pe_clr_pc   <= 1'b0;
            case (pe_st)
            7'd0: if ((phase == 2'd2) && (cyc >= PE_AT) && (wc_st == 3'd4)) begin
                      pe_ep <= 4'd1; pe_conn <= 4'd1; pe_ret <= 7'd1; pe_st <= 7'd70;
                  end
            // ---- ⭐ 静默例程 (Q): 每次"关 conn1 的窗"之前先把重放机压静 ----
            //   为什么必须: TB 的 RTO 扫描会在**别的窗口开着**时给 conn1 置上 `rto_pend[1]`,
            //   而 `rto_pend` **不随武装条件变假而清** (只在会话服务 / 非 ESTAB / cfg_up 清)
            //   ⇒ 一旦带着陈旧的 `rto_pend[1]` 关窗, 回卷会话会被**反复**服务 ⇒ conn1 的
            //   重放帧持续上线: ① 破坏 j3 的"snd_nxt 逐位不变" ② 让 E7 的"跨连接帧"判据
            //   假红 ③ 主判据的 J3/J4 被重放语义扰动 (首轮实测: payload=2/seqcont=1)。
            //   做法: cfg_up(conn) 清该连接的 `rto_pend/timer/epoch/flag` 族 (设计件 §3.4-4
            //   正是同一脉冲), 然后等重放机**空闲** (`!retx_active` 且无挂起请求)。
            //   ⚠️ 只对 conn1 用 (cfg_up 会清 `fin_sent_r` ⇒ 不能对 conn2 用, 见 7'd73)。
            7'd70: begin
                      cfg_up <= 1'b1; cfg_up_id <= pe_conn; pe_t <= 0; pe_st <= 7'd71;
                  end
            7'd71: begin
                      cfg_up <= 1'b0; pe_t <= 0; pe_st <= 7'd72;
                  end
            7'd72: begin
                      pe_t <= pe_t + 1;
                      if ((!retx_req && !u_dut.retx_active && !u_dut.rto_pend[pe_conn]) ||
                          (pe_t > 8000)) begin
                          if (u_dut.retx_active) w_ps_quiet_to <= w_ps_quiet_to + 1;
                          pe_st <= pe_ret;
                      end
                  end
            // 静默例程 (只等, 不 cfg_up): E5 用 (conn2 的 `fin_sent_r` 不能被清)
            7'd73: begin pe_t <= 0; pe_st <= 7'd74; end
            7'd74: begin
                      pe_t <= pe_t + 1;
                      if ((!retx_req && !u_dut.retx_active) || (pe_t > 8000)) begin
                          if (u_dut.retx_active) w_ps_quiet_to <= w_ps_quiet_to + 1;
                          pe_st <= pe_ret;
                      end
                  end
            // ========================== E1 阶梯 (j1/j2/j3/j5/j7) ==============
            7'd1: begin   // E1: 关 conn1 的窗 + 冻结其 snd_una
                      pe_conn <= 4'd1;
                      psc_ack_hold[1] <= 1'b1; pe_no_retx <= 1'b1;
                      // ⚠️ 源侧同时**不给 conn1 供数**: 既存的 `win_open` 1 拍注册偏斜
                      //    (门用**上一拍 rb_id** 的窗) 会在"源刚呈交 conn1 那一拍"放行
                      //    一帧 ⇒ 关窗期仍有 conn1 数据上线 (实测 +5919 B) ⇒ 那是既存行为、
                      //    不是探询的副作用; 本 episode 要量**探询**的副作用 ⇒ 把源挡住。
                      src_skip <= 16'hFFFE;
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= 32'd0;
                      pe_st <= 7'd2;
                  end
            7'd2: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0;
                      psc_win_closed[1] <= 1'b1;
                      pe_exp_conn <= 4'd1; pe_exp_seq[1] <= u_tcb.snd_una_r[1];
                      pe_sndnxt0 <= u_tcb.snd_nxt_r[1];   // j3: 窗内 snd_nxt 逐位不变的锚
                      pe_lad_vc <= w_vis1;                // 阶梯判据的 visit 口径锚
                      pe_clr_pc <= 1'b1; pe_lad_close <= cyc; pe_t <= 0; pe_st <= 7'd3;
                  end
            7'd3: begin   // E1: 窗内等 3 条探询 (j1 的期望条数)
                      pe_t <= pe_t + 1;
                      if (pe_probe_cur >= 3) pe_st <= 7'd4;
                      else if (pe_t > PE_LAD_WAIT) begin
                          pe_clr_pc <= 1'b1; pe_st <= 7'd4;   // 超时也往下 (判据在 summary 裁)
                      end
                  end
            7'd4: begin   // E1: 快照阶梯时刻 + 重开窗 (j7 前半的起点)
                      pe_lad_n  <= pe_probe_cur;
                      pe_sndnxt1 <= u_tcb.snd_nxt_r[1];   // j3: 窗末的 snd_nxt (须逐位同锚)
                      pe_lad_vo <= w_vis1;                // visit 口径: 重开窗时刻
                      // 阶梯三档的 visit 间隔 (主判据口径; 拍数只作显示 —— 扫描节奏会被
                      // ACK/重放挤稀, 而 RTL 的 `ps_timer` **数的就是 visit**)
                      pe_lad_dc <= pe_pv[0] - pe_lad_vc;
                      pe_lad_d1 <= pe_pv[1] - pe_pv[0];
                      pe_lad_d2 <= pe_pv[2] - pe_pv[1];
                      pe_lad_t0 <= pe_pt[0]; pe_lad_t1 <= pe_pt[1]; pe_lad_t2 <= pe_pt[2];
                      pe_lad_reopen <= cyc;
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND};
                      pe_t <= 0; pe_st <= 7'd5;
                  end
            7'd5: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0;
                      psc_ack_hold[1] <= 1'b0; pe_no_retx <= 1'b0;
                      psc_win_closed[1] <= 1'b0; src_skip <= 16'h0000;
                      pe_clr_pc <= 1'b1; pe_t <= 0; pe_st <= 7'd6;
                  end
            7'd6: begin   // E1: 恢复观察窗 (j7: 0 新探询 + 数据恢复)
                      pe_t <= pe_t + 1;
                      if (pe_t > PE_AFTER) pe_st <= 7'd7;
                  end
            7'd7: begin   // E1b: 再关窗 (验"首档退回 RTO_LIM")
                      pe_lad_n2 <= pe_probe_cur;    // j7a: 恢复窗内新增探询数 (应为 0)
                      psc_ack_hold[1] <= 1'b1; pe_no_retx <= 1'b1; src_skip <= 16'hFFFE;
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= 32'd0;
                      pe_st <= 7'd8;
                  end
            7'd8: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0;
                      psc_win_closed[1] <= 1'b1;
                      pe_lad_vr <= w_vis1;      // visit 口径: 再关窗时刻
                      pe_clr_pc <= 1'b1; pe_lad_reclose <= cyc; pe_t <= 0; pe_st <= 7'd9;
                  end
            7'd9: begin   // E1b: 等首探询 ⇒ 记录间隔 (拍 + visit 双口径)
                      pe_t <= pe_t + 1;
                      if (pe_probe_cur >= 1) begin
                          pe_f_reclose_gap <= cyc - pe_lad_reclose;
                          pe_f_gap4_v <= w_vis1 - pe_lad_vr;
                          pe_st <= 7'd10;
                      end else if (pe_t > PE_LAD_WAIT) begin
                          pe_f_gap4_v <= w_vis1 - pe_lad_vr; pe_st <= 7'd10;
                      end
                  end
            7'd10: begin  // E1 收尾
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND};
                      pe_st <= 7'd11;
                  end
            7'd11: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0;
                      psc_ack_hold[1] <= 1'b0; pe_no_retx <= 1'b0;
                      psc_win_closed[1] <= 1'b0; src_skip <= 16'h0000;
                      pe_ep <= 4'd2; pe_st <= 7'd12;   // E2 不需要静默 (不关窗)
                  end
            // ========================== E2 无在飞不发 (j6) ====================
            7'd12: begin  // E2: 只允许 conn0 供数 ⇒ conn1 排空 (ACK 照常 ⇒ snd_una 追上)
                      src_skip <= 16'hFFFE; pe_t <= 0; pe_st <= 7'd13;
                  end
            7'd13: begin
                      pe_t <= pe_t + 1;
                      if (u_tcb.snd_nxt_r[1] == u_tcb.snd_una_r[1]) begin
                          w_ps_drain <= w_ps_drain + 1; pe_st <= 7'd14;
                      end else if (pe_t > PE_E2_DRAIN) pe_st <= 7'd14;
                  end
            7'd14: begin  // E2: 关窗 (此时无在飞 ⇒ 武装条件第二子句为假)
                      psc_ack_hold[1] <= 1'b1; pe_no_retx <= 1'b1;
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= 32'd0;
                      pe_st <= 7'd15;
                  end
            7'd15: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0; psc_win_closed[1] <= 1'b1;
                      pe_clr_pc <= 1'b1; pe_exp_conn <= 4'd1;
                      pe_exp_seq[1] <= u_tcb.snd_una_r[1]; pe_t <= 0; pe_st <= 7'd16;
                  end
            7'd16: begin
                      pe_t <= pe_t + 1;
                      if (pe_t > PE_HOLD_SHORT) begin
                          pe_f_e2_probe <= pe_probe_cur; pe_st <= 7'd17;
                      end
                  end
            7'd17: begin
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND};
                      pe_st <= 7'd18;
                  end
            7'd18: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0;
                      psc_ack_hold[1] <= 1'b0; pe_no_retx <= 1'b0;
                      psc_win_closed[1] <= 1'b0; src_skip <= 16'h0000;
                      pe_ep <= 4'd3; pe_conn <= 4'd1; pe_ret <= 7'd19; pe_st <= 7'd70;
                  end
            // ========================== E3 打第二把锁 (j8) ====================
            7'd19: begin  // E3(a): 冻结 snd_una + 注入 retx_req 直到 epoch 饱和
                      //   [!!] 先饱和、后关窗: 每次回卷 (svc_rewind) 都把 snd_nxt 写回
                      //   snd_una => 若先关窗, 饱和结束时在飞 = 0 => 武装条件第二子句
                      //   为假 => 探询结构性不发 (首轮实测 0 条)。窗开着时饱和: data 照流
                      //   => 关窗那一刻在飞非 0。
                      psc_ack_hold[1] <= 1'b1; pe_no_retx <= 1'b1; src_skip <= 16'hFFFE;
                      pe_clr_pc <= 1'b1;
                      pe_stat0 <= stat_retx; pe_req0 <= w_ps_retx_req;
                      pe_t <= 0; pe_st <= 7'd21;
                  end
            7'd21: begin  // E3(b): 注入 retx_req 直到 epoch 饱和 (见证 blocked 面)
                      pe_t <= pe_t + 1;
                      if (!retx_req) begin
                          retx_req <= 1'b1; retx_id <= 4'd1;
                          w_ps_retx_req <= w_ps_retx_req + 1;
                      end else if (retx_gnt) retx_req <= 1'b0;
                      if ((u_dut.epoch[1] >= 4'd15) || (pe_t > PE_E3_SESS)) begin
                          retx_req <= 1'b0;
                          if (u_dut.epoch[1] >= 4'd15) w_ps_blocked <= w_ps_blocked + 1;
                          pe_t <= 0; pe_st <= 7'd66;
                      end
                  end
            7'd66: begin  // E3(b2): **补在飞** —— 饱和期把 conn1 的在飞抽干了
                      //   (实测: 关窗时 `nxt == una` ⇒ 武装条件第二子句为假 ⇒ 探询结构性
                      //    不发 —— DUT 行为**正确** (§3.4-2 停条件), 是**激励缺陷**)。
                      //   做法: 放开源跳过, 让 conn1 的数据重新上线若干帧; 此后 epoch 已
                      //   饱和 ⇒ 不会再回卷 ⇒ 也不会有"载荷基址 vs 会话"那类错位。
                      src_skip <= 16'h0000; pe_t <= 0; pe_st <= 7'd67;
                  end
            7'd67: begin
                      pe_t <= pe_t + 1;
                      if (((u_tcb.snd_nxt_r[1] - u_tcb.snd_una_r[1]) != 32'd0) &&
                          (pe_t > 2500)) begin pe_t <= 0; pe_st <= 7'd20; end
                      else if (pe_t > 12000) begin pe_t <= 0; pe_st <= 7'd20; end
                  end
            7'd20: begin  // E3(c): 关窗 (补完在飞) + 挡住源
                      src_skip <= 16'hFFFE;
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= 32'd0;
                      pe_st <= 7'd65;
                  end
            7'd65: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0; psc_win_closed[1] <= 1'b1;
                      pe_clr_pc <= 1'b1; pe_exp_conn <= 4'd1;
                      pe_exp_seq[1] <= u_tcb.snd_una_r[1];
                      pe_t <= 0; pe_st <= 7'd22;
                  end
            7'd22: begin  // E3(d): 关窗观察窗 (j8: blocked 后仍要 >=2 条)
                      pe_t <= pe_t + 1;
                      if (((pe_t % 5000) == 0) && (w_ps_dbg4 < 10)) begin
                          w_ps_dbg4 <= w_ps_dbg4 + 1;
                          $display("DBG E3 @%0d t=%0d wnd=%0d nxt=%h una=%h fin=%b rst=%b blk=%b pt=%0d pp=%0d ract=%b ep=%0d prdy=%b",
                                   cyc, pe_t, u_tcb.snd_wnd_r[1], u_tcb.snd_nxt_r[1],
                                   u_tcb.snd_una_r[1], u_dut.fin_sent_r[1], u_dut.rst_sent_r[1],
                                   u_dut.blocked, u_dut.ps_timer[1], u_dut.ps_phase[1],
                                   u_dut.retx_active, u_dut.epoch[1], u_dut.ps_stage_rdy);
                      end
                      pe_t <= pe_t + 1;
                      if (pe_t > PE_E3_HOLD) begin
                          pe_f_e3_probe <= pe_probe_cur;
                          pe_stat1 <= stat_retx; pe_req1 <= w_ps_retx_req;
                          pe_sndnxt1 <= u_tcb.snd_nxt_r[1];
                          pe_st <= 7'd23;
                      end
                  end
            7'd23: begin
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND};
                      pe_st <= 7'd24;
                  end
            7'd24: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0;
                      psc_ack_hold[1] <= 1'b0; pe_no_retx <= 1'b0;
                      psc_win_closed[1] <= 1'b0; src_skip <= 16'h0000;
                      pe_ep <= 4'd4; pe_conn <= 4'd1; pe_ret <= 7'd25; pe_st <= 7'd70;
                  end
            // ======================== E4 cfg_up 清暂存 (j10) ==================
            7'd25: begin  // E4: 关窗 + 按住 conn0 的 data-start 门 (源持续供数 ⇒ ds_guard=0
                          //     ⇒ 待发暂存不会被"空档"消费掉, 相位可控)
                      psc_ack_hold[1] <= 1'b1; pe_no_retx <= 1'b1; pe_holdb <= 1'b1;
                      src_skip <= 16'hFFFE;
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= 32'd0;
                      pe_st <= 7'd26;
                  end
            7'd26: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0; psc_win_closed[1] <= 1'b1;
                      pe_clr_pc <= 1'b1; pe_exp_conn <= 4'd1;
                      pe_exp_seq[1] <= u_tcb.snd_una_r[1]; pe_t <= 0; pe_st <= 7'd27;
                  end
            7'd27: begin  // E4: 等 fire
                      pe_t <= pe_t + 1;
                      if (u_dut.ps_fire || (pe_t > PE_E4_WAIT)) begin pe_t <= 0; pe_st <= 7'd28; end
                  end
            7'd28: begin  // E4: 等暂存落地 ⇒ 打 cfg_up (清暂存); 见证 rdy
                      pe_t <= pe_t + 1;
                      if (u_dut.ps_stage_rdy) begin
                          cfg_up <= 1'b1; cfg_up_id <= 4'd1; w_ps_rdy <= w_ps_rdy + 1;
                          pe_st <= 7'd29;
                      end else if (pe_t > 600) pe_st <= 7'd29;
                  end
            7'd29: begin pe_t <= 0; pe_st <= 7'd30; end   // cfg_up 由块首默认自然落 0
            7'd30: begin  // E4: 观察窗: 被清掉的暂存不得再上线
                      //   ⚠️ 窗长必须 < 重新武装的延迟 (RTO' = 2048 拍): 清位之后**计时器
                      //   也被清** (cfg_up ⇒ timer/phase = 0) ⇒ 到下一档会有一条**合法**
                      //   的新探询; 窗口开太长会把合法重发误判成"没清干净"。
                      pe_t <= pe_t + 1;
                      if (pe_t > PE_E4_OBS) begin
                          pe_f_e4_probe <= pe_probe_cur; pe_t <= 0; pe_st <= 7'd31;
                      end
                  end
            7'd31: begin  // E4 正控 (a): 放开 data-start hold + 重开窗
                      //   ⚠️ `psc_ack_hold[1]` **不放开** —— 放开会让 TB 把 conn1 排空
                      //   (snd_una 追到 snd_nxt) ⇒ 后面的正控再关窗时**没有在飞** ⇒ 武装
                      //   条件第二子句为假 ⇒ 正控空判据 (首轮实测正是这样)。
                      pe_holdb <= 1'b0; src_skip <= 16'h0000;
                      pe_no_retx <= 1'b0;
                      psc_win_closed[1] <= 1'b0;
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND};
                      pe_st <= 7'd32;
                  end
            7'd32: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0; pe_clr_pc <= 1'b1; pe_t <= 0; pe_st <= 7'd33;
                  end
            7'd33: begin  // E4 正控 (b): 同一构造再关窗 ⇒ 探询应出现 (非空判据的正控)
                      psc_ack_hold[1] <= 1'b1; pe_no_retx <= 1'b1; src_skip <= 16'hFFFE;
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= 32'd0;
                      pe_st <= 7'd34;
                  end
            7'd34: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0; psc_win_closed[1] <= 1'b1;
                      pe_clr_pc <= 1'b1; pe_exp_conn <= 4'd1;
                      pe_exp_seq[1] <= u_tcb.snd_una_r[1]; pe_t <= 0; pe_st <= 7'd35;
                  end
            7'd35: begin
                      pe_t <= pe_t + 1;
                      if (pe_probe_cur >= 1) begin
                          w_ps_posctrl <= w_ps_posctrl + 1; pe_st <= 7'd36;
                      end else if (pe_t > PE_E4_PC) pe_st <= 7'd36;
                  end
            7'd36: begin
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND};
                      pe_st <= 7'd37;
                  end
            7'd37: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0;
                      psc_ack_hold[1] <= 1'b0; pe_no_retx <= 1'b0;
                      psc_win_closed[1] <= 1'b0; src_skip <= 16'h0000;
                      pe_ep <= 4'd5; pe_conn <= 4'd1; pe_ret <= 7'd76; pe_st <= 7'd70;
                  end
            7'd76: begin   // E5 前: conn1 静默完再对 conn2 走"只等"静默
                      pe_conn <= 4'd2; pe_ret <= 7'd38; pe_st <= 7'd73;
                  end
            // ==================== E5 FIN 在飞 (j12 / j11 变异) =================
            7'd38: begin  // E5: 关 conn2 的窗 (fin_sent_r[2] 由 phase>=1 关闭语义造成)
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd2;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= 32'd0;
                      pe_st <= 7'd39;
                  end
            7'd39: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd2)) begin
                      scfg_upd_wr <= 1'b0; psc_win_closed[2] <= 1'b1;
                      pe_clr_pc <= 1'b1; pe_exp_conn <= 4'd2;
                      pe_exp_seq[2] <= u_tcb.snd_una_r[2]; pe_t <= 0; pe_st <= 7'd40;
                  end
            7'd40: begin
                      pe_t <= pe_t + 1;
                      if (u_dut.fin_sent_r[2]) w_ps_fin <= w_ps_fin + 1;
                      // 粘滞见证: "除 !fin_sent_r 之外的武装条件**同时**为真" 至少出现一拍
                      //   ("该臂有牙"的构造性见证; 首轮曾因重放会话把在飞抹掉而假空)
                      if (u_dut.fin_sent_r[2] && !u_dut.rst_sent_r[2] &&
                          (u_tcb.snd_wnd_r[2] == 16'd0) &&
                          (u_tcb.snd_nxt_r[2] != u_tcb.snd_una_r[2])) w_ps_e5ok <= w_ps_e5ok + 1;
                      if (u_tcb.snd_wnd_r[2] == 16'd0) w_ps_e5win <= w_ps_e5win + 1;
                      if (pe_t > PE_HOLD_SHORT) begin
                          pe_f_e5_probe <= pe_probe_cur;
                          pe_f_e5_state <= {u_dut.fin_sent_r[2], u_dut.rst_sent_r[2],
                                            (u_tcb.snd_nxt_r[2] != u_tcb.snd_una_r[2])};
                          pe_st <= 7'd41;
                      end
                  end
            7'd41: begin
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd2;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND};
                      pe_st <= 7'd42;
                  end
            7'd42: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd2)) begin
                      scfg_upd_wr <= 1'b0; psc_win_closed[2] <= 1'b0;
                      pe_ep <= 4'd6; pe_st <= 7'd43;
                  end
            // (E6 已挪到 E7 **之后** = 7'd55 起: 用 conn1 + 现场注入的 RST。
            //  原 conn3 版在本 TB 上**结构性不可达**: conn3 的 RST 预留 +1 会被打到
            //  conn3 的重放会话抹掉 —— `svc_rewind` 把 snd_nxt 写回 snd_una ⇒ 武装条件
            //  的"有在飞"子句为假 ⇒ 该臂退化成空判据 (首轮实测 E6 inflight=0)。)
            7'd43: begin pe_ep <= 4'd7; pe_conn <= 4'd1; pe_ret <= 7'd48; pe_st <= 7'd70; end
            // ============ E7 多连接相撞 (j13/j14; 本刀最重的那条缺陷) ==========
            //   构造: A = conn1 (关窗 ⇒ 探询待发) + B = conn0 (供数, 但被
            //   `ack_seen_tb[0]=0` ⇒ `tx_blk_sid[0]=1` 按住启动门 ⇒ 源**持续呈交**一个
            //   开帧请求而 DUT 不收 ⇒ `ds_guard = 0` 且 `s_tvalid = 1` 长期成立)。
            //   在 fire+2 拍 (= 读流水第 2 拍, 暂存落地前一拍) 释放 hold ⇒ 暂存落地那一拍
            //   `tx_blk_sid = 0` ⇒ 若没有 `ds_guard`, 探询槽上线与数据帧启动**同拍** ⇒
            //   数据帧带 conn1 的四元组与 seq 上线 (跨连接错帧 + 按错 seq 写 ring)。
            //   ⛔ 单连接 (A==B) 时自洽 ⇒ 本 episode 是**必须多连接**的那条 (REVIEW2 欠账)。
            7'd48: begin  // E7: 关 conn1 的窗 + 只允许 conn0 供数 + 按住 conn0 启动门
                      pe_conn <= 4'd1;
                      psc_ack_hold[1] <= 1'b1; pe_no_retx <= 1'b1; pe_holdb <= 1'b1;
                      src_skip <= 16'hFFFE;
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= 32'd0;
                      pe_st <= 7'd49;
                  end
            7'd49: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0; psc_win_closed[1] <= 1'b1;
                      pe_clr_pc <= 1'b1; pe_exp_conn <= 4'd1;
                      pe_exp_seq[1] <= u_tcb.snd_una_r[1];
                      pe_t <= 0; pe_st <= 7'd50;
                  end   // (`pe_coll_wit` 归观察块所有; 由 pe_clr_pc 清零 —— 单写者)
            7'd50: begin  // E7: 等 conn1 的 fire
                      pe_t <= pe_t + 1;
                      if (u_dut.ps_fire && (u_dut.scan_id == 4'd1)) begin
                          pe_de0 <= pe_d_ev;        // 见证锚: 观察窗内的数据帧计数
                          pe_t <= 0; pe_st <= 7'd51;
                      end else if (pe_t > PE_COLL_WAIT) begin
                          pe_de0 <= pe_d_ev; pe_t <= 0; pe_st <= 7'd51;
                      end
                  end
            7'd51: begin  // E7: 等 fire+2 (读流水第 2 拍) ⇒ 释放 hold
                      pe_t <= pe_t + 1;
                      if (u_dut.ps_rd_d2) begin pe_holdb <= 1'b0; pe_t <= 0; pe_st <= 7'd52; end
                      else if (pe_t > 16) begin pe_holdb <= 1'b0; pe_t <= 0; pe_st <= 7'd52; end
                  end
            7'd52: begin  // E7: 相撞观察窗 (判决在观察块 + frame_check)
                      pe_t <= pe_t + 1;
                      if ((pe_t <= 14) && (w_ps_dbg < 40)) begin
                          w_ps_dbg <= w_ps_dbg + 1;
                          $display("DBG E7 @%0d t=%0d rdy=%b rxidle=%b rf=%b tval=%b tid=%0d blk=%b busy=%b aqem=%b svc=%b re=%b scn=%b ract=%b wo=%b apen=%b fifo=%b bkr=%b coll=%b",
                                   cyc, pe_t, u_dut.ps_stage_rdy, u_dut.rx_idle, u_dut.recv_first,
                                   s_tvalid, s_tid, u_dut.tx_blk_sid, u_dut.ctrl_slot_busy,
                                   u_dut.ackq_empty, u_dut.svc, u_dut.ring_eval, u_dut.scan_now,
                                   u_dut.retx_active, win_open, u_dut.ack_pend_r, u_dut.fifo_full,
                                   u_dut.bank_rdy[u_dut.rx_bank], psc_coll);
                      end
                      if (pe_t > PE_COLL_OBS) begin
                          pe_f_e7_wit <= pe_coll_wit; pe_de1 <= pe_d_ev; pe_st <= 7'd53;
                      end
                  end
            7'd53: begin  // E7 收尾
                      pe_holdb <= 1'b0; src_skip <= 16'h0000;
                      psc_ack_hold[1] <= 1'b0; pe_no_retx <= 1'b0;
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND};
                      pe_st <= 7'd54;
                  end
            7'd54: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0; psc_win_closed[1] <= 1'b0;
                      pe_ep <= 4'd6; pe_conn <= 4'd1; pe_ret <= 7'd55; pe_st <= 7'd70;
                  end
            // ============ E6 RST 在飞 (j12 扩展 / j11 变异) —— 用在 E7 之后 ========
            //   为什么用 conn1 而不是 conn3: 见 7'd43 的注 (conn3 的 +1 留不住)。
            //   构造: 关 conn1 的窗 (在飞) + 现注入一条 RST (ack_req+ack_rst, id=1) ⇒
            //   RST 上线后 `rst_sent_r[1]=1` 且 `snd_nxt[1] = snd_una[1]+1` (预留 +1)
            //   ⇒ 除 `!rst_sent_r` 之外的武装条件**全部成立** ⇒ 这是**有牙**的构造:
            //   `PS_MUT_NOARM_RST` (删 `!rst_sent_r`) 必在此臂上冒探询。
            7'd55: begin  // E6: 关 conn1 的窗 + 冻结 snd_una + 挡住源 (同 E1 的相位纪律)
                      psc_ack_hold[1] <= 1'b1; pe_no_retx <= 1'b1; src_skip <= 16'hFFFE;
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= 32'd0;
                      pe_st <= 7'd56;
                  end
            7'd56: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0; psc_win_closed[1] <= 1'b1;
                      pe_clr_pc <= 1'b1; pe_exp_conn <= 4'd1;
                      pe_exp_seq[1] <= u_tcb.snd_una_r[1]; pe_t <= 0; pe_st <= 7'd57;
                  end
            7'd57: begin  // E6: 注入 RST 请求 (电平保持到 rst_sent_r[1] 出现)
                      pe_t <= pe_t + 1;
                      ack_req <= 1'b1; ack_id <= 4'd1; ack_rst <= 1'b1;
                      ack_syn <= 1'b0; ack_fin <= 1'b0; ack_val <= RCV_NXT;
                      if (u_dut.rst_sent_r[1] || (pe_t > 600)) begin
                          ack_req <= 1'b0; ack_rst <= 1'b0;
                          if (u_dut.rst_sent_r[1]) w_ps_rst1 <= w_ps_rst1 + 1;
                          pe_t <= 0; pe_st <= 7'd58;
                      end
                  end
            7'd58: begin  // E6: 观察窗 (j12-RST: 必须 0 探询)
                      pe_t <= pe_t + 1;
                      if (u_tcb.snd_wnd_r[1] == 16'd0) w_ps_e6win <= w_ps_e6win + 1;
                      if (u_dut.rst_sent_r[1]) w_ps_rst1 <= w_ps_rst1 + 1;
                      if (u_dut.rst_sent_r[1] && !u_dut.fin_sent_r[1] &&
                          (u_tcb.snd_wnd_r[1] == 16'd0) &&
                          (u_tcb.snd_nxt_r[1] != u_tcb.snd_una_r[1])) w_ps_e6ok <= w_ps_e6ok + 1;
                      if (pe_t > PE_HOLD_SHORT) begin
                          pe_f_e6_probe <= pe_probe_cur;
                          pe_f_e6_state <= {u_dut.fin_sent_r[1], u_dut.rst_sent_r[1],
                                            (u_tcb.snd_nxt_r[1] != u_tcb.snd_una_r[1])};
                          pe_st <= 7'd59;
                      end
                  end
            7'd59: begin  // E6 收尾
                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;
                      scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND};
                      pe_st <= 7'd60;
                  end
            7'd60: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin
                      scfg_upd_wr <= 1'b0;
                      psc_ack_hold[1] <= 1'b0; pe_no_retx <= 1'b0;
                      psc_win_closed[1] <= 1'b0; src_skip <= 16'h0000;
                      pe_done <= 1'b1; pe_ep <= 4'd0; pe_st <= 7'd61;
                  end
            default: ;
            endcase
`endif
        end
    end

    // ===================== ⭐ 构建 E: W66 的 TB 侧逐拍复算 =====================
    //   判据 (与 rtl/tcp_tx_frame.v 的 stat_winstall_ev **逐项同款**, 但在本 TB 里
    //   独立写出): 帧器站在数据帧启动点 + 呈交口有字 + 其余门全开 + 只有窗口关着。
    //   ⚠️ 只在 TCP_TX_OVL 分支有对应实现 (默认/串行分支的启动点是 state==S_IDLE,
    //      判据不同) ⇒ 本判据包 OVL。
`ifdef TCP_TX_OVL
    // ⭐ 构建 F: 谓词线提出成 `wire` —— W66/W67/W69 三个判据共用同一份**TB 自写**表达式
    //   (与改动前的内联写法**逐字同款**; 提出只是去重, 值不变)。
    wire tb_winstall_ev = (u_dut.rx_state == 2'd0) && u_dut.recv_first && s_tvalid &&
                          !u_dut.ack_pend_r && !u_dut.svc && !u_dut.ring_eval && !u_dut.scan_now &&
                          !u_dut.rx_flush && !u_dut.fifo_full && !u_dut.bank_rdy[u_dut.rx_bank] &&
                          !u_dut.tx_blk_sid && !win_open;
    // ⭐ 构建 F: 分裂判据 (TB 侧独立写; 与 DUT 的 `win_cap_bind` 同式不同源 —— 阈值取 TB 的档位值)
    wire tb_winstall_cap_ev = tb_winstall_ev && (win_wnd_eff >= TB_WIN_CAP);
    // ⭐ 构建 F (第二轮实测后补): W69 的**定向见证快照**。
    //   为什么第一轮的"跑完比末尾值"不够: 跑窗里还有一族 "零帽 conn" 的等窗事件
    //   (`tcb` 复位把 16 槽全清 0 ⇒ `win_cap = 0` ⇒ `win_open ≡ 0` ⇒ 那些拍也算等窗,
    //   且样本 = {0,0}) ⇒ 末尾值经常**恰好是 0** ⇒ "0 == 0" 是空判据 (实测 arm B/O 都是)。
    //   本快照只抓"样本归属 = 关窗那个 conn"的事件 (prev_rb_id == WC_CONN): 那时
    //   `win_cap == 1460` 且 `wing_diff >= 1460` ⇒ 样本**构造上非零** ⇒ 判据非空。
    reg  [3:0]  w67w_id_d;                    // 上一拍 rb_id = 本拍样本的归属 conn
    reg         w69_dir_arm, w69_dir_arm1;
    reg  [31:0] w69_dir_dut, w69_dir_tb;
    integer     w69_dir_hits;
    // ⭐ W67 机理探针 (arm B 实测有 4 拍"板帽侧" —— 结构性上需要某样本在飞 >= RING_CAP,
    //   机理**未定位** ⇒ 先取原始读数; 只打前 8 条, 不改变任何判据)
    integer     w67_dbg_n;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exp_winstall_cyc <= 0; exp_winstall_cap_cyc <= 0;
            exp_win_at_winstall <= 32'd0; wc_seen <= 1'b0;
            w67w_id_d <= 4'd0; w69_dir_arm <= 1'b0; w69_dir_arm1 <= 1'b0;
            w69_dir_dut <= 32'd0; w69_dir_tb <= 32'd0; w69_dir_hits <= 0;
            w67_dbg_n <= 0;
        end else begin
            if (tb_winstall_ev) begin
                exp_winstall_cyc <= exp_winstall_cyc + 1;
                exp_win_at_winstall <= {win_inflight, win_wnd_eff};   // W69 的期望锁存值
            end
            if (tb_winstall_cap_ev) exp_winstall_cap_cyc <= exp_winstall_cap_cyc + 1;
            if (!win_open) wc_seen <= 1'b1;
            // ---- W69 定向见证快照 (见声明处注) ----
            w67w_id_d   <= rb_id;
            w69_dir_arm1 <= w69_dir_arm;
            w69_dir_arm  <= (wc_st == 3'd2) && tb_winstall_ev && (w67w_id_d == WC_CONN);
            if (w69_dir_arm) w69_dir_hits <= w69_dir_hits + 1;
            if (w69_dir_arm1) begin      // 事件后 1 拍: DUT 与 TB 的锁存都已落地
                w69_dir_dut <= w_win_at_winstall;
                w69_dir_tb  <= exp_win_at_winstall;
            end
            // ---- W67 机理探针 (只打前 8 条) ----
            if (tb_winstall_cap_ev && (w67_dbg_n < 8)) begin
                w67_dbg_n = w67_dbg_n + 1;
                $display("DBG W67CAP#%0d @%0d prev_id=%0d eff=%04h infl=%04h win_open=%0d",
                         w67_dbg_n, cyc, w67w_id_d, win_wnd_eff, win_inflight, win_open);
            end
        end
    end
`endif

    // ===================== 影子账本 + 相位 =====================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 16; i = i + 1) begin sh_nxt[i] <= 32'd0; sh_una[i] <= 32'd0; end
            phase <= 2'd0;
        end else begin
            if ((phase == 2'd0) && (nseg[0] >= 30) && (nseg[1] >= 30) &&
                (nseg[2] >= 30) && (nseg[3] >= 5)) phase <= 2'd1;
            if ((phase == 2'd1) && (n_data >= 100) && fin_seen[2] && rst_seen[3])
                phase <= 2'd2;
            if (tcb_wr && (tcb_sel == 3'd1)) begin
                if (tcb_val == sh_nxt[tcb_id]) begin
                    e_idem = e_idem + 1;                // 幂等写 (0 长帧) — 合法
                end else if ((tcb_val - sh_nxt[tcb_id]) < 32'h8000_0000) begin
                    sh_nxt[tcb_id] <= tcb_val;
                end else if (tcb_val == sh_una[tcb_id]) begin
                    sh_nxt[tcb_id] <= tcb_val;
                    cov_rewinds = cov_rewinds + 1;
                end else if (!sel_tx) begin
                    sh_nxt[tcb_id] <= tcb_val;
                end else begin
                    e_seqmono = e_seqmono + 1;
                    if (e_seqmono < 6)
                        $display("[FAIL] seq_mono rev conn=%0d val=%h was=%h una=%h @%0d",
                                 tcb_id, tcb_val, sh_nxt[tcb_id], sh_una[tcb_id], cyc);
                end
                if (sel_tx && ((tcb_val - sh_una[tcb_id]) >= 32'h8000_0000)) begin
`ifdef TCP_TX_OVL
                    if (u_dut.retx_active) begin
                        e_below_retx = e_below_retx + 1;   // 回卷会话内: 迟到累计 ACK 所致
                    end else begin
`endif
                    e_seqmono = e_seqmono + 1;
                    if (e_seqmono < 6)
                        $display("[FAIL] seq below una conn=%0d val=%h una=%h @%0d",
                                 tcb_id, tcb_val, sh_una[tcb_id], cyc);
`ifdef TCP_TX_OVL
                    end
`endif
                end
            end else if (tcb_wr && (tcb_sel == 3'd2)) begin
                sh_una[tcb_id] <= tcb_val;
            end
            if (rst_seen[3]) dead[3] <= 1'b1;
        end
    end

    reg ack_req_p;
    always @(posedge clk) begin
        ack_req_p <= ack_req;
        if (ack_req && !ack_req_p && dbg_ar < 24) begin
            dbg_ar = dbg_ar + 1;
            $display("DBG ack_req rise @%0d id=%0d syn=%b fin=%b rst=%b", cyc, ack_id,
                     ack_syn, ack_fin, ack_rst);
        end
    end

    always @(posedge clk) begin
        if (dbg_on && (cyc % 20000) == 0 && (dbg_s < 40)) begin
            dbg_s = dbg_s + 1;
`ifdef TCP_TX_OVL
            $display("DBG st @%0d ph=%0d sc=%0d s0..3=%0d/%0d/%0d/%0d nseg=%0d/%0d/%0d/%0d bv=%b cc=%0d len=%0d pos=%0d srdy=%b sdata=%b wnd=%b ap=%b bkr=%b",
                     cyc, phase, setup_c, setup_st[0], setup_st[1], setup_st[2],
                     setup_st[3], nseg[0], nseg[1], nseg[2], nseg[3],
                     beat_v, cur_c, cur_len, cur_pos, s_tready,
                     u_dut.start_data, u_dut.wnd_open, u_dut.ack_pend_r,
                     u_dut.bank_rdy);
`endif
`ifdef TCP_TX_OVL
            $display("   sub: tready=%b rxst=%b rf=%b full=%b ff=%b em=%b bkr=%b blk=%b svc=%b re=%b scn=%b fl=%b",
                     u_dut.s_axis_tready, u_dut.rx_state, u_dut.recv_first,
                     u_dut.fifo_full, u_dut.fu_b, u_dut.em_b, u_dut.bank_rdy,
                     u_dut.tx_blk_sid, u_dut.svc, u_dut.ring_eval, u_dut.scan_now,
                     u_dut.rx_flush);
`endif
        end
    end

    reg [15:0] dbg_w2;
    initial dbg_w2 = 0;
    always @(posedge clk) begin
        if (s_tvalid && s_tready && dbg_w2 < 24) begin
            dbg_w2 <= dbg_w2 + 16'd1;
            $display("DBG sex @%0d c=%0d op=%b pos=%0d n=%0d td=%h tk=%h tl=%b",
                     cyc, cur_c, cur_op, cur_pos, cur_n, s_tdata, s_tkeep, s_tlast);
        end
    end

    // ===================== 源侧停滞看门狗 =====================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stall_cyc[0] <= 0;
        end else if (beat_v && !s_tready) begin
            stall[cur_c] <= 1'b1;
            stall_cyc[cur_c] <= stall_cyc[cur_c] + 1;
            // 帧启动门 (对应 app_pattern 的 tx_ok): 只持 opener 时被 DUT 合法挡
            // (fin_req/rst_sent 等) => 撤帧, 不卡住整个源 (撤时尚未交付任何字节)
            if (cur_op && (stall_cyc[cur_c] > 64)) begin
                if (dbg_on && (dbg_e < 12)) begin
                    dbg_e = dbg_e + 1;
                    $display("DBG cancel @%0d c=%0d (DUT gate closed: fin=%b rst=%b fs=%b rs=%b)",
                             cyc, cur_c, fin_req[cur_c], rst_req[cur_c],
                             o_fin_sent[cur_c], o_rst_sent[cur_c]);
                end
                beat_v <= 1'b0; cur_op <= 1'b0;
                stall_cyc[cur_c] <= 0;
                beat_id <= 4'd15;              // 无效 tid: 下一拍必换连接
            end
`ifdef TCP_TX_OVL
            if (dbg_on && (stall_cyc[cur_c] == 200) && (dbg_c < 8)) begin
                dbg_c = dbg_c + 1;
                $display("DBG stall @%0d c=%0d pos=%0d rxs=%b rf=%b ap=%b svc=%b re=%b scn=%b fl=%b wnd=%b blk=%b full=%b bkr=%b tba=%b",
                         cyc, cur_c, cur_pos, u_dut.rx_state, u_dut.recv_first,
                         u_dut.ack_pend_r, u_dut.svc, u_dut.ring_eval, u_dut.scan_now,
                         u_dut.rx_flush, u_dut.wnd_open, u_dut.tx_blk_sid,
                         u_dut.fifo_full, u_dut.bank_rdy, u_dut.s_axis_tready);
            end
`endif
        end
    end

    // ============ ⭐ r6 (L-A, 2026-10-08): ack_seen 数据启动门专项臂 ============
    //   `-d ARM_ACKGATE` 时启用: 数据流中途抽掉 ack_seen (全 0) 并保持 2000 拍 ——
    //   判据 (a) 保持窗内 (从 +2 拍起, 避同拍决策竞态) 不得出现任何 start_data 拍
    //            (有牙: 撤门变异件会在源供数后数拍内启动 ⇒ 红);
    //   判据 (b) 放回全 1 后 600 拍内必须恢复 start_data (死门 ⇒ 红);
    //   非空见证: 保持窗内源供数拍数 ≥ 100 (否则 (a) 是空判据) + 触发前已见帧上线
    //            (否则"抽取"发生在无数据期 = 空判据) —— 二者在 summary 查。
    //   ⚠️ 抽门期间源侧 opener 会被 64 拍看门狗合法撤帧 (DUT 门关是设计行为),
    //      源随后换连接继续供数 ⇒ 保持窗内供数见证照常累积。
`ifdef ARM_ACKGATE
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ack_seen_tb <= 16'hFFFF; ag_st <= 2'd0; ag_cyc <= 0;
            ag_wit_sv <= 0; ag_seen_sd <= 1'b0;
        end else begin
            if (u_dut.start_data) ag_seen_sd <= 1'b1;
            case (ag_st)
            2'd0: if ((cyc > 30000) && ag_seen_sd) begin
                      ack_seen_tb <= 16'h0; ag_st <= 2'd1;
                      ag_cyc <= 0; ag_wit_sv <= 0;
                  end
            2'd1: begin
                ag_cyc <= ag_cyc + 1;
                if (s_tvalid) ag_wit_sv <= ag_wit_sv + 1;
                if ((ag_cyc >= 2) && u_dut.start_data) e_ag_block <= e_ag_block + 1;
                if (ag_cyc >= 2000) begin
                    ack_seen_tb <= 16'hFFFF; ag_st <= 2'd2; ag_cyc <= 0;
                end
            end
            2'd2: begin
                ag_cyc <= ag_cyc + 1;
                if (u_dut.start_data) ag_st <= 2'd3;
                else if (ag_cyc >= 600) begin
                    e_ag_resume <= e_ag_resume + 1;
                    ag_st <= 2'd3;
                end
            end
            default: ;          // 2'd3 = 完成 (见证在 summary 查)
            endcase
        end
    end
`endif

    // ===================== OVL-only 判据 =====================
`ifdef TCP_TX_OVL
    wire        d_upd_wr_data = u_dut.upd_wr_data;
    wire        d_upd_wr_ctrl = u_dut.upd_wr_ctrl;
    wire        d_upd_wr_rew  = u_dut.upd_wr_rew;
    wire        d_slot_busy   = u_dut.ctrl_slot_busy;
    wire        d_tx_pend     = u_dut.ctrl_tx_pend;
    wire [2:0]  d_tx_state    = u_dut.tx_state;
    wire [1:0]  d_rx_state    = u_dut.rx_state;
    wire [2:0]  d_fin_cnt     = u_dut.fin_cnt;
    wire        d_tx_is_ctrl  = u_dut.tx_is_ctrl;
    wire        d_start_data  = u_dut.start_data;
    wire        d_start_ack   = u_dut.start_ack;
    wire        d_ovf_a       = u_dut.dovf_a;
    wire        d_ring_start  = u_dut.ring_start;
    wire        d_retx_ovf    = u_dut.retx_ovf;
    wire        d_rx_idle     = u_dut.rx_idle;
    wire [31:0] d_stat_drop_len = u_dut.stat_drop_len;
    wire        d_ovf_b       = u_dut.dovf_b;
    integer cnt_wsrc [0:2];
    integer pend_clr_wrong, pend_prev, issued_fin, issued_rst, issued_syn;
    integer ctrlp_kind;
    integer rx_t0, tx_t0, last_fin_cyc, last_fin_gap_v;
    integer rx1460_n, rx1460_min, tx1460_n, tx1460_min, fp1460_min, last_fp1460;
    integer ov_n, rx_n;
    reg [31:0] stat_drop_len_p;
    reg [1:0]  prev_wsrc;
    reg [7:0]  prev_gap;
    reg     retx_prev;
    integer rep_t0, rep_una;
    initial begin
        cnt_wsrc[0]=0; cnt_wsrc[1]=0; cnt_wsrc[2]=0;
        pend_clr_wrong=0; pend_prev=0; issued_fin=0; issued_rst=0; issued_syn=0;
        ctrlp_kind=0; rx_t0=-1; tx_t0=-1; last_fin_cyc=-1;
        rep_hi=0; rep_max=0; rep_hi_w=0; rep_lo_ok=0; rep_fcnt=0; rep_wcnt=0;
        rx1460_n=0; rx1460_min=1000000; tx1460_n=0; tx1460_min=1000000;
        fp1460_min=1000000; last_fp1460=-1; ov_n=0; rx_n=0;
        stat_drop_len_p=32'd0; prev_wsrc=2'd0; prev_gap=8'd255;
        ctrlp_cyc=-1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e_onehot <= 0;
        end else begin
            if ((d_upd_wr_data ? 1 : 0) + (d_upd_wr_ctrl ? 1 : 0) +
                (d_upd_wr_rew ? 1 : 0) > 1) begin
                e_onehot = e_onehot + 1;
                if (e_onehot < 6)
                    $display("[FAIL] onehot0 data=%b ctrl=%b rew=%b @%0d",
                             d_upd_wr_data, d_upd_wr_ctrl, d_upd_wr_rew, cyc);
            end
            if (d_upd_wr_data) cnt_wsrc[0] = cnt_wsrc[0] + 1;
            if (d_upd_wr_data && u_dut.retx_active) begin
                rep_wcnt = rep_wcnt + 1;
                if (dbg_on && (dbg_p < 24)) begin
                    dbg_p = dbg_p + 1;
                    $display("DBG adv_w @%0d id=%0d val=%h rxst=%0d finc=%0d fc=%0d pl=%0d",
                             cyc, u_dut.upd_id, u_dut.upd_val, d_rx_state, d_fin_cnt,
                             u_dut.f_conn[u_dut.rx_bank], u_dut.f_plen[u_dut.rx_bank]);
                end
            end
            if (d_upd_wr_ctrl) cnt_wsrc[1] = cnt_wsrc[1] + 1;
            if (d_upd_wr_rew ) cnt_wsrc[2] = cnt_wsrc[2] + 1;
            if (d_tx_pend && !d_slot_busy) begin
                e_pendbusy = e_pendbusy + 1;
                if (e_pendbusy < 6) $display("[FAIL] pend w/o busy @%0d", cyc);
            end
            if (pend_prev && !d_tx_pend && (d_tx_state == 3'd0))
                pend_clr_wrong = pend_clr_wrong + 1;
            pend_prev <= d_tx_pend;
            if (d_slot_busy && u_dut.ack_pend_r && !u_dut.ackq_empty)
                cov_ctrlblock = cov_ctrlblock + 1;
            if (d_start_ack) begin
                if (dbg_on && (dbg_n < 24)) begin
                    dbg_n = dbg_n + 1;
                    $display("DBG start_ack @%0d id=%0d is=%b aqem=%b apen=%b busy=%b",
                             cyc, u_dut.ctrl_id, u_dut.ctrl_is, u_dut.ackq_empty,
                             u_dut.ack_pend_r, d_slot_busy);
                end
                ctrlp_cyc = cyc;
                if (u_dut.aq_fin) begin issued_fin = issued_fin + 1; ctrlp_kind = 1; end
                if (u_dut.aq_rst) begin issued_rst = issued_rst + 1; ctrlp_kind = 2; end
                if (u_dut.aq_syn) begin issued_syn = issued_syn + 1; ctrlp_kind = 3; end
            end
            if ((ctrlp_cyc >= 0) && ((cyc - ctrlp_cyc) > (32*260))) begin
                e_ctrl_to = e_ctrl_to + 1;
                $display("[FAIL] ctrl slot timeout kind=%0d @%0d", ctrlp_kind, cyc);
                ctrlp_cyc = -1;
            end
            if (d_start_data && s_tready && (rx_t0 < 0)) rx_t0 = cyc;
            if ((d_rx_state == 2'd2) && (d_fin_cnt == 3'd4) && (rx_t0 >= 0)) begin
                rx_cyc_n = rx_cyc_n + 1;
                rx_cyc_sum = rx_cyc_sum + (cyc - rx_t0 + 1);
                if ((cyc - rx_t0 + 1) < rx_cyc_min) rx_cyc_min = cyc - rx_t0 + 1;
                if (u_dut.f_plen[u_dut.rx_bank] == 12'd1460) begin
                    rx1460_n = rx1460_n + 1;
                    if ((cyc - rx_t0 + 1) < rx1460_min) rx1460_min = cyc - rx_t0 + 1;
                end
                rx_t0 = -1;
            end
            if ((d_tx_state == 3'd1) && (u_dut.thcnt == 3'd0) && !d_tx_is_ctrl &&
                (tx_t0 < 0)) tx_t0 = cyc;
            if ((d_rx_state == 2'd2) && (d_fin_cnt == 3'd0)) last_fin_w_cyc = cyc;
            if ((d_rx_state == 2'd2) && (d_fin_cnt == 3'd4)) last_fin_cyc = cyc;
            if (d_start_data && s_tready && (last_fin_cyc >= 0)) begin
                if ((cyc - last_fin_cyc) < min_fin_gap) min_fin_gap = cyc - last_fin_cyc;
                if ((cyc - last_fin_cyc) == 1) cov_fin_min = cov_fin_min + 1;
                last_fin_cyc = -1;
            end
            if (d_start_data && s_tready && (last_fin_w_cyc >= 0)) begin
                if ((cyc - last_fin_w_cyc) < min_wr_gap) min_wr_gap = cyc - last_fin_w_cyc;
                last_fin_w_cyc = -1;
            end
            if ((d_tx_state == 3'd4) && !d_tx_is_ctrl && (!m_tvalid || m_tready)) begin
                if (last_tx_done_cyc >= 0) begin
                    fp_n = fp_n + 1;
                    fp_sum = fp_sum + (cyc - last_tx_done_cyc);
                    if ((cyc - last_tx_done_cyc) < fp_min) fp_min = cyc - last_tx_done_cyc;
                end
                last_tx_done_cyc = cyc;
                if (tx_t0 >= 0) begin
                    tx_cyc_n = tx_cyc_n + 1;
                    tx_cyc_sum = tx_cyc_sum + (cyc - tx_t0 + 1);
                    if ((cyc - tx_t0 + 1) < tx_cyc_min) tx_cyc_min = cyc - tx_t0 + 1;
                    if (u_dut.f_plen[u_dut.tx_bank] == 12'd1460) begin
                        tx1460_n = tx1460_n + 1;
                        if ((cyc - tx_t0 + 1) < tx1460_min)
                            tx1460_min = cyc - tx_t0 + 1;
                        if (last_fp1460 >= 0) begin
                            if ((cyc - last_fp1460) < fp1460_min)
                                fp1460_min = cyc - last_fp1460;
                        end
                        last_fp1460 = cyc;
                    end
                    tx_t0 = -1;
                end
            end
            if (d_ovf_a || d_ovf_b) e_ovf = e_ovf + 1;
            // ⭐ 新判据 (对抗审查 B1/F1): 回绕安全 —— `ring_start` 与 `retx_ovf` 不得同拍;
            //    且会话期间**不得**出现"delta 为负却仍起重放"的拍 (洪水必要条件)
            if (d_ring_start && d_retx_ovf) begin
                e_f1_ring = e_f1_ring + 1;
                if (dbg_on && (e_f1_ring < 4))
                    $display("DBG F1! ring_start with retx_ovf @%0d snd_nxt=%h retx_hi=%h",
                             cyc, u_dut.rb_snd_nxt, u_dut.retx_hi);
            end
            if (d_retx_ovf && u_dut.retx_active) e_f1 = e_f1 + 1;   // 越顶拍 (信息计数)
            // F1 判据 ②(delta 非负, 回绕安全): ring_start 拍上 delta 必须是"正"长度
            if (d_ring_start && (d_ring_delta > 32'h7FFF_FFFF)) begin
                e_f1_delta = e_f1_delta + 1;
                if (e_f1_delta < 6)
                    $display("[FAIL] F1 delta: ring_start w/ delta=%h plen_preset=%0d @%0d",
                             d_ring_delta, d_plen_preset, cyc);
            end
            // F1 判据 ③(每拍 wrap-safe): 重放期内不得出现 snd_nxt 越过 retx_hi
            if (d_ring_act && d_retx_ovf) begin
                e_f1_cyc = e_f1_cyc + 1;
                if (e_f1_cyc < 6)
                    $display("[FAIL] F1 wrap-safe: ring_act w/ snd_nxt=%h > retx_hi=%h @%0d",
                             u_dut.rb_snd_nxt, u_dut.retx_hi, cyc);
            end
            // 见证补齐: 中止帧数 (TB 侧独立记) + 控制/数据写口相邻拍数
            if (d_stat_drop_len != stat_drop_len_p) begin
                cov_aborts = cov_aborts + (d_stat_drop_len - stat_drop_len_p);
                stat_drop_len_p = d_stat_drop_len;
            end
            if ((prev_wsrc != 2'd0) && (d_upd_wr_data || d_upd_wr_ctrl)) begin
                if ((prev_wsrc == 2'd2) && d_upd_wr_data) cov_cdadj = cov_cdadj + 1;
                if ((prev_wsrc == 2'd1) && (prev_gap == 1)) cov_cdadj = cov_cdadj + 1;
            end
            if (d_upd_wr_ctrl) prev_wsrc = 2'd1;
            else if (d_upd_wr_data) prev_wsrc = 2'd2;
            else if (d_upd_wr_rew) prev_wsrc = 2'd3;
            if (d_upd_wr_data || d_upd_wr_ctrl || d_upd_wr_rew) prev_gap = 0;
            else if (prev_gap < 8'd255) prev_gap = prev_gap + 8'd1;
            // 覆盖见证 "槽忙时 start_ack 真被挡": 加 rx_idle (审查: 原计数是超集)
            if (d_slot_busy && d_rx_idle && u_dut.ack_pend_r && !u_dut.ackq_empty)
                cov_ctrlblock_real = cov_ctrlblock_real + 1;
            // M-C6 判据 (审查构造): 门 = "有同 conn 的 seq 消耗型控制帧在飞时不服务回卷"
            //   c6_gated   = 窗口内请求真的被门挡住的拍数 (见证: 门被武装)
            //   e_c6       = 回卷在控制帧在飞时**被服务** (M-C6 签名; 修复版必须恒 0)
            //   e_c6_grant = 窗口内请求被 gnt (同步签名, 供变异体定位)
            if (d_adv_infl && c6_hold) c6_gated = c6_gated + 1;
            if (d_adv_infl && d_svc_rew) begin
                e_c6 = e_c6 + 1;
                if (e_c6 < 6)
                    $display("[FAIL] C6: rewind served while ctrl in flight id=%0d @%0d",
                             u_dut.retx_id_r, cyc);
            end
            //   (gnt 是组合信号 `svc_x && retx_req`; 窗口内允许"会话启动 gnt",
            //    但**绝不准**在 adv_infl 拍上出 gnt —— 那说明门被绕开了)
            if (u_dut.retx_gnt && d_adv_infl) e_c6_grant = e_c6_grant + 1;
            // ⭐ P7B-RETXFIX 判据 C (M-C2 确定性化, 2026-10-07): 契约 FIX-2' "帧首拍同拍
            //   预留 +1" —— 消耗 seq 的 SYN/FIN/RST 在 start_ack 拍上必须**同拍**出现
            //   (wr,val,id) 三件套 (upd_wr_ctrl ∧ upd_val=rb_snd_nxt+1 ∧ upd_id=start_id)。
            //   旧见证 (seqmono/seqcont) 靠"8 拍窗内恰好落一个数据帧"的巧合 —— 实测在
            //   udp_hls_10g_fix 轮静默 (原树 StageC 轮命中 1 次)。本判据按契约判 ⇒
            //   M-C2 (预留寄存 8 拍) 首拍即红, 与交错相位无关。旧见证保留不删。
            if (u_dut.start_ack && (u_dut.aq_syn | u_dut.aq_fin | u_dut.aq_rst)) begin
                cov_c2_resv = cov_c2_resv + 1;
                if (!u_dut.upd_wr_ctrl ||
                    (u_dut.upd_val != (u_dut.rb_snd_nxt + 32'd1)) ||
                    (u_dut.upd_id != u_dut.start_id)) begin
                    e_c2_resv = e_c2_resv + 1;
                    if (e_c2_resv < 6)
                        $display("[FAIL] C2: seq-consuming start_ack missing same-cycle +1 (wr=%b val=%h id=%0d want=%h/%0d) @%0d",
                                 u_dut.upd_wr_ctrl, u_dut.upd_val, u_dut.upd_id,
                                 u_dut.rb_snd_nxt + 32'd1, u_dut.start_id, cyc);
                end
            end
            // 覆盖见证: 预算被撞到 (跳写拍) —— 判"判据是否被走到" (防空判据)
            if (u_dut.replay_jump) cov_jump_ev = cov_jump_ev + 1;
            // T8 结构性判据: RX 引擎与 TX 引擎**同时在飞**的拍数占比 (乒乓定义)
            // RX "在飞" = 状态非 IDLE **或** 正在收帧 (收帧期 rx_state 仍 = RX_IDLE!)
            if (((d_rx_state != 2'd0) || !u_dut.recv_first) && (d_tx_state != 3'd0))
                ov_n = ov_n + 1;
            if ((d_rx_state != 2'd0) || !u_dut.recv_first) rx_n = rx_n + 1;
            if (u_dut.retx_active && !retx_prev) begin
                cov_replay_sessions = cov_replay_sessions + 1;
                rep_hi   = u_dut.retx_hi;
                rep_hi_w = u_dut.retx_hi;
                rep_max  = u_dut.rb_snd_una;
                rep_una = u_dut.rb_snd_una;
                rep_t0  = cyc;
                rep_f0  = cov_replay_frames;   // ⭐ P7B-RETXFIX: 会话重放帧计数锚
                rep_full = u_dut.replay_full;  // ⭐ r4: RTO 全会话 ⇒ 跨度判据豁免
            end
            if (!u_dut.retx_active && retx_prev) begin
                j9_dl = 60000; j9_conn = u_dut.retx_id_r; j9_hi = rep_hi_w;
                // ⚠️ 判据降级 (如实登记在 P7B_STAGEC_TX.md): "会话内必须覆盖到 retx_hi"
                // 这一条在本 TB 上**无法干净建立** —— 回卷时刻**仍在 bank 里未发送**的
                // 帧, 其字节由 bank 在会话前后照常送出 (不占会话窗口), 而 `retx_active`
                // 是**全局**旗, 无法把"会话期间别的连接的推进写"分离出去 ⇒ 尾段短差
                // 不能判成缺陷。硬判据改挂: (a) 会话有界终止 (stuck=0); (b) 会话窗口内
                // 每个帧的**内容**逐字节正确 (payload 判据); (c) 跨整轮 J4 无空洞。
                if (!rep_lo_ok || (((rep_hi_w - rep_max) != 32'd0) &&
                                   ((rep_hi_w - rep_max) < 32'h8000_0000))) begin
                    e_replay_tail = e_replay_tail + 1;
                    if (dbg_on && (e_replay_tail < 8))
                        $display("DBG replay tail short: hi=%h max=%h frames=%0d adv_writes=%0d @%0d",
                                 rep_hi_w, rep_max, rep_fcnt, rep_wcnt, cyc);
                end
            // ⭐ P7B-RETXFIX 判据 A (重放预算): 本会话重放帧数 (迟到帧计数差分) 必须
            //   ≤ RETX_SPAN+1 (K 帧 + 1 拍捕获滑移)。旧行为 = 整窗重放 (实测 StageC
            //   轮同 TB 平均 2.9 帧/会话, 窗口最大 ~5-6 帧) ⇒ M-K1 变体确定性命中。
            if (!rep_full && ((cov_replay_frames - rep_f0) > (u_dut.RETX_SPAN + 1))) begin
                e_replay_span = e_replay_span + 1;
                $display("[FAIL] RETXFIX span: session replay frames=%0d > K+1 (%0d) conn=%0d @%0d",
                         cov_replay_frames - rep_f0, u_dut.RETX_SPAN + 1, j9_conn, cyc);
            end
            if (!rep_full && ((cov_replay_frames - rep_f0) > rep_smax))
                rep_smax = cov_replay_frames - rep_f0;
            // ⭐ P7B-RETXFIX 判据 B (收尾跳写): 会话结束时 snd_nxt 不得低于 retx_hi
            //   (预算耗尽必须跳写到位; 否则 tcp_rx 的 ACK 接受上界回落 ⇒ P4d 死锁面)。
            //   M-K2 变体 (只撤跳写) 确定性命中; 全窗排空 (==) / F1 越顶 (>) 均合法。
            if ((u_tcb.snd_nxt_r[j9_conn] - rep_hi_w) >= 32'h8000_0000) begin
                e_replay_jump = e_replay_jump + 1;
                $display("[FAIL] RETXFIX jump: session end snd_nxt=%h < retx_hi=%h conn=%0d @%0d",
                         u_tcb.snd_nxt_r[j9_conn], rep_hi_w, j9_conn, cyc);
            end
            // J9 (审查 B4 口径): 会话结束后 60k 拍内, 该连接的对端前沿必须达到 retx_hi
            //   —— 这是"覆盖由构造保证"的**可切分**形式 (与 exp_new 对齐, 不依赖会话窗口)
            if (j9_dl != 0) begin
                j9_dl = j9_dl - 1;
                if ((j9_dl == 1) && ((exp_new[j9_conn] - j9_hi) >= 32'h8000_0000)) begin
                    e_j9 = e_j9 + 1;
                    if (dbg_on && (e_j9 < 4))
                        $display("DBG J9 uncovered: conn=%0d hi=%h peer=%h @%0d",
                                 j9_conn, j9_hi, exp_new[j9_conn], cyc);
                end
            end
            end
            // ⭐ (审查 B2 族的"结构性恒 0"教训): 会话自锁判据必须**每拍**评估 ——
            //   原先写在 `!retx_active && retx_prev` (会话结束沿) 块里 ⇒
            //   **永不终止的会话永远不会被计到** (恒 0)。M-C4 就是这一族。
            if (u_dut.retx_active && !stuck_r && ((cyc - rep_t0) > 120000)) begin
                e_replay_stuck = e_replay_stuck + 1;
                $display("[FAIL] replay session stuck (no end) id=%0d t0=%0d @%0d",
                         u_dut.retx_id_r, rep_t0, cyc);
            end
            stuck_r = u_dut.retx_active && ((cyc - rep_t0) > 120000);
            retx_prev <= u_dut.retx_active;
        end
    end
`endif

`ifdef ARM_PERSIST
    // ================ ⭐ P7B-PERSIST 观察块 (只读 DUT 状态线; 单写者) ================
    //   消费 `frame_check` 落的探询事件 (计数变化沿), 维护累计 + "当前 episode" 计数,
    //   并维护相撞见证 `pe_coll_wit` (由 FSM 的 `pe_clr_pc` 清零 ⇒ 单写者规则保持)。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pe_probe_seen <= 0; pe_probe_ep <= 0; pe_probe_out <= 0;
            pe_probe_cur <= 0; pe_pn <= 0; pe_coll_wit <= 0;
            pe_d_seen <= 0; w_vis1 <= 0; w_vis1_cyc <= 0; w_leak1 <= 0;
            for (pe_x = 0; pe_x < 8; pe_x = pe_x + 1) begin
                pe_pt[pe_x] <= 0; pe_pv[pe_x] <= 0;
            end
        end else begin
            // 扫描访问计数 (conn1): 与 RTL `ps_timer` 的**同一把尺子** (1 visit = 该连接
            // 的一次 scan_now 访问) —— 阶梯判据用它, 而不是用拍数 (扫描节奏会被 ACK/重放
            // 挤稀 ⇒ 拍数口径不可判; 设计件 §3.1 的 "1 visit = 256 拍" 只在扫描不停时成立)
            if (u_dut.scan_now && (u_dut.scan_id == 4'd1)) w_vis1 <= w_vis1 + 1;
            // 泄漏见证: "TB 自己关着 conn1 的窗" 期间仍上线了 conn1 的数据帧 (非探询)
            if (u_dut.scan_now && (u_dut.scan_id == 4'd1)) w_vis1_cyc <= cyc;
            if (pe_d_ev != pe_d_seen) begin
                pe_d_seen <= pe_d_ev;
                if (psc_win_closed[pe_d_conn] && (pe_d_conn == 4'd1)) w_leak1 <= w_leak1 + 1;
            end
            if (pe_probe_ev != pe_probe_seen) begin
                pe_probe_seen <= pe_probe_ev;
                if (pe_st != 7'd0) begin
                    // j3 口径 (订正): "探询序列**首/末**之间的 snd_nxt 逐位不变" ——
                    //   关窗边界上正在收的那一帧会合法推进 snd_nxt (实测 +1531 B),
                    //   那不是探询的副作用; 首个探询 ≥ RTO 之后, 边界的在飞早已落地。
                    if (pe_exp_conn == 4'd1) begin
                        if (pe_probe_cur == 0) pe_sn_first <= u_tcb.snd_nxt_r[1];
                        pe_sn_last <= u_tcb.snd_nxt_r[1];
                    end
                    pe_probe_ep  <= pe_probe_ep + 1;
                    pe_probe_cur <= pe_probe_cur + 1;
                    if (pe_pn < 8) begin
                        pe_pt[pe_pn] <= pe_rec_cyc; pe_pv[pe_pn] <= w_vis1; pe_pn <= pe_pn + 1;
                    end
                end else
                    pe_probe_out <= pe_probe_out + 1;   // j5: episode 外必须恒 0
            end
            // 相撞见证 (psc_coll 的真值 = 逐项自写的 "无 ds_guard 时探询槽上线 ∧ 数据帧启动")
            if (psc_coll && ((pe_st == 7'd51) || (pe_st == 7'd52))) pe_coll_wit <= pe_coll_wit + 1;
            // 清零放最后 ⇒ 同拍冲突时"清"优先 (与 RTL 的 cfg_up/解除武装清位同序)
            if (pe_clr_pc) begin pe_probe_cur <= 0; pe_pn <= 0; pe_coll_wit <= 0; end
        end
    end

    // 容差带判据助手 (只在本臂用): |x - want| <= want*tol_pct/100 + slack
    function in_band;
        input integer x; input integer want; input integer tol_pct; input integer slack;
        integer d;
        begin
            d = (x > want) ? (x - want) : (want - x);
            in_band = (d <= ((want * tol_pct) / 100 + slack));
        end
    endfunction
`endif

    // ===================== 汇总 =====================
    integer tot_red;
    task summary_and_exit;
        begin
            tot_red = e_parse + e_csum + e_payload + e_seqcont + e_seqmono + e_ctrl +
                      e_ctrl_to + e_onehot + e_pendbusy + e_replay + e_replay_stuck +
                      e_ovf + e_ackf + e_f1_ring + e_j9 + e_c6 + e_f1_delta + e_f1_cyc +
                      e_replay_span + e_replay_jump + e_c2_resv +
                      e_ag_block + e_ag_resume;
            // ⭐ P7B-PERSIST 本臂判决: 与既有判据同款 —— 每条 `tot_red = tot_red + 1`
            //    直接落在下面对应判据里 (计数器只为显示, 不重复计入)。
            $display("---------------- TB_TCP_TX_OVL SUMMARY ----------------");
            $display("FRAMES recv=%0d data=%0d ctrl=%0d dead_skip=%0d cyc=%0d",
                     n_frames, n_data, n_ctrl, n_dead_skip, cyc);
            $display("COV frames=%0d replay_sessions=%0d replay_frames=%0d conns=%0d plen0=%0d singlebeat=%0d ctrlblock=%0d rewinds=%0d",
                     n_data, cov_replay_sessions, cov_replay_frames, cov_conns,
                     cov_plen0, cov_singlebeat, cov_ctrlblock, cov_rewinds);
            $display("MINGAP handoff_to_next_start=%0d finmin1_hits=%0d advwrite_to_next_start=%0d",
                     min_fin_gap, cov_fin_min, min_wr_gap);
            $display("CYCRX min=%0d avg_milli=%0d n=%0d", rx_cyc_min,
                     (rx_cyc_sum*1000)/((rx_cyc_n==0)?1:rx_cyc_n), rx_cyc_n);
            $display("CYCTX min=%0d avg_milli=%0d n=%0d", tx_cyc_min,
                     (tx_cyc_sum*1000)/((tx_cyc_n==0)?1:tx_cyc_n), tx_cyc_n);
            $display("FRAMEPERIOD min=%0d avg_milli=%0d n=%0d", fp_min,
                     (fp_sum*1000)/((fp_n==0)?1:fp_n), fp_n);
            $display("WIRE fin=%0d rst=%0d syn=%0d", w_fin[0]+w_fin[1]+w_fin[2]+w_fin[3],
                     w_rst[0]+w_rst[1]+w_rst[2]+w_rst[3],
                     w_syn[0]+w_syn[1]+w_syn[2]+w_syn[3]);
            $display("DUT stat_frames=%0d stat_bytes=%0d stat_ack=%0d adrop=%0d drop_len=%0d eend=%0d fin=%0d rst=%0d retx=%0d tlast_in=%0d",
                     stat_frames, stat_bytes, stat_ack, stat_ack_drop, stat_drop_len,
                     stat_eend, stat_fin, stat_rst, stat_retx, stat_tlast_in);
`ifdef TCP_TX_OVL
            $display("OVL F1 overtop_cyc=%0d wrap_ev=%0d delta_red=%0d cyc_red=%0d cov_aborts=%0d cov_cdadj=%0d ctrlblk_real=%0d",
                     e_f1, u_dut.stat_retx_wrap, e_f1_delta, e_f1_cyc, cov_aborts, cov_cdadj,
                     cov_ctrlblock_real);
            $display("OVL C6 wins=%0d req_win=%0d gated=%0d grant_in_win=%0d servedwhile=0_chk_red_%0d",
                     c6_n, c6_req_win, c6_gated, e_c6_grant, e_c6);
            $display("OVL wsrc data=%0d ctrl=%0d rew=%0d pendclr_wrong=%0d ovf=%0d issued fin/rst/syn=%0d/%0d/%0d",
                     cnt_wsrc[0], cnt_wsrc[1], cnt_wsrc[2], pend_clr_wrong, e_ovf,
                     issued_fin, issued_rst, issued_syn);
            $display("OVL RETXFIX span_max=%0d span_over=%0d jump_bad=%0d c2resv_n=%0d c2resv_bad=%0d jump_ev=%0d",
                     rep_smax, e_replay_span, e_replay_jump, cov_c2_resv, e_c2_resv, cov_jump_ev);
`endif
            $display("REDS parse=%0d csum=%0d payload=%0d seqcont=%0d seqmono=%0d ctrl=%0d ctrl_to=%0d onehot=%0d pendbusy=%0d replay=%0d stuck=%0d ovf=%0d ackf=%0d",
                     e_parse, e_csum, e_payload, e_seqcont, e_seqmono, e_ctrl,
                     e_ctrl_to, e_onehot, e_pendbusy, e_replay, e_replay_stuck,
                     e_ovf, e_ackf);
            $display("REDS2 replay_gap=%0d below_una_during_retx=%0d replay_tail_short=%0d (info) F1_ring=%0d J9=%0d",
                     e_replay_gap, e_below_retx, e_replay_tail, e_f1_ring, e_j9);
            if (n_data < NF_TGT) begin tot_red = tot_red + 1;
                $display("[FAIL] T5 witness cov_frames %0d < %0d", n_data, NF_TGT); end
`ifdef TCP_TX_OVL
            if (cov_replay_sessions < 5) begin tot_red = tot_red + 1;
                $display("[FAIL] T5 witness replay_sessions=%0d < 5", cov_replay_sessions); end
`endif
            if ((cov_plen0 < 1) || (cov_singlebeat < 1)) begin tot_red = tot_red + 1;
                $display("[FAIL] T5 witness plen0=%0d singlebeat=%0d", cov_plen0, cov_singlebeat); end
            if (cov_conns < 3) begin tot_red = tot_red + 1;
                $display("[FAIL] T5 witness conns=%0d < 3", cov_conns); end
            if (stat_eend != 32'd0) begin tot_red = tot_red + 1;
                $display("[FAIL] stat_eend=%0d", stat_eend); end
`ifdef TCP_TX_OVL
            if ((cnt_wsrc[0]==0)||(cnt_wsrc[1]==0)||(cnt_wsrc[2]==0)) begin
                tot_red = tot_red + 1;
                $display("[FAIL] T3 空判据 wsrc=%0d/%0d/%0d",
                         cnt_wsrc[0], cnt_wsrc[1], cnt_wsrc[2]); end
            if (cov_ctrlblock < 20) begin tot_red = tot_red + 1;
                $display("[FAIL] T5 witness ctrlblock=%0d < 20", cov_ctrlblock); end
            if (cov_ctrlblock_real < 1) begin tot_red = tot_red + 1;
                $display("[FAIL] T5 witness ctrlblock_real(%0d) == 0 (槽忙且 rx_idle 且有待发条目)", cov_ctrlblock_real); end
            if (c6_req_win < 1) begin tot_red = tot_red + 1;
                $display("[FAIL] T5 witness M-C6窗口未武装 (req_win=0)"); end
            if (c6_gated < 1) begin tot_red = tot_red + 1;
                $display("[FAIL] T5 witness M-C6 gate never engaged (gated=0)"); end
            if (e_c6_grant > 0) begin tot_red = tot_red + 1;
                $display("[FAIL] M-C6: 窗口内请求被 gnt (=%0d)", e_c6_grant); end
            if (cov_aborts < 2) begin tot_red = tot_red + 1;
                $display("[FAIL] T5 witness cov_aborts=%0d < 2 (中止帧)", cov_aborts); end
            if (cov_cdadj < 20) begin tot_red = tot_red + 1;
                $display("[FAIL] T5 witness cov_ctrl_data_write_adjacent=%0d < 20", cov_cdadj); end
            if ((cov_fin_min < 20) && (c6_n > 0)) begin tot_red = tot_red + 1;
                $display("[FAIL] T5 witness finmin1_hits=%0d < 20", cov_fin_min); end
            if (e_f1_ring > 0) begin tot_red = tot_red + 1;
                $display("[FAIL] F1: ring_start 与 retx_ovf 同拍 (=%0d)", e_f1_ring); end
            if (e_j9 > 0) begin tot_red = tot_red + 1;
                $display("[FAIL] J9: 会话结束后 60k 拍内对端前沿未达 retx_hi (=%0d)", e_j9); end
            if (issued_fin != (w_fin[0]+w_fin[1]+w_fin[2]+w_fin[3])) begin
                tot_red = tot_red + 1;
                $display("[FAIL] T4 FIN issued=%0d transmitted=%0d", issued_fin,
                         w_fin[0]+w_fin[1]+w_fin[2]+w_fin[3]); end
            if (issued_rst != (w_rst[0]+w_rst[1]+w_rst[2]+w_rst[3])) begin
                tot_red = tot_red + 1;
                $display("[FAIL] T4 RST issued=%0d transmitted=%0d", issued_rst,
                         w_rst[0]+w_rst[1]+w_rst[2]+w_rst[3]); end
            if (issued_syn != (w_syn[0]+w_syn[1]+w_syn[2]+w_syn[3])) begin
                tot_red = tot_red + 1;
                $display("[FAIL] T4 SYN issued=%0d transmitted=%0d", issued_syn,
                         w_syn[0]+w_syn[1]+w_syn[2]+w_syn[3]); end
            if (pend_clr_wrong > 0) begin tot_red = tot_red + 1;
                $display("[FAIL] T9 pend 清位拍异常 =%0d", pend_clr_wrong); end
            // ---- T8: 拍/帧判据 (只对满长 1460B 帧) ----
            $display("T8 rx1460 min=%0d n=%0d (expect <=190)  tx1460 min=%0d n=%0d (expect <=192)",
                     rx1460_min, rx1460_n, tx1460_min, tx1460_n);
            if (rx1460_n == 0) begin tot_red = tot_red + 1;
                $display("[FAIL] T8 witness rx1460_n==0"); end
            else if (rx1460_min > 190) begin tot_red = tot_red + 1;
                $display("[FAIL] T8 RX 引擎 min=%0d > 190", rx1460_min); end
            if (tx1460_n == 0) begin tot_red = tot_red + 1;
                $display("[FAIL] T8 witness tx1460_n==0"); end
            else if (tx1460_min > 192) begin tot_red = tot_red + 1;
                $display("[FAIL] T8 TX 引擎 min=%0d > 192", tx1460_min); end
            // T8 结构性判据 (乒乓定义): **RX 在飞期间 TX 也在飞的拍数 / RX 在飞拍数**
            // 健康乒乓 ≈ 50-60%; 退化单 bank (收完才发) ≈ 0-1%.
            $display("T8 fp1460 min=%0d (expect <=200)  overlap=%0d/100 of RX-inflight (%0d/%0d)",
                     fp1460_min, (ov_n*100)/((rx_n==0)?1:rx_n), ov_n, rx_n);
            if ((rx_n > 50000) && ((ov_n*100) < (rx_n*25))) begin tot_red = tot_red + 1;
                $display("[FAIL] T8 收发重叠度 %0d%% < 25%% (乒乓退化?)", (ov_n*100)/rx_n); end
            if ((fp1460_min > 220) && (tx1460_n > 100)) begin tot_red = tot_red + 1;
                $display("[FAIL] T8 满长帧帧周期 min=%0d > 220 (乒乓退化?)", fp1460_min); end
`ifdef TCP_TX_OVL
            // ---- ⭐ 构建 E: W66 (stat_winstall = 帧器侧**窗口门**停顿拍数) ------
            $display("W66 dut=%0d tb=%0d wndclosed_seen=%0d wc_st=%0d",
                     w_stat_winstall, exp_winstall_cyc, wc_seen, wc_st);
            if (!wc_seen) begin tot_red = tot_red + 1;
                $display("[FAIL] W66 空判据: 整个跑窗内 wnd_open 从未观察到 0"); end
            if (exp_winstall_cyc < 64) begin tot_red = tot_red + 1;
                $display("[FAIL] W66 空判据: TB 侧窗口门停顿拍=%0d < 64", exp_winstall_cyc); end
            if (w_stat_winstall !== exp_winstall_cyc) begin tot_red = tot_red + 1;
                $display("[FAIL] W66 语义不符 (逐拍复算): dut=%0d tb=%0d",
                         w_stat_winstall, exp_winstall_cyc); end
            // ---- ⭐ 构建 F: W67 (板帽侧那一份) + W69 (操作点锁存) -----------------
            //   判据形状 = **双边等式** (与 TB 侧独立复算逐字相等) ⇒ 两个方向都有牙:
            //     多数 (把对端侧也算进来) 与 少数 (哑计数器) 都会红。
            //   ⚠️ 在**默认帽** (0xBFFE) 下板帽侧结构性为 0 ⇒ 该方向是**空判据**;
            //     真正激励它的是 `-d W67_CAP_SMALL` 那一臂 (`W67_MINCAP_WIT 见下)。
            $display("W67 dut=%0d tb_cap=%0d tb_peer=%0d (W66=%0d)",
                     w_stat_winstall_cap, exp_winstall_cap_cyc,
                     exp_winstall_cyc - exp_winstall_cap_cyc, w_stat_winstall);
            $display("W69 dut=%08h tb=%08h", w_win_at_winstall, exp_win_at_winstall);
            if (w_stat_winstall_cap !== exp_winstall_cap_cyc) begin tot_red = tot_red + 1;
                $display("[FAIL] W67 语义不符 (逐拍复算): dut=%0d tb_cap=%0d",
                         w_stat_winstall_cap, exp_winstall_cap_cyc); end
            // 结构性牙 (设计件 §2.2 点名的**免费**判据): W67 是 W66 的子集 ⇒ 逐窗恒真
            if (w_stat_winstall_cap > w_stat_winstall) begin tot_red = tot_red + 1;
                $display("[FAIL] W67 > W66 (=%0d > %0d) ⇒ 子集关系被破坏 (实现错)",
                         w_stat_winstall_cap, w_stat_winstall); end
            // W69 判据 (定向见证快照): 关窗保持期内"样本归属 = 关窗 conn"的事件后 1 拍,
            //   DUT 与 TB 的锁存值必须逐字相等, 且**非零** (构造上必非零: 窗=1460, 在飞>=1460)。
            $display("W69DIR hits=%0d dut=%08h tb=%08h (末尾值 dut=%08h tb=%08h)",
                     w69_dir_hits, w69_dir_dut, w69_dir_tb,
                     w_win_at_winstall, exp_win_at_winstall);
            if (w69_dir_hits < 1) begin tot_red = tot_red + 1;
                $display("[FAIL] W69 空判据: 关窗保持期内没有\"样本归属=关窗 conn\"的等窗事件"); end
            if (w69_dir_dut === 32'd0) begin tot_red = tot_red + 1;
                $display("[FAIL] W69 空判据: 定向快照读到 0 (构造上不可能)"); end
            if (w69_dir_dut !== w69_dir_tb) begin tot_red = tot_red + 1;
                $display("[FAIL] W69 定向快照不符: dut=%08h tb=%08h", w69_dir_dut, w69_dir_tb); end
            // 次要 (跑完的末尾值; ⚠️ 可能落到 {0,0} 上 ⇒ 这一条比上面弱, 只作显示)
            if (w_win_at_winstall !== exp_win_at_winstall) begin tot_red = tot_red + 1;
                $display("[FAIL] W69 末尾锁存值与复算不符: dut=%08h tb=%08h",
                         w_win_at_winstall, exp_win_at_winstall); end
`ifdef W67_CAP_SMALL
            // 本臂的存在理由 = 让"板帽侧"非空 ⇒ 必须见证它真的被激励 (否则又是空判据)
            if (exp_winstall_cap_cyc < 64) begin tot_red = tot_red + 1;
                $display("[FAIL] W67 空判据 (W67_CAP_SMALL 臂): TB 侧板帽侧拍=%0d < 64",
                         exp_winstall_cap_cyc); end
`endif
`endif
`ifdef ARM_ACKGATE
            // ⭐ r6 (L-A): ack_seen 门专项判据 (见驱动块注)
            $display("ACKGATE block=%0d resume=%0d witness_offer=%0d (expect block=0 resume=0 offer>=100)",
                     e_ag_block, e_ag_resume, ag_wit_sv);
            if (e_ag_block > 0) begin tot_red = tot_red + 1;
                $display("[FAIL] L-A: ack_seen=0 期间仍有帧启动 (=%0d)", e_ag_block); end
            if (e_ag_resume > 0) begin tot_red = tot_red + 1;
                $display("[FAIL] L-A: ack_seen 放回后 600 拍未恢复 (=%0d)", e_ag_resume); end
            if (ag_wit_sv < 100) begin tot_red = tot_red + 1;
                $display("[FAIL] L-A 空判据: 保持窗内供数拍=%0d < 100", ag_wit_sv); end
            if (!ag_seen_sd) begin tot_red = tot_red + 1;
                $display("[FAIL] L-A 空判据: 抽取前从未见帧上线"); end
`endif
            if (fp_n > 0)
                $display("PACE fpc_milli=%0d", (fp_n*1000000)/cyc);
`endif
`ifdef ARM_PERSIST
            // ============ ⭐ P7B-PERSIST 判据组 (设计件 §5.2-Ⅲ: j1..j14) ============
            //   【事实】= 本 TB 的读数与判据式; 【推断】= 见设计件的对应节。
            //   判例形态: 每条判据 = 计数器 + `tot_red+1` + `[FAIL]` 行 (与既有判据同款)。
            $display("PS0 MAXINFLIGHT c0=%0d c1=%0d c2=%0d c3=%0d (BOUND 62948 / RING 65536)",
                     dbg_maxd[0], dbg_maxd[1], dbg_maxd[2], dbg_maxd[3]);
            $display("PS1 fire probe_ep=%0d probe_out=%0d probe_bad=%0d d_ev=%0d",
                     pe_probe_ep, pe_probe_out, pe_probe_bad, pe_d_ev);
            $display("PS2 LAD n=%0d visits dc=%0d d1=%0d d2=%0d gap4=%0d (want %0d/%0d/%0d/%0d) n2=%0d",
                     pe_lad_n, pe_lad_dc, pe_lad_d1, pe_lad_d2, pe_f_gap4_v,
                     TB_RTO_LIM, TB_PS_BASE, TB_T_BASE2 / TB_VISIT, TB_RTO_LIM, pe_lad_n2);
            $display("PS2b LAD cycles t_close=%0d t1=%0d t2=%0d t3=%0d reopen=%0d reclose=%0d gap4=%0d leak1=%0d",
                     pe_lad_close, pe_lad_t0, pe_lad_t1, pe_lad_t2,
                     pe_lad_reopen, pe_lad_reclose, pe_f_reclose_gap, w_leak1);
            $display("PS3 EP probes E2=%0d E3=%0d E4=%0d E5=%0d E6=%0d E7wit=%0d",
                     pe_f_e2_probe, pe_f_e3_probe, pe_f_e4_probe,
                     pe_f_e5_probe, pe_f_e6_probe, pe_f_e7_wit);
            $display("PS4 WIT drain=%0d blocked=%0d rdy=%0d posctrl=%0d coll=%0d e5ok=%0d e6ok=%0d de=%0d rst1=%0d qto=%0d",
                     w_ps_drain, w_ps_blocked, w_ps_rdy, w_ps_posctrl, pe_coll_wit,
                     w_ps_e5ok, w_ps_e6ok, pe_de1 - pe_de0, w_ps_rst1, w_ps_quiet_to);
            $display("PS5 STATE e5=%b e6=%b sn_first=%h sn_last=%h (win %h->%h) dstat=%0d dreq=%0d retxreq=%0d",
                     pe_f_e5_state, pe_f_e6_state, pe_sn_first, pe_sn_last,
                     pe_sndnxt0, pe_sndnxt1,
                     pe_stat1 - pe_stat0, pe_req1 - pe_req0, w_ps_retx_req);
            $display("PS6 BAD ladder=%0d stop=%0d field=%0d side=%0d sndnxt=%0d e2=%0d e3=%0d e4=%0d e5=%0d e6=%0d coll=%0d",
                     e_ps_ladder, e_ps_stop, e_ps_field, e_ps_side, e_ps_sndnxt,
                     e_ps_e2, e_ps_e3, e_ps_e4, e_ps_e5, e_ps_e6, e_ps_coll);
            // ---- j5 (健康态零额外帧): episode 外探询必须为 0 ----
            if (pe_probe_out != 0) begin tot_red = tot_red + 1;
                $display("[FAIL] PS j5: episode 外出现探询 =%0d", pe_probe_out); end
            // 非空判据 (见证): 本臂的 episode 内至少要出现探询 (臂 T 会失败 = 期望)
            // (逐 episode 的"应有探询"由各自的正控/见证判据承担, 这里只兜底)
            if (pe_probe_ep < 2) begin tot_red = tot_red + 1;
                $display("[FAIL] PS 空判据: episode 内探询总数=%0d < 2", pe_probe_ep); end
            if (pe_done != 1'b1) begin tot_red = tot_red + 1;
                $display("[FAIL] PS 空判据: episode 序列未走完 (pe_st=%0d)", pe_st); end
            // ---- j2 (逐字段): 探询帧的 IP 长度/plen/flags/seq/归属 ----
            if (pe_probe_bad > 0) begin tot_red = tot_red + 1;
                e_ps_field = pe_probe_bad;
                $display("[FAIL] PS j2: 探询帧字段/归属不合规 =%0d", pe_probe_bad); end
            // ---- j1 (阶梯): 恰好 3 条 + 间隔 = RTO / PS_BASE / 2·PS_BASE ----
            if (pe_lad_n != 3) begin tot_red = tot_red + 1; e_ps_ladder = e_ps_ladder + 1;
                $display("[FAIL] PS j1: 阶梯窗内探询数=%0d != 3", pe_lad_n); end
            else begin
                // visit 口径 (设计件 §3.1 的 `ps_timer` 单位 = 该连接的扫描访问数)
                if (!in_band(pe_lad_dc, TB_RTO_LIM, 25, 1)) begin
                    tot_red = tot_red + 1; e_ps_ladder = e_ps_ladder + 1;
                    $display("[FAIL] PS j1: 首条探询延迟=%0d visits (want≈%0d; 拍口径 %0d)",
                             pe_lad_dc, TB_RTO_LIM, pe_lad_t0 - pe_lad_close); end
                if (!in_band(pe_lad_d1, TB_PS_BASE, 25, 1)) begin
                    tot_red = tot_red + 1; e_ps_ladder = e_ps_ladder + 1;
                    $display("[FAIL] PS j1: t2-t1=%0d visits (want≈%0d)",
                             pe_lad_d1, TB_PS_BASE); end
                if (!in_band(pe_lad_d2, TB_T_BASE2 / TB_VISIT, 25, 1)) begin
                    tot_red = tot_red + 1; e_ps_ladder = e_ps_ladder + 1;
                    $display("[FAIL] PS j1: t3-t2=%0d visits (want≈%0d)",
                             pe_lad_d2, TB_T_BASE2 / TB_VISIT); end
            end
            // ---- j7 (停条件): 窗重开后 0 新探询 + 再关窗首档退回 RTO_LIM' ----
            if (pe_lad_n2 != 0) begin tot_red = tot_red + 1; e_ps_stop = e_ps_stop + 1;
                $display("[FAIL] PS j7: 窗重开期间新增探询 =%0d (阶梯计数 %0d)",
                         pe_lad_n2, pe_lad_n); end
            if (!in_band(pe_f_gap4_v, TB_RTO_LIM, 40, 2)) begin
                tot_red = tot_red + 1; e_ps_stop = e_ps_stop + 1;
                $display("[FAIL] PS j7: 再关窗后首探询间隔=%0d visits (want≈%0d ⇒ 首档未退回 RTO; 拍口径 %0d)",
                         pe_f_gap4_v, TB_RTO_LIM, pe_f_reclose_gap); end
            // ---- j3/j9 (无序列副作用 / 环安全): snd_nxt 逐位不变 + Δstat_retx ≤ 注入的请求数 ----
            // 口径: **探询序列首/末之间**的 snd_nxt 逐位不变 (关窗边界上正在收的那一帧、
            // 以及 E3 饱和后"补在飞"的合法数据流都会推进 snd_nxt —— 那是窗口外的量,
            // 不是探询的副作用 ⇒ 只判序列内那一段)。窗首末 (pe_sndnxt0/1) 仅作显示。
            if (pe_sn_first !== pe_sn_last) begin
                tot_red = tot_red + 1; e_ps_sndnxt = e_ps_sndnxt + 1;
                $display("[FAIL] PS j3: 探询序列内 conn1 的 snd_nxt 变了: first=%h last=%h (窗首末 %h -> %h)",
                         pe_sn_first, pe_sn_last, pe_sndnxt0, pe_sndnxt1); end
            if ((pe_stat1 - pe_stat0) > (pe_req1 - pe_req0)) begin
                tot_red = tot_red + 1; e_ps_side = e_ps_side + 1;
                $display("[FAIL] PS j9: Δstat_retx=%0d > TB 注入的 retx 请求数=%0d (探询引出会话?)",
                         pe_stat1 - pe_stat0, pe_req1 - pe_req0); end
            // ---- j6 (无在飞不发): 排空 + 关窗 ⇒ 0 ----
            if (pe_f_e2_probe != 0) begin tot_red = tot_red + 1; e_ps_e2 = e_ps_e2 + 1;
                $display("[FAIL] PS j6: 无在飞+窗0 时出现探询 =%0d", pe_f_e2_probe); end
            if (w_ps_drain < 1) begin tot_red = tot_red + 1; e_ps_e2 = e_ps_e2 + 1;
                $display("[FAIL] PS j6 空判据: 排空见证缺失 (drain=0)"); end
            // ---- j8 (打第二把锁): epoch 饱和 (blocked) 后窗 0 仍要 ≥2 条 ----
            if (pe_f_e3_probe < 2) begin tot_red = tot_red + 1; e_ps_e3 = e_ps_e3 + 1;
                $display("[FAIL] PS j8: blocked 后窗内探询=%0d < 2", pe_f_e3_probe); end
            if (w_ps_blocked < 1) begin tot_red = tot_red + 1; e_ps_e3 = e_ps_e3 + 1;
                $display("[FAIL] PS j8 空判据: epoch 未饱和 (blocked 见证=0)"); end
            // ---- j10 (重连清干净): 待发 + cfg_up ⇒ 0; 且同一构造的正控必须能出探询 ----
            if (pe_f_e4_probe != 0) begin tot_red = tot_red + 1; e_ps_e4 = e_ps_e4 + 1;
                $display("[FAIL] PS j10: cfg_up 后仍出现探询 =%0d", pe_f_e4_probe); end
            if (w_ps_rdy < 1) begin tot_red = tot_red + 1; e_ps_e4 = e_ps_e4 + 1;
                $display("[FAIL] PS j10 空判据: 未见暂存落地 (rdy 见证=0)"); end
            if (w_ps_posctrl < 1) begin tot_red = tot_red + 1; e_ps_e4 = e_ps_e4 + 1;
                $display("[FAIL] PS j10 空判据: 正控未出探询 (posctrl=0)"); end
            // ---- j12 (FIN/RST 在飞 ⇒ 0 探询; v3 含 RST 角) ----
            if (pe_f_e5_probe != 0) begin tot_red = tot_red + 1; e_ps_e5 = e_ps_e5 + 1;
                $display("[FAIL] PS j12: FIN 在飞时出现探询 =%0d", pe_f_e5_probe); end
            if (pe_f_e6_probe != 0) begin tot_red = tot_red + 1; e_ps_e6 = e_ps_e6 + 1;
                $display("[FAIL] PS j12: RST 在飞时出现探询 =%0d", pe_f_e6_probe); end
            if ((w_ps_e5ok < 1) || (w_ps_fin < 1)) begin
                tot_red = tot_red + 1; e_ps_e5 = e_ps_e5 + 1;
                $display("[FAIL] PS j12 空判据(E5): 构造条件未同真过 (e5ok=%0d fin_sent=%0d win0拍=%0d inflight=%0d)",
                         w_ps_e5ok, w_ps_fin, w_ps_e5win, pe_f_e5_state[2]); end
            if ((w_ps_e6ok < 1) || (w_ps_rst1 < 1)) begin
                tot_red = tot_red + 1; e_ps_e6 = e_ps_e6 + 1;
                $display("[FAIL] PS j12 空判据(E6): 构造条件未同真过 (e6ok=%0d rst1=%0d win0拍=%0d inflight=%0d)",
                         w_ps_e6ok, w_ps_rst1, w_ps_e6win, pe_f_e6_state[2]); end
            // ---- j13/j14 (多连接相撞; 本刀最重的那条缺陷) ----
            if (e_coll_bad > 0) begin tot_red = tot_red + 1; e_ps_coll = e_ps_coll + 1;
                $display("[FAIL] PS j13: E7 相撞窗内出现跨连接数据帧 =%0d", e_coll_bad); end
            if (pe_f_e7_wit < 1) begin tot_red = tot_red + 1; e_ps_coll = e_ps_coll + 1;
                $display("[FAIL] PS j13 空判据: 相撞条件从未成立 (wit=0)"); end
            if ((pe_de1 - pe_de0) < 1) begin tot_red = tot_red + 1; e_ps_coll = e_ps_coll + 1;
                $display("[FAIL] PS j13 空判据: E7 观察窗内无数据帧 (%0d)", pe_de1 - pe_de0); end
`endif
            if (tot_red == 0) $display("TB_TCP_TX_OVL: OK");
            else              $display("TB_TCP_TX_OVL: FAIL reds=%0d", tot_red);
            $finish;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        #200 rst_n = 1'b1;
    end
    always @(posedge clk) begin
        if (rst_n && (e_replay_stuck > 0)) begin
            $display("  (early exit: replay session stuck)");
            summary_and_exit;
        end
        if (rst_n && (cyc > CY_MAX)) begin
            $display("  (cycle budget %0d reached)", CY_MAX);
            summary_and_exit;
        end
        // ⭐ P7B-PERSIST: 本臂要求 episode 序列**跑完**才允许收尾 (否则"目标帧数已到"
        //   会在 episode 中途把仿真掐掉 ⇒ 判据全空); 非该臂 = 原条件逐字不变。
        if (rst_n && (n_data >= NF_TGT) && (phase == 2'd2)
`ifdef ARM_PERSIST
            && pe_done
`endif
            )
            summary_and_exit;
    end
endmodule
