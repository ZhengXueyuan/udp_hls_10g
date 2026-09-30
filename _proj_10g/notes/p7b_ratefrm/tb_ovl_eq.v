`timescale 1ns/1ps
//=============================================================================
// tb_ovl_eq -- udp_tx_cfg + udp_tx_frame 的**默认/重叠两版逐字节等价**门
//=============================================================================
// 目的 (P7B_RATE_FRAMER 验证 1/2):
//   ① 同一激励下, 线上帧流**逐字节**落盘 (eq_frames.txt) ⇒ 两版 diff 必须为空
//   ② o_busy 逐拍序列落盘 (eq_busy.txt) + 事件表 (eq_events.txt) + 内建判据:
//        C5: 任一帧在飞窗口 [帧首接受拍+1, 本帧末字被消费拍] 内 busy 必须恒 1
//      (帧首接受那一拍本身允许 busy=0; 默认实现同样如此)
//   ③ 帧内容语义自检: 每帧 42+len 字节 / dst_mac 随 peer / 双校验和 / 载荷逐字节
//   ④ cfg 学习门: 帧内换 peer ⇒ 本帧仍用旧 peer (帧内稳定); 后续帧用新 peer
//   ⑤ 改 peer 引发的**门阻塞拍数** (cfg 刷新窗口的后果) 前后对照
//
// 激励 (固定拍流, 两版共用同一份 ⇒ 与实现无关):
//   A 孤立帧 (帧间 400 拍)   长度族 0/32/63/65/100/1471/1472/1500/1501(中止)/4096(中止)
//   B 背靠背 17×1472 + 4×100(间隔 3)    ← 重叠收益主战场
//   C 背靠背流中段换 peer (第 33 帧第 3 拍触发) + 之后 6×64
//   D 慢消费者 (tready 5 拍通 / 3 拍停) 下 8×1472 + 2×800
//=============================================================================
module tb_ovl_eq;
    localparam [47:0] MY_MAC    = 48'h000A3501FEC0;
    localparam [31:0] MY_IP     = 32'hC0A86402;
    localparam [15:0] MY_PORT   = 16'h1F91;
    localparam [15:0] DST_PORT  = 16'h1F91;
    localparam [47:0] PEER_A_MAC = 48'h112233445566;
    localparam [31:0] PEER_A_IP  = 32'hC0A86401;
    localparam [47:0] PEER_B_MAC = 48'hAABBCCDDEEFF;
    localparam [31:0] PEER_B_IP  = 32'hC0A8647F;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                 // 6.4 ns = 156.25 MHz

    integer cyc;                            // 全局拍号 (先声明后用, xvlog 铁律)
    integer errs = 0;
    integer checks = 0;
    task chk;
        input        cond;
        input [8*80:1] msg;
        begin
            checks = checks + 1;
            if (!cond) begin
                errs = errs + 1;
                $display("  [FAIL] %0s", msg);
            end
        end
    endtask

    //=========================================================================
    // 拍流队列 (两版共用; 帧长/间隔全部由本表决定)
    //=========================================================================
    localparam integer QMAX = 8192;
    localparam integer FMAX = 64;
    reg [63:0] q_data [0:QMAX];
    reg [7:0]  q_keep [0:QMAX];
    reg        q_last [0:QMAX];
    integer    q_gap  [0:QMAX];     // 本拍被接受后要空转的拍数 (帧末才非 0)
    integer    qn;
    integer    fq_qi  [0:FMAX];     // 第 k 帧首拍在队列里的下标
    integer    fq_len [0:FMAX];
    integer    nfrq;                // 队列里的帧数
    integer    exp_peer [0:FMAX];   // 0=A 1=B (本帧应使用的 peer)
    integer    exp_out  [0:FMAX];   // 1 = 期望上线 0 = 期望被守卫丢弃

    function [7:0] payb;
        input integer fidx;
        input integer i;
        begin
            payb = (i * 7 + 3 + fidx * 29) & 8'hFF;
        end
    endfunction

    task push_frame;
        input integer fidx;
        input integer len;
        input integer gap;
        input integer peer;
        input integer emout;
        integer k, j, nb, nby;
        reg [63:0] w;
        reg [7:0]  kp;
        begin
            fq_qi[fidx] = qn;
            fq_len[fidx] = len;
            exp_peer[fidx] = peer;
            exp_out[fidx]  = emout;
            nb = (len == 0) ? 1 : (len + 7) / 8;
            for (k = 0; k < nb; k = k + 1) begin
                w  = 64'd0;
                kp = 8'h00;
                nby = len - k * 8;
                if (nby > 8) nby = 8;
                for (j = 0; j < 8; j = j + 1) begin
                    if (j < nby) begin
                        w[63 - 8*j -: 8] = payb(fidx, k * 8 + j);
                        kp[7 - j]        = 1'b1;
                    end
                end
                q_data[qn] = w; q_keep[qn] = kp;
                q_last[qn] = (k == nb - 1);
                q_gap [qn] = (k == nb - 1) ? gap : 0;
                qn = qn + 1;
            end
            nfrq = nfrq + 1;
        end
    endtask

    integer i;
    task build_queue;
        begin
            qn = 0; nfrq = 0;
            // ---- A: 孤立帧 (间隔 400 拍 ⇒ 两版都不重叠) ----
            push_frame( 0,    0, 400, 0, 1);
            push_frame( 1,   32, 400, 0, 1);
            push_frame( 2,   63, 400, 0, 1);
            push_frame( 3,   65, 400, 0, 1);
            push_frame( 4,  100, 400, 0, 1);
            push_frame( 5, 1471, 400, 0, 1);
            push_frame( 6, 1472, 400, 0, 1);
            push_frame( 7, 1500, 400, 0, 1);
            push_frame( 8, 1501, 400, 0, 0);   // 中止 (守卫)
            push_frame( 9, 4096, 400, 0, 0);   // 中止 (守卫, >FIFO 2048B 路径)
            // ---- B: 背靠背 ----
            for (i = 10; i < 27; i = i + 1) push_frame(i, 1472, 0, 0, 1);
            for (i = 27; i < 31; i = i + 1) push_frame(i,  100, 3, 0, 1);
            // ---- C: 背靠背流中换 peer (触发 = 第 33 帧第 3 拍) ----
            push_frame(31,  64, 0, 0, 1);
            push_frame(32,  64, 0, 0, 1);
            push_frame(33,  64, 0, 0, 1);   // 换 peer 落在此帧中段
            push_frame(34,  64, 0, 1, 1);   // 门刷新后首帧 ⇒ 已用 B
            for (i = 35; i < 43; i = i + 1) push_frame(i,  64, 0, 1, 1);  // 换 B 之后
            // ---- D: 慢消费者 ----
            for (i = 43; i < 51; i = i + 1) push_frame(i, 1472, 0, 1, 1);
            for (i = 51; i < 53; i = i + 1) push_frame(i,  800, 0, 1, 1);
        end
    endtask

    //=========================================================================
    // 输入驱动 (寄存器化; 坑 3/17: 只用 posedge 采样值推进)
    //=========================================================================
    reg  [63:0] s_d;
    reg  [7:0]  s_k;
    reg         s_v, s_l;
    wire        s_r;
    integer     qi, gapc, acc_total;
    integer     cin_fr;                 // 已被接受的帧数 (帧首拍计)
    integer     SW_BEAT;                // 触发换 peer 的"累计被接受拍"号
    reg         peer_sw_done;

    reg         peer_wr;
    reg  [47:0] peer_mac;
    reg  [31:0] peer_ip;
    integer     sw_cyc, sw_next_frm;    // 换 peer 当拍 / 之后首个**帧首**被接受拍
    integer     deny_cyc, deny_cyc_sw;  // 门阻塞拍数 (总 / 换 peer 之后)
    reg         pw_a_req;               // 起始写 peer A 的请求 (initial → 时钟块握手)
    reg         deny_d;                 // 上一拍是否处于"帧首阻塞" (事件去重)

    integer     fbusy, ffrm, fevt;      // 轨迹文件句柄
    wire        utx_tready;             // 帧器的 s_axis_tready (先声明后用: 坑 22)

    always @(posedge clk) begin
        if (!rst_n) begin
            s_v <= 1'b0; s_d <= q_data[0]; s_k <= q_keep[0]; s_l <= q_last[0];
            qi <= 0; gapc <= 0; acc_total <= 0; cin_fr <= 0;
            peer_wr <= 1'b0; peer_mac <= 48'd0; peer_ip <= 32'd0;
            peer_sw_done <= 1'b0; sw_cyc <= -1; sw_next_frm <= -1;
            deny_cyc <= 0; deny_cyc_sw <= 0; deny_d <= 1'b0;
        end else begin
            peer_wr <= 1'b0;
            // ---- 起始: 注入 peer A (板上 = learn-on-RX; TB 侧显式注入) ----
            if (pw_a_req) begin
                pw_a_req <= 1'b0;
                peer_wr  <= 1'b1;
                peer_mac <= PEER_A_MAC;
                peer_ip  <= PEER_A_IP;
            end
            // ---- 门在帧首拍阻塞的拍数 (cfg 刷新窗口的后果) ----
            deny_d <= (s_v && !s_r && utx_tready && (cin_fr < nfrq) && (qi == fq_qi[cin_fr]));
            if (s_v && !s_r && utx_tready && (cin_fr < nfrq) && (qi == fq_qi[cin_fr])) begin
                deny_cyc <= deny_cyc + 1;
                if (peer_sw_done) deny_cyc_sw <= deny_cyc_sw + 1;
                if (fevt != 0 && !deny_d) $fwrite(fevt, "%0d D\n", cyc);
            end
            if (s_v && s_r) begin
                acc_total <= acc_total + 1;
                if (q_last[qi]) begin
                    // 帧末拍被接受 ⇒ 进入帧间隙 + 记帧首
                    s_v   <= 1'b0;
                    gapc  <= q_gap[qi];
                    qi    <= qi + 1;
                    cin_fr <= cin_fr + 1;
                    s_d   <= (qi + 1 < qn) ? q_data[qi+1] : 64'd0;
                    s_k   <= (qi + 1 < qn) ? q_keep[qi+1] : 8'h00;
                    s_l   <= (qi + 1 < qn) ? q_last[qi+1] : 1'b0;
                end else begin
                    qi  <= qi + 1;
                    s_d <= q_data[qi+1];
                    s_k <= q_keep[qi+1];
                    s_l <= q_last[qi+1];
                    s_v <= 1'b1;
                end
                if ((cin_fr < nfrq) && (qi == fq_qi[cin_fr])) begin
                    if (fevt != 0) $fwrite(fevt, "%0d A\n", cyc);
                    if (peer_sw_done && (sw_next_frm < 0)) sw_next_frm <= cyc;
                end
                if (!peer_sw_done && (acc_total == SW_BEAT)) begin
                    peer_sw_done  <= 1'b1;
                    peer_wr       <= 1'b1;      // 帧**中段**换 peer (最严苛窗口)
                    peer_mac      <= PEER_B_MAC;
                    peer_ip       <= PEER_B_IP;
                    sw_cyc        <= cyc;
                    if (fevt != 0) $fwrite(fevt, "%0d S\n", cyc);
                end
            end else if (!s_v) begin
                if (gapc != 0) begin
                    gapc <= gapc - 1;
                end else if (qi < qn) begin
                    s_v <= 1'b1;
                end
            end
        end
    end

    //=========================================================================
    // DUT 链: udp_tx_cfg → udp_tx_frame (与 wrapper APP_MODE 支同构)
    //=========================================================================
    wire        u_busy;
    wire [63:0] utx_tdata; wire [7:0] utx_tkeep;
    wire        utx_tvalid, utx_tlast;
    wire [47:0] cf_dmac, cf_smac;
    wire [31:0] cf_dip, cf_sip;
    wire [15:0] cf_dport, cf_sport;
    wire        cf_csum, cf_ready;
    wire [31:0] cf_frames, cf_deny;

    udp_tx_cfg u_cfg (
        .clk(clk), .rst_n(rst_n),
        .peer_wr(peer_wr), .peer_mac(peer_mac), .peer_ip(peer_ip),
        .frame_busy(u_busy),
        .cfg_my_mac(MY_MAC), .cfg_my_ip(MY_IP),
        .cfg_my_port(MY_PORT), .cfg_dst_port(DST_PORT), .cfg_csum_en(1'b1),
        .s_axis_tdata(s_d), .s_axis_tkeep(s_k),
        .s_axis_tvalid(s_v), .s_axis_tready(s_r), .s_axis_tlast(s_l),
        .m_axis_tdata(utx_tdata), .m_axis_tkeep(utx_tkeep),
        .m_axis_tvalid(utx_tvalid), .m_axis_tready(utx_tready), .m_axis_tlast(utx_tlast),
        .o_dst_mac(cf_dmac), .o_dst_ip(cf_dip), .o_dst_port(cf_dport),
        .o_src_mac(cf_smac), .o_src_ip(cf_sip), .o_src_port(cf_sport),
        .o_csum_en(cf_csum), .o_ready(cf_ready),
        .stat_frames(cf_frames), .stat_deny(cf_deny)
    );

    wire [63:0] m_tdata; wire [7:0] m_tkeep;
    wire        m_tvalid, m_tlast;
    reg         m_ready;
    wire [31:0] tx_frames, tx_bytes, tx_drop_len;

    udp_tx_frame u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(utx_tdata), .s_axis_tkeep(utx_tkeep),
        .s_axis_tvalid(utx_tvalid), .s_axis_tready(utx_tready), .s_axis_tlast(utx_tlast),
        .cfg_src_mac(cf_smac), .cfg_dst_mac(cf_dmac),
        .cfg_src_ip(cf_sip), .cfg_dst_ip(cf_dip),
        .cfg_src_port(cf_sport), .cfg_dst_port(cf_dport),
        .cfg_csum_en(cf_csum),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_ready), .m_axis_tlast(m_tlast),
        .stat_frames(tx_frames), .stat_bytes(tx_bytes), .stat_drop_len(tx_drop_len),
        .o_busy(u_busy)
    );

    //=========================================================================
    // 下游消费者: 阶段 D 用 "5 拍通 / 3 拍停" 的寄存器化 tready (最坏背压面)
    //=========================================================================
    reg  [2:0] cst;
    reg        slow_mode;
    always @(posedge clk) begin
        if (!rst_n) begin
            m_ready <= 1'b1; cst <= 3'd0;
        end else begin
            cst <= cst + 3'd1;
            m_ready <= (!slow_mode) ? 1'b1 : (cst < 3'd5);
        end
    end

    //=========================================================================
    // 帧捕获 / 逐拍 busy 轨迹 / 在飞窗口判据
    //=========================================================================
    localparam integer FB = 2048;
    reg [7:0]  fr [0:FMAX*FB-1];
    integer    fr_len [0:FMAX];
    integer    nfr, fcnt, bbi;
    integer    nin_first, nin_last, nout;  // 帧首拍 / 帧末拍被接受 / 末字被消费
    integer    viol_old, viol_new;         // 默认窗口 / 新窗口 的 busy 覆盖违反

    always @(posedge clk) begin
        if (!rst_n) begin
            cyc <= 0; nfr <= 0; fcnt <= 0; nin_first <= 0; nin_last <= 0; nout <= 0;
            viol_old <= 0; viol_new <= 0;
        end else begin
            cyc <= cyc + 1;
            // 帧首拍被接受 ⇒ 进入"新窗口"; 帧末拍被接受 ⇒ 进入"默认窗口"
            if (s_v && s_r && (cin_fr < nfrq) && (qi == fq_qi[cin_fr]) &&
                (exp_out[cin_fr] == 1)) nin_first <= nin_first + 1;
            if (s_v && s_r && s_l && (cin_fr < nfrq) && (exp_out[cin_fr] == 1))
                nin_last <= nin_last + 1;
            // C5-old: 默认实现的窗口 = [帧末拍接受+1, 末字消费] ⇒ 两版都必须成立
            if ((nin_last > nout) && (u_busy !== 1'b1)) begin
                viol_old <= viol_old + 1;
                $display("  [BUSY-GAP-OLD] cyc=%0d nin_last=%0d nout=%0d busy=%b",
                         cyc, nin_last, nout, u_busy);
            end
            // C5-new: 重叠实现的窗口 = [帧首拍接受+1, 末字消费] ⇒ 只作读数
            if ((nin_first > nout) && (u_busy !== 1'b1)) viol_new <= viol_new + 1;
            // 输出侧: 捕获字节 + 帧末
            if (m_tvalid && m_ready) begin
                for (bbi = 0; bbi < 8; bbi = bbi + 1) begin
                    if (m_tkeep[7-bbi] && (fcnt < FB - 1)) begin
                        fr[nfr*FB + fcnt] = m_tdata[63 - 8*bbi -: 8];
                        fcnt = fcnt + 1;
                    end
                end
                if (m_tlast) begin
                    fr_len[nfr] = fcnt;
                    nfr = nfr + 1;
                    fcnt = 0;
                    nout <= nout + 1;
                    if (fevt != 0) $fwrite(fevt, "%0d O\n", cyc);
                end
            end
            if (fbusy != 0) $fwrite(fbusy, "%b", u_busy);
        end
    end

    //=========================================================================
    // 帧语义自检 (解码线上帧; 期望值全部由 TB 自算)
    //=========================================================================
    integer    cbase;
    reg [31:0] csum_acc;
    task csum_add;
        input integer off;
        input integer nb;
        integer j;
        begin
            for (j = 0; j + 1 < nb; j = j + 2)
                csum_acc = csum_acc + {fr[cbase+off+j], fr[cbase+off+j+1]};
            if (nb % 2)
                csum_acc = csum_acc + {fr[cbase+off+nb-1], 8'h00};
        end
    endtask
    function [15:0] fold32;
        input [31:0] s;
        reg [16:0] t;
        begin
            t = s[15:0] + s[31:16];
            t = t[15:0] + t[16];
            fold32 = t[15:0];
        end
    endfunction

    integer k, ok_k, expk;
    reg [47:0] edmac;
    reg [31:0] edip;
    reg [15:0] u_len;

    initial begin
        errs = 0; checks = 0;
        slow_mode = 1'b0;
        rst_n = 1'b0;
        build_queue;
        SW_BEAT = fq_qi[33] + 2;      // 第 33 帧 (64B, 背靠背) 中段: 帧首后第 3 拍
        fbusy = 0; ffrm = 0; fevt = 0;
        pw_a_req = 1'b0;
        $display("TB_OVL_EQ: 队列 %0d 拍 / %0d 帧 / 期望上线 %0d 帧  SW_BEAT=%0d",
                 qn, nfrq, nfrq-2, SW_BEAT);
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
        @(negedge clk); pw_a_req = 1'b1;   // 注入 peer A (此后帧才能过门; negedge 定时)
        @(posedge clk);
`ifdef DUMP_TRACE
        fbusy = $fopen("eq_busy.txt", "w");
        ffrm  = $fopen("eq_frames.txt", "w");
        fevt  = $fopen("eq_events.txt", "w");
