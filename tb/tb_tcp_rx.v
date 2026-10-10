`timescale 1ns/1ps
// tcp_rx 全链 TB: mac_rx_64 -> tcp_rx + tcb。
// GMII 字节流时钟化非阻塞驱动 (stim_data/dv/er.memh, 与 tb_udp_rx 同约定);
// 配置阶段 (前 40 拍): CAM 3 条 + TCB 2 条 × 6 字段 (cfg_tcb.memh 拍序写入, 慢路径口)。
// 捕获: m_axis 接受词 + META + FEND + ACK 请求 + 末尾 STATS/STATM/TCBF (TCB 终态)。
// 背压 (plusarg): 无 / STALL (3 高 1 低) / HARD (字节窗 [hw[0], hw[1]) 硬停)。
// P4b-7-P6 定向段: 基流末插 conn0 基线重配 + 4 帧 [推进 + 重复纯 ACK 突发], 帧
// 间 fend 落 upd_gnt 抢占窗 [D_HOLD0, D_HOLD1) 内 (真实 TX 优先仲裁的 gnt-hold);
// 收尾自检: rcv_nxt=0x44C / snd_una=0x1770 / snd_wnd=0x4000 (旧 drain 实现丢推进)。
module tb_tcp_rx;

    // ======== ⭐ P7B-SNDWND-GUARD 两臂 (`-d SNDWND_LEGACY` 选遗留臂) ========
    //   FIXED  (默认) : DUT SNDWND_GUARD=1 —— 腿 A 期望绿 (陈旧/越界 ACK 不覆盖窗)
    //   LEGACY (-d)   : DUT SNDWND_GUARD=0 —— 腿 A **期望红** (缺陷复现 = 腿 C
    //                   的机器证明), 腿 B 两臂都必须绿 (守卫没打死零窗恢复)
    //   ⚠️ 期望红的表达 = 专标记 `SNDWND LEGA XFAIL-REPRODUCED` (不是把判据放宽;
    //      先例 sim/p5e_udp 的 neglearn"期望 exit 1")
`ifdef SNDWND_LEGACY
    localparam SNDWND_ARM = 1'b0;
