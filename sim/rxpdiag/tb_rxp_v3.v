`timescale 1ns/1ps
//=============================================================================
// tb_rxp_v3.v — RXP_DIAG v3 帧边界记账的**功能**自检门 (ISSUE_RX_BYTE_CORRUPTION)
//
// 为什么需要这条门 (与相 7 的格式门分工):
//   格式门 (tb_rxp_diag 相 7) 用**常量输入**只证明 22 个字段的**字符布局**;
//   它证明不了"锁存的到底是不是那一拍的记账值"。v3 的字段只在两个事件上写:
//   ① 播放器收下本帧第一拍 (帧首记录 current/prev) ② ds_cap (活值 + 写侧指纹)。
//   本门用**真帧流**把 udp_split 的播放器 (帧级 store-and-forward)、写侧、
//   回卷三条路都跑一遍, 并对**TB 自己的接口侧模型**逐值断言。
//
// 模型从哪来 (关键: 期望值**不取自 DUT 内部**, 否则是自证):
//   · app RX 口每收下一拍 = 播放器弹出一个字 (uf_rd = play_v && tready; 0 长帧
//     的合成拍不弹) ⇒ **TB 的"已收拍数"就是 uf_rptr**:
//       FR = 帧首拍之前的已收拍数;  LR = ds_cap 当拍的已收拍数。
//   · 一帧 = 184 字 (1472B/8) ⇒ FR 按 184 递增, 且 **FR - PR == 184** (读者必须
//     恰走一帧的字数; 0 或 2x ⇒ 跳过/重读一帧 —— 这是 v3 的核心判据之一)。
//   · 写侧指纹: SW/SF 是"**播放器正在播的那一帧**的第一个数据字 / 它写入的槽址",
//     TB 完全知道自己写到线上的是什么 (payc) ⇒ 逐值可断言:
//       SW == 该帧载荷第 0 字 (含 TB 的注入!)    SF == (184 x 帧号) mod 512。
//   · 只对**不变量**用宽松断言 (不依赖写侧进度): FO == FW-FR, 184 <= FO <= 512,
//     FH <= 184, LW >= LR, LO == LW-LR, LW >= FW。
//
// 相位 (每相先复位; 注入做在**线上图案**数组 payc 上 ⇒ tcrs 仍为 1, 即板级的
//   "FCS 盲区"场景: FCS 是对干净载荷算的, 坏值出现在算完之后 —— 这正是本设备
//   要复现的物理处境):
//   P1 干净 4x1472B               ⇒ 无触发: v3 字段全 0, RC=VC=0, ds_v=0
//   P2 帧首字节坏 (板级签名)      ⇒ 帧首/活值/写侧**逐值**断言 + SW==GW 演示
//   P3 帧中字节坏                 ⇒ 帧首记录 != 失配当拍活值 (判别性)
//   P4 帧末字坏                   ⇒ 活值 = 整帧已走完 (LR-FR == 帧字数, 且 != FR)
//   P5 小帧背靠背 + 帧末字坏      ⇒ **滞后 9 拍**的跨帧用例 (v3_fn 可能是下一帧)
//   P6 坏 FCS 帧 (kill 回卷)      ⇒ RC=1 且 **VC=0** (回卷丢弃字数 == 在收帧字数)
//   P7 长度不符帧 (残帧回卷)      ⇒ RC>=1 且 **VC=0**
//   P8 回卷检测器正对照 (缺牙补)  ⇒ 冻 wsnap 造"漏 snap" ⇒ 回卷多吃一帧已提交数据
//                                  ⇒ **RC>=1, VC=1, VX=184, VS=0, VR=184**
//   P9 同拍角落 (缺牙补)          ⇒ 载荷 ≡ 1 (mod 8) 且首失配落在末字节 ⇒
//                                  **ds_cap 与帧首拍同拍**, 记录须整体描述失配那一帧
//   P10 **读侧单独注入** (缺牙补)  ⇒ 只污染 app 收到的字 (写侧 din/wh_word 一字不动),
//                                  失配落在注入帧**第 0 字** ⇒ **SW != GW** 的存在性证明
//   (P8/P9 由独立审查指出: 原 P1-P7 里**没有任何一相**能产生回卷违例或同拍角落,
//    所以 `v3_rb_viol` 与"删掉的同拍 mux"两条通路都从未被激励 —— 变异不红.)
//   (P10 由独立审查指出: 原 P1-P9 里"写侧内容"与"读侧内容"对**该帧首字恒等**
//    —— 注入做在线图案 payc 上, 写进去的就是读出来的 ⇒ `chk(v3_sw == ds_gw)` 在
//    "SW 采写路径" 与 "SW 采读路径" 两种取样下**同样成立** ⇒ 替身假设
//    ("SW 其实采的是读路径的帧首字") 无判别力, 只靠源码追踪排除.)
//
// 运行: sim/rxpdiag/run_tb_rxp_v3.bat (独立目录, 防 xsim.dir 文件锁 — 坑 7)
//=============================================================================
module tb_rxp_v3;

    localparam [31:0] MY_IP    = 32'hC0A86402;   // 192.168.100.2
    localparam [31:0] PEER_IP  = 32'hC00A0001;   // 192.168.100.1
    localparam [15:0] APP_PORT = 16'd9000;
    localparam integer PLEN    = 1472;           // 板级载荷 (184 字)
    localparam integer FW      = PLEN / 8;       // 184 字/帧
    localparam integer NFRM    = 4;              // P1..P4/P6/P7 每相帧数
    localparam integer SMALL   = 64;             // P5 小帧载荷
    localparam integer SWW     = SMALL / 8;      // 8 字/帧
    localparam integer NFRMS   = 6;              // P5 帧数
    localparam integer NB      = 32768;          // 图案数组
    localparam integer PBPL    = 1465;           // P9 载荷字节数 (≡ 1 mod 8 ⇒ 末字 1 字节)
    localparam integer PBW     = (PBPL + 7)/8;   // P9 每帧字数 = 184

    reg clk = 1'b0, rst_n = 1'b0;
    always #4 clk = ~clk;                        // 125 MHz

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

    reg [7:0] pay  [0:NB-1];                     // 干净图案 (期望值来源)
    reg [7:0] payc [0:NB-1];                     // 线上实际 (含注入)
    integer   k;
    reg [63:0] st;
    initial begin
        st = 64'h9E3779B97F4A7C15;
        for (k = 0; k < NB; k = k + 1) begin
            pay[k] = st[31:24];                  // 先取后推进 (与 RTL/peer 同款)
            st = xs_next(st);
        end
    end

    // ---- 64 位整字 (lane0 = 最高字节 = tdata[63:56], 同 RTL 的 byte_at) ----
    function [63:0] w_of;
        input integer base;
        input integer wire_side;                 // 1 = payc, 0 = pay
        begin
            if (wire_side)
                w_of = {payc[base+0], payc[base+1], payc[base+2], payc[base+3],
                        payc[base+4], payc[base+5], payc[base+6], payc[base+7]};
            else
                w_of = {pay[base+0], pay[base+1], pay[base+2], pay[base+3],
                        pay[base+4], pay[base+5], pay[base+6], pay[base+7]};
        end
    endfunction

    //=========================================================================
    // DUT: udp_split (真播放器 + 真回卷) + app_udp_pattern (真校验器 + ds_cap)
    //=========================================================================
    reg  [63:0] s_tdata;  reg [7:0] s_tkeep;  reg s_tvalid;
    wire        s_tready;
    reg         s_tlast, s_tuser, s_tcrs, s_terr;
    wire [63:0] p_tdata;  wire [7:0] p_tkeep; wire p_tvalid;
    wire        p_tlast, p_tuser, p_tcrs, p_terr;
    wire        p_tready = 1'b1;
    wire [63:0] a_tdata;  wire [7:0] a_tkeep; wire a_tvalid; wire a_tlast, a_sof;
    wire [15:0] a_len;    wire [31:0] a_sip;  wire [15:0] a_sport;
    wire        a_tready;                        // ← app_udp_pattern 的校验器

    //=========================================================================
    // P10: **读侧单独注入器** —— SW / GW 分叉的**存在性证明**
    //   注入点 = u_split 内部 `uf_dout[63:0]` (frame_fifo 的**读口**), force 成一个
    //   常数字 p10_ival ⇒ **任何**采自读侧的取样点都拿到这个坏值:
    //     ① app 实际收到的字 (udp_split.v:517 app_rx_tdata = uf_dout[63:0]) = GW 的来源
    //     ② 直接读 uf_dout 的任何替身取样 (含"读到该帧首字那一刻才采"的写法)
    //   而**写侧** (u_uf 的 din = u_m_d 与 wh_word 表)**一字不动** ⇒ SW 应仍是该帧
    //   写进去的干净首字。选 uf_dout 而不是 app 侧连线, 就是为了把"读侧"的**全部**
    //   取样点一次覆盖 (只污染 app 连线会漏掉"直接采 uf_dout"的替身写法)。
    //   ⚠️ 只 force [63:0]: tkeep/tlast (uf_dout[71:64]/[72]) 保持原值 ⇒ 帧几何与握手
    //   全程不变; uf_dout 在 udp_split 内的用法只有 :517-519 与 :547, 全在读侧。
    //   层次名 `u_split.uf_dout` 逐字取自 udp_split.v:279 (工程坑 22)。
    //   窗口 = `p10_done` (app 侧 tlast 计数) == 1, 即**第 2 个被呈现完的帧的整帧**:
    //   窗口起点/终点都在时钟沿上 force/release ⇒ 生效晚于该沿的采样; 帧间必有
    //   ≥1 拍 tvalid=0 (R_PLAY→R_IDLE) ⇒ 窗口第一拍恰是该帧**第 0 字** ⇒ 首失配
    //   必落在第 0 字 lane 0。
    //   注入值是常数字 ⇒ 失配字节数 TB **自算** (逐 lane 与该字干净期望字比, 见
    //   p10_mm_exp) ⇒ 断言里不出现魔数。
    //=========================================================================
    localparam [63:0] P10_MASK = 64'hA55A_5AA5_0FF0_F00F;   // 每 lane 均非 0
    reg  [3:0]  p10_done;
    reg         p10_en, p10_on_r, p10_hit;
    reg  [63:0] p10_ival;
    integer     p10_w, p10_b, p10_mm_exp;
    wire        p10_on = p10_en && (p10_done == 4'd1);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) p10_done <= 4'd0;
        else if (a_tvalid && a_tready && a_tlast) p10_done <= p10_done + 4'd1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) p10_hit <= 1'b0;
        else if (p10_on && a_tvalid && a_tready) p10_hit <= 1'b1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p10_on_r <= 1'b0;
            release u_split.uf_dout[63:0];           // 复位即释放 (防御)
        end else begin
            if (p10_on && !p10_on_r)      force   u_split.uf_dout[63:0] = p10_ival;
            else if (!p10_on && p10_on_r) release u_split.uf_dout[63:0];
            p10_on_r <= p10_on;
        end
    end
    reg  [31:0] cfg_dip;
    wire [31:0] st_app_frames, st_app_bytes, st_app_null, st_drop_crc,
                st_drop_ovf, st_drop_part, st_drop_excl,
                st_hls_frames, st_hls_drop, st_hls_split;
    // v3 观测口 (与 udp_split 的端口同宽: UDP_AW=9 ⇒ 10 位指针)
    wire        ds_cap;
    wire [63:0] v3_sw;
    wire [8:0]  v3_sf;
    wire        v3_sm;
    wire [7:0]  v3_wd;
    wire [9:0]  v3_fr, v3_fw, v3_fo, v3_fh;
    wire [1:0]  v3_fs;
    wire [15:0] v3_fn;
    wire [9:0]  v3_pr, v3_pw, v3_ph;
    wire [9:0]  v3_lr, v3_lw, v3_lo, v3_lh;
    wire [15:0] v3_rc, v3_vc;
    wire [9:0]  v3_vx, v3_vs, v3_vr;
    wire [15:0] v3_vn;

    udp_split #(.EXCL_PORT(16'd8080)) u_split (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .p_axis_tdata(p_tdata), .p_axis_tkeep(p_tkeep), .p_axis_tvalid(p_tvalid),
        .p_axis_tready(p_tready),
        .p_axis_tlast(p_tlast), .p_axis_tuser(p_tuser),
        .p_axis_tcrs(p_tcrs), .p_axis_terr(p_terr),
        .app_rx_tdata(a_tdata), .app_rx_tkeep(a_tkeep), .app_rx_tvalid(a_tvalid),
        .app_rx_tready(a_tready), .app_rx_tlast(a_tlast), .app_rx_sof(a_sof),
        .app_rx_len(a_len), .app_rx_src_ip(a_sip), .app_rx_src_port(a_sport),
        .cfg_dst_ip(cfg_dip), .cfg_multi_en(1'b0),
        .cfg_port0(APP_PORT), .cfg_port1(16'hFFFF),
        .cfg_port2(16'hFFFF), .cfg_port3(16'hFFFF), .cfg_port_any(1'b0),
        .stat_app_frames(st_app_frames), .stat_app_bytes(st_app_bytes),
        .stat_app_null(st_app_null), .stat_drop_crc(st_drop_crc),
        .stat_drop_ovf(st_drop_ovf), .stat_drop_part(st_drop_part),
        .stat_drop_excl(st_drop_excl), .stat_hls_frames(st_hls_frames),
        .stat_hls_drop(st_hls_drop), .stat_hls_split(st_hls_split),
        .ds_cap(ds_cap),
        .v3_sw(v3_sw), .v3_sf(v3_sf), .v3_sm(v3_sm), .v3_wd(v3_wd),
        .v3_fr(v3_fr), .v3_fw(v3_fw), .v3_fo(v3_fo), .v3_fh(v3_fh),
        .v3_fs(v3_fs), .v3_fn(v3_fn),
        .v3_pr(v3_pr), .v3_pw(v3_pw), .v3_ph(v3_ph),
        .v3_lr(v3_lr), .v3_lw(v3_lw), .v3_lo(v3_lo), .v3_lh(v3_lh),
        .v3_rc(v3_rc), .v3_vc(v3_vc),
        .v3_vx(v3_vx), .v3_vs(v3_vs), .v3_vr(v3_vr), .v3_vn(v3_vn)
    );

    wire [31:0] ds_idx, ds_b1, ds_b2, ds_bg, ds_dup;
    wire [7:0]  ds_got, ds_exp, ds_prev;
    wire        ds_v;
    wire [63:0] ds_gw, ds_ew;
    wire [31:0] ds_oz, ds_ol, ds_om, ds_oh;
    wire [31:0] a_rx_bytes, a_rx_frames, a_rx_null, a_mismatch;

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0)) u_app (
        .clk(clk), .rst_n(rst_n),
        .i_en(1'b1), .i_tx_ready(1'b0), .i_paylen(12'd1472),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b0), .m_tlast(),
        .rx_tdata(a_tdata), .rx_tkeep(a_tkeep), .rx_tvalid(a_tvalid),
        .rx_tready(a_tready), .rx_tlast(a_tlast), .rx_sof(a_sof), .rx_len(a_len),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_rx_bytes(a_rx_bytes),
        .stat_rx_frames(a_rx_frames), .stat_rx_null(a_rx_null),
        .stat_mismatch(a_mismatch), .active(), .done(), .led(),
        .ds_idx(ds_idx),
        .ds_b1(ds_b1), .ds_b2(ds_b2), .ds_bg(ds_bg), .ds_dup(ds_dup),
        .ds_got(ds_got), .ds_exp(ds_exp), .ds_prev(ds_prev), .ds_v(ds_v),
        .ds_gw(ds_gw), .ds_ew(ds_ew),
        .ds_oz(ds_oz), .ds_ol(ds_ol), .ds_om(ds_om), .ds_oh(ds_oh),
        .ds_cap(ds_cap)
    );

    //=========================================================================
    // TB 接口侧模型 (真值源 = app RX 口的握手 + 已知帧几何)
    //=========================================================================
    integer m_pop;          // 已弹出字数 = DUT 的 uf_rptr
    integer m_fs_cnt;       // 已发生帧首次数
    integer m_fs_rptr;      // 最近一次帧首时的 rptr
    integer m_fs_idx;       // 最近一次帧首的帧号
    integer m_fs_rptr_p;    // 上一次帧首时的 rptr
    integer m_beat;         // 本帧已收拍数
    integer m_done;         // 已收完的帧数
    integer m_null_seen;    // 见过的 0 长帧数 (本门不用, 只作断言防御)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_pop <= 0; m_fs_cnt <= 0; m_fs_rptr <= 0; m_fs_idx <= 0;
            m_fs_rptr_p <= 0; m_beat <= 0; m_done <= 0; m_null_seen <= 0;
        end else if (a_tvalid && a_tready) begin
            if (a_sof) begin
                m_fs_rptr_p <= m_fs_rptr;
                m_fs_rptr   <= m_pop;            // 本帧首字所在槽
                m_fs_idx    <= m_fs_cnt;
                m_fs_cnt    <= m_fs_cnt + 1;
                m_beat      <= 1;               // 含帧首这一拍
                if (a_len == 16'd0) m_null_seen <= m_null_seen + 1;
            end else begin
                m_beat <= m_beat + 1;
            end
            if (a_len != 16'd0) m_pop <= m_pop + 1;   // 0 长帧的合成拍不弹
            if (a_tlast)        m_done <= m_done + 1;
        end
    end

    // ds_cap 当拍的模型快照 (与 DUT 锁存同拍, 同沿采样)
    reg        c_seen;
    reg        c_fe;          // ds_cap 当拍**同时**是帧首事件 (v3_fs_evt) ⇒ 同拍角落
    integer    c_pop, c_beat, c_fsidx, c_fsrptr, c_fsrptr_p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) c_seen <= 1'b0;
        else if (ds_cap) begin
            c_seen <= 1'b1;
            // 角落标志直接取 DUT 自己的 v3_fs_evt 线 (与它更新帧首记录的条件同一根线),
            // 不用 TB 复算 —— 否则"角落是否命中"变成模型自证。
            c_fe <= u_split.v3_fs_evt;
            c_pop <= m_pop; c_beat <= m_beat; c_fsidx <= m_fs_idx;
            c_fsrptr <= m_fs_rptr; c_fsrptr_p <= m_fs_rptr_p;
        end
    end


    // 帧首全记录 (给 P5 的跨帧用例算"失配属于哪一帧")
    integer fh_cnt;
    integer fh_rptr [0:63];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fh_cnt <= 0;
        else if (a_tvalid && a_tready && a_sof && fh_cnt < 64) begin
            fh_rptr[fh_cnt] <= m_pop;
            fh_cnt <= fh_cnt + 1;
        end
    end

    //=========================================================================
    // 激励: 构造 classify-slow 字流 (帧头与 tb_udp_split 同款)
    //=========================================================================
    localparam integer SN = 8192;
    reg [76:0] stim [0:SN-1];
    integer    sp;

    reg [7:0]  fb [0:2047];
    integer    flen;

    task fb_put(input [7:0] b); begin fb[flen] = b; flen = flen + 1; end endtask
    task fb_put16(input [15:0] v); begin
        fb[flen] = v[15:8]; fb[flen+1] = v[7:0]; flen = flen + 2; end endtask
    task fb_put32(input [31:0] v); begin
        fb[flen]=v[31:24]; fb[flen+1]=v[23:16]; fb[flen+2]=v[15:8]; fb[flen+3]=v[7:0];
        flen = flen + 4; end endtask

    integer h_i; reg [19:0] h_sum; reg [16:0] h_f1; reg [15:0] h_ck;
    task mk_hdr(input integer iplen);
        begin
            flen = 0;
            fb_put32(32'h000A3501); fb_put16(16'hFEC0);     // dst mac
            fb_put32(32'h11223344); fb_put16(16'h5566);     // src mac
            fb_put16(16'h0800);                             // ethertype IPv4
            fb_put(8'h45); fb_put(8'h00);                   // ver/ihl, dscp
            fb_put16(iplen[15:0]); fb_put16(16'h1234); fb_put16(16'h4000);
            fb_put(8'd64); fb_put(8'h11);                   // ttl, UDP
            fb_put16(16'h0000);                             // ip csum 占位 (14..33)
            fb_put32(PEER_IP); fb_put32(MY_IP);
            h_sum = 20'd0;
            for (h_i = 0; h_i < 10; h_i = h_i + 1)
                h_sum = h_sum + {4'b0, fb[14+2*h_i], fb[15+2*h_i]};
            h_f1 = h_sum[15:0] + {12'b0, h_sum[19:16]};
            h_ck = ~(h_f1[15:0] + {15'b0, h_f1[16]});
            fb[24] = h_ck[15:8]; fb[25] = h_ck[7:0];
        end
    endtask

    integer u_i; reg [15:0] u_len;
    // base = 该帧载荷在图案流里的起点; plen = 载荷字节数; bad_udplen: 声明 > 实际
    task mk_udp_frame(input integer base, input integer plen, input integer bad_udplen);
        begin
            mk_hdr(plen + 28);
            fb_put16(16'h3039);            // sport
            fb_put16(APP_PORT);            // dport (匹配 cfg_port0)
            u_len = plen + 8;
            if (bad_udplen) u_len = plen + 58;
            fb_put16(u_len); fb_put16(16'h0000);
            for (u_i = 0; u_i < plen; u_i = u_i + 1) fb_put(payc[base + u_i]);
        end
    endtask

    integer e_w, e_b, e_nw, e_nb;
    reg [63:0] e_d;  reg [7:0] e_k;
    task emit_frame(input integer crc_ok, input integer gap);
        begin
            e_nw = (flen + 7) / 8;
            for (e_w = 0; e_w < e_nw; e_w = e_w + 1) begin
                e_nb = flen - e_w*8;  if (e_nb > 8) e_nb = 8;
                e_d = 64'd0;  e_k = 8'hFF << (8 - e_nb);
                for (e_b = 0; e_b < e_nb; e_b = e_b + 1)
                    e_d[63 - 8*e_b -: 8] = fb[e_w*8 + e_b];
                stim[sp] = {1'b1, e_d, e_k, (e_w == e_nw-1), (e_w == 0),
                            (((e_w == e_nw-1) && (crc_ok != 0)) ? 1'b1 : 1'b0), 1'b0};
                sp = sp + 1;
            end
            for (e_w = 0; e_w < gap; e_w = e_w + 1) begin stim[sp] = 77'd0; sp = sp + 1; end
        end
    endtask

    integer r_i;
    task run_stim(input integer a, input integer b);
        begin
            for (r_i = a; r_i < b; r_i = r_i + 1) begin
                @(posedge clk);
                s_tvalid <= stim[r_i][76];
                s_tdata  <= stim[r_i][75:12];
                s_tkeep  <= stim[r_i][11:4];
                s_tlast  <= stim[r_i][3];
                s_tuser  <= stim[r_i][2];
                s_tcrs   <= stim[r_i][1];
                s_terr   <= stim[r_i][0];
            end
        end
    endtask

    task idle_drive(input integer n);
        begin
            for (r_i = 0; r_i < n; r_i = r_i + 1) begin
                @(posedge clk);
                s_tvalid <= 1'b0; s_tdata <= 64'd0; s_tkeep <= 8'd0;
                s_tlast <= 1'b0;  s_tuser <= 1'b0; s_tcrs <= 1'b0; s_terr <= 1'b0;
            end
        end
    endtask

    // 有界等待 ds_cap (不给死锁留机会: 坏帧不会被交付, 用"等交付数"会挂死)
    integer wt_i;
    task wait_cap(input integer maxc);
        begin
            for (wt_i = 0; wt_i < maxc; wt_i = wt_i + 1) begin
                if (c_seen) wt_i = maxc; else @(posedge clk);
            end
        end
    endtask
    // 喂一帧后的定拍间隔: 读者每 8 拍吐 1 字 ⇒ 一帧 184 字 ≈ 1472 拍 ⇒ 1800 拍
    // 足以让该帧走完 (占用因此恒在 1 帧量级, 不会撞 512 字满)。
    task pace(input integer n);
        begin
            idle_drive(n);
        end
    endtask

    //=========================================================================
    // P8 用: 读侧"已弹完 N 字"的界内等待 (不给死锁留机会)
    //=========================================================================
    integer wp_i;
    task wait_pop(input integer n, input integer maxc);
        begin
            for (wp_i = 0; wp_i < maxc; wp_i = wp_i + 1) begin
                if (m_pop >= n) wp_i = maxc; else @(posedge clk);
            end
        end
    endtask

    //=========================================================================
    // P8 用: 冻结/解冻 frame_fifo 的 wsnap + 仪器影子 v3_wsnap_r
    //   目的 = 屏蔽下一帧的 snap (漏 snap 缺陷的等效物)。取值在**时钟沿之间**
    //   (negedge) 读/施加, 避免与 DUT 的同沿非阻塞赋值竞争。
    //   层次名与 udp_split.v 里逐字一致 (u_uf = frame_fifo 例化名; 坑 22)。
    //=========================================================================
    integer frz_wsnap, frz_shadow;
    task freeze_wsnap;
        begin
            @(negedge clk);
            frz_wsnap  = u_split.u_uf.wsnap;
            frz_shadow = u_split.v3_wsnap_r;
            force u_split.u_uf.wsnap = frz_wsnap[9:0];
            force u_split.v3_wsnap_r = frz_shadow[9:0];
        end
    endtask
    task unfreeze_wsnap;
        begin
            @(negedge clk);
            release u_split.u_uf.wsnap;
            release u_split.v3_wsnap_r;
        end
    endtask

    // 绝不反压观测 (TB 若灌得比读者排空更快, 会破坏 udp_split 的"结构性不反压"前提)
    integer stall_cyc;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) stall_cyc <= 0;
        else if (!s_tready) stall_cyc <= stall_cyc + 1;

    integer fail = 0;
    // ⚠️ 必须用 `!==` 判 X: 用 `if (!cond)` 时 X 会走 else 分支 ⇒ **X 被当成通过**
    //    (变异 M4 "写侧采集打死" 实测: v3_sw 变成 xxxxxxxxxxxxxxxx 而门仍报 OK)。
    task chk(input cond, input [255:0] name);
        begin
            if (cond !== 1'b1) begin
                fail = fail + 1;
                $display("  FAIL: %0s", name);
            end
        end
    endtask

    task do_reset;
        begin
            @(negedge clk); rst_n = 1'b0;
            repeat (20) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
        end
    endtask

    //=========================================================================
    // 判据: ds_cap 快照 vs 接口侧模型
    //   kind=0: 帧首/活值/写侧全套 (需 frw = 该帧的"写侧帧号")
    //   frw   : 期望的写侧帧号 (= 播放器正在播的那一帧; 由调用者定, 见各相注释)
    //   prevw : 该帧之前的帧长 (字), 用于 FR-PR 的期望
    //=========================================================================
    integer exp_frw, exp_prevw;
    integer wbase;
    integer plen_p;      // 本相载荷字节数 (P1-P4/P6/P7 = 1472, P5 = 64)
    integer wfw_p;       // 本相每帧字数 (= 写侧定址/帧长判据的单位)
    task chk_cap(input [255:0] nm);
        begin
            $display("  [%0s] fn=%0d fr=%0d fw=%0d fo=%0d fh=%0d fs=%0d pr=%0d pw=%0d ph=%0d",
                     nm, v3_fn, v3_fr, v3_fw, v3_fo, v3_fh, v3_fs, v3_pr, v3_pw, v3_ph);
            $display("  [%0s] lr=%0d lw=%0d lo=%0d lh=%0d sw=%016X sf=%03X sm=%0d wd=%0d rc=%0d vc=%0d",
                     nm, v3_lr, v3_lw, v3_lo, v3_lh, v3_sw, v3_sf, v3_sm, v3_wd,
                     v3_rc, v3_vc);
            // ---- 模型值 (接口侧) ----
            chk(c_seen, "ds_cap 从未发生 (快照门未被触发)");
            chk(v3_fn == c_fsidx[15:0], "FN != 模型帧号");
            chk(v3_fr == c_fsrptr[9:0], "FR != 帧首拍 uf_rptr");
            chk(v3_pr == c_fsrptr_p[9:0], "PR != 上一帧帧首 uf_rptr");
            chk(v3_lr == c_pop[9:0],    "LR != ds_cap 当拍 uf_rptr");
            chk((v3_lr - v3_fr) == c_beat[9:0], "LR-FR != 帧首以来已收拍数");
            chk((v3_fr - v3_pr) == exp_prevw[9:0], "FR-PR != 上一帧字数 (读者跳过/重读?)");
            chk(v3_fs == 2'd1, "FS != 1 (非空帧的帧首必须处于 R_PLAY)");
            // ---- 行内恒等式 ----
            chk(v3_fo == (v3_fw - v3_fr), "FO != FW-FR");
            chk(v3_lo == (v3_lw - v3_lr), "LO != LW-LR");
            chk(v3_fo <= 10'd512, "FO > 512 (缓冲越界)");
            chk(v3_fo >= wfw_p[9:0], "FO < 本帧字数 (该帧已提交, 写指针该已越过它)");
            chk(v3_fw >= v3_fr, "FW < FR");
            chk(v3_lw >= v3_lr, "LW < LR");
            chk(v3_lw >= v3_fw, "LW < FW (写指针回退, 本相无回卷)");
            // ---- 写侧指纹 ----
            wbase = exp_frw * plen_p;
            chk(v3_sm == 1'b1, "SM != 1 (写侧表项未命中; 表项过期?)");
            chk(v3_wd >= 8'd1 && v3_wd <= 8'd7, "WD 不在 1..7 (写-读帧差异常)");
            // SF = 该帧首字写入的**环槽号** = (帧序 x 每帧**字**数) mod 512。用 wfw_p
            // (每帧字数) 而不是 plen_p/8: 两者在载荷长度为 8 的整数倍时逐位相同
            // (既有各相 P2-P5 不变), 而 P9 的 1465 字节帧末字只含 1 字节 ⇒ 必须按字数算。
            chk(v3_sf == ((exp_frw * wfw_p) % 512), "SF != (帧序 x 每帧字数) mod 512");
            chk(v3_sw == w_of(wbase, 1), "SW != 该帧实测写入的首字 (线上图案)");
            $display("  [%0s] SW==GW? %0d   SW==EW? %0d",
                     nm, (v3_sw == ds_gw), (v3_sw == ds_ew));
        end
    endtask

    // 不变量断言 (任何相位后都该成立)
    task chk_inv(input [255:0] nm);
        begin
            chk(v3_fo == (v3_fw - v3_fr), "FO != FW-FR");
            chk(v3_fo <= 10'd512, "FO > 512 (缓冲越界)");
            chk(v3_fh <= 184, "FH > 一帧字数");
            chk(v3_lo == (v3_lw - v3_lr), "LO != LW-LR");
        end
    endtask

    //=========================================================================
    // 相位
    //=========================================================================
    integer fi, base_i, inj_i;
    integer wn;                                  // 该相每帧字数
    integer nc;                                  // 该相帧数

    task load_frames(input integer n, input integer plen, input integer gap,
                     input integer badcrc_idx, input integer badlen_idx);
        begin
            sp = 0;
            for (fi = 0; fi < n; fi = fi + 1) begin
                base_i = fi * plen;
                mk_udp_frame(base_i, plen, (fi == badlen_idx) ? 1 : 0);
                emit_frame((fi == badcrc_idx) ? 0 : 1, gap);
            end
        end
    endtask

    initial begin
        s_tvalid = 1'b0; s_tdata = 64'd0; s_tkeep = 8'd0;
        s_tlast = 1'b0; s_tuser = 1'b0; s_tcrs = 1'b0; s_terr = 1'b0;
        cfg_dip = MY_IP;
        sp = 0; fail = 0;
        p10_en = 1'b0;                               // P10 读侧注入器 (只在本相打开)

        //---------------------------------------------------------------------
        // P1: 干净 4 x 1472B, 帧间留空隙 (逐帧喂 + 等交付 ⇒ 占用 ~1 帧, 不溢出)
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        plen_p = PLEN; wfw_p = FW;
        for (fi = 0; fi < NFRM; fi = fi + 1) begin
            wn = fi*PLEN; sp = 0;                     // payload BYTE base (not words!)
            mk_udp_frame(wn, PLEN, 0);
            emit_frame(1, 4);
            run_stim(0, sp); pace(1800);                 // 喂一帧 + 等它被读完
        end
        pace(200);
        $display("RXPV3 P1 mm=%0d ds_v=%b seen=%b rc=%0d vc=%0d | cap: fn=%0d fr=%0d lr=%0d sw=%016X",
                 a_mismatch, ds_v, c_seen, v3_rc, v3_vc, v3_fn, v3_fr, v3_lr, v3_sw);
        chk(a_mismatch == 0, "P1 干净流出现失配");
        chk(ds_v == 1'b0, "P1 无失配却有 ds_v");
        chk(c_seen == 1'b0, "P1 无失配却触发了 v3 快照 (假触发!)");
        chk(v3_fn == 0 && v3_fr == 0 && v3_lr == 0 && v3_sw == 0, "P1 v3 字段非 0");
        chk(v3_rc == 0 && v3_vc == 0, "P1 无回卷却 RC/VC != 0");
        chk(a_rx_frames == NFRM, "P1 交付帧数不符");
        chk(m_pop == NFRM*FW, "P1 模型弹字数不符");

        //---------------------------------------------------------------------
        // P2: **帧首字节坏** (板级签名 §13) —— 帧 2 的载荷第 0 字节
        //     期望: 快照落在帧 2 的帧首; 写侧首字 == 收到的坏字 (SW==GW)
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        payc[2*PLEN + 0] = pay[2*PLEN + 0] ^ 8'h40;          // 帧 2 载荷 byte 0 (lane 0)
        plen_p = PLEN; wfw_p = FW;
        for (fi = 0; fi < NFRM; fi = fi + 1) begin
            wn = fi*PLEN; sp = 0;                     // payload BYTE base (not words!)
            mk_udp_frame(wn, PLEN, 0);
            emit_frame(1, 4);
            run_stim(0, sp); pace(1800);
        end
        wait_cap(2000);
        $display("RXPV3 P2 mm=%0d idx=%0d got=%02X exp=%02X | gw=%016X ew=%016X",
                 a_mismatch, ds_idx, ds_got, ds_exp, ds_gw, ds_ew);
        chk(a_mismatch == 1, "P2 失配字节数 != 1");
        chk(ds_idx == (2*PLEN), "P2 II != 帧2载荷首字节的全局收到字节号");
        chk(ds_got == (pay[2*PLEN] ^ 8'h40) && ds_exp == pay[2*PLEN], "P2 GG/EE 不符");
        exp_frw = 2; exp_prevw = FW;
        chk_cap("P2");
        // 板级判读演示: 写进去的就是坏字 (上游"FCS 盲区"型) vs 写进去是干净字
        chk(v3_sw == ds_gw, "P2 写侧首字 != 收到的坏字 (SW 与 GW 应相同)");
        chk(v3_sw != ds_ew, "P2 写侧首字 == 期望字 (与注入矛盾)");
        chk_inv("P2");

        //---------------------------------------------------------------------
        // P3: 帧**中**字节坏 (帧 1 字 50 lane 3) ⇒ 帧首记录 != 失配当拍活值
        //     判别性: 若把 ds_cap 触发接到帧首/打错拍, LR-FR 立刻不对
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        inj_i = 1*PLEN + 50*8 + 3;                       // 帧 1 字 50 lane 3 (字节基址)
        payc[inj_i] = pay[inj_i] ^ 8'h02;
        plen_p = PLEN; wfw_p = FW;
        for (fi = 0; fi < NFRM; fi = fi + 1) begin
            wn = fi*PLEN; sp = 0;                     // payload BYTE base (not words!)
            mk_udp_frame(wn, PLEN, 0);
            emit_frame(1, 4);
            run_stim(0, sp); pace(1800);
        end
        wait_cap(2000);
        $display("RXPV3 P3 mm=%0d idx=%0d (帧内 word=%0d lane=%0d)",
                 a_mismatch, ds_idx, (ds_idx/8) % FW, ds_idx % 8);
        chk(a_mismatch == 1, "P3 失配字节数 != 1");
        chk(ds_idx == inj_i, "P3 II != 注入点的全局收到字节号");
        exp_frw = 1; exp_prevw = FW;
        chk_cap("P3");
        // 帧首记录与活值必须**不同** (否则说明快照锁的是帧首那一拍)
        chk(v3_lr != v3_fr, "P3 活值 == 帧首记录 (触发拍可疑!)");
        chk((v3_lr - v3_fr) == c_beat[9:0], "P3 LR-FR != 模型拍数");
        chk_inv("P3");

        //---------------------------------------------------------------------
        // P4: 帧**末字**坏 (帧 2 字 183 lane 0) ⇒ 活值恰在整帧走完处
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        inj_i = 2*PLEN + 183*8 + 0;                      // 帧 2 末字 lane 0 (字节基址)
        payc[inj_i] = payc[inj_i] ^ 8'h80;
        plen_p = PLEN; wfw_p = FW;
        for (fi = 0; fi < NFRM; fi = fi + 1) begin
            wn = fi*PLEN; sp = 0;                     // payload BYTE base (not words!)
            mk_udp_frame(wn, PLEN, 0);
            emit_frame(1, 4);
            run_stim(0, sp); pace(1800);
        end
        wait_cap(2000);
        $display("RXPV3 P4 mm=%0d idx=%0d (帧内 word=%0d lane=%0d)",
                 a_mismatch, ds_idx, (ds_idx/8) % FW, ds_idx % 8);
        chk(a_mismatch == 1, "P4 失配字节数 != 1");
        exp_frw = 2; exp_prevw = FW;
        chk_cap("P4");
        chk((v3_lr - v3_fr) == FW[9:0], "P4 帧末字失配时 LR-FR != 一帧字数");
        chk_inv("P4");

        //---------------------------------------------------------------------
        // P5: 小帧 (64B = 8 字) **背靠背** + 帧末字坏
        //     目的: 触发"1 字前瞻 + 逐字节比对"的 9 拍滞后跨帧用例 —— 快照可能
        //     落(a)失配所属帧 (LR 已到帧尾) 或 (b) 下一帧帧首 (v3_fn = 失配帧+1)。
        //     两者都按**模型**判: 模型自己会算出"最近一次帧首"是哪一个。
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        plen_p = SMALL; wfw_p = SWW;
        inj_i = 3*SMALL + 7*8 + 0;                       // 帧 3 末字 lane0 (字节基址)                          // 帧 3 的末字 lane0
        payc[inj_i] = payc[inj_i] ^ 8'h08;
        sp = 0;
        for (fi = 0; fi < NFRMS; fi = fi + 1) begin
            mk_udp_frame(fi*SMALL, SMALL, 0);
            emit_frame(1, 1);                             // 1 拍空隙 (近背靠背)
        end
        run_stim(0, sp); pace(3000); wait_cap(2000); pace(200);
        $display("RXPV3 P5 mm=%0d idx=%0d (帧 %0d 内 word=%0d lane=%0d) | 失配帧号 %0d",
                 a_mismatch, ds_idx, ds_idx/SMALL, (ds_idx/8) % SWW, ds_idx % 8,
                 ds_idx/SMALL);
        chk(a_mismatch == 1, "P5 失配字节数 != 1");
        exp_frw = c_fsidx; exp_prevw = SWW;               // 跨帧用例: 写侧帧号 = 观测帧号
        chk_cap("P5");
        chk(v3_fn == (ds_idx/SMALL) || v3_fn == (ds_idx/SMALL) + 1,
            "P5 FN 既不是失配所属帧也不是其后一帧 (滞后模型之外)");
        chk_inv("P5");

        //---------------------------------------------------------------------
        // P6: 坏 FCS 帧 (kill 回卷) ⇒ RC 计数, 且**不得**出现一致性违例
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        plen_p = PLEN; wfw_p = FW;
        for (fi = 0; fi < NFRM; fi = fi + 1) begin
            wn = fi*PLEN; sp = 0;                     // payload BYTE base (not words!)
            mk_udp_frame(wn, PLEN, 0);
            emit_frame((fi == 1) ? 0 : 1, 4);             // 帧 1 坏 FCS
            run_stim(0, sp); pace(1800);
        end
        pace(400);
        // 注: 坏 FCS 帧被丢 ⇒ 线上图案流在 app 眼里**不再连续** ⇒ mm > 0 是预期的
        // (本相只判回卷一致性, 不判图案连续性)。
        $display("RXPV3 P6 rc=%0d vc=%0d drop_crc=%0d frames=%0d mm=%0d (mm>0 预期: 丢帧后图案流断)",
                 v3_rc, v3_vc, st_drop_crc, a_rx_frames, a_mismatch);
        chk(st_drop_crc == 32'd1, "P6 坏 FCS 帧未整帧丢弃");
        chk(v3_rc >= 16'd1, "P6 回卷未发生 (RC=0)");
        chk(v3_vc == 16'd0, "P6 回卷一致性违例 (丢弃字数 != 在收帧字数)");
        chk(a_rx_frames == NFRM - 1, "P6 交付帧数不符 (坏帧不该交付)");
        chk_inv("P6");

        //---------------------------------------------------------------------
        // P7: 长度不符帧 (残帧回卷: 无 TLAST ⇒ 下一帧 meta_valid 拍回卷)
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        plen_p = PLEN; wfw_p = FW;
        for (fi = 0; fi < NFRM; fi = fi + 1) begin
            wn = fi*PLEN; sp = 0;
            mk_udp_frame(wn, PLEN, (fi == 1) ? 1 : 0);    // 帧 1 声明 > 实际
            emit_frame(1, 4);
            run_stim(0, sp); pace(1800);
        end
        pace(400);
        $display("RXPV3 P7 rc=%0d vc=%0d drop_part=%0d frames=%0d mm=%0d (mm>0 预期)",
                 v3_rc, v3_vc, st_drop_part, a_rx_frames, a_mismatch);
        chk(st_drop_part >= 32'd1, "P7 残帧未回卷 (stat_drop_part=0)");
        chk(v3_rc >= 16'd1, "P7 回卷未发生 (RC=0)");
        chk(v3_vc == 16'd0, "P7 回卷一致性违例");
        chk_inv("P7");

        //---------------------------------------------------------------------
        // P8 (a): **回卷一致性检测器的正对照** —— 造一次"漏 snap"
        //
        // 手法 (审查给的配方): 在坏 FCS 帧的 meta_valid **之前**, 把
        //   `u_split.u_uf.wsnap` (真回卷边界) 与 `u_split.v3_wsnap_r` (仪器影子)
        //   一起冻在当前值 = **上一帧的起点** ⇒ 本帧的 snap 被屏蔽 (漏 snap 的等效物)
        //   ⇒ 坏帧回卷时丢弃的字数 = 本帧 + 上一帧 = 2x184, 而 hold_rem 只有 184
        //   ⇒ 回卷**吃掉了整整一帧已提交数据**。
        // 两处都必须冻: wsnap 决定**真实行为** (wptr 真的回卷到上一帧起点),
        //   v3_wsnap_r 决定**检测器读数**; 只冻一处就只测了影子/只测了真值, 不算数。
        //
        // 期望 (审查在同一手法下实测到的数): RC >= 1, VC = 1, VX = 184,
        //   VS = 0 (= 冻结值 = 帧 0 起点), VR = 184 (= 读者正落在被吃区间内).
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        plen_p = PLEN; wfw_p = FW;
        // 帧 0 (好) —— 让读者把它读完 (rptr = 184, 成为"被吃的已提交数据")
        sp = 0; mk_udp_frame(0, PLEN, 0); emit_frame(1, 4);
        run_stim(0, sp); pace(1900); wait_pop(FW, 4000);
        chk(m_pop == FW, "P8 reader did not drain f0");
        // 帧 1 (坏 FCS) —— 前 5 字先驱动, 再冻 wsnap, 然后驱动其余字
        //   (meta_valid = 帧第 6 字 w5 被接受拍 ⇒ 冻结恒在它之前)
        sp = 0; mk_udp_frame(PLEN, PLEN, 0); emit_frame(0, 4);
        run_stim(0, 5);
        freeze_wsnap;
        run_stim(5, sp);
        pace(2000);
        $display("RXPV3 P8 rc=%0d vc=%0d vx=%0d vs=%0d vr=%0d vn=%0d | 冻结值=%0d 影子=%0d wptr=%0d rptr=%0d",
                 v3_rc, v3_vc, v3_vx, v3_vs, v3_vr, v3_vn,
                 frz_wsnap, frz_shadow, u_split.uf_wptr, u_split.uf_rptr);
        chk(frz_shadow == 0, "P8 freeze value != 0");
        chk(v3_rc >= 16'd1, "P8 RC == 0 (no rollback)");
        chk(v3_vc == 16'd1, "P8 VC != 1 (violation missed)");
        chk(v3_vx == FW[9:0], "P8 VX != 184 (frames eaten)");
        chk(v3_vs == 10'd0, "P8 VS != 0 (frozen wsnap)");
        chk(v3_vr == FW[9:0], "P8 VR != 184 (reader pos)");
        chk(v3_vr > v3_vs, "P8 VR <= VS (not in eaten range)");
        // 真实数据路径的旁证: 回卷**真的**落在冻结的边界上 (wptr 回到 0, 而读者还在 184)
        chk(u_split.uf_wptr == 10'd0, "P8 real wptr != 0 (force missed DUT?)");
        chk(u_split.uf_rptr == FW[9:0], "P8 real rptr != 184");
        unfreeze_wsnap;
        pace(300);

        //---------------------------------------------------------------------
        // P9 (b): **ds_cap 与帧首事件同拍**的角落
        //
        // 为什么必须有这一相: 独立审查证明"把同拍 mux 加回 v3_fn"这类自相矛盾
        //   变异**不会**让原门变红 ⇒ 说明这个角落从来没被激励到。删掉同拍 mux 之后,
        //   同拍时记录必须**整体**描述"失配字所属那一帧"(更新前的记录)。
        //
        // 几何 (由本门用探针**实测标定**): app 的逐字节比对是**连续**的
        //   (1 字节/拍) ⇒ 以 S_k = 帧 k 首个比对拍, W = 每帧字数, n_w = 字 w 的字节数:
        //     ds_cap(帧 k 的字 w) = S_k + 8w + (n_w - 1)   (该字**最后**一个字节的比对拍)
        //     fe(帧 k+1 首拍)     = S_k + 8(W-1)           (nx 在末字比对**起**拍释放)
        //   两者相等 ⟺ n_last == 1 ⇒ **载荷长度 ≡ 1 (mod 8)**。
        //   载荷是 8 的整数倍时两式恒差 7 (mod 8) ⇒ 结构上**永不**同拍。
        //   ⚠️ 审查给的配方是"帧内 ~178..181 字" (按 ds_cap = 收下+9 估的相位) ——
        //   探针实测稳态下 ds_cap = 该字**末字节比对拍** (= 收下 + 9 只在"装载不排队"
        //   那一拍成立), 所以那个窗口在本 TB 的激励下**打不中** (帧内字距 8 拍、
        //   而需要的偏移差 7 拍, 相位差 (mod 8) 与帧无关)。⇒ 换成下面这个**等价
        //   可打中**的几何: plen = 1465 (末字恰 1 字节) + 首失配落在**帧 1 的最后一
        //   个载荷字节**上 ⇒ ds_cap 与帧 2 的帧首拍同拍 (探针实测 dcap_fe = 0 逐拍确认).
        //
        // 断言: (1) 角落**确实**命中 (c_fe, 取 DUT 自己的 v3_fs_evt 线);
        //       (2) 全套记录都描述**失配那一帧** (chk_cap 的模型断言 + 帧号/首字);
        //       (3) 判别性: FN 必须 != 下一帧, SW 必须 != 下一帧的首字。
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        plen_p = PBPL; wfw_p = PBW;
        inj_i = PBPL + (PBPL - 1);            // 帧 1 的**最后一个载荷字节** (全局字节 2929)
        payc[inj_i] = payc[inj_i] ^ 8'h01;    // lane0 (末字只 1 字节)
        sp = 0;
        mk_udp_frame(0,        PBPL, 0); emit_frame(1, 0);
        mk_udp_frame(PBPL,     PBPL, 0); emit_frame(1, 0);
        run_stim(0, sp);
        pace(600);                            // 帧 2 在读者抵达帧 1 末尾**之前**已提交
        sp = 0;
        mk_udp_frame(2*PBPL,   PBPL, 0); emit_frame(1, 0);
        run_stim(0, sp);
        pace(2400);
        wait_cap(2000);
        $display("RXPV3 P9 mm=%0d idx=%0d (帧内 byte=%0d word=%0d lane=%0d) 同拍=%0d",
                 a_mismatch, ds_idx, ds_idx % PBPL, (ds_idx % PBPL)/8,
                 (ds_idx % PBPL) % 8, c_fe);
        // 注: 断言名一律用**短 ASCII** —— chk 的名字走 [255:0] 向量口, 超过 32 字节
        //     会被截断且多字节汉字会被切碎 (实测输出乱码); 数值证据看上面的 $display
        //     与 chk_cap 的 ASCII 字段转储.
        chk(a_mismatch == 1, "P9 mismatch bytes != 1");
        chk(c_seen, "P9 ds_cap never happened");
        // (1) 角落确实命中 —— 这一条就是"本相有没有牙"的守卫: 若某次重构让同拍
        //     不再可达, 本相报 FAIL, 而不是换个姿势继续"绿灯"。
        chk(c_fe == 1'b1, "P9 corner NOT hit (same cycle)");
        exp_frw = ds_idx / PBPL;              // 失配所属帧 = 1
        exp_prevw = PBW;                       // 每帧字数 = 184
        chk(exp_frw == 1, "P9 mismatch frame != 1");
        // (2) 全套模型断言: FN/FR/PR/LR/LO/LW/FS/SM/SF/SW 全部按"更新前的记录"判
        chk_cap("P9");
        // (2b) **不依赖 TB 模型**的独立几何期望 (防"模型与 DUT 一起错"):
        //   读者每帧恰走 184 字 ⇒ 失配帧的帧首 rptr = 1x184 = 184, 上一帧 = 0.
        //   同拍取新帧的旧行为会把 FR 变成 2x184 = 368 ⇒ 这两条也会红。
        chk(v3_fr == ((exp_frw * PBW) % 1024), "P9 FR != frame idx x 184");
        chk(v3_pr == (((exp_frw - 1) * PBW) % 1024), "P9 PR != prev frame start");
        // (3) 判别性 (专抓"同拍取新帧"的旧行为): FN 必须是失配帧的帧号, 不得是下一帧;
        //     SW 必须是失配帧的首个载荷字, 不得是下一帧的首字。
        chk(v3_fn == exp_frw[15:0], "P9 FN != mismatch frame idx");
        chk(v3_fn != (exp_frw + 1), "P9 FN == next frame idx !");
        chk(v3_sw == w_of(exp_frw * PBPL, 1), "P9 SW != mismatch frame W0");
        chk(v3_sw != w_of((exp_frw + 1) * PBPL, 1), "P9 SW == next frame W0 !");
        // 帧首记录 vs 活值: 同拍时 FR 是失配帧的帧首, LR 是失配帧**已走完**的读数
        chk((v3_lr - v3_fr) == PBW[9:0], "P9 LR-FR != 184");
        chk_inv("P9");

        //---------------------------------------------------------------------
        // P10 (缺牙补): **读侧单独注入** —— `SW != GW` 的**存在性证明**
        //
        // 要补的缺口 (独立审查逐行核对源码后指出, 且原门无任何相位覆盖):
        //   原 P1-P9 的注入一律做在**线图案 payc** 上 (即"写进去的就是读出来的"),
        //   所以对任意一帧, "写侧内容" 与 "读侧内容" **恒等** ⇒ `chk(v3_sw == ds_gw)`
        //   在 "SW 采写路径" 与 "SW 采读路径" 两种取样下**同样成立** ⇒ 那个最像的
        //   替身假设 ("SW 其实采的是读路径的帧首字") 在门里**没有判别力**。
        //
        // 本相: 注入点 = **u_split.uf_dout[63:0]** (frame_fifo 的读口, force 成常数字),
        //   窗口 = 第 2 个被呈现完的帧的整帧 ⇒ 只动**读侧** (app 收到的字 + 任何直接
        //   采读口的替身写法, 一次全覆盖); u_uf 的 din (= u_m_d) 与写侧 wh_word 表
        //   **一字不动**。
        // 断言: ① GW == 注入的坏值   ② SW == 该帧写侧干净首字 (且 == EW)
        //       ③ **SW != GW** ← 核心: 两个字段可以不同 ⇒ 取样路径独立。
        // 判别性: 若某次重构让 SW 改从读路径取样, 本相必红 (SW 会带上注入的坏值);
        //   反之, 原 P2 那种"线上注入"的相位对这条**无感** —— 那正是本相要补的牙。
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];   // 线上图案全干净
        plen_p = PLEN; wfw_p = FW;
        p10_ival = w_of(1*PLEN, 0) ^ P10_MASK;         // 注入字 = 该帧干净首字 ^ 掩码
        p10_en   = 1'b1;                               // 打开注入器 (窗口由 tlast 计数给)
        for (fi = 0; fi < NFRM; fi = fi + 1) begin
            wn = fi*PLEN; sp = 0;
            mk_udp_frame(wn, PLEN, 0);
            emit_frame(1, 4);
            run_stim(0, sp); pace(1800);
        end
        wait_cap(2000);
        p10_en = 1'b0;                                 // 关掉注入器 (后续无相位)
        // 自算失配字节数: 读口被钉成常数字 ⇒ 该帧 184 字的每一 lane 与该字干净期望字比
        p10_mm_exp = 0;
        for (p10_w = 0; p10_w < FW; p10_w = p10_w + 1)
            for (p10_b = 0; p10_b < 8; p10_b = p10_b + 1)
                if (p10_ival[63 - 8*p10_b -: 8] !== pay[1*PLEN + 8*p10_w + p10_b])
                    p10_mm_exp = p10_mm_exp + 1;
        $display("RXPV3 P10 mm=%0d (自算 %0d) idx=%0d (帧 %0d 内 word=%0d lane=%0d) 注入窗口命中=%0d",
                 a_mismatch, p10_mm_exp, ds_idx, ds_idx/PLEN, (ds_idx % PLEN)/8,
                 (ds_idx % PLEN) % 8, p10_hit);
        $display("RXPV3 P10 gw=%016X (期望 = 干净 %016X ^ 掩码 %016X = force 值 %016X)",
                 ds_gw, w_of(1*PLEN, 0), P10_MASK, p10_ival);
        $display("RXPV3 P10 注入帧坏值=%016X 该帧干净期望字(EW)=%016X | SW(写侧首字)=%016X SW==GW? %0d SW==EW? %0d",
                 p10_ival, ds_ew, v3_sw, (v3_sw == ds_gw), (v3_sw == ds_ew));
        chk(p10_hit == 1'b1, "P10 inject window never hit a beat");
        chk(p10_ival !== w_of(1*PLEN, 1), "P10 injected word == clean word (mask no-op!)");
        chk(a_mismatch == p10_mm_exp, "P10 mm != self-computed mismatch count");
        chk(ds_idx == 1*PLEN, "P10 II != injected frame payload byte 0");
        // ① 读侧确实收到坏值 (逐位 = force 进去的字)
        chk(ds_gw == p10_ival, "P10 GW != injected bad word");
        chk(ds_ew == w_of(1*PLEN,0), "P10 EW != clean expected word");
        exp_frw = 1; exp_prevw = FW;
        chk_cap("P10");                                // 含 "SW == 写侧首字" 全套模型
        // ② 写侧没被污染: SW 仍等于该帧**干净**首字 (即 EW)
        chk(v3_sw == w_of(1*PLEN, 1), "P10 SW != clean written first word");
        chk(v3_sw == ds_ew, "P10 SW != EW (write side polluted)");
        // ③ ★ 核心: 两个字段**可以**不同 ⇒ SW 的取样路径独立于读路径 (存在性证明)
        chk(v3_sw != ds_gw, "P10 SW == GW (read path not isolated!)");
        chk_inv("P10");

        chk(stall_cyc == 0, "s_axis_tready 曾为 0 (TB 灌得太猛, 违反不反压铁律)");
        if (fail == 0) $display("RXP-V3 GATE: OK");
        else           $display("RXP-V3 GATE: FAIL (%0d)", fail);
        $finish;
    end

    // 看门狗
    initial begin
        repeat (2000000) @(posedge clk);
        $display("RXP-V3 GATE: FAIL (timeout) pop=%0d done=%0d", m_pop, m_done);
        $finish;
    end
endmodule