`endif
        // ---- 阶段 A/B/C 跑完 (到阶段 D 边界) ----
        for (i = 0; i < 4000000; i = i + 1) begin
            if (qi >= fq_qi[43]) i = 4000000;
            else @(posedge clk);
        end
        slow_mode = 1'b1;                          // 阶段 D: 慢消费者
        for (i = 0; i < 4000000; i = i + 1) begin
            if (qi >= qn) i = 4000000;
            else @(posedge clk);
        end
        slow_mode = 1'b0;
        repeat (2000) @(posedge clk);              // 静默尾窗
        if (fbusy != 0) $fclose(fbusy);

        $display("--- TB_OVL_EQ 读数 ---");
        $display("  ACCEPTED beats = %0d/%0d   frames queued = %0d  (accepted frames=%0d)",
                 qi, qn, nfrq, cin_fr);
        $display("  WIRE frames = %0d   utx stat_frames=%0d stat_bytes=%0d drop_len=%0d",
                 nfr, tx_frames, tx_bytes, tx_drop_len);
        $display("  cfg stat_frames=%0d  stat_deny=%0d  ready=%b",
                 cf_frames, cf_deny, cf_ready);
        $display("  BUSY VIOL old-window (默认窗口违反, 两版都必须 0) = %0d", viol_old);
        $display("  BUSY VIOL new-window (重叠窗口违反)                  = %0d", viol_new);
        $display("  DENY cycles total = %0d  (after peer switch = %0d)",
                 deny_cyc, deny_cyc_sw);
        $display("  PEER-SWITCH: cyc=%0d  之后首个帧首被接受拍=%0d  间隔=%0d 拍",
                 sw_cyc, sw_next_frm, sw_next_frm - sw_cyc);
        $display("  TOTAL CYCLES = %0d", cyc);

        // ---- 判据 ----
        chk(qi == qn,                    "全部拍流被接受 (无死锁/不卡 app)");
        chk(nfr == nfrq - 2,             "上线帧数 = 帧表 - 2 帧中止");
        chk(tx_frames == nfr,            "stat_frames = 上线帧数");
        chk(tx_drop_len == 32'd2,        "stat_drop_len = 2 (1501B + 4096B)");
        chk(viol_old == 0,               "C5-old: 默认窗口 [帧末拍+1,末字] 内 o_busy 恒 1");
`ifdef UDP_TX_OVL
        chk(viol_new == 0,               "C5-new: 重叠窗口 [帧首拍+1,末字] 内 o_busy 恒 1");
