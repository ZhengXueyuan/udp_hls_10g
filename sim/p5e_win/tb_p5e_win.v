`timescale 1ns/1ps
//=============================================================================
// tb_p5e_win — P5e "0 载荷 opener" 窄窗定向门 (app_pattern + axis_pipe + tcp_tx_frame)
//
// 被测缺陷 (P5d-D2 帧启动门修不掉的残余):
//   axis_pipe 的 s_ready = m_ready || !m_valid ⇒ app 呈交口有 1 拍前瞻。帧 N 的
//   末字被**帧器**(S_RECV, tready=1) 收走的同一拍, pipe 就把帧 N+1 的**首字**
//   锁存了; 此后帧器要花 S_WAIT/S_HDR/S_PAY (~195 拍) 把帧 N 发上线, 期间一个
//   beat 都不收 ⇒ 帧 N+1 首字在 pipe 里滞留 ~195 拍 (占帧周期 ~13%, 不是"极窄")。
//   若这期间连接被 DEL/fence 后**重建** (新会话/新 ISN), 帧器一回 S_IDLE 就把这个
//   滞留字当新会话首帧首字收下:
//     - 无 opener (修前): 8 字节旧流载荷 ⇒ 新会话图案整段偏移 8 (D1 观测的
//       "8B 循环移位/计数差 8");
//     - 有 opener (修后): 0 载荷占位字 ⇒ 只是"预开一帧", plen/seq/tap_seq 都不动,
//       载荷从新会话起点算 ⇒ 零泄漏。
//
// 激励 (精确落在窄窗上, 不靠魔法拍数):
//   narrow_win = ① pipe 内有字 (u_pipe.m_valid) 且 ② 帧器不在 S_RECV/S_IDLE
//   (dbg_state = S_WAIT/S_HDR/S_PAY/S_DONE, 正在发上一帧) —— 这就是"留一个残余字
//   给下一会话"的结构性条件, 随 RTL 变体自动成立。命中后:
//     场景 1 (真实时序): DEL (rb_state<=0, 帧器启动门 st_ok 是 rb_state 活读) +
//       ev_down; 70 拍 (真实 DEL->ADD 间隔) 后 ADD: rb_state<=1 + 新 ISN + cfg_up
//       + ev_up。app 的收尾要等帧器发完上一帧 (~195 拍) ⇒ ev_up 落在 app 还在
//       closing 等交付的拍上 (app_tx_ready 全程保持 1 = 真实 256 拍轮扫快照滞后)。
//     场景 2 (撞车角): 先只写 rb_state<=1 + 新 ISN (帧器下一拍就绪), **再**一拍发
//       ev_up ⇒ ev_up 与 W3 收尾同拍撞车 (真实慢路径里 cfg 序列的 state 写先于
//       收尾授权脉冲) —— 检验撤字/换流优先级: 载荷字不得漏进新会话。
//   判据 (只看线上 TCP 帧的载荷字节):
//     W1 每次换流后首个载荷字节 seq == 新 ISN (无前置/无空洞)
//     W2 **所有**载荷字节 == pattern(seq - 所属会话 ISN) (逐字节图案, 零跨会话泄漏)
//     W3 每个会话载荷总量 == TX_BYTES (会话跑满, app 没被事件打丢)
//     W4 窄窗滞留字 pop8(keep) == 0 (证据: 残余字载荷为零)
//     另打印: 滞留字 tkeep + ev_up 落点处 app 状态
// 判据行: "GATE tb_p5e_win: PASS" / "... FAIL" —— bat 用 findstr 映射退出码。
// 编译: 必须 -d APP_MODE (app_pattern 只在 APP_MODE 构建; 帧器 st_ok 门同)。
//=============================================================================
module tb_p5e_win;

    localparam integer SEGSZ    = 1460;
    localparam integer NFRM     = 8;
    localparam [31:0]  TX_BYTES = SEGSZ * NFRM;
    localparam [31:0]  BASE_A   = 32'h0000_1000;    // 会话 A
    localparam [31:0]  BASE_B   = 32'h0000_9000;    // 会话 B (场景1 新 ISN)
    localparam [31:0]  BASE_C   = 32'h0001_0000;    // 会话 C (场景2 被拆掉的那一段)
    localparam [31:0]  BASE_D   = 32'h0002_0000;    // 会话 D (场景2 撞车后新 ISN)
    localparam [63:0]  SEED     = 64'h9E3779B97F4A7C15;
    localparam integer BUFMAX   = 2048;

    reg clk, rst_n;
    integer errs;

    always #4 clk = ~clk;

    task chk;
        input        cond;
        input [255:0] name;
        begin
            if (cond) $display("  PASS %0s", name);
            else begin
                errs = errs + 1;
                $display("  FAIL %0s", name);
            end
        end
    endtask

    function integer pop8_tb;
        input [7:0] v;
        integer k;
        begin
            pop8_tb = 0;
            for (k = 0; k < 8; k = k + 1) pop8_tb = pop8_tb + v[k];
        end
    endfunction

    // ---------------- 图案 (与 app_pattern 逐位同源) ----------------
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

    reg [7:0] pat [0:TX_BYTES+16];
    integer   pi;
    reg [63:0] ps;
    initial begin
        ps = SEED;
        for (pi = 0; pi <= TX_BYTES + 15; pi = pi + 1) begin
            pat[pi] = ps[31:24];
            ps = xs_next(ps);
        end
    end

    // ---------------- 假 TCB (单连接 0) ----------------
    reg [31:0] tcb_snd_nxt, tcb_snd_una, tcb_rcv_nxt;
    reg [15:0] tcb_rcv_wnd, tcb_snd_wnd;
    reg [3:0]  tcb_state;
    reg        win_open_r;

    // ---------------- DUT ----------------
    reg         ev_up, ev_down;
    reg  [3:0]  ev_slot;
    reg  [15:0] app_tx_ready;

    wire [63:0] pat_tdata;
    wire [7:0]  pat_tkeep;
    wire        pat_tvalid, pat_tready, pat_tlast;
    wire [3:0]  pat_tid;
    wire        pat_close_req;
    wire [3:0]  pat_close_id;
    wire [31:0] pat_tx_bytes, pat_tx_frames, pat_rx_bytes, pat_mismatch;
    wire        pat_active, pat_done;
    wire [3:0]  pat_led;
    wire [31:0] pat_lfsr, pat_bad_frames;

    app_pattern #(
        .TX_BYTES(TX_BYTES), .TX_SEGSZ(SEGSZ), .AUTO_CLOSE(1'b0)
    ) u_app (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .m_tdata(pat_tdata), .m_tkeep(pat_tkeep), .m_tvalid(pat_tvalid),
        .m_tready(pat_tready), .m_tlast(pat_tlast), .m_tid(pat_tid),
        .app_tx_ready(app_tx_ready),
        .close_req(pat_close_req), .close_id(pat_close_id),
        .rx_tdata(64'd0), .rx_tkeep(8'd0), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_tid(4'd0),
        .i_bad_frame(16'd0),
        .stat_tx_bytes(pat_tx_bytes), .stat_tx_frames(pat_tx_frames),
        .stat_bad_frames(pat_bad_frames),
        .stat_rx_bytes(pat_rx_bytes), .stat_mismatch(pat_mismatch),
        .active(pat_active), .act_id(), .done(pat_done),
        .dbg_lfsr(pat_lfsr), .led(pat_led)
    );

    // app -> pipe (77b: {tkeep, tlast, tdata, tid})
    wire [76:0] app2_pack;
    wire        app2_tvalid, app2_tready;
    wire [7:0]  app2_tkeep;
    wire        app2_tlast;
    wire [63:0] app2_tdata;
    wire [3:0]  app2_tid;
    assign {app2_tkeep, app2_tlast, app2_tdata, app2_tid} = app2_pack;

    axis_pipe #(.W(77)) u_pipe (
        .clk(clk), .rst_n(rst_n),
        .s_data({pat_tkeep, pat_tlast, pat_tdata, pat_tid}),
        .s_valid(pat_tvalid), .s_ready(pat_tready),
        .m_data(app2_pack), .m_valid(app2_tvalid), .m_ready(app2_tready)
    );

    reg  [15:0] fin_req, rst_req;
    reg         cfg_up;
    reg  [3:0]  cfg_up_id;
    wire [15:0] o_fin_sent, o_rst_sent;

    wire [63:0] x_tdata;
    wire [7:0]  x_tkeep;
    wire        x_tvalid, x_tlast;
    wire        x_tready;
    wire [3:0]  x_tid;
    wire [2:0]  tx_dbg_state;   // 注意: tcp_tx_frame.dbg_state 是 3 位
    wire        upd_wr;
    wire [3:0]  upd_id;
    wire [2:0]  upd_sel;
    wire [31:0] upd_val;
    wire [31:0] stat_eend;

    tcp_tx_frame u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(app2_tdata), .s_axis_tkeep(app2_tkeep),
        .s_axis_tvalid(app2_tvalid), .s_axis_tready(app2_tready),
        .s_axis_tlast(app2_tlast), .s_axis_tid(app2_tid),
        .ack_req(1'b0), .ack_id(4'd0), .ack_val(32'd0), .ack_syn(1'b0),
        .ack_fin(1'b0), .ack_rst(1'b0),
        .fin_req(fin_req), .rst_req(rst_req),
        .cfg_up(cfg_up), .cfg_up_id(cfg_up_id),
        .o_fin_sent(o_fin_sent), .o_rst_sent(o_rst_sent),
        .wu_req(1'b0), .wu_id(4'd0), .wu_val(32'd0), .wu_gnt(),
        .rb_id(), .rb_snd_nxt(tcb_snd_nxt), .rb_rcv_nxt(tcb_rcv_nxt),
        .rb_rcv_wnd(tcb_rcv_wnd), .rb_snd_una(tcb_snd_una),
        .rb_snd_wnd(tcb_snd_wnd), .rb_state(tcb_state),
        .win_open(win_open_r), .win_inflight(16'd0), .win_wnd_eff(16'd0),
        .upd_wr(upd_wr), .upd_id(upd_id), .upd_sel(upd_sel), .upd_val(upd_val),
        .cam_rd_id(), .cam_rd_dmac(48'h000A3501FEC1), .cam_rd_sip(32'hC0A80102),
        .cam_rd_sport(16'd8080), .cam_rd_dport(16'd1234),
        .cfg_src_mac(48'h000A3501FEC0), .cfg_src_ip(32'hC0A80101),
        .m_axis_tdata(x_tdata), .m_axis_tkeep(x_tkeep), .m_axis_tvalid(x_tvalid),
        .m_axis_tready(x_tready), .m_axis_tlast(x_tlast),
        .stat_frames(), .stat_bytes(), .stat_ack(), .stat_ack_drop(),
        .stat_eend(stat_eend), .stat_drop_len(), .stat_fin(), .stat_rst(),
        .stat_tlast_in(),
        .retx_req(1'b0), .retx_id(4'd0), .retx_gnt(), .stat_retx(),
        .o_retx_hi(), .o_retx_active(), .o_retx_id(),
        .dbg_wnd_open(), .dbg_pay_full(), .dbg_sready(), .dbg_saxis_tvalid(),
        .dbg_plen_r(), .dbg_state(tx_dbg_state), .dbg_pay_wptr(), .dbg_pay_rptr(),
        .dbg_pay_full2(), .dbg_pay_empty(), .dbg_plen()
    );

    // TCB 更新 (upd_sel=1 => snd_nxt; 帧器 S_DONE 组合脉冲)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) win_open_r <= 1'b0;
        else        win_open_r <= ((tcb_snd_nxt - tcb_snd_una) < 32'h0000_BFFE);
    end
    always @(posedge clk) begin
        if (upd_wr && (upd_id == 4'd0) && (upd_sel == 3'd1)) tcb_snd_nxt <= upd_val;
    end

    assign x_tready = 1'b1;

    // ---- 线上帧解码 (MAC 字流: tdata[63:56] = 帧首字节; tkeep 高位有效) ----
    reg [7:0]  fbuf [0:BUFMAX-1];
    integer    flen;
    integer    fi, fj;
    integer    nfrm_tot;
    integer    n_payload;          // 全部会话载荷字节
    integer    n_wrong;            // 图案失配字节
    integer    sess_bytes [0:3];   // 逐会话载荷字节 (A/B/C/D)
    integer    sess_frm   [0:3];
    reg [31:0] sess_base  [0:3];
    reg [31:0] sess_first [0:3];   // 逐会话首个载荷字节 seq
    reg        sess_seen  [0:3];
    integer    cur_sess;
    integer    si;
    reg [31:0] f_seq;
    integer    f_plen;
    reg [7:0]  f_flags;
    reg [7:0]  resid_keep [0:1];   // 两次窄窗的滞留字 tkeep

    // 会话判定: seq 落在 [base, base+TX_BYTES) 内即为该会话
    function integer sess_of;
        input [31:0] s;
        begin
            sess_of = -1;
            for (si = 3; si >= 0; si = si - 1)
                if ((sess_of < 0) && (s >= sess_base[si]) &&
                    (s < sess_base[si] + TX_BYTES)) sess_of = si;
        end
    endfunction

    always @(posedge clk) begin
        if (x_tvalid && x_tready) begin
            for (fi = 0; fi < 8; fi = fi + 1) begin
                if (x_tkeep[7-fi] && (flen < BUFMAX)) begin
                    fbuf[flen] = x_tdata[63-8*fi -: 8];
                    flen = flen + 1;
                end
            end
            if (x_tlast) begin
                nfrm_tot = nfrm_tot + 1;
                if (flen >= 54) begin
                    f_seq   = {fbuf[38], fbuf[39], fbuf[40], fbuf[41]};
                    f_flags = fbuf[47];
                    f_plen  = flen - 54;
                    cur_sess = sess_of(f_seq);
                    $display("  FRM t=%0t seq=%08h plen=%0d flags=%02h sess=%0d",
                             $time, f_seq, f_plen, f_flags, cur_sess);
                    if (cur_sess >= 0) begin
                        sess_frm[cur_sess] = sess_frm[cur_sess] + 1;
                        if (f_plen > 0) begin
                            if (!sess_seen[cur_sess]) begin
                                sess_seen[cur_sess]  = 1;
                                sess_first[cur_sess] = f_seq;
                            end
                            for (fj = 0; fj < f_plen; fj = fj + 1) begin
                                n_payload = n_payload + 1;
                                sess_bytes[cur_sess] = sess_bytes[cur_sess] + 1;
                                if (fbuf[54+fj] !==
                                    pat[f_seq + fj - sess_base[cur_sess]])
                                    n_wrong = n_wrong + 1;
                            end
                        end
                    end else if (f_plen > 0) begin
                        // seq 不在任何已知会话区间 = 陈旧/错位帧 -> 一律记失配
                        n_payload = n_payload + f_plen;
                        n_wrong   = n_wrong + f_plen;
                        $display("  !! out-of-session frame: seq=%08h plen=%0d", f_seq, f_plen);
                    end
                end else begin
                    $display("  WARN: wire frame len %0d < 54", flen);
                end
                flen = 0;
            end
        end
    end

    // ---- 窄窗探针: pipe 有字 且 帧器在发上一帧 (非 S_RECV/S_IDLE) ----
    localparam [2:0] S_IDLE = 3'd0, S_RECV = 3'd1;
    wire narrow_win = u_pipe.m_valid &&
                      (tx_dbg_state != S_RECV) && (tx_dbg_state != S_IDLE);
    wire frac_ready = app2_tready;    // pipe.s_ready: 帧器在收 (m_ready) 或 pipe 空

    integer i, k;
    integer win_cyc;

    // 等待窄窗命中 (要求已见过 >=1 帧, 避免复位后的空 pipe 拍)
    task wait_win;
        input integer tag;
        begin
            k = 0;
            win_cyc = -1;
            for (i = 0; (i < 60000) && (win_cyc < 0); i = i + 1) begin
                @(negedge clk);
                if (narrow_win && (nfrm_tot >= 1)) win_cyc = i;
            end
            if (win_cyc >= 0) begin
                resid_keep[tag] = app2_tkeep;
                $display("WIN%d hit: fsm=%0d, pipe-residual tkeep=%02h (pop8=%0d)",
                         tag + 1, tx_dbg_state, app2_tkeep,
                         pop8_tb(app2_tkeep));
            end else begin
                chk(1'b0, "WIN hit (no pipe-residual + fsm-busy cycle found)");
            end
        end
    endtask

    task do_del_down;                     // DEL + ev_down (fence 活读门拉低)
        begin
            @(negedge clk);
            tcb_state = 4'd0;
            ev_down   = 1'b1;
            @(negedge clk);
            ev_down   = 1'b0;
        end
    endtask

    initial begin
        clk = 0; rst_n = 0;
        errs = 0;
        ev_up = 0; ev_down = 0; ev_slot = 4'd0;
        app_tx_ready = 16'd0;
        fin_req = 16'd0; rst_req = 16'd0; cfg_up = 0; cfg_up_id = 4'd0;
        tcb_snd_nxt = BASE_A; tcb_snd_una = BASE_A; tcb_rcv_nxt = 32'h0000_5001;
        tcb_rcv_wnd = 16'hC000; tcb_snd_wnd = 16'h4000;
        tcb_state = 4'd1;
        flen = 0; nfrm_tot = 0; n_payload = 0; n_wrong = 0;
        nfrm_tot = 0; win_cyc = 0;
        for (i = 0; i < 4; i = i + 1) begin
            sess_bytes[i] = 0; sess_frm[i] = 0; sess_seen[i] = 0;
            sess_first[i] = 32'd0;
        end
        sess_base[0] = BASE_A; sess_base[1] = BASE_B;
        sess_base[2] = BASE_C; sess_base[3] = BASE_D;
        resid_keep[0] = 8'h00; resid_keep[1] = 8'h00;

        repeat (20) @(negedge clk);
        rst_n = 1;
        repeat (10) @(negedge clk);

        // ================= 会话 A =================
        @(negedge clk);
        ev_slot = 4'd0;
        app_tx_ready = 16'h0001;
        ev_up = 1'b1;
        @(negedge clk);
        ev_up = 1'b0;

        // ================= 场景 1: DEL 后等旧帧发完再 ADD ======================
        // (真实重连间隔 = 对端 SYN 往返, 远大于旧帧残留的 ~195 拍; 此处"等帧器回
        //  S_IDLE"同一语义 —— 注意别在旧帧 S_DONE 之前 ADD: tcb.v 的 upd 口无守卫,
        //  旧帧 S_DONE 会把新会话的 snd_nxt 冲掉 (本 TB 如实照抄 tcb 语义 ⇒ 必须
        //  按真实时序避开, 这是独立于 opener 的一条既存缺陷, 见报告)。)
        wait_win(0);
        do_del_down;
        for (i = 0; (i < 60000) && (tx_dbg_state != S_IDLE); i = i + 1)
            @(negedge clk);
        repeat (5) @(negedge clk);
        $display("SC1 ADD cycle app: active=%b closing=%b pw_valid=%b op_pend=%b op_sent=%b seg_sent=%0d",
                 pat_active, u_app.closing, u_app.pw_valid, u_app.op_pend,
                 u_app.op_sent, u_app.seg_sent);
        @(negedge clk);
        tcb_state   = 4'd1;
        tcb_snd_nxt = BASE_B;
        tcb_snd_una = BASE_B;
        cfg_up      = 1'b1;
        cfg_up_id   = 4'd0;
        ev_up       = 1'b1;
        ev_slot     = 4'd0;
        @(negedge clk);
        cfg_up = 1'b0;
        ev_up  = 1'b0;

        // 等会话 B 跑完
        for (i = 0; i < 60000; i = i + 1) begin
            @(negedge clk);
            if (pat_done && !pat_active && (sess_bytes[1] >= TX_BYTES)) i = 60000;
        end
        repeat (200) @(negedge clk);
        $display("SC1 session B done: bytes %0d / frames %0d / first-seq %08h",
                 sess_bytes[1], sess_frm[1], sess_first[1]);

        // ================= 会话 C (场景 2 撞车角) =================
        @(negedge clk);
        tcb_state   = 4'd1;
        tcb_snd_nxt = BASE_C;
        tcb_snd_una = BASE_C;
        cfg_up      = 1'b1;
        cfg_up_id   = 4'd0;
        ev_up       = 1'b1;
        ev_slot     = 4'd0;
        @(negedge clk);
        cfg_up = 1'b0;
        ev_up  = 1'b0;

        wait_win(1);
        do_del_down;
        // 等帧器把上一帧发完 (回 S_IDLE; 此时 rb_state=0 ⇒ 它只等、不收)
        for (i = 0; (i < 60000) && (tx_dbg_state != S_IDLE); i = i + 1)
            @(negedge clk);
        repeat (5) @(negedge clk);
        // X 拍: 只写新 ISN + ESTAB (帧器下一拍就绪); X+1 拍: 换流脉冲撞车
        @(negedge clk);
        tcb_state   = 4'd1;            // 只写 ESTAB + 新 ISN: 帧器下一拍就绪
        tcb_snd_nxt = BASE_D;
        tcb_snd_una = BASE_D;
        @(negedge clk);
        $display("SC2 pre-ev_up cycle app: closing=%b pw_valid=%b op_sent=%b seg_sent=%0d (%s)",
                 u_app.closing, u_app.pw_valid, u_app.op_sent, u_app.seg_sent,
                 frac_ready ? "pipe-ready(accepting)" : "pipe-not-ready");
        cfg_up  = 1'b1;                // 换流脉冲比 state 写晚一拍 (真实 cfg 序列次序)
        cfg_up_id = 4'd0;
        ev_up   = 1'b1;
        ev_slot = 4'd0;
        @(negedge clk);
        cfg_up = 1'b0;
        ev_up  = 1'b0;
        repeat (3000) @(negedge clk);
        $display("  post-sc2+3000: act=%b opend=%b opsent=%b pwv=%b segsent=%0d seglen=%0d remain=%0d cls=%b fw=%b pmv=%b prdy=%b fsm=%0d",
                 pat_active, u_app.op_pend, u_app.op_sent, u_app.pw_valid,
                 u_app.seg_sent, u_app.seg_len, u_app.remain, u_app.closing,
                 u_app.frm_wait, u_pipe.m_valid, app2_tready, tx_dbg_state);

        // 等会话 C 跑完 (或超时)
        for (i = 0; i < 80000; i = i + 1) begin
            @(negedge clk);
            if (pat_done && !pat_active && (sess_bytes[3] >= TX_BYTES)) i = 80000;
        end
        repeat (200) @(negedge clk);

        // ---------------- 判据 ----------------
        $display("-----------------------------------------------");
        $display("residual tkeep: [1]=%02h [2]=%02h / wire frames %0d",
                 resid_keep[0], resid_keep[1], nfrm_tot);
        $display("B: %0d bytes/%0d frames/first-seq %08h | pre-DEL C: %0d bytes | D: %0d bytes/%0d frames/first-seq %08h",
                 sess_bytes[1], sess_frm[1], sess_first[1],
                 sess_bytes[2], sess_bytes[3], sess_frm[3], sess_first[3]);
        $display("payload %0d / mismatch %0d / app stat_tx_bytes=%0d stat_tx_frames=%0d",
                 n_payload, n_wrong, pat_tx_bytes, pat_tx_frames);
        $display("fsm stat_eend=%0d", stat_eend);
        $display("-----------------------------------------------");

        chk(pop8_tb(resid_keep[0]) == 0, "W0-1 narrow-window residual is 0-payload (opener)");
        chk(pop8_tb(resid_keep[1]) == 0, "W0-2 narrow-window residual is 0-payload (opener)");
        chk(sess_seen[1] && (sess_first[1] == BASE_B), "W1-1 session B first payload seq == new ISN");
        chk(sess_seen[3] && (sess_first[3] == BASE_D), "W1-2 session D first payload seq == new ISN (collision)");
        chk(n_wrong == 0, "W2 all payload bytes match pattern (zero cross-session leak)");
        chk(sess_bytes[1] == TX_BYTES, "W3-1 session B payload == TX_BYTES");
        chk(sess_bytes[3] == TX_BYTES, "W3-2 session D payload == TX_BYTES (collision)");
        chk(stat_eend == 0, "W4 no underrun frame end (stat_eend == 0)");

        if (errs == 0) $display("GATE tb_p5e_win: PASS");
        else           $display("GATE tb_p5e_win: FAIL (%0d)", errs);
        $finish;
    end

    initial begin
        #16000000;
        $display("TIMEOUT (sim did not converge)");
        $display("GATE tb_p5e_win: FAIL (timeout)");
        $finish;
    end

endmodule