`else
    localparam SNDWND_ARM = 1'b1;
`endif

    reg        clk, rst_n;
    reg [7:0]  rx_d;
    reg        rx_dv, rx_er;
    reg [7:0]  stim_d [0:65535];
    reg [7:0]  stim_v [0:65535];
    reg [7:0]  stim_e [0:65535];
    integer    nstim;
    reg [16:0] i;
    reg [31:0] sc;
    reg        tready, hardstall;
    reg        done;
    reg [31:0] hw [0:1];
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
    reg        gnt_hold;   // P4b-7-P6 定向段: 模拟真实仲裁 TX 占写口 (upd_gnt 长挂起)

    // ---- ⭐ P7B-SNDWND-GUARD 三腿快照机制 -------------------------------------
    //   字节位置由 tools/gen_stim_tcp_rx.py 写入 sw_legs.memh (与激励同源 ⇒
    //   不会与帧表漂移; 格式 9 值, 见生成器 sw_legs.memh):
    //     [0] SW_CFG2  = 腿相位前的全 6 字段基线重配窗口起点 (6 字节)
    //     [1] SW_ZERO  = B1 前置的 snd_wnd=0 单字节慢路径写点
    //     [2] SNAP_DIR = 定向段终态快照点 (drain 已完成)
    //     [3] SNAP_A0  = 腿 A 前 (重配后基线)  [4] SNAP_A1 = A1 后
    //     [5] SNAP_A2  = A2 后               [6] SNAP_Z  = 零窗写后
    //     [7] SNAP_B1  = B1 后               [8] SNAP_B2 = B2 后 (终态)
    //   每点均在"最后一帧字节 +30 字节"之后 ⇒ 该帧 fend/drain 已完成;
    //   腿帧 = 真实 60B 纯 ACK (S_PAD→fend_pad, 取本帧 wnd_l) —— 不用 w6-tlast
    //   短帧 (那里 wnd_f 取上一帧值, 注入的 wnd 到不了 TCB = 假阴性温床)。
    reg [31:0] sw_pos [0:8];
    integer    swi;
    integer    fend_cnt;
    reg [31:0] pass_dir, pass_a0, pass_a1, pass_a2, pass_z, pass_b1, pass_b2;
    integer    fnd_dir, fnd_a0, fnd_a1, fnd_a2, fnd_z, fnd_b1, fnd_b2;
    reg [15:0] wnd_dir, wnd_a0, wnd_a1, wnd_a2, wnd_z, wnd_b1, wnd_b2;
    reg [31:0] una_dir, rcv_dir, una_b2;
    reg        lega_ok, legb1_ok, legb2_ok;

    wire [63:0] s_tdata;
    wire [7:0]  s_tkeep;
    wire        s_tvalid, s_tlast, s_tuser, s_tcrs, s_terr;

    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tlast;
    wire [1:0]  m_tuser;
    wire        meta_valid;
    wire        fend, ferr;
    wire [31:0] meta_src_ip;
    wire [15:0] meta_src_port, meta_len;
    wire [3:0]  meta_conn_id;
    wire [31:0] meta_seq;
    wire [3:0]  ra_id;
    wire [31:0] ra_rcv_nxt, ra_snd_nxt, ra_snd_una;
    wire [15:0] ra_rcv_wnd;
    wire [3:0]  ra_state;
    wire [3:0]  ra_wscale;
    wire        ack_req;
    wire [3:0]  ack_id;
    wire [31:0] ack_val;
    wire [31:0] stat_pass, stat_nonmatch, stat_ipcsum, stat_crc, stat_seq, stat_ack, stat_bytes;
    // ⭐ 构建 F (W68): DUT 的新输出 + **TB 侧独立复算**
    //   ⚠️ 刻意**不引用** DUT 的 `ack_adv_ev` (引用它 = 环路恒等式, 变异体改判据时 oracle 跟着改
    //      ⇒ 永远相等 = 没牙)。这里逐项自写; 用到的 `ack_adv_l`/`fend_trunc` 是 DUT 的**状态线**,
    //      不是它的判据线 —— 与既有 W66 复算引用 `u_dut.svc/ring_eval/...` 同一手法。
    //   ⚠️ 登记过的暴露面: 若有人改 `fend_trunc` 本身, 两边同步改 (该子项不是独立 oracle)。
    wire [31:0] stat_ack_adv;
    integer     exp_ack_adv;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) exp_ack_adv <= 0;
        else if (fend && s_tcrs && u_rx.ack_adv_l && !u_rx.fend_trunc)
            exp_ack_adv <= exp_ack_adv + 1;
    end
    wire [31:0] m_frames, m_crc_err, m_drop, m_bytes;
    wire        u_rx_upd_wr;
    wire [3:0]  u_rx_upd_id;
    wire [2:0]  u_rx_upd_sel;
    wire [31:0] u_rx_upd_val;
    wire        s_ready;
    wire [31:0] cam_q_sip, cam_q_dip;
    wire [15:0] cam_q_sport, cam_q_dport;
    wire        cam_q_hit;
    wire [3:0]  cam_q_id;
    // TCB 更新 mux: 慢路径配置优先; RX 更新受 upd_gnt 门控 (P4b-7-P6: 模拟真实
    // 仲裁器 — TX 占写口时 RX 的 gnt 挂起, 其 upd_wr 组合脉冲也不落到 TCB)
    wire        rx_gnt = !cfg_upd_wr && !gnt_hold;
    wire [2:0]  tcb_sel = cfg_upd_wr ? cfg_upd_sel : u_rx_upd_sel;
    wire [3:0]  tcb_id  = cfg_upd_wr ? cfg_upd_id  : u_rx_upd_id;
    wire [31:0] tcb_val = cfg_upd_wr ? cfg_upd_val : u_rx_upd_val;
    wire        tcb_wr  = cfg_upd_wr || (u_rx_upd_wr && rx_gnt);

    integer     fd;

    // ---- P4b-7-P6 定向段常量 (与 tools/gen_stim_tcp_rx.py 同源; 改动帧表须同步) ----
    // 定向段: 基流末(4225)+空闲 94 字节后连发 4 帧 [推进数据 + 3 重复纯 ACK],
    // 全部 fend 落在 upd_gnt 抢占窗 [D_HOLD0, D_HOLD1) 内 → drain 在拍1挂起,
    // 每帧 fend 重启 drain — 旧实现(每 fend 重锁存)丢推进, sticky 修复保留。
    localparam [31:0] D_CFG2  = 32'd4319;   // 重配 conn0 = TCB0 基线 (6 拍)
    localparam [31:0] D_HOLD0 = 32'd4425;   // gnt 抢占窗 (模拟 TX 优先仲裁)
    localparam [31:0] D_HOLD1 = 32'd4805;
    localparam [31:0] D_RCVX  = 32'h44C;    // 期望终态: rcv_nxt=1100
    localparam [31:0] D_UNAX  = 32'h1770;   //            snd_una=6000

    mac_rx_64 u_mac (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(s_tdata), .m_axis_tkeep(s_tkeep), .m_axis_tvalid(s_tvalid),
        .m_axis_tready(s_ready), .m_axis_tlast(s_tlast), .m_axis_tuser(s_tuser),
        .m_axis_terr(s_terr), .m_axis_tcrs(s_tcrs),
        .stat_frames(m_frames), .stat_crc_err(m_crc_err),
        .stat_drop(m_drop), .stat_bytes(m_bytes)
    );

    tcp_rx #(
        // ⭐ P7B-SNDWND-GUARD 两臂 (宏选, 见文件头注): 1 = 修后 / 0 = 遗留行为
        .SNDWND_GUARD   (SNDWND_ARM)
    ) u_rx (
        .clk(clk), .rst_n(rst_n),
        // P5d H-fix: ACC_MARGIN 由参数改为端口。默认构建显式传 0 ⇒
        // acc_wnd = {1'b0,ra_rcv_wnd} ⇒ 与旧参数版逐位等价 (C12: 参数→端口必须补全)
        .ACC_MARGIN     (16'd0),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_ready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .cfg_suppress_data_ack(1'b0),   // 单元 TB 覆盖未抑制路径
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .fend(fend), .ferr(ferr),
        .meta_valid(meta_valid), .meta_src_ip(meta_src_ip), .meta_src_port(meta_src_port),
        .meta_len(meta_len), .meta_conn_id(meta_conn_id), .meta_seq(meta_seq),
        .ra_id(ra_id),
        .ra_rcv_nxt(ra_rcv_nxt), .ra_snd_nxt(ra_snd_nxt), .ra_snd_una(ra_snd_una),
        .ra_rcv_wnd(ra_rcv_wnd), .ra_state(ra_state), .ra_wscale(ra_wscale),
        .ra_retx_hi(32'd0), .ra_retx_active(1'b0),
        .upd_wr(u_rx_upd_wr), .upd_id(u_rx_upd_id), .upd_sel(u_rx_upd_sel), .upd_val(u_rx_upd_val),
        .upd_gnt(rx_gnt),
        .ack_req(ack_req), .ack_id(ack_id), .ack_val(ack_val),
        .cam_q_sip(cam_q_sip), .cam_q_dip(cam_q_dip),
        .cam_q_sport(cam_q_sport), .cam_q_dport(cam_q_dport),
        .cam_q_hit(cam_q_hit), .cam_q_id(cam_q_id),
        .stat_pass(stat_pass), .stat_drop_nonmatch(stat_nonmatch),
        .stat_drop_ipcsum(stat_ipcsum), .stat_drop_crc(stat_crc),
        .stat_drop_seq(stat_seq), .stat_ack(stat_ack), .stat_bytes(stat_bytes),
        // ⭐ P7B 构建 F: W68 (`stat_ack_adv` = 推进 snd_una 的 ACK 事件数; 纯观测)
        .stat_ack_adv(stat_ack_adv)
    );

    tcp_cam u_cam (
        .clk(clk), .rst_n(rst_n),
        .cfg_wr(cfg_wr), .cfg_addr(cfg_addr),
        .cfg_sip(cfg_sip), .cfg_dip(cfg_dip),
        .cfg_sport(cfg_sport), .cfg_dport(cfg_dport), .cfg_dmac(cfg_dmac),
        .q_sip(cam_q_sip), .q_dip(cam_q_dip),
        .q_sport(cam_q_sport), .q_dport(cam_q_dport),
        .q_id(cam_q_id), .q_hit(cam_q_hit),
        .rd_id(4'd0), .rd_dmac(), .rd_dip(), .rd_sport(), .rd_dport()
    );

    tcb u_tcb (
        .clk(clk), .rst_n(rst_n),
        .ra_id(ra_id), .ra_rcv_nxt(ra_rcv_nxt), .ra_snd_nxt(ra_snd_nxt),
        .ra_snd_una(ra_snd_una), .ra_rcv_wnd(ra_rcv_wnd), .ra_snd_wnd(),
        .ra_state(ra_state), .ra_wscale(ra_wscale),
        .rb_id(4'd0), .rb_rcv_nxt(), .rb_snd_nxt(), .rb_snd_una(),
        .rb_rcv_wnd(), .rb_snd_wnd(), .rb_state(),
        .win_id(4'b0), .win_open(), .win_inflight(), .win_wnd_eff(),   // 无消费方
        .upd_wr(tcb_wr), .upd_id(tcb_id), .upd_sel(tcb_sel), .upd_val(tcb_val)
    );

    always #4 clk = ~clk;     // 125 MHz

    // ⭐ SNDWND 腿的承重件: "帧被收下 + fend" 计数 (防空判据 —— 若注入帧被静默
    //   丢弃, "窗不变"在两臂同为真 = 腿结构安静退化)。fend_cnt 由本 TB 侧独立
    //   计数 (不引用 DUT 的 stat 线以外的东西)。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fend_cnt <= 0;
        else if (fend) fend_cnt <= fend_cnt + 1;
    end

    // ---- 时钟化激励驱动 + 配置阶段 (非阻塞, 无 TB/DUT 竞争) ----
    always @(posedge clk) begin
        if (!rst_n) begin
            i <= 0; rx_d <= 8'h07; rx_dv <= 0; rx_er <= 0;
            tready <= 1; sc <= 0; done <= 0; cphase <= 0;
            cfg_wr <= 0; cfg_addr <= 0; cfg_sip <= 0; cfg_dip <= 0;
            cfg_sport <= 0; cfg_dport <= 0;
            cfg_dmac <= 48'h112233445566;
            cfg_upd_wr <= 0; cfg_upd_id <= 0; cfg_upd_sel <= 0; cfg_upd_val <= 0;
            gnt_hold <= 0;
        end else begin
            if (cphase < 40) begin
                rx_dv <= 0; rx_er <= 0;
                // CAM 3 条 (拍 2..4)
                cfg_wr <= (cphase >= 2 && cphase <= 4);
                cfg_addr <= cphase - 2;
                case (cphase)
                    6'd2: begin
                        cfg_sip <= 32'h0A000001; cfg_dip <= 32'hC0A86402;
                        cfg_sport <= 16'h3039; cfg_dport <= 16'h1F90;
                    end
                    6'd3: begin
                        cfg_sip <= 32'h0A000001; cfg_dip <= 32'hC0A86402;
                        cfg_sport <= 16'hD431; cfg_dport <= 16'h1F91;
                    end
                    6'd4: begin
                        cfg_sip <= 32'h0A00000F; cfg_dip <= 32'hC0A86402;
                        cfg_sport <= 16'h5000; cfg_dport <= 16'h1F92;
                    end
                    default: ;
                endcase
                // TCB 2 条 × 6 字段 (拍 6..17, 条目 e 字段 f: tcbc[e*6+f])
                cfg_upd_wr <= (cphase >= 6 && cphase <= 17);
                cfg_upd_id  <= (cphase - 6) / 6;
                cfg_upd_sel <= (cphase - 6) % 6;
                cfg_upd_val <= tcbc[cphase - 6];
                cphase <= cphase + 1;
            end else begin
                cfg_wr <= 0;
                if (i < nstim) begin
                    rx_d  <= stim_d[i];
                    rx_dv <= stim_v[i][0];
                    rx_er <= stim_e[i][0];
                    i <= i + 1;
                    // P4b-7-P6 定向段: 字节 [D_CFG2, D_CFG2+6) 经慢路径重写 conn0
                    // = TCB0 基线 6 字段 (基流尾帧 ack_badwin 已把它改坏;
                    // 常量与 gen_stim_tcp_rx.py 同源)
                    if (i >= D_CFG2 && i < D_CFG2 + 6) begin
                        cfg_upd_wr <= 1;
                        cfg_upd_id  <= 4'd0;
                        cfg_upd_sel <= (i - D_CFG2) % 6;
                        cfg_upd_val <= tcbc[i - D_CFG2];
                    end else if (i >= sw_pos[0] && i < sw_pos[0] + 6) begin
                        // ⭐ SNDWND 腿相位前置: 全 6 字段基线重配 conn0 = TCB0
                        //   (snd_una=5000 snd_nxt=6000 ⇒ 可接受区间 [5000,6000];
                        //    F3: 腿 B2 的 ack=snd_una+0x100 只有在此区间内才有判别力
                        //    —— 定向段结束时 snd_una=snd_nxt=6000, 不重配则 B2 必假红)
                        cfg_upd_wr <= 1;
                        cfg_upd_id  <= 4'd0;
                        cfg_upd_sel <= (i - sw_pos[0]) % 6;
                        cfg_upd_val <= tcbc[i - sw_pos[0]];
                    end else if (i == sw_pos[1]) begin
                        // ⭐ 腿 B1 前置: 慢路径单字节写 conn0 snd_wnd = 0
                        //   (零窗现场; B1 的零推进 ACK 必须把窗重开成 0x4000)
                        cfg_upd_wr <= 1;
                        cfg_upd_id  <= 4'd0;
                        cfg_upd_sel <= 3'd4;
                        cfg_upd_val <= 32'h0;
                    end else begin
                        cfg_upd_wr <= 0;
                    end
                    // upd_gnt 抢占窗 [D_HOLD0, D_HOLD1): 4 个定向帧的 fend
                    // 全部落窗内 → drain 挂起, 重复纯 ACK 的 fend 打到未完成的
                    // 推进 (板上 TX 优先仲裁的 gnt-hold 复现)
                    gnt_hold <= (i >= D_HOLD0 && i < D_HOLD1);
                    // ---- ⭐ SNDWND 三腿快照 (位置来自 sw_legs.memh; 每点在最后一帧
                    //      字节 +30 之后 ⇒ 该帧 fend/drain 已完成; 采样为 posedge
                    //      非阻塞 ⇒ 取该时刻已落盘值) ----
                    if (i == sw_pos[2]) begin
                        pass_dir <= stat_pass; fnd_dir <= fend_cnt;
                        wnd_dir <= u_tcb.snd_wnd_r[0];
                        una_dir <= u_tcb.snd_una_r[0];
                        rcv_dir <= u_tcb.rcv_nxt_r[0];
                    end
                    if (i == sw_pos[3]) begin
                        pass_a0 <= stat_pass; fnd_a0 <= fend_cnt;
                        wnd_a0  <= u_tcb.snd_wnd_r[0];
                    end
                    if (i == sw_pos[4]) begin
                        pass_a1 <= stat_pass; fnd_a1 <= fend_cnt;
                        wnd_a1  <= u_tcb.snd_wnd_r[0];
                    end
                    if (i == sw_pos[5]) begin
                        pass_a2 <= stat_pass; fnd_a2 <= fend_cnt;
                        wnd_a2  <= u_tcb.snd_wnd_r[0];
                    end
                    if (i == sw_pos[6]) begin
                        pass_z  <= stat_pass; fnd_z  <= fend_cnt;
                        wnd_z   <= u_tcb.snd_wnd_r[0];
                    end
                    if (i == sw_pos[7]) begin
                        pass_b1 <= stat_pass; fnd_b1 <= fend_cnt;
                        wnd_b1  <= u_tcb.snd_wnd_r[0];
                    end
                    if (i == sw_pos[8]) begin
                        pass_b2 <= stat_pass; fnd_b2 <= fend_cnt;
                        wnd_b2  <= u_tcb.snd_wnd_r[0];
                        una_b2  <= u_tcb.snd_una_r[0];
                    end
                end else begin
                    cfg_upd_wr <= 0; gnt_hold <= 0;
                    rx_dv <= 0; rx_er <= 0; done <= 1;
                end
            end
            if (hardstall && i >= hw[0] && i < hw[1]) tready <= 0;
            else if ($test$plusargs("STALL")) begin
                tready <= (sc % 4 == 0) ? 1'b0 : 1'b1;   // 3 高 1 低
                sc <= sc + 1;
            end
            else tready <= 1;
        end
    end

    initial begin
        clk = 0; rst_n = 0; hardstall = 0;
        $readmemh("stim_data.memh", stim_d);
        $readmemh("stim_dv.memh",   stim_v);
        $readmemh("stim_er.memh",   stim_e);
        $readmemh("cfg_tcb.memh",   tcbc);
        nstim = 0;
        while (nstim < 65536 && stim_d[nstim] !== 8'hxx) nstim = nstim + 1;
        if ($test$plusargs("HARD")) begin
            hardstall = 1;
            $readmemh("hardwin.memh", hw);
        end
        // ⭐ SNDWND 三腿位置表 (与激励同源; 先填 0 确保 readmemh 失败时可见:
        //    位置为 0 ⇒ 快照永不触发 ⇒ 腿判据全红 = 响亮失败, 不是静默通过)
        for (swi = 0; swi < 9; swi = swi + 1) sw_pos[swi] = 32'd0;
        $readmemh("sw_legs.memh", sw_pos);
        if (SNDWND_ARM) $display("SNDWND ARM=FIXED (SNDWND_GUARD=1)");
        else            $display("SNDWND ARM=LEGACY (SNDWND_GUARD=0)");
        $display("SNDWND sw_pos cfg2=%0d zero=%0d dir=%0d a0=%0d a1=%0d a2=%0d z=%0d b1=%0d b2=%0d",
                 sw_pos[0], sw_pos[1], sw_pos[2], sw_pos[3], sw_pos[4],
                 sw_pos[5], sw_pos[6], sw_pos[7], sw_pos[8]);
        if ($test$plusargs("STALL")) fd = $fopen("resp_tcp_rx_stall.memh", "w");
        else if ($test$plusargs("HARD")) fd = $fopen("resp_tcp_rx_hard.memh", "w");
        else fd = $fopen("resp_tcp_rx.memh", "w");
        #200; rst_n = 1;
        wait (done == 1);
        repeat (800) @(posedge clk);
        $fwrite(fd, "STATS %0d %0d %0d %0d %0d %0d %0d\n",
                stat_pass, stat_nonmatch, stat_ipcsum, stat_crc, stat_seq, stat_ack, stat_bytes);
        $fwrite(fd, "STATM %0d %0d %0d %0d\n",
                m_frames, m_crc_err, m_drop, m_bytes);
        $fwrite(fd, "TCBF %08h %08h %08h %04h %04h %0d %08h %08h %08h %04h %04h %0d\n",
                u_tcb.rcv_nxt_r[0], u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                u_tcb.rcv_wnd_r[0], u_tcb.snd_wnd_r[0], u_tcb.state_r[0],
                u_tcb.rcv_nxt_r[1], u_tcb.snd_nxt_r[1], u_tcb.snd_una_r[1],
                u_tcb.rcv_wnd_r[1], u_tcb.snd_wnd_r[1], u_tcb.state_r[1]);
        $fclose(fd);
        // ---- P4b-7-P6 定向段自检: 3 重复纯 ACK fend 落在 gnt 抢占窗内时,
        //      推进 (rcv_nxt/snd_una) 与窗口 (snd_wnd) 都必须最终落盘 ----
        // ⚠️ 检查点 = SNAP_DIR 快照 (定向段终态), 不再是"仿真终态" —— 判据值一字
        //    未改 (0x44C / 0x1770 / 0x4000), 只因其后新增了 SNDWND 腿相位 (会再写
        //    snd_una/snd_wnd), 终态已不代表定向段收口。
        if (rcv_dir == D_RCVX && una_dir == D_UNAX && wnd_dir == 16'h4000)
            $display("P4b7 DIRECTED PASS rcv_nxt=%08h snd_una=%08h snd_wnd=%04h",
                     rcv_dir, una_dir, wnd_dir);
        else
            $display("P4b7 DIRECTED FAIL rcv_nxt=%08h (exp 0000044c) snd_una=%08h (exp 00001770) snd_wnd=%04h (exp 4000)",
                     rcv_dir, una_dir, wnd_dir);
        // ================= ⭐ P7B-SNDWND-GUARD 三腿判据 =========================
        //   腿 A (判别): 陈旧/越界 ACK 不得覆盖 snd_wnd。⚠️ 承重件 = "帧被收下 + fend"
        //     的增量断言 (pass/fend +2) —— 否则"窗没变"可能只是"帧没被收下"= 空判据。
        //   腿 B (正对照): B1 = 零推进窗口更新 (零窗重开) / B2 = 推进 + 窗变小。
        //     两臂都必须绿 (守卫不许打死零窗恢复 / 不许误伤"变小照收")。
        //   腿 C = 用 `SNDWND_LEGACY` 编译的遗留臂: 腿 A **期望红** (专标记
        //     XFAIL-REPRODUCED = 缺陷复现的机器证明), 腿 B 仍必须绿。
        //   ⚠️ 判据值域 (与 gen_stim_tcp_rx.py 的帧表同源):
        //     A 基线重配后 snd_wnd=0x2000; A1 陈旧窗=0x0100 / A2 越界窗=0x1100;
        //     B1 窗=0x4000 (零推进 ACK); B2 窗=0x1234 + snd_una 5000→5256 (0x1488;
        //     B2 的 ack = snd_una + 0x100 = 5000+256, 与 gen_stim_tcp_rx.py 同源)
        lega_ok  = (pass_a2 - pass_a0) == 2 && (fnd_a2 - fnd_a0) == 2 &&
                   ((SNDWND_ARM) ? (wnd_a1 == 16'h2000 && wnd_a2 == 16'h2000)
                                 : (wnd_a1 == 16'h0100 && wnd_a2 == 16'h1100));
        legb1_ok = (wnd_z == 16'h0000) && (wnd_b1 == 16'h4000) &&
                   (pass_b1 - pass_z) == 1 && (fnd_b1 - fnd_z) == 1;
        legb2_ok = (wnd_b2 == 16'h1234) && (una_b2 == 32'h00001488) &&
                   (pass_b2 - pass_b1) == 1 && (fnd_b2 - fnd_b1) == 1;
        if (!SNDWND_ARM && lega_ok)
            $display("SNDWND LEGA XFAIL-REPRODUCED wnd1=%04h wnd2=%04h passd=%0d fendd=%0d",
                     wnd_a1, wnd_a2, pass_a2 - pass_a0, fnd_a2 - fnd_a0);
        else if (!lega_ok)
            $display("[FAIL] SNDWND LEGA wnd1=%04h (exp %04h) wnd2=%04h (exp %04h) base=%04h passd=%0d fendd=%0d pass_d2=%0d",
                     wnd_a1, SNDWND_ARM ? 16'h2000 : 16'h0100, wnd_a2,
                     SNDWND_ARM ? 16'h2000 : 16'h1100, wnd_a0,
                     pass_a2 - pass_a0, fnd_a2 - fnd_a0, pass_a2 - pass_a0);
        else
            $display("SNDWND LEGA PASS wnd1=%04h wnd2=%04h base=%04h passd=%0d fendd=%0d",
                     wnd_a1, wnd_a2, wnd_a0, pass_a2 - pass_a0, fnd_a2 - fnd_a0);
        if (legb1_ok)
            $display("SNDWND LEGB1 PASS wnd_zero=%04h wnd=%04h passd=%0d fendd=%0d",
                     wnd_z, wnd_b1, pass_b1 - pass_z, fnd_b1 - fnd_z);
        else
            $display("[FAIL] SNDWND LEGB1 wnd_zero=%04h (exp 0000) wnd=%04h (exp 4000) passd=%0d fendd=%0d",
                     wnd_z, wnd_b1, pass_b1 - pass_z, fnd_b1 - fnd_z);
        if (legb2_ok)
            $display("SNDWND LEGB2 PASS wnd=%04h snd_una=%08h passd=%0d fendd=%0d",
                     wnd_b2, una_b2, pass_b2 - pass_b1, fnd_b2 - fnd_b1);
        else
            $display("[FAIL] SNDWND LEGB2 wnd=%04h (exp 1234) snd_una=%08h (exp 00001488) passd=%0d fendd=%0d",
                     wnd_b2, una_b2, pass_b2 - pass_b1, fnd_b2 - fnd_b1);
        if (SNDWND_ARM) begin
            if (lega_ok && legb1_ok && legb2_ok) $display("SNDWND ALL PASS");
            else $display("[FAIL] SNDWND FIXED arm: legA=%b legB1=%b legB2=%b",
                          lega_ok, legb1_ok, legb2_ok);
        end else begin
            if (lega_ok && legb1_ok && legb2_ok)
                $display("SNDWND LEGACY OK (legA defect reproduced + B1/B2 green + accept deltas ok)");
            else $display("[FAIL] SNDWND LEGACY arm: legA=%b legB1=%b legB2=%b",
                          lega_ok, legb1_ok, legb2_ok);
        end
        // ⭐ 构建 F: W68 判据 (双边等式 + 非空见证; 形状与 tb_tcp_tx_ovl 的 W66/W67 同款)
        //   ⚠️ 本门的整体口径另有既存红 (HARD 臂的 python 期望失配), 与本判据无关;
        //      本判据只保证"dut 与 TB 独立复算逐字相等, 且非空"。
        $display("W68ADV dut=%0d tb=%0d", stat_ack_adv, exp_ack_adv);
        if (exp_ack_adv == 0) $display("[FAIL] W68 空判据 (TB 侧推进 ACK 事件 = 0)");
        if (stat_ack_adv !== exp_ack_adv)
            $display("[FAIL] W68 语义不符 (逐拍复算): dut=%0d tb=%0d", stat_ack_adv, exp_ack_adv);
        $display("DONE pass=%0d nonmatch=%0d ipcsum=%0d crc=%0d seq=%0d ack=%0d bytes=%0d | mac fr=%0d crc=%0d drop=%0d",
                 stat_pass, stat_nonmatch, stat_ipcsum, stat_crc, stat_seq, stat_ack, stat_bytes,
                 m_frames, m_crc_err, m_drop);
        $finish;
    end

    // ---- AXIS 输出 + 元数据 + fend + ACK 捕获 ----
    always @(posedge clk) begin
        if (rst_n && m_tvalid && tready)
            $fwrite(fd, "%016h %02h %d %d %d\n",
                    m_tdata, m_tkeep, m_tlast, m_tuser[0], m_tuser[1]);
        if (rst_n && meta_valid)
            $fwrite(fd, "META %08h %04h %04h %0d %08h\n",
                    meta_src_ip, meta_src_port, meta_len, meta_conn_id, meta_seq);
        if (rst_n && fend)
            $fwrite(fd, "FEND %d\n", ferr);
        if (rst_n && ack_req)
            $fwrite(fd, "ACK %0d %08h\n", ack_id, ack_val);
    end
endmodule