`endif

        // ---- 逐帧字段 ----
        cbase = 0; expk = 0;
        for (k = 0; k < nfrq; k = k + 1) begin
            if (exp_out[k] == 1) begin
                if (exp_peer[k] == 0) begin edmac = PEER_A_MAC; edip = PEER_A_IP; end
                else                  begin edmac = PEER_B_MAC; edip = PEER_B_IP; end
                cbase = expk * FB;
                ok_k = 1;
                if (fr_len[expk] != fq_len[k] + 42) begin
                    ok_k = 0;
                    $display("  [FAIL] 帧 %0d 长度 %0d != %0d+42", k, fr_len[expk], fq_len[k]);
                end
                if (fr[cbase+0] !== edmac[47:40] || fr[cbase+1] !== edmac[39:32] ||
                    fr[cbase+2] !== edmac[31:24] || fr[cbase+3] !== edmac[23:16] ||
                    fr[cbase+4] !== edmac[15:8]  || fr[cbase+5] !== edmac[7:0]) ok_k = 0;
                if (fr[cbase+6]  !== MY_MAC[47:40] || fr[cbase+7]  !== MY_MAC[39:32] ||
                    fr[cbase+8]  !== MY_MAC[31:24] || fr[cbase+9]  !== MY_MAC[23:16] ||
                    fr[cbase+10] !== MY_MAC[15:8]  || fr[cbase+11] !== MY_MAC[7:0]) ok_k = 0;
                if ({fr[cbase+12],fr[cbase+13]} !== 16'h0800) ok_k = 0;
                if (fr[cbase+23] !== 8'h11) ok_k = 0;
                if ({fr[cbase+16],fr[cbase+17]} !== (fq_len[k] + 28)) ok_k = 0;
                if ({fr[cbase+30],fr[cbase+31],fr[cbase+32],fr[cbase+33]} !== edip) ok_k = 0;
                if ({fr[cbase+26],fr[cbase+27],fr[cbase+28],fr[cbase+29]} !== MY_IP) ok_k = 0;
                if ({fr[cbase+34],fr[cbase+35]} !== MY_PORT) ok_k = 0;
                if ({fr[cbase+36],fr[cbase+37]} !== DST_PORT) ok_k = 0;
                u_len = {fr[cbase+38], fr[cbase+39]};
                if (u_len !== (fq_len[k] + 8)) ok_k = 0;
                csum_acc = 32'd0; csum_add(14, 20);
                if (fold32(csum_acc) !== 16'hFFFF) ok_k = 0;
                csum_acc = 32'd0;
                csum_add(26, 8);
                csum_acc = csum_acc + 16'h0011 + u_len;
                csum_add(34, 8 + fq_len[k]);
                if (fold32(csum_acc) !== 16'hFFFF) ok_k = 0;
                for (i = 0; i < fq_len[k]; i = i + 1)
                    if (fr[cbase+42+i] !== payb(k, i)) ok_k = 0;
                if (ok_k == 0) begin
                    errs = errs + 1;
                    $display("  [FAIL] 帧 %0d (线上第 %0d 帧, len=%0d) 字段/校验和/载荷不符",
                             k, expk, fq_len[k]);
                end
                expk = expk + 1;
            end
        end
        chk(expk == nfr, "逐帧字段检查帧数 = 上线帧数");

        // ---- 帧流落盘 (逐字节; 两版 diff 必须为空) ----
        if (ffrm != 0) begin
            for (k = 0; k < nfr; k = k + 1) begin
                $fwrite(ffrm, "%0d %0d ", k, fr_len[k]);
                for (i = 0; i < fr_len[k]; i = i + 1)
                    $fwrite(ffrm, "%02x", fr[k*FB + i]);
                $fwrite(ffrm, "\n");
            end
            $fclose(ffrm);
        end
        if (fevt != 0) $fclose(fevt);

        if (errs == 0) $display("OVL EQ GATE: OK (checks=%0d frames=%0d viol_old=%0d viol_new=%0d deny=%0d deny_sw=%0d sw_gap=%0d)",
                                checks, nfr, viol_old, viol_new, deny_cyc, deny_cyc_sw,
                                sw_next_frm - sw_cyc);
        else           $display("OVL EQ GATE: FAIL errs=%0d", errs);
        $finish;
    end
endmodule
