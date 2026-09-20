`timescale 1ns/1ps
// =====================================================================
// f2chk -- tcp_rx "pcount 跨帧泄漏" 指控的独立定向复核 TB
//   (独立目录 sim/f2chk; 不改 rtl/ 与既有 tb/)
//
// 待复核指控: 短段(304B)紧跟长段(1460B)时, pcount 可能还是上一帧残值 1458,
//   使新段在 tcp_rx.v L753 (pcount + 8 > plen_l) 被误判"帧身超过 IP total_len"
//   -> S_DROP -> 永久 seq 空洞。
//
// 本 TB 的四组判据:
//   A) 健康窗口下 1460B -> 304B -> 148B 连续交付, 逐字节校验 (指控场景本身)
//   B) 用 rcv_wnd=0 (P5b 窗口关闭) 复现对方 TB 的 NOMATCH 现场行, 并打印
//      判定拍 (决策拍) 的 state/wcnt/pcount/plen + rcv_nxt/rcv_wnd -- 证真因
//   C) 段长扫描: 长段后紧跟各种长度 (整除/非整除/边界/极小) 全部交付
//   D) L753 守卫可达性: 只有"帧身 > 声明载荷"的畸形帧才触发, 且签名是
//      prev_wcnt=7 (S_PAY), 与对方日志的 wcnt=6 (S_HDR 头字判定) 互斥
//
// 依赖: rtl/tcp_rx.v + rtl/tcb.v + rtl/tcp_cam.v (例化, 不修改)
// =====================================================================
module tb_f2chk;

    reg         clk, rst_n;
    integer     k;                      // 全局拍计数 (诊断打印用)

    // ---- DUT s_axis (直接驱动 64bit 字流, 不经 mac_rx_64: 精确控制帧长/边界) ----
    reg  [63:0] s_tdata;
    reg  [7:0]  s_tkeep;
    reg         s_tvalid;
    reg         s_tlast, s_tuser, s_tcrs, s_terr;
    wire        s_tready;

    // ---- DUT m_axis sink ----
    reg         m_tready;
    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tlast;
    wire [1:0]  m_tuser;

    wire        fend, ferr, meta_valid, ack_req;
    wire [3:0]  ack_id;
    wire [31:0] ack_val;
    wire [31:0] meta_src_ip;
    wire [15:0] meta_src_port, meta_len;
    wire [3:0]  meta_conn_id;
    wire [31:0] meta_seq;
    wire [31:0] stat_pass, stat_nonmatch, stat_trunc, stat_ipcsum, stat_crc, stat_seq, stat_ack, stat_bytes;
    wire [2:0]  dbg_state;
    wire        dbg_accept, dbg_emitv, dbg_emit_l, dbg_fend;
    wire [15:0] dbg_plen_l, dbg_pcount, dbg_pcount2, dbg_pay_r, dbg_w2_tlen;
    wire [2:0]  dbg_wcnt;
    wire [31:0] dbg_words_in;
    wire [31:0] dbg_dseq, dbg_dcrc, dbg_dnm, dbg_dipc, dbg_dtrunc, dbg_dpass;
    wire        retx_req, syn_v;
    wire [47:0] syn_smac;
    wire [31:0] syn_sip;
    wire [15:0] syn_sport, syn_dport, syn_wnd;
    wire [31:0] syn_seq;

    // ---- TCB / CAM 接线 ----
    wire [3:0]  ra_id;
    wire [31:0] ra_rcv_nxt, ra_snd_nxt, ra_snd_una;
    wire [15:0] ra_rcv_wnd, ra_snd_wnd;
    wire [3:0]  ra_state, ra_wscale;
    wire        u_rx_upd_wr;
    wire [3:0]  u_rx_upd_id;
    wire [2:0]  u_rx_upd_sel;
    wire [31:0] u_rx_upd_val;
    // TB 配置写 (优先级高于 DUT 的 drain 写; 只在帧间空隙写)
    reg         tb_upd_wr;
    reg  [3:0]  tb_upd_id;
    reg  [2:0]  tb_upd_sel;
    reg  [31:0] tb_upd_val;
    wire        rx_gnt   = !tb_upd_wr;                       // 无仲裁: TB 写时不给 DUT 授权
    wire        tcb_wr   = tb_upd_wr || (u_rx_upd_wr && rx_gnt);
    wire [2:0]  tcb_sel  = tb_upd_wr ? tb_upd_sel : u_rx_upd_sel;
    wire [3:0]  tcb_id   = tb_upd_wr ? tb_upd_id  : u_rx_upd_id;
    wire [31:0] tcb_val  = tb_upd_wr ? tb_upd_val : u_rx_upd_val;

    wire [31:0] cam_q_sip, cam_q_dip;
    wire [15:0] cam_q_sport, cam_q_dport;
    wire        cam_q_hit;
    wire [3:0]  cam_q_id;
    reg         cfg_wr;
    reg  [3:0]  cfg_addr;
    reg  [31:0] cfg_sip, cfg_dip;
    reg  [15:0] cfg_sport, cfg_dport;
    reg  [47:0] cfg_dmac;

    // =================================================================
    // DUT
    // =================================================================
    tcp_rx u_rx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .cfg_suppress_data_ack(1'b0),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .fend(fend), .ferr(ferr),
        .meta_valid(meta_valid), .meta_src_ip(meta_src_ip), .meta_src_port(meta_src_port),
        .meta_len(meta_len), .meta_conn_id(meta_conn_id), .meta_seq(meta_seq),
        .ra_id(ra_id),
        .ra_rcv_nxt(ra_rcv_nxt), .ra_snd_nxt(ra_snd_nxt), .ra_snd_una(ra_snd_una),
        .ra_rcv_wnd(ra_rcv_wnd), .ra_state(ra_state), .ra_wscale(ra_wscale),
        .ra_retx_hi(32'd0), .ra_retx_active(1'b0),
        .upd_wr(u_rx_upd_wr), .upd_id(u_rx_upd_id), .upd_sel(u_rx_upd_sel),
        .upd_val(u_rx_upd_val), .upd_gnt(rx_gnt),
        .ack_req(ack_req), .ack_id(ack_id), .ack_val(ack_val),
        .retx_req(retx_req), .retx_id(), .retx_gnt(1'b0),
        .syn_v(syn_v), .syn_smac(syn_smac), .syn_sip(syn_sip), .syn_sport(syn_sport),
        .syn_dport(syn_dport), .syn_seq(syn_seq), .syn_wnd(syn_wnd),
        .cam_q_sip(cam_q_sip), .cam_q_dip(cam_q_dip),
        .cam_q_sport(cam_q_sport), .cam_q_dport(cam_q_dport),
        .cam_q_hit(cam_q_hit), .cam_q_id(cam_q_id),
        .stat_pass(stat_pass), .stat_drop_nonmatch(stat_nonmatch),
        .stat_drop_trunc(stat_trunc), .stat_drop_ipcsum(stat_ipcsum),
        .stat_drop_crc(stat_crc), .stat_drop_seq(stat_seq),
        .stat_ack(stat_ack), .stat_bytes(stat_bytes),
        .dbg_state(dbg_state), .dbg_accept(dbg_accept), .dbg_emitv(dbg_emitv),
        .dbg_plen_l(dbg_plen_l), .dbg_pcount(dbg_pcount), .dbg_w2_tlen(dbg_w2_tlen),
        .dbg_stat_drop_seq(dbg_dseq), .dbg_stat_drop_crc(dbg_dcrc),
        .dbg_stat_drop_nonmatch(dbg_dnm), .dbg_stat_drop_ipcsum(dbg_dipc),
        .dbg_stat_drop_trunc(dbg_dtrunc), .dbg_stat_pass(dbg_dpass),
        .dbg_emit_l(dbg_emit_l), .dbg_pay_r(dbg_pay_r), .dbg_pcount2(dbg_pcount2),
        .dbg_fend(dbg_fend), .dbg_stat_words_in(dbg_words_in), .dbg_wcnt(dbg_wcnt)
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
        .ra_snd_una(ra_snd_una), .ra_rcv_wnd(ra_rcv_wnd), .ra_snd_wnd(ra_snd_wnd),
        .ra_state(ra_state), .ra_wscale(ra_wscale),
        .rb_id(4'd0), .rb_rcv_nxt(), .rb_snd_nxt(), .rb_snd_una(),
        .rb_rcv_wnd(), .rb_snd_wnd(), .rb_state(),
        .win_id(4'b0), .win_open(), .win_inflight(), .win_wnd_eff(),
        .rc_id(4'd0), .rc_rcv_nxt(), .rc_snd_nxt(), .rc_snd_una(),
        .rc_rcv_wnd(), .rc_snd_wnd(), .rc_state(),
        .dbg_snd_nxt0(), .dbg_snd_una0(), .dbg_rcv_nxt0(), .dbg_snd_wnd0(),
        .dbg_wscale0(), .dbg_state0(),
        .upd_wr(tcb_wr), .upd_id(tcb_id), .upd_sel(tcb_sel), .upd_val(tcb_val)
    );

    always #4 clk = ~clk;      // 125 MHz

    initial begin clk = 0; rst_n = 0; end

    always @(posedge clk) if (!rst_n) k <= 0; else k <= k + 1;

    // =================================================================
    // 帧构造 + 发送 (word-aligned 字流, 与 MAC 字流规范一致)
    // =================================================================
    reg [7:0]  fb [0:8191];
    integer    fbody, fwords, ipid;
    // 载荷图案 = f(seq, i): 交付字节可与期望逐字节比对
    function [7:0] payb(input [31:0] sq, input integer i);
        begin payb = (sq[7:0] + i) & 8'hFF; end
    endfunction

    task build_frame(input [31:0] seq, input [31:0] ackv, input [15:0] plen,
                     input [15:0] wnd, input [31:0] ipidv, input integer extra);
        integer i, csum;
        reg [31:0] s;
        begin
            fbody = 54 + plen + extra;
            if ((extra == 0) && (fbody < 60)) fbody = 60;   // 真实以太网最小帧填充
            for (i = 0; i < 8192; i = i + 1) fb[i] = 8'h00;
            // eth (14B): dst/src mac + 0x0800
            fb[0]=8'h02; fb[1]=8'h00; fb[2]=8'h00; fb[3]=8'h00; fb[4]=8'h00; fb[5]=8'h01;
            fb[6]=8'h02; fb[7]=8'h00; fb[8]=8'h00; fb[9]=8'h00; fb[10]=8'h00; fb[11]=8'h02;
            fb[12]=8'h08; fb[13]=8'h00;
            // ip (20B): total_len = 40 + plen (声明值, 与 extra 无关 -> extra>0 = 畸形帧)
            fb[14]=8'h45; fb[15]=8'h00;
            fb[16]=(16'd40 + plen) >> 8; fb[17]=(16'd40 + plen) & 8'hFF;
            fb[18]=ipidv[15:8]; fb[19]=ipidv[7:0];
            fb[20]=8'h40; fb[21]=8'h00;       // DF, MF=0 frag=0
            fb[22]=8'd64; fb[23]=8'h06;       // ttl / proto TCP
            fb[24]=8'h00; fb[25]=8'h00;       // ip csum 占位
            fb[26]=8'h0A; fb[27]=8'h00; fb[28]=8'h00; fb[29]=8'h01;   // 10.0.0.1
            fb[30]=8'hC0; fb[31]=8'hA8; fb[32]=8'h64; fb[33]=8'h02;   // 192.168.100.2
            // tcp (20B)
            fb[34]=8'h30; fb[35]=8'h39;       // sport 0x3039
            fb[36]=8'h1F; fb[37]=8'h90;       // dport 0x1F90
            fb[38]=seq[31:24]; fb[39]=seq[23:16]; fb[40]=seq[15:8]; fb[41]=seq[7:0];
            fb[42]=ackv[31:24]; fb[43]=ackv[23:16]; fb[44]=ackv[15:8]; fb[45]=ackv[7:0];
            fb[46]=8'h50; fb[47]=8'h18;       // doff=5, PSH|ACK
            fb[48]=wnd[15:8]; fb[49]=wnd[7:0];
            fb[50]=8'h00; fb[51]=8'h00; fb[52]=8'h00; fb[53]=8'h00;
            // 载荷 (tcp csum 不查)
            for (i = 0; i < plen; i = i + 1) fb[54+i] = payb(seq, i);
            // ip 头校验和
            s = 0;
            for (i = 0; i < 20; i = i + 2) s = s + {fb[14+i], fb[15+i]};
            while (s[31:16] != 0) s = {16'b0, s[15:0]} + {16'b0, s[31:16]};
            csum = (~s[15:0]) & 16'hFFFF;
            fb[24] = csum[15:8]; fb[25] = csum[7:0];
            fwords = (fbody + 7) / 8;
        end
    endtask

    // 字驱动: 保持 tvalid 直到 accept (s_tready 为组合, 周期内稳定)
    task put_word(input [63:0] d, input [7:0] kk, input l, input u);
        begin
            s_tdata <= d; s_tkeep <= kk; s_tvalid <= 1'b1;
            s_tlast <= l; s_tuser <= u; s_tcrs <= 1'b1; s_terr <= 1'b0;
            @(negedge clk);
            while (!s_tready) begin
                @(posedge clk);
                @(negedge clk);
            end
            @(posedge clk);                 // accept 沿
            s_tvalid <= 1'b0; s_tlast <= 1'b0; s_tuser <= 1'b0;
        end
    endtask

    integer wi, wj, nv;
    reg [63:0] wd;
    task send_frame(input [31:0] seq, input [31:0] ackv, input [15:0] plen,
                    input [15:0] wnd, input integer gap, input integer extra);
        begin
            build_frame(seq, ackv, plen, wnd, ipid, extra);
            ipid = ipid + 1;
            @(posedge clk);
            for (wi = 0; wi < fwords; wi = wi + 1) begin
                wd = 64'h0;
                for (wj = 0; wj < 8; wj = wj + 1)
                    if ((8*wi + wj) < fbody)
                        wd = wd | ({56'b0, fb[8*wi+wj]} << (8*(7-wj)));
                nv = fbody - 8*wi; if (nv > 8) nv = 8;
                put_word(wd, (8'hFF << (8-nv)), (wi == fwords-1), (wi == 0));
            end
            repeat (gap) @(posedge clk);
        end
    endtask

    // 半帧: 只驱动前 nw 个字, 不带 tlast (模拟 mac_rx 中途中止)
    task send_partial(input [31:0] seq, input [31:0] ackv, input [15:0] plen,
                      input [15:0] wnd, input integer nw, input integer gap);
        begin
            build_frame(seq, ackv, plen, wnd, ipid, 0);
            ipid = ipid + 1;
            @(posedge clk);
            for (wi = 0; wi < nw; wi = wi + 1) begin
                wd = 64'h0;
                for (wj = 0; wj < 8; wj = wj + 1)
                    if ((8*wi + wj) < fbody)
                        wd = wd | ({56'b0, fb[8*wi+wj]} << (8*(7-wj)));
                nv = fbody - 8*wi; if (nv > 8) nv = 8;
                put_word(wd, (8'hFF << (8-nv)), 1'b0, (wi == 0));
            end
            repeat (gap) @(posedge clk);
        end
    endtask

    // =================================================================
    // sink: 收集交付载荷字节 (按 tkeep 掩码)
    // =================================================================
    reg [7:0]  cap [0:262143];
    reg [7:0]  expa [0:262143];
    integer    capn, expn, mcap, mexp;
    integer    sj, nvb;
    always @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            nvb = 0;
            for (sj = 0; sj < 8; sj = sj + 1)
                if (m_tkeep[7-sj]) begin
                    cap[capn + nvb] = (m_tdata >> (8*(7-sj))) & 8'hFF;
                    nvb = nvb + 1;
                end
            capn <= capn + nvb;
        end
    end

    reg [31:0] exp_nxt;          // TB 侧独立推演的期望 rcv_nxt
    reg [15:0] sentence_len;
    reg [31:0] nm_b, sq_b;       // case B 基线计数

    task exp_add(input [31:0] sq, input [15:0] plen);
        integer i;
        begin
            for (i = 0; i < plen; i = i + 1) begin
                expa[expn] = payb(sq, i); expn = expn + 1;
            end
        end
    endtask

    task chk(input [8*40:1] name);
        integer i, bad;
        begin
            bad = 0;
            if ((capn - mcap) != (expn - mexp)) begin
                bad = 1;
                $display("  ** %0s LEN MISMATCH: delivered=%0d expected=%0d",
                         name, capn - mcap, expn - mexp);
            end
            for (i = 0; i < (capn - mcap); i = i + 1)
                if ((i < (expn - mexp)) && (cap[mcap+i] !== expa[mexp+i])) begin
                    if (bad < 4)
                        $display("  ** %0s BYTE MISMATCH off=%0d cap=%02h exp=%02h",
                                 name, i, cap[mcap+i], expa[mexp+i]);
                    bad = bad + 1;
                end
            if (bad == 0)
                $display("CASE %0s: PASS  delivered=%0d bytes, rcv_nxt=%08h (exp %08h) wnd=%04h",
                         name, capn - mcap, ra_rcv_nxt, exp_nxt, ra_rcv_wnd);
            else
                $display("CASE %0s: FAIL  delivered=%0d (exp %0d) rcv_nxt=%08h (exp %08h)",
                         name, capn - mcap, expn - mexp, ra_rcv_nxt, exp_nxt);
            mcap = capn; mexp = expn;
            if (ra_rcv_nxt !== exp_nxt)
                $display("  ** rcv_nxt MISMATCH: dut=%08h tb=%08h", ra_rcv_nxt, exp_nxt);
        end
    endtask

    // =================================================================
    // 配置写
    // =================================================================
    task cfg_cam(input [3:0] id, input [31:0] sip, input [31:0] dip,
                 input [15:0] sp, input [15:0] dp);
        begin
            @(posedge clk);
            cfg_wr <= 1'b1; cfg_addr <= id;
            cfg_sip <= sip; cfg_dip <= dip; cfg_sport <= sp; cfg_dport <= dp;
            cfg_dmac <= 48'h020000000002;
            @(posedge clk);
            cfg_wr <= 1'b0;
        end
    endtask

    task cfg_tcb(input [3:0] id, input [2:0] sel, input [31:0] val);
        begin
            @(posedge clk);
            tb_upd_wr <= 1'b1; tb_upd_id <= id; tb_upd_sel <= sel; tb_upd_val <= val;
            @(posedge clk);
            tb_upd_wr <= 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    // =================================================================
    // 诊断探针 (对方 TB 同款打印 + 补齐判定拍与窗口字段)
    // =================================================================
    reg [31:0] nm_d;
    reg [2:0]  st_d, wc_d;
    reg [15:0] pc_d, pl_d;
    reg [7:0]  tk_d;
    reg [63:0] td_d;
    always @(posedge clk) begin
        if (!rst_n) begin
            nm_d <= 0; st_d <= 0; wc_d <= 0; pc_d <= 0; pl_d <= 0; tk_d <= 0; td_d <= 0;
        end else begin
            nm_d <= stat_nonmatch;
            st_d <= dbg_state; wc_d <= dbg_wcnt; pc_d <= dbg_pcount;
            pl_d <= dbg_plen_l; tk_d <= s_tkeep; td_d <= s_tdata;
            // (A) 对方 TB 的 NOMATCH 行 (+1 拍采样) — 复现原样, 补齐关键字段
            if ((stat_nonmatch != nm_d) && (stat_nonmatch != 0))
                $display("NOMATCH k=%0d st=1 wcnt=%0d pcount=%0d plen=%0d fsm=%0d tdata=%016h tkeep=%02h tlast=%0d psnd=%08h  ||判定拍: state=%0d wcnt=%0d pcount=%0d plen=%0d pay_r=%0d || rcv_nxt=%08h rcv_wnd=%04h",
                         k, dbg_wcnt, dbg_pcount, dbg_plen_l, dbg_state, td_d, tk_d, s_tlast,
                         ra_snd_nxt, st_d, wc_d, pc_d, pl_d, pl_d - pc_d,
                         ra_rcv_nxt, ra_rcv_wnd);
            // (B) 进入 S_DROP 的拍: 打印上一拍 (= 判定拍) 的 state/wcnt/pcount/plen
            if ((st_d != dbg_state) && (dbg_state == 3'd3))
                $display("  [DROPENTER] k=%0d 判定拍 state=%0d wcnt=%0d pcount=%0d plen=%0d pay_r=%0d  (→S_DROP)",
                         k, st_d, wc_d, pc_d, pl_d, pl_d - pc_d);
            // (C) 进入 S_PAY 的拍: 打印 pcount 是否被重置
            if ((st_d != dbg_state) && (dbg_state == 3'd1))
                $display("  [PAYENTER ] k=%0d 上一拍 wcnt=%0d  pcount(本拍)=%0d plen=%0d",
                         k, wc_d, dbg_pcount, dbg_plen_l);
        end
    end

    integer ci;

    // =================================================================
    // 主序列
    // =================================================================
    initial begin
        rst_n = 0; m_tready = 1; ipid = 0;
        s_tdata = 0; s_tkeep = 0; s_tvalid = 0; s_tlast = 0; s_tuser = 0;
        s_tcrs = 0; s_terr = 0;
        cfg_wr = 0; cfg_addr = 0; cfg_sip = 0; cfg_dip = 0;
        cfg_sport = 0; cfg_dport = 0; cfg_dmac = 0;
        tb_upd_wr = 0; tb_upd_id = 0; tb_upd_sel = 0; tb_upd_val = 0;
        capn = 0; expn = 0; mcap = 0; mexp = 0; exp_nxt = 32'h1000;

        #200; rst_n = 1;
        repeat (10) @(posedge clk);

        // CAM + TCB 初始配置 (ESTAB, rcv_nxt=0x1000, rcv_wnd=0xC000)
        cfg_cam(4'd0, 32'h0A000001, 32'hC0A86402, 16'h3039, 16'h1F90);
        cfg_tcb(4'd0, 3'd0, 32'h1000);          // rcv_nxt
        cfg_tcb(4'd0, 3'd1, 32'h2000);          // snd_nxt
        cfg_tcb(4'd0, 3'd2, 32'h2000);          // snd_una
        cfg_tcb(4'd0, 3'd3, 32'hC000);          // rcv_wnd (健康)
        cfg_tcb(4'd0, 3'd5, 32'h1);             // state = ESTAB
        cfg_tcb(4'd0, 3'd6, 32'h0);             // wscale = 0
        $display("==== f2chk: pcount 跨帧泄漏指控复核 ====");
        $display("cfg: rcv_nxt=%08h rcv_wnd=%04h state=%0d", ra_rcv_nxt, ra_rcv_wnd, ra_state);

        // ---------------------------------------------------------------
        // A) 指控场景原样: 1460 -> 304 -> 148, 窗口健康
        // ---------------------------------------------------------------
        $display("-- A) 长段(1460) -> 短段(304) -> 148 (rcv_wnd=0xC000) --");
        exp_add(32'h1000, 16'd1460);
        send_frame(32'h1000, 32'h2000, 16'd1460, 16'h4000, 12, 0);
        exp_nxt = 32'h1000 + 1460;
        $display("   after F1(1460): pcount=%0d (残值), rcv_nxt=%08h", dbg_pcount, ra_rcv_nxt);
        exp_add(32'h15B4, 16'd304);
        send_frame(32'h15B4, 32'h2000, 16'd304, 16'h4000, 12, 0);
        exp_nxt = 32'h15B4 + 304;
        $display("   after F2(304):  pcount=%0d, rcv_nxt=%08h", dbg_pcount, ra_rcv_nxt);
        exp_add(32'h16E4, 16'd148);
        send_frame(32'h16E4, 32'h2000, 16'd148, 16'h4000, 12, 0);
        exp_nxt = 32'h16E4 + 148;
        chk("A long1460->short304->148");

        // ---------------------------------------------------------------
        // B) 复现对方 NOMATCH 现场行: 窗口关闭 (rcv_wnd=0) 下的顺序短段
        // ---------------------------------------------------------------
        $display("-- B) 复现 NOMATCH 现场行 (前置 1460 长段 + rcv_wnd=0) --");
        exp_add(32'h1778, 16'd1460);
        send_frame(32'h1778, 32'h2000, 16'd1460, 16'h4000, 16, 0);
        exp_nxt = 32'h1778 + 1460;
        $display("   F4(1460) 后 pcount 残值 = %0d (对方日志里的 1458)", dbg_pcount);
        cfg_tcb(4'd0, 3'd3, 32'h0);            // rcv_wnd = 0 (P5b 窗口关闭)
        nm_b = stat_nonmatch; sq_b = stat_seq;
        $display("   set rcv_wnd=0 -> %04h ; 发 304B 顺序段 (seq=rcv_nxt=%08h) nm0=%0d seq0=%0d",
                 ra_rcv_wnd, exp_nxt, stat_nonmatch, stat_seq);
        send_frame(exp_nxt, 32'h2000, 16'd304, 16'h4000, 12, 0);
        $display("   seq==rcv_nxt 的 304B 段在 wnd=0 下的结果: d_nonmatch=%0d d_seq=%0d",
                 stat_nonmatch, stat_seq);
        if (stat_nonmatch != nm_b) $display("   >>> 判定: 窗口=0 时顺序段被判 NONMATCH (与对方日志同为 nonmatch 计数路)");
        else                      $display("   >>> 判定: 窗口=0 时未走 nonmatch 路 (d_seq=%0d)", stat_seq - sq_b);
        cfg_tcb(4'd0, 3'd3, 32'hC000);         // 窗口重开
        $display("   set rcv_wnd=0xC000 -> %04h ; 同一段 (同一 pcount 残值) 重发",
                 ra_rcv_wnd);
        exp_add(exp_nxt, 16'd304);
        send_frame(exp_nxt, 32'h2000, 16'd304, 16'h4000, 12, 0);
        exp_nxt = exp_nxt + 304;
        chk("B wnd0-reject then wnd-ok-accept");

        // ---------------------------------------------------------------
        // C) 段长扫描: 长段后紧跟各种段长 (整除/非整除/极小/极大)
        // ---------------------------------------------------------------
        $display("-- C) 段长扫描 (每个长度前面都先来一个 1460 长段, 制造 pcount 残值) --");
        // 列表: 每次都长段(1460) + 目标段(L)
        for (ci = 0; ci < 34; ci = ci + 1) begin
            if (ra_rcv_nxt !== exp_nxt) begin
                $display("   !! C 扫描前 rcv_nxt 已偏离 (dut=%08h tb=%08h) - 中止扫描",
                         ra_rcv_nxt, exp_nxt);
                ci = 99;
            end else begin
            case (ci)
              0:  sentence_len = 16'd1460;
              1:  sentence_len = 16'd1;
              2:  sentence_len = 16'd2;
              3:  sentence_len = 16'd3;
              4:  sentence_len = 16'd4;
              5:  sentence_len = 16'd5;
              6:  sentence_len = 16'd6;
              7:  sentence_len = 16'd7;
              8:  sentence_len = 16'd8;
              9:  sentence_len = 16'd9;
              10: sentence_len = 16'd10;
              11: sentence_len = 16'd11;
              12: sentence_len = 16'd16;
              13: sentence_len = 16'd148;
              14: sentence_len = 16'd296;
              15: sentence_len = 16'd297;
              16: sentence_len = 16'd298;
              17: sentence_len = 16'd299;
              18: sentence_len = 16'd300;
              19: sentence_len = 16'd301;
              20: sentence_len = 16'd302;
              21: sentence_len = 16'd303;
              22: sentence_len = 16'd304;
              23: sentence_len = 16'd305;
              24: sentence_len = 16'd306;
              25: sentence_len = 16'd307;
              26: sentence_len = 16'd308;
              27: sentence_len = 16'd312;
              28: sentence_len = 16'd1448;
              29: sentence_len = 16'd1450;
              30: sentence_len = 16'd1456;
              31: sentence_len = 16'd1458;
              32: sentence_len = 16'd1459;
              33: sentence_len = 16'd1460;
              default: sentence_len = 16'd304;
            endcase
            exp_add(exp_nxt, 16'd1460);
            send_frame(exp_nxt, 32'h2000, 16'd1460, 16'h4000, 8, 0);
            exp_nxt = exp_nxt + 1460;
            exp_add(exp_nxt, sentence_len);
            send_frame(exp_nxt, 32'h2000, sentence_len, 16'h4000, 8, 0);
            exp_nxt = exp_nxt + sentence_len;
            end
        end
        chk("C len-sweep (34x [1460 + L])");

        // ---------------------------------------------------------------
        // E) 前一帧被拒收 (S_DROP 中段, pcount 停在残值) 后紧跟短段
        //    -- 对方假设"被拒收的帧让 pcount 残留 -> 下一段被误杀"
        // ---------------------------------------------------------------
        $display("-- E) 前一帧被拒收(窗口外, S_DROP 中段) -> 紧跟短段 --");
        exp_add(exp_nxt, 16'd1460);
        send_frame(exp_nxt, 32'h2000, 16'd1460, 16'h4000, 8, 0);
        exp_nxt = exp_nxt + 1460;
        $display("   E0: 1460 交付后 pcount 残值=%0d rcv_nxt=%08h", dbg_pcount, ra_rcv_nxt);
        // E1: 1460 帧, seq 超前窗口外 (rcv_nxt + 0xC000 + 0x100) -> w6 判 nonmatch -> S_DROP
        send_frame(exp_nxt + 32'hC100, 32'h2000, 16'd1460, 16'h4000, 8, 0);
        $display("   E1: 窗口外 1460 帧 -> nonmatch=%0d, pcount 残值仍=%0d (S_DROP 期间不重置)",
                 stat_nonmatch, dbg_pcount);
        // E2: 正确 seq 的 304 短段 -> 必须交付
        exp_add(exp_nxt, 16'd304);
        send_frame(exp_nxt, 32'h2000, 16'd304, 16'h4000, 8, 0);
        exp_nxt = exp_nxt + 304;
        chk("E prev-frame-rejected -> short frame OK");

        // ---------------------------------------------------------------
        // F) s_axis_tuser 半帧中止 (S_PAY 中段) 后的短段
        // ---------------------------------------------------------------
        $display("-- F) tuser 半帧中止 (S_PAY 中段) -> 后续短段 --");
        send_partial(exp_nxt, 32'h2000, 16'd1460, 16'h4000, 40, 4);   // 40 字后中止 (无 tlast)
        $display("   F1: 半帧中止时 fsm=%0d pcount=%0d emit_l=%0d", dbg_state, dbg_pcount, dbg_emit_l);
        send_frame(exp_nxt + 32'd7, 32'h2000, 16'd200, 16'h4000, 8, 0);   // 新帧 (tuser=1) = 中止拍
        $display("   F2: 中止后 fsm=%0d pcount=%0d rcv_nxt=%08h (半帧未推进)", dbg_state, dbg_pcount, ra_rcv_nxt);
        capn = 0; expn = 0; mcap = 0; mexp = 0;                          // 半帧残字节清账
        exp_add(exp_nxt, 16'd304);
        send_frame(exp_nxt, 32'h2000, 16'd304, 16'h4000, 8, 0);
        exp_nxt = exp_nxt + 304;
        chk("F after-tuser-abort short frame");

        // ---------------------------------------------------------------
        // G) S_PAD 退出路径 (纯 ACK 带填充) 后的短段
        // ---------------------------------------------------------------
        $display("-- G) 纯 ACK 帧 (S_PAD 路径) -> 紧跟短段 --");
        exp_add(exp_nxt, 16'd100);
        send_frame(exp_nxt, 32'h2000, 16'd100, 16'h4000, 8, 0);
        exp_nxt = exp_nxt + 100;
        send_frame(exp_nxt, 32'h2000, 16'd0, 16'h4000, 8, 0);            // 纯 ACK (60B 带填充)
        $display("   G1: 纯 ACK 后 pcount 残值=%0d rcv_nxt=%08h (不应推进)", dbg_pcount, ra_rcv_nxt);
        exp_add(exp_nxt, 16'd304);
        send_frame(exp_nxt, 32'h2000, 16'd304, 16'h4000, 8, 0);
        exp_nxt = exp_nxt + 304;
        chk("G after-pure-ACK short frame");

        // ---------------------------------------------------------------
        // H) 对方场景等价复现: 通告窗 304 (与日志同值), 段在飞途中窗口塌到 0
        // ---------------------------------------------------------------
        $display("-- H) 在飞期间窗口塌陷 (wnd 0x130=304 -> 0) --");
        exp_add(exp_nxt, 16'd1460);
        send_frame(exp_nxt, 32'h2000, 16'd1460, 16'h4000, 8, 0);
        exp_nxt = exp_nxt + 1460;
        cfg_tcb(4'd0, 3'd3, 32'h130);            // 通告窗口 = 304
        build_frame(exp_nxt, 32'h2000, 16'd304, 16'h4000, ipid, 0);
        ipid = ipid + 1;
        @(posedge clk);
        for (wi = 0; wi < 4; wi = wi + 1) begin  // w0..w3 在飞 (窗口仍 304)
            wd = 64'h0;
            for (wj = 0; wj < 8; wj = wj + 1)
                if ((8*wi + wj) < fbody)
                    wd = wd | ({56'b0, fb[8*wi+wj]} << (8*(7-wj)));
            nv = fbody - 8*wi; if (nv > 8) nv = 8;
            put_word(wd, (8'hFF << (8-nv)), 1'b0, (wi == 0));
        end
        cfg_tcb(4'd0, 3'd3, 32'h0);              // 在飞途中窗口塌到 0 (应用缓冲占满)
        for (wi = 4; wi < fwords; wi = wi + 1) begin
            wd = 64'h0;
            for (wj = 0; wj < 8; wj = wj + 1)
                if ((8*wi + wj) < fbody)
                    wd = wd | ({56'b0, fb[8*wi+wj]} << (8*(7-wj)));
            nv = fbody - 8*wi; if (nv > 8) nv = 8;
            put_word(wd, (8'hFF << (8-nv)), (wi == fwords-1), 1'b0);
        end
        repeat (8) @(posedge clk);
        $display("   H: 塌陷拍在飞 -> nonmatch=%0d seq=%0d rcv_nxt=%08h (应停在 %08h)",
                 stat_nonmatch, stat_seq, ra_rcv_nxt, exp_nxt);
        cfg_tcb(4'd0, 3'd3, 32'hC000);           // 窗口重开 -> 同段重发必须交付
        exp_add(exp_nxt, 16'd304);
        send_frame(exp_nxt, 32'h2000, 16'd304, 16'h4000, 8, 0);
        exp_nxt = exp_nxt + 304;
        chk("H window-collapse-in-flight");

        // ---------------------------------------------------------------
        // D) L753 守卫可达性: 只有"帧身 > 声明载荷"的畸形帧才触发
        // ---------------------------------------------------------------
        $display("-- D) 畸形帧 (声明 plen=304, 帧身 400B) = L753 唯一可达路径 --");
        // 先来一个正常 1460 长段 (制造残值), 再发畸形帧
        exp_add(exp_nxt, 16'd1460);
        send_frame(exp_nxt, 32'h2000, 16'd1460, 16'h4000, 8, 0);
        exp_nxt = exp_nxt + 1460;
        $display("   D1 畸形帧前 pcount 残值=%0d", dbg_pcount);
        send_frame(exp_nxt, 32'h2000, 16'd304, 16'h4000, 12, 96);   // extra=96 -> 帧身 400
        $display("   D1 畸形帧结果: nonmatch=%0d trunc=%0d pass=%0d", stat_nonmatch, stat_trunc, stat_pass);
        // flush: 半帧被守卫吞掉, sink 里有残留字节 -> 清空对账基线
        capn = 0; expn = 0; mcap = 0; mexp = 0;
        // 正常重发同一 seq 的 304B 段 -> 应交付 (守卫不误伤好帧)
        exp_add(exp_nxt, 16'd304);
        send_frame(exp_nxt, 32'h2000, 16'd304, 16'h4000, 12, 0);
        exp_nxt = exp_nxt + 304;
        chk("D malformed-guard + recovery");

        repeat (40) @(posedge clk);
        $display("==== f2chk 收尾 ====");
        $display("STATS pass=%0d nonmatch=%0d trunc=%0d ipcsum=%0d crc=%0d seq=%0d ack=%0d bytes=%0d",
                 stat_pass, stat_nonmatch, stat_trunc, stat_ipcsum, stat_crc, stat_seq, stat_ack, stat_bytes);
        $display("TCB rcv_nxt=%08h rcv_wnd=%04h snd_una=%08h state=%0d",
                 u_tcb.rcv_nxt_r[0], u_tcb.rcv_wnd_r[0], u_tcb.snd_una_r[0], u_tcb.state_r[0]);
        $display("delivered=%0d expected=%0d", capn, expn);
        $finish;
    end

    initial begin
        #40000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
