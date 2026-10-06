`timescale 1ns/1ps
//=============================================================================
// tb_wu_review: kang-zheng-shen-cha agent de du-li fu-he tai (P7b-WU xiu-fu)
//   san bi tong shi yun xing, tong yi ji li:
//     u_new  = app_ctrl (mo ren = xiu fu hou)
//     u_leg  = app_ctrl #(.WU_LEGACY(1))     (zuo zhe sheng cheng = xiu fu qian)
//     u_head = app_ctrl_head                 (**cong git ff78247 qu chu de yuan wen jian**,
//                                             zhi ba mo kuai ming gai cheng app_ctrl_head)
//   pan ju:
//     E1  u_leg zhu pai === u_head (quan fang zhen, quan xiang wei)
//         => "WU_LEGACY zhu zi fu xian xiu fu qian" bei **du li** zheng shi
//     E2  u_new yu u_head zhi shao yi pai bu tong => bi jiao qi **you ya** (negative control)
//   chang jing (mei ge xian pulse rst_n, san bi yi qi chong lai):
//     PH0 sui ji zou cha (occ quan liang cheng + shi jian + gnt dou dong)
//     PH1 winq = 3    (floor(winq/4)=0 => xin wu zhuang tiao jian jie gou xing bu ke da)
//     PH2 winq = 5    (Zeno xuan ting 1..3, yong bu chu 0)
//     PH3 winq = 3072 (N=16 fen chi, chan pin pei zhi): wu zhuang / bu chu fa / chu fa
//     PH4 shuang lian jie (conn0 you liu liang, conn1 quan jing mo): kong zhuan shi fou fa wu
//     PH5 ao dang chuan 3/4 (occ 40000 <-> 20000): mei zhou qi wu tiao shu
//   zhi du ji cun qi 0x96/0x9B; wei yi xie = 0x0C (**jue bu peng 0x08** = ban shang SCRATCH/TX_DIS)
//=============================================================================
module tb_wu_review;
    localparam [15:0] WINQ = 16'hC000;
    localparam [15:0] WQ16 = 16'h0C00;      // 49152/16 (N=16 fen chi)
    localparam [31:0] RN0  = 32'h3000_0001;

    reg clk, rst_n;
    integer errs;
    integer eq_bad, new_diff, lock_bad;     // kua xiang wei lei ji
    integer i, kv, kw, kg;
    integer nfire_n, nfire_l, nfire_h;      // ge bi stat_wu zeng liang
    reg [31:0] w0n, w0l, w0h, w1n, w1l, w1h;
    integer cyc_cnt;
    reg [15:0] hb;
    reg        first_mism_done;

    // ---------------- jia TCB ----------------
    reg [31:0] t_rcv_nxt [0:15];
    reg [31:0] t_snd_nxt [0:15];
    reg [31:0] t_snd_una [0:15];
    reg [15:0] t_rcv_wnd [0:15];
    reg [15:0] t_snd_wnd [0:15];
    reg [3:0]  t_state   [0:15];

    wire [3:0]  rc_id_n, rc_id_l, rc_id_h;
    wire [3:0]  rc_id      = rc_id_n;
    wire [31:0] rc_rcv_nxt = t_rcv_nxt[rc_id];
    wire [31:0] rc_snd_nxt = t_snd_nxt[rc_id];
    wire [31:0] rc_snd_una = t_snd_una[rc_id];
    wire [15:0] rc_rcv_wnd = t_rcv_wnd[rc_id];
    wire [15:0] rc_snd_wnd = t_snd_wnd[rc_id];
    wire [3:0]  rc_state   = t_state[rc_id];

    // ---------------- gong xiang ji li ----------------
    reg [16:0] occ;
    reg        ev_up, ev_down;
    reg [3:0]  ev_slot;
    reg [15:0] fin_sent, rst_sent;
    reg [7:0]  reg_addr;
    reg        reg_wr;
    reg [31:0] reg_wdata;
    reg        gnt_en;
    reg        walk_en;

    // ---------------- san bi ----------------
    wire        wu_req_n, wu_req_l, wu_req_h;
    wire [3:0]  wu_id_n,  wu_id_l,  wu_id_h;
    wire [31:0] wu_val_n, wu_val_l, wu_val_h;
    wire        fc_wr_n,  fc_wr_l,  fc_wr_h;
    wire [3:0]  fc_id_n,  fc_id_l,  fc_id_h;
    wire [2:0]  fc_sel_n, fc_sel_l, fc_sel_h;
    wire [31:0] fc_val_n, fc_val_l, fc_val_h;
    wire [31:0] rd_n, rd_l, rd_h;
    wire [15:0] rdy_n, rdy_l, rdy_h;
    wire [31:0] s_evup_n, s_evup_l, s_evup_h;
    wire [31:0] s_pool_n, s_pool_l, s_pool_h;
    wire [31:0] s_sru_n,  s_sru_l,  s_sru_h;
    wire [31:0] s_wait_n, s_wait_l, s_wait_h;
    wire        oeu_n, oeu_l, oeu_h, oed_n, oed_l, oed_h;
    wire [3:0]  oes_n, oes_l, oes_h;
    wire [15:0] frq_n, frq_l, frq_h, rrq_n, rrq_l, rrq_h;
    wire [3:0]  dc0s_n, dc0s_l, dc0s_h;
    wire [31:0] dc0n_n, dc0n_l, dc0n_h, dc0u_n, dc0u_l, dc0u_h, dc0r_n, dc0r_l, dc0r_h;
    wire [15:0] dc0w_n, dc0w_l, dc0w_h, dc0x_n, dc0x_l, dc0x_h;
    wire [15:0] decn_n, decn_l, decn_h, devn_n, devn_l, devn_h;
    wire [31:0] dred_n, dred_l, dred_h;
    wire [15:0] dwq_n,  dwq_l,  dwq_h, dwm_n, dwm_l, dwm_h;
    wire [16:0] dpl_n,  dpl_l,  dpl_h;

    wire wu_gnt_n = gnt_en && wu_req_n;
    wire wu_gnt_l = gnt_en && wu_req_l;
    wire wu_gnt_h = gnt_en && wu_req_h;
    wire fc_gnt   = fc_wr_n || fc_wr_l || fc_wr_h;

    app_ctrl #(.WIN_CAP(16'hBFFE), .WIN_POOL(16'hC000), .WIN_Q_MAX(16'hC000),
               .FIN_TO_LIM(18'd10))
    u_new (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(32'h0), .ev_peer_port(16'h0), .ev_peer_mac(48'h0),
        .rc_id(rc_id_n), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .rx_occ_bytes(occ), .fin_sent(fin_sent), .rst_sent(rst_sent),
        .o_ev_up(oeu_n), .o_ev_down(oed_n), .o_ev_slot(oes_n),
        .fin_req(frq_n), .rst_req(rrq_n),
        .close_req(1'b0), .close_id(4'd0),
        .fc_upd_wr(fc_wr_n), .fc_upd_id(fc_id_n), .fc_upd_sel(fc_sel_n),
        .fc_upd_val(fc_val_n), .fc_gnt(fc_gnt),
        .wu_req(wu_req_n), .wu_id(wu_id_n), .wu_val(wu_val_n), .wu_gnt(wu_gnt_n),
        .reg_addr(reg_addr), .reg_wr(reg_wr), .reg_wdata(reg_wdata),
        .reg_rdata(rd_n),
        .app_tx_ready(rdy_n),
        .dbg_c0_state(dc0s_n), .dbg_c0_snd_nxt(dc0n_n), .dbg_c0_snd_una(dc0u_n),
        .dbg_c0_rcv_nxt(dc0r_n), .dbg_c0_rcv_wnd(dc0w_n), .dbg_c0_snd_wnd(dc0x_n),
        .dbg_estab_cnt(decn_n), .dbg_ev_cnt(devn_n),
        .dbg_redge0(dred_n), .dbg_winq0(dwq_n), .dbg_wu_mark0(dwm_n), .dbg_pool(dpl_n),
        .stat_ev_up(s_evup_n), .stat_ev_down(), .stat_ev_drop(), .stat_cmd_close(),
        .stat_cmd_abort(), .stat_wu(), .stat_pool_exhaust(s_pool_n), .stat_fc_upd(),
        .stat_slot_reuse(s_sru_n), .stat_fc_wait_max(s_wait_n)
    );

    app_ctrl #(.WIN_CAP(16'hBFFE), .WIN_POOL(16'hC000), .WIN_Q_MAX(16'hC000),
               .FIN_TO_LIM(18'd10), .WU_LEGACY(1'b1))
    u_leg (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(32'h0), .ev_peer_port(16'h0), .ev_peer_mac(48'h0),
        .rc_id(rc_id_l), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .rx_occ_bytes(occ), .fin_sent(fin_sent), .rst_sent(rst_sent),
        .o_ev_up(oeu_l), .o_ev_down(oed_l), .o_ev_slot(oes_l),
        .fin_req(frq_l), .rst_req(rrq_l),
        .close_req(1'b0), .close_id(4'd0),
        .fc_upd_wr(fc_wr_l), .fc_upd_id(fc_id_l), .fc_upd_sel(fc_sel_l),
        .fc_upd_val(fc_val_l), .fc_gnt(fc_gnt),
        .wu_req(wu_req_l), .wu_id(wu_id_l), .wu_val(wu_val_l), .wu_gnt(wu_gnt_l),
        .reg_addr(reg_addr), .reg_wr(reg_wr), .reg_wdata(reg_wdata),
        .reg_rdata(rd_l),
        .app_tx_ready(rdy_l),
        .dbg_c0_state(dc0s_l), .dbg_c0_snd_nxt(dc0n_l), .dbg_c0_snd_una(dc0u_l),
        .dbg_c0_rcv_nxt(dc0r_l), .dbg_c0_rcv_wnd(dc0w_l), .dbg_c0_snd_wnd(dc0x_l),
        .dbg_estab_cnt(decn_l), .dbg_ev_cnt(devn_l),
        .dbg_redge0(dred_l), .dbg_winq0(dwq_l), .dbg_wu_mark0(dwm_l), .dbg_pool(dpl_l),
        .stat_ev_up(s_evup_l), .stat_ev_down(), .stat_ev_drop(), .stat_cmd_close(),
        .stat_cmd_abort(), .stat_wu(), .stat_pool_exhaust(s_pool_l), .stat_fc_upd(),
        .stat_slot_reuse(s_sru_l), .stat_fc_wait_max(s_wait_l)
    );

    app_ctrl_head #(.WIN_CAP(16'hBFFE), .WIN_POOL(16'hC000), .WIN_Q_MAX(16'hC000),
               .FIN_TO_LIM(18'd10))
    u_head (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(32'h0), .ev_peer_port(16'h0), .ev_peer_mac(48'h0),
        .rc_id(rc_id_h), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .rx_occ_bytes(occ), .fin_sent(fin_sent), .rst_sent(rst_sent),
        .o_ev_up(oeu_h), .o_ev_down(oed_h), .o_ev_slot(oes_h),
        .fin_req(frq_h), .rst_req(rrq_h),
        .close_req(1'b0), .close_id(4'd0),
        .fc_upd_wr(fc_wr_h), .fc_upd_id(fc_id_h), .fc_upd_sel(fc_sel_h),
        .fc_upd_val(fc_val_h), .fc_gnt(fc_gnt),
        .wu_req(wu_req_h), .wu_id(wu_id_h), .wu_val(wu_val_h), .wu_gnt(wu_gnt_h),
        .reg_addr(reg_addr), .reg_wr(reg_wr), .reg_wdata(reg_wdata),
        .reg_rdata(rd_h),
        .app_tx_ready(rdy_h),
        .dbg_c0_state(dc0s_h), .dbg_c0_snd_nxt(dc0n_h), .dbg_c0_snd_una(dc0u_h),
        .dbg_c0_rcv_nxt(dc0r_h), .dbg_c0_rcv_wnd(dc0w_h), .dbg_c0_snd_wnd(dc0x_h),
        .dbg_estab_cnt(decn_h), .dbg_ev_cnt(devn_h),
        .dbg_redge0(dred_h), .dbg_winq0(dwq_h), .dbg_wu_mark0(dwm_h), .dbg_pool(dpl_h),
        .stat_ev_up(s_evup_h), .stat_ev_down(), .stat_ev_drop(), .stat_cmd_close(),
        .stat_cmd_abort(), .stat_wu(), .stat_pool_exhaust(s_pool_h), .stat_fc_upd(),
        .stat_slot_reuse(s_sru_h), .stat_fc_wait_max(s_wait_h)
    );

    always #4 clk = ~clk;

    // jin du ke jian (xsim -log shi huan chong de; stdout chong ding xiang cai ke shi shi tail)
    always @(posedge clk) begin
        cyc_cnt <= cyc_cnt + 1;
        hb <= hb + 16'd1;
        if (hb == 16'd0)
            $display("[HB] t=%0t ns cyc=%0d eq_bad=%0d new_diff=%0d lock_bad=%0d",
                     $time, cyc_cnt, eq_bad, new_diff, lock_bad);
    end

    //=========================================================================
    // zhu pai bi jiao (kua xiang wei lei ji; zhi zai rst_n gao shi ji)
    //=========================================================================
    always @(posedge clk) begin
        if (rst_n) begin
            if ( u_leg.wu_zero      !== u_head.wu_zero      ||
                 u_leg.wu_pend      !== u_head.wu_pend      ||
                 u_leg.wu_mark[0]   !== u_head.wu_mark[0]   ||
                 u_leg.wu_mark[1]   !== u_head.wu_mark[1]   ||
                 u_leg.wu_mark[2]   !== u_head.wu_mark[2]   ||
                 u_leg.wu_req       !== u_head.wu_req       ||
                 u_leg.wu_id        !== u_head.wu_id        ||
                 u_leg.wu_val       !== u_head.wu_val       ||
                 u_leg.stat_wu      !== u_head.stat_wu      ||
                 u_leg.stat_fc_upd  !== u_head.stat_fc_upd  ||
                 u_leg.pool         !== u_head.pool         ||
                 u_leg.winq[0]      !== u_head.winq[0]      ||
                 u_leg.winq[1]      !== u_head.winq[1]      ||
                 u_leg.winq[2]      !== u_head.winq[2]      ||
                 u_leg.redge[0]     !== u_head.redge[0]     ||
                 u_leg.redge[1]     !== u_head.redge[1]     ||
                 u_leg.pb_v         !== u_head.pb_v         ||
                 u_leg.pb_sid       !== u_head.pb_sid       ||
                 u_leg.pb_wscan     !== u_head.pb_wscan     ||
                 u_leg.fc_pend      !== u_head.fc_pend      ||
                 u_leg.stat_slot_reuse !== u_head.stat_slot_reuse ||
                 u_leg.stat_ev_up   !== u_head.stat_ev_up   ||
                 fc_wr_l            !== fc_wr_h             ||
                 rd_l               !== rd_h                ||
                 dpl_l              !== dpl_h ) begin
                eq_bad <= eq_bad + 1;
                if (!first_mism_done) begin
                    first_mism_done <= 1'b1;
                    $display("[MISM] cyc=%0d wz=%b/%b wp=%b/%b wm=%04x/%04x wr=%b/%b swu=%0d/%0d pool=%05x/%05x wq0=%04x/%04x pbv=%b/%b pbws=%04x/%04x fcp=%b/%b",
                        cyc_cnt,
                        u_leg.wu_zero, u_head.wu_zero, u_leg.wu_pend, u_head.wu_pend,
                        u_leg.wu_mark[0], u_head.wu_mark[0], u_leg.wu_req, u_head.wu_req,
                        u_leg.stat_wu, u_head.stat_wu, u_leg.pool, u_head.pool,
                        u_leg.winq[0], u_head.winq[0], u_leg.pb_v, u_head.pb_v,
                        u_leg.pb_wscan, u_head.pb_wscan, u_leg.fc_pend, u_head.fc_pend);
                end
            end
            if ( u_new.wu_zero !== u_head.wu_zero ||
                 u_new.wu_pend !== u_head.wu_pend ||
                 u_new.wu_req  !== u_head.wu_req  ||
                 u_new.stat_wu !== u_head.stat_wu )
                new_diff <= new_diff + 1;
            if ((rc_id_n !== rc_id_l) || (rc_id_l !== rc_id_h) ||
                (u_new.tick_cnt !== u_leg.tick_cnt) ||
                (u_leg.tick_cnt !== u_head.tick_cnt) ||
                (u_new.scan_id  !== u_head.scan_id))
                lock_bad <= lock_bad + 1;
        end
    end

    //=========================================================================
    // sui ji zou cha (PH0 zhuan yong)
    //=========================================================================
    reg [15:0] lfsr;
    reg [4:0]  step_t;
    reg [15:0] stepv;
    reg        stepdir;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr <= 16'hACE1; step_t <= 5'd0; stepv <= 16'd64; stepdir <= 1'b0;
        end else if (walk_en) begin
            lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
            gnt_en <= ~(lfsr[6] & lfsr[5]);
            if (step_t == 5'd0) begin
                step_t <= 5'd7;
                case (lfsr[14:12])
                    3'd0: begin stepv <= 16'd1;    stepdir <= 1'b1; end
                    3'd1: begin stepv <= 16'd64;   stepdir <= 1'b1; end
                    3'd2: begin stepv <= 16'd2048; stepdir <= 1'b0; end
                    3'd3: begin stepv <= 16'd64;   stepdir <= 1'b0; end
                    3'd4: begin stepv <= 16'd512;  stepdir <= 1'b1; end
                    3'd5: begin stepv <= 16'd8192; stepdir <= 1'b1; end
                    3'd6: begin stepv <= 16'd4096; stepdir <= 1'b0; end
                    3'd7: begin stepv <= 16'd8000; stepdir <= 1'b1; end
                endcase
            end else
                step_t <= step_t - 5'd1;
            if (stepdir) begin
                if (occ <= ({1'b0, WINQ} + 17'd400 - {1'b0, stepv})) begin
                    occ <= occ + {1'b0, stepv};
                    t_rcv_nxt[0] <= t_rcv_nxt[0] + {16'b0, stepv};
                end else
                    occ <= {1'b0, WINQ} + 17'd400;
            end else begin
                if (occ >= {1'b0, stepv}) occ <= occ - {1'b0, stepv};
                else                      occ <= 17'd0;
            end
        end
    end

    // TCB xie mo xing (rcv_wnd)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 16; i = i + 1) t_rcv_wnd[i] <= 16'd0;
        end else if (fc_gnt && (fc_sel_n == 3'd3)) begin
            t_rcv_wnd[fc_id_n] <= fc_val_n[15:0];
        end
    end

    //=========================================================================
    // gong ju task
    //=========================================================================
    task chk;
        input         cond;
        input [255:0] name;
        begin
            if (cond) $display("  PASS %0s", name);
            else begin errs = errs + 1; $display("  FAIL %0s", name); end
        end
    endtask

    integer kc;
    task do_clk;
        input integer n;
        begin for (kc = 0; kc < n; kc = kc + 1) @(posedge clk); end
    endtask

    task ev_up_at;
        input [3:0] s;
        begin
            @(posedge clk); ev_up <= 1'b1; ev_slot <= s;
            @(posedge clk); ev_up <= 1'b0;
        end
    endtask

    task ev_down_at;
        input [3:0] s;
        begin
            @(posedge clk); ev_down <= 1'b1; ev_slot <= s;
            @(posedge clk); ev_down <= 1'b0;
        end
    endtask

    task wr_reg;
        input [7:0]  a;
        input [31:0] d;
        begin
            @(posedge clk);
            reg_addr <= a; reg_wdata <= d; reg_wr <= 1'b1;
            @(posedge clk);
            reg_wr <= 1'b0;
            @(posedge clk);
        end
    endtask

    task rd_word;
        input [7:0] a;
        begin
            reg_addr = a;
            #1;
        end
    endtask

    task wait_scan;
        input integer n;
        begin
            for (kw = 0; kw < n; kw = kw + 1) begin
                kg = 0;
                while (!((u_new.tick_cnt == 4'd15) && (u_new.scan_id == 4'd0) &&
                         !u_new.init_pend) && (kg < 4000)) begin
                    @(posedge clk); kg = kg + 1;
                end
                repeat (3) @(posedge clk);
            end
        end
    endtask

    task read_wu;
        output [31:0] a, b, c;
        begin
            rd_word(8'h96);
            a = rd_n; b = rd_l; c = rd_h;
        end
    endtask

    task delta_wu;
        begin
            read_wu(w1n, w1l, w1h);
            nfire_n = w1n - w0n; nfire_l = w1l - w0l; nfire_h = w1h - w0h;
            w0n = w1n; w0l = w1l; w0h = w1h;
        end
    endtask

    task do_reset;
        begin
            walk_en = 1'b0;
            rst_n = 1'b0;
            occ = 17'd0;
            ev_up = 0; ev_down = 0; ev_slot = 0; fin_sent = 0; rst_sent = 0;
            reg_addr = 8'h00; reg_wr = 0; reg_wdata = 0; gnt_en = 0;
            for (kv = 0; kv < 16; kv = kv + 1) begin
                t_rcv_nxt[kv] = 32'd0; t_snd_nxt[kv] = 32'd0; t_snd_una[kv] = 32'd0;
                t_rcv_wnd[kv] = 16'd0; t_snd_wnd[kv] = 16'd0; t_state[kv] = 4'd0;
            end
            do_clk(8);
            rst_n = 1'b1;
            do_clk(6);
        end
    endtask

    //=========================================================================
    initial begin
        clk = 1'b0; rst_n = 1'b0; errs = 0;
        cyc_cnt = 0; hb = 16'd0; first_mism_done = 1'b0;
        eq_bad = 0; new_diff = 0; lock_bad = 0;
        occ = 17'd0; ev_up = 0; ev_down = 0; ev_slot = 0; fin_sent = 0;
        rst_sent = 0; reg_addr = 8'h00; reg_wr = 0; reg_wdata = 0;
        gnt_en = 0; walk_en = 0;
        for (i = 0; i < 16; i = i + 1) begin
            t_rcv_nxt[i] = 32'd0; t_snd_nxt[i] = 32'd0; t_snd_una[i] = 32'd0;
            t_rcv_wnd[i] = 16'd0; t_snd_wnd[i] = 16'd0; t_state[i] = 4'd0;
        end
        #100; rst_n = 1'b1;
        do_clk(10);

        //=====================================================================
        $display("PH0: random walk (occ full range + events + gnt jitter)");
        //=====================================================================
        t_state[0]   <= 4'd1;  t_rcv_nxt[0] <= RN0;  t_rcv_wnd[0] <= 16'hC000;
        t_snd_wnd[0] <= 16'h4000;
        ev_up_at(4'd0);
        do_clk(30);
        gnt_en = 1'b1;
        walk_en = 1'b1;
        do_clk(30000);
        walk_en = 1'b0;
        do_clk(20);
        t_state[1]   <= 4'd1;  t_rcv_nxt[1] <= 32'h4000_0001; t_rcv_wnd[1] <= 16'hC000;
        t_snd_wnd[1] <= 16'h4000;
        ev_up_at(4'd1);
        do_clk(30);
        walk_en = 1'b1;
        do_clk(20000);
        walk_en = 1'b0;
        do_clk(20);
        ev_down_at(4'd1);
        do_clk(20);
        ev_up_at(4'd1);
        do_clk(30);
        walk_en = 1'b1;
        do_clk(10000);
        walk_en = 1'b0;
        do_clk(20);
        rd_word(8'h00);
        read_wu(w1n, w1l, w1h);
        $display("  [READ] PH0 stat_wu: new=%0d leg=%0d head=%0d", w1n, w1l, w1h);
        chk(eq_bad == 0, "E1 u_leg === u_head per-cycle (all phases)");
        chk(new_diff > 0, "E2 u_new != u_head at least one cycle (comparator has teeth)");
        chk(lock_bad == 0, "E3 three arms lockstep (rc_id/tick_cnt/scan_id)");
        $display("  [READ] eq_bad=%0d new_diff=%0d lock_bad=%0d", eq_bad, new_diff, lock_bad);

        //=====================================================================
        $display("PH1: winq = 3 (floor(winq/4)=0 => new arm condition unreachable)");
        //=====================================================================
        do_reset;
        gnt_en = 1'b1;
        wr_reg(8'h0C, 32'd3);
        t_state[0] <= 4'd1; t_rcv_nxt[0] <= RN0; t_rcv_wnd[0] <= 16'hC000;
        t_snd_wnd[0] <= 16'h4000;
        ev_up_at(4'd0);
        do_clk(20);
        rd_word(8'h9A);
        $display("  [READ] winq[0]: new=%04x leg=%04x head=%04x (expect 0003)",
                 dwq_n, dwq_l, dwq_h);
        rd_word(8'h00);
        read_wu(w0n, w0l, w0h);
        occ <= 17'd3;
        wait_scan(3);
        $display("  [READ] wscan=0: new wu_zero=%b leg=%b head=%b",
                 u_new.wu_zero[0], u_leg.wu_zero[0], u_head.wu_zero[0]);
        occ <= 17'd0;
        wait_scan(3);
        do_clk(6);
        delta_wu;
        $display("  [READ] PH1 fires: new=%0d leg=%0d head=%0d", nfire_n, nfire_l, nfire_h);
        chk(nfire_n == 0, "PH1a NEW 0 fires (winq=3 => cannot arm, structurally)");
        chk(nfire_h >= 1, "PH1b HEAD >=1 fire (old arm COULD => fix loses capability)");
        chk(nfire_l == nfire_h, "PH1c LEGACY count == HEAD count");

        //=====================================================================
        $display("PH2: winq = 5 + Zeno hover (win 1..3, never exactly 0)");
        //=====================================================================
        do_reset;
        gnt_en = 1'b1;
        wr_reg(8'h0C, 32'd5);
        t_state[0] <= 4'd1; t_rcv_nxt[0] <= RN0; t_rcv_wnd[0] <= 16'hC000;
        t_snd_wnd[0] <= 16'h4000;
        ev_up_at(4'd0);
        do_clk(20);
        rd_word(8'h00);
        read_wu(w0n, w0l, w0h);
        for (kv = 0; kv < 20; kv = kv + 1) begin
            occ <= 17'd4; wait_scan(1);
            occ <= 17'd2; wait_scan(1);
        end
        do_clk(6);
        delta_wu;
        $display("  [READ] PH2 fires: new=%0d leg=%0d head=%0d", nfire_n, nfire_l, nfire_h);
        chk(nfire_n == 0, "PH2a NEW 0 fires (arm floor(5/4)=1 => needs exact 0)");
        chk(nfire_h == 0, "PH2b HEAD 0 fires (small quota: both conditions unreachable)");

        //=====================================================================
        $display("PH3: winq = 3072 (N=16 pool split, product config) three points");
        //=====================================================================
        do_reset;
        gnt_en = 1'b1;
        wr_reg(8'h0C, {16'b0, WQ16});
        t_state[0] <= 4'd1; t_rcv_nxt[0] <= RN0; t_rcv_wnd[0] <= 16'hC000;
        t_snd_wnd[0] <= 16'h4000;
        ev_up_at(4'd0);
        do_clk(20);
        rd_word(8'h9A);
        $display("  [READ] winq[0]: new=%04x (expect 0C00)", dwq_n);
        chk(dwq_n == WQ16, "PH3a pool split effective winq[0]=0x0C00");
        rd_word(8'h00);
        read_wu(w0n, w0l, w0h);
        occ <= 17'd3000;
        wait_scan(3);
        chk(u_new.wu_zero[0] == 1'b1, "PH3b NEW armed (wscan=72 < wq/4=768)");
        occ <= 17'd2000;
        wait_scan(3);
        delta_wu;
        chk(nfire_n == 0, "PH3c false-fail direction: 1072 < wq/2=1536 => 0 fires");
        chk(u_new.wu_zero[0] == 1'b1, "PH3d still armed (not fired)");
        occ <= 17'd1500;
        wait_scan(3);
        do_clk(6);
        delta_wu;
        rd_word(8'h9B);
        $display("  [READ] PH3 fires: new=%0d head=%0d; wu_mark[0]=%04x (expect ~061c)",
                 nfire_n, nfire_h, dwm_n);
        chk(nfire_n == 1, "PH3e NEW fires (wscan=1572 >= wq/2)");
        chk(nfire_h == 0, "PH3f HEAD 0 fires (same stim, win never exactly 0)");
        chk((dwm_n >= WQ16[15:1]) && (dwm_n <= (WQ16[15:1] + 16'd400)),
            "PH3g wu_mark = sampled window at fire (obs semantics)");
        rd_word(8'h00);

        //=====================================================================
        $display("PH4: two connections, conn0 busy / conn1 fully idle - spare conn wu?");
        //=====================================================================
        do_reset;
        gnt_en = 1'b1;
        wr_reg(8'h0C, {16'b0, WQ16});
        t_state[0] <= 4'd1; t_rcv_nxt[0] <= RN0;           t_rcv_wnd[0] <= 16'hC000;
        t_snd_wnd[0] <= 16'h4000;
        ev_up_at(4'd0);
        do_clk(20);
        t_state[1] <= 4'd1; t_rcv_nxt[1] <= 32'h5000_0001; t_rcv_wnd[1] <= 16'hC000;
        t_snd_wnd[1] <= 16'h4000;
        ev_up_at(4'd1);
        do_clk(20);
        rd_word(8'h9A);
        $display("  [READ] winq[0]=%04x", dwq_n);
        rd_word(8'h00);
        read_wu(w0n, w0l, w0h);
        occ <= 17'd3000; t_rcv_nxt[0] <= t_rcv_nxt[0] + 32'd3000;
        wait_scan(4);
        chk((u_new.wu_zero[0] == 1'b1) && (u_new.wu_zero[1] == 1'b1),
            "PH4a both connections armed (shared occ => conn1 enters danger zone)");
        occ <= 17'd1000;
        wait_scan(4);
        do_clk(8);
        delta_wu;
        $display("  [READ] PH4 fires: new=%0d head=%0d", nfire_n, nfire_h);
        chk(nfire_n == 2, "PH4b idle conn1 also emitted 1 wu (shared-occ noise)");
        chk(nfire_h == 0, "PH4c HEAD 0 fires");

        //=====================================================================
        $display("PH5: oscillation across 3/4 (occ 40000 <-> 20000): wu per cycle");
        //=====================================================================
        do_reset;
        gnt_en = 1'b1;
        t_state[0] <= 4'd1; t_rcv_nxt[0] <= RN0; t_rcv_wnd[0] <= 16'hC000;
        t_snd_wnd[0] <= 16'h4000;
        ev_up_at(4'd0);
        do_clk(20);
        rd_word(8'h00);
        read_wu(w0n, w0l, w0h);
        for (kv = 0; kv < 5; kv = kv + 1) begin
            occ <= 17'd40000;
            wait_scan(2);
            if (kv == 0)
                $display("  [DBG] PH5 iter0 arm-check: occ=%0d winq0=%04x wz=%b pbws=%04x",
                         occ, u_new.winq[0], u_new.wu_zero[0], u_new.pb_wscan);
            kg = 0;
            while ((occ > 17'd24400) && (kg < 40000)) begin
                @(posedge clk);
                kg = kg + 1;
                occ <= occ - 17'd1;
                t_rcv_nxt[0] <= t_rcv_nxt[0] + 32'd1;
            end
            if (kv == 0)
                $display("  [DBG] PH5 iter0 after drain: occ=%0d cycles=%0d wz=%b pbws=%04x statwu=%0d",
                         occ, kg, u_new.wu_zero[0], u_new.pb_wscan, u_new.stat_wu);
            do_clk(20);
        end
        delta_wu;
        $display("  [READ] PH5 fires: new=%0d head=%0d (5 cycles)", nfire_n, nfire_h);
        chk(nfire_n == 5, "PH5a one wu per cycle (5/5)");
        chk(nfire_h == 0, "PH5b HEAD 0 fires");

        //=====================================================================
        $display("PH6: healthy high-window phase (occ 500..8000, data flowing) => 0 extra wu");
        //=====================================================================
        do_reset;
        gnt_en = 1'b1;
        t_state[0] <= 4'd1; t_rcv_nxt[0] <= RN0; t_rcv_wnd[0] <= 16'hC000;
        t_snd_wnd[0] <= 16'h4000;
        ev_up_at(4'd0);
        do_clk(20);
        rd_word(8'h00);
        read_wu(w0n, w0l, w0h);
        for (kv = 0; kv < 40; kv = kv + 1) begin
            occ <= 17'd8000; t_rcv_nxt[0] <= t_rcv_nxt[0] + 32'd2000; wait_scan(1);
            occ <= 17'd500;  t_rcv_nxt[0] <= t_rcv_nxt[0] + 32'd2000; wait_scan(1);
        end
        delta_wu;
        $display("  [READ] PH6 fires: new=%0d leg=%0d head=%0d (40 scans, healthy)",
                 nfire_n, nfire_l, nfire_h);
        chk(nfire_n == 0, "PH6a healthy high window => 0 extra wu (frame-rate discipline)");
        chk(nfire_h == 0, "PH6b HEAD 0 too");

        //=====================================================================
        do_clk(20);
        $display("------------------------------------------------------------");
        $display("cumulative: eq_bad=%0d (E1) new_diff=%0d (E2) lock_bad=%0d",
                 eq_bad, new_diff, lock_bad);
        if (errs == 0) $display("WU-REVIEW GATE OK");
        else           $display("WU-REVIEW GATE FAIL %0d", errs);
        $finish;
    end
endmodule
