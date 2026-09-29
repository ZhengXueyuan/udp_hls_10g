`timescale 1ns/1ps
//=============================================================================
// tb_f4_chain.v -- F4 下游判别实验 (慢路径失聪假设检验)
//
// 链路 (与 wrapper 的单域形态同构): mac_rx_64 -> vlan_strip -> rx_classify
//        -> slow_rx_adp -> "HLS 模型" (字节流消费, 记每帧 tag + 字节数)
//        -> fast 侧监视器 (按 SOP/TLAST 分组, 记 tag + 词数 + 裸 SOP)
//
// 判据: 一次被 stall 打出的 MAC 截断事件 (F4(a)/(b)) 会让**几个**后续帧丢失/错路?
//   有界且立刻自愈 ⇒ 不能解释"慢路径失聪 ~20 分钟"(那需要无界/持久状态)。
// 帧标记: 净荷 byte20 = tag (慢侧: 前导 8 字节后第 21 字节; fast 侧: word2[31:24])。
// 附: CHAIN_CHECK keep2n(0) —— TERM 字 (tkeep=0) 若被 frame_fifo 播放, keep2n(8'h00)=1
//   会呈现"1 字节帧"; 本门统计 HLS 模型收到的 <60 字节帧数 (以太网最小净荷 60) 必须为 0,
//   以此把"TERM 靠下游 rollback 兜住"从隐性依赖变成**可判读数**。
// 触发帧 tag 取 10 的倍数 (10/20/30/40), 跟随帧 = 其后 6 个 (t+1..t+6)。
//=============================================================================
module tb_f4_chain;

    reg        clk = 0, rst_n = 0;
    reg [7:0]  rx_d;
    reg        rx_dv, rx_er;
    reg        plan_ready;
    wire       vlan_ready;
    wire       mac_ready = plan_ready && vlan_ready;
    reg [7:0]  sd [0:131071];
    reg [7:0]  sv [0:131071];
    reg [7:0]  se [0:131071];
    reg [7:0]  sw [0:131071];
    integer    nstim, i, fd, k;

    always #4 clk = ~clk;

    // ---------------- DUT 链 ----------------
    wire [63:0] m_tdata; wire [7:0] m_tkeep;
    wire        m_tvalid, m_tlast, m_tuser, m_tcrs, m_terr;
    wire [31:0] mac_frames, mac_crc, mac_drop, mac_bytes, mac_words;
    wire [31:0] mac_drop_full, mac_drop_partial, mac_orphan_bytes, mac_ovf;

`ifdef F4_NEWPORTS
    mac_rx_64 u_mac (
        .clk(clk), .rst_n(rst_n), .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(mac_ready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .m_axis_terr(m_terr), .m_axis_tcrs(m_tcrs),
        .stat_frames(mac_frames), .stat_crc_err(mac_crc), .stat_drop(mac_drop),
        .stat_bytes(mac_bytes), .dbg_stat_words_out(mac_words),
        .stat_drop_full(mac_drop_full), .stat_drop_partial(mac_drop_partial),
        .stat_orphan_bytes(mac_orphan_bytes), .stat_fifo_ovf(mac_ovf)
    );
`else
    mac_rx_64 u_mac (
        .clk(clk), .rst_n(rst_n), .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(mac_ready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .m_axis_terr(m_terr), .m_axis_tcrs(m_tcrs),
        .stat_frames(mac_frames), .stat_crc_err(mac_crc), .stat_drop(mac_drop),
        .stat_bytes(mac_bytes), .dbg_stat_words_out(mac_words)
    );
    assign mac_drop_full = 0; assign mac_drop_partial = 0;
    assign mac_orphan_bytes = 0; assign mac_ovf = 0;
`endif

    wire [63:0] v_tdata; wire [7:0] v_tkeep;
    wire        v_tvalid, v_tready, v_tlast, v_tuser, v_tcrs, v_terr;
    wire [31:0] v_stripped; wire v_dbg;
    vlan_strip u_vlan (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(m_tdata), .s_axis_tkeep(m_tkeep), .s_axis_tvalid(m_tvalid),
        .s_axis_tready(vlan_ready), .s_axis_tlast(m_tlast), .s_axis_tuser(m_tuser),
        .s_axis_tcrs(m_tcrs), .s_axis_terr(m_terr),
        .m_axis_tdata(v_tdata), .m_axis_tkeep(v_tkeep), .m_axis_tvalid(v_tvalid),
        .m_axis_tready(v_tready), .m_axis_tlast(v_tlast), .m_axis_tuser(v_tuser),
        .m_axis_tcrs(v_tcrs), .m_axis_terr(v_terr),
        .stat_stripped(v_stripped), .dbg_vlan(v_dbg)
    );

    wire [63:0] f_tdata; wire [7:0] f_tkeep;
    wire        f_tvalid, f_tready, f_tlast, f_tuser, f_tcrs, f_terr;
    wire [63:0] s_tdata; wire [7:0] s_tkeep;
    wire        s_tvalid, s_tready, s_tlast, s_tuser, s_tcrs, s_terr;
    wire [31:0] cls_fast, cls_slow, cls_win, cls_wout;
    assign f_tready = 1'b1;                 // fast 侧监视器: 永远收
    rx_classify u_cls (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(v_tdata), .s_axis_tkeep(v_tkeep), .s_axis_tvalid(v_tvalid),
        .s_axis_tready(v_tready), .s_axis_tlast(v_tlast), .s_axis_tuser(v_tuser),
        .s_axis_tcrs(v_tcrs), .s_axis_terr(v_terr),
        .m_fast_tdata(f_tdata), .m_fast_tkeep(f_tkeep), .m_fast_tvalid(f_tvalid),
        .m_fast_tready(f_tready), .m_fast_tlast(f_tlast), .m_fast_tuser(f_tuser),
        .m_fast_tcrs(f_tcrs), .m_fast_terr(f_terr),
        .m_slow_tdata(s_tdata), .m_slow_tkeep(s_tkeep), .m_slow_tvalid(s_tvalid),
        .m_slow_tready(s_tready), .m_slow_tlast(s_tlast), .m_slow_tuser(s_tuser),
        .m_slow_tcrs(s_tcrs), .m_slow_terr(s_terr),
        .stat_fast(cls_fast), .stat_slow(cls_slow),
        .dbg_stat_words_in(cls_win), .dbg_stat_words_out(cls_wout)
    );

    wire [15:0] h_tdata; wire h_tvalid, h_rstn;
    wire [31:0] sr_commit, sr_drop;
    wire [21:0] sr_starv; wire sr_rst;
    slow_rx_adp u_slow (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .hls_rx_tdata(h_tdata), .hls_rx_tvalid(h_tvalid), .hls_rx_tready(1'b1),
        .hls_rst_n(h_rstn), .stat_commit(sr_commit), .stat_drop(sr_drop),
        .dbg_starv(sr_starv), .dbg_hls_rst(sr_rst)
    );

    // ---------------- 交付记账 (按 tag) ----------------
    integer   dlv [0:255];       // 1=slow 2=fast, 0=未交付
    integer   dlvb [0:255];
    integer   nmiss, nmisr, nbare, nslow_fr, nfast_fr;
    integer   nf_trig_lost, nf_follow_lost, nf_follow_misr;
    integer   nshort_slow;

    // ---- 慢侧 (HLS 模型: 前导 8 字节后的字节流) ----
    integer sbcnt;               // 帧内字节序号 (0 起, 含前导)
    reg [7:0] stg;
    always @(posedge clk) begin
        if (h_tvalid) begin
            if (sbcnt >= 8 && (sbcnt - 8) == 20) stg = h_tdata[7:0];
            if (h_tdata[8]) begin
                if (stg != 8'hFF) begin
                    dlv[stg] = 1; dlvb[stg] = sbcnt - 7; nslow_fr = nslow_fr + 1;
                    // frame_fifo 的 keep2n(8'h00) 返回 1 ⇒ TERM 字一旦被**播放**就会呈现
                    // "1 字节帧"。以太网最小净荷 60 ⇒ 出现 <60 的帧 = TERM 被播出了 (兜漏)。
                    if ((sbcnt - 7) < 60) begin
                        nshort_slow = nshort_slow + 1;
                        $display("   SHORT_SLOW tag=%0d payload_bytes=%0d (<60: TERM 被播出?)",
                                 stg, sbcnt - 7);
                    end
                    $display("   SLOW_FRAME tag=%0d payload_bytes=%0d", stg, sbcnt - 7);
                end
                sbcnt = 0; stg = 8'hFF;
            end else sbcnt = sbcnt + 1;
        end
    end

    // ---- fast 侧 (词流; 帧内第 3 个词取 tag) ----
    integer fwc;
    reg [7:0] ftg;
    always @(posedge clk) begin
        if (f_tvalid) begin
            if (f_tuser) begin
                if (fwc != 0) begin
                    nbare = nbare + 1;
                    $display("   FAST_BARE_SOP prev_frames_words=%0d tag=%0d", fwc, ftg);
                end
                fwc = 0; ftg = 8'hFF;
            end
            if (fwc == 2) ftg = f_tdata[31:24];
            fwc = fwc + 1;
            if (f_tlast) begin
                if (ftg != 8'hFF) begin
                    dlv[ftg] = 2; dlvb[ftg] = fwc; nfast_fr = nfast_fr + 1;
                    $display("   FAST_FRAME tag=%0d words=%0d keep=%02h", ftg, fwc, f_tkeep);
                end
                fwc = 0; ftg = 8'hFF;
            end
        end
    end


    // ---- 事件轨迹 (调试: mac 丢帧/适配器丢帧那几拍) ----
    reg [31:0] mdropq, sdropq; integer nev = 0;
`ifdef F4_NEWPORTS
    wire dbg_term_pend = u_mac.term_pend;
`else
    wire dbg_term_pend = 1'b0;      // 修复前 RTL 无此信号
`endif
    always @(posedge clk) begin
        if (mac_drop !== mdropq) begin
            if (nev < 40)
                $display("   [MAC_DROP] t=%0t i=%0d plan_ready=%0d dv=%0d st=%0d wptr=%0d rptr=%0d first_done=%0d term_pend=%0d dpart=%0d",
                         $time, i, plan_ready, rx_dv, u_mac.state, u_mac.u_fifo.wptr,
                         u_mac.u_fifo.rptr, u_mac.first_done, dbg_term_pend, mac_drop_partial);
            nev = nev + 1; mdropq = mac_drop;
        end
        if (sr_drop !== sdropq) begin
            if (nev < 60) $display("   [ADP_DROP] t=%0t sr_commit=%0d sr_drop=%0d", $time, sr_commit, sr_drop);
            nev = nev + 1; sdropq = sr_drop;
        end
    end

    // ---------------- 帧表 + 汇总 ----------------
    integer nframe;
    integer ttag [0:255], tpay [0:255], troute [0:255];   // troute: 1=SLOW 2=FAST
    integer tkind, tidx;
    integer fi, is_trig;
    integer f_lost [0:63], f_misr [0:63], f_first_lost [0:63], ntrig;

    initial begin
        clk = 0; rst_n = 0; rx_d = 8'h07; rx_dv = 0; rx_er = 0; plan_ready = 1;
        i = 0; nstim = 0;
        for (k = 0; k < 256; k = k + 1) begin dlv[k] = 0; dlvb[k] = 0; end
        sbcnt = 0; stg = 8'hFF; fwc = 0; ftg = 8'hFF;
        nmiss=0; nmisr=0; nbare=0; nslow_fr=0; nfast_fr=0;
        nf_trig_lost=0; nf_follow_lost=0; nf_follow_misr=0; ntrig=0; nshort_slow=0;
        $readmemh("f5_data.memh", sd);
        $readmemh("f5_dv.memh",   sv);
        $readmemh("f5_er.memh",   se);
        $readmemh("f5_wr.memh",   sw);
        while (nstim < 131072 && sd[nstim] !== 8'hxx) nstim = nstim + 1;
        fd = $fopen("f5_frames.txt", "r");
        nframe = 0;
        while (!$feof(fd) && nframe < 256) begin
            // 行格式: tag kind pay_bytes stim_idx route   (全数字, 免字符串解析歧义)
            if ($fscanf(fd, "%d %d %d %d %d\n", ttag[nframe], tkind, tpay[nframe],
                        tidx, troute[nframe]) == 5)
                nframe = nframe + 1;
        end
        $fclose(fd);
        $display("F4CHAIN TB: nstim=%0d nframe=%0d", nstim, nframe);

        repeat (25) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);
        wait (i >= nstim);
        repeat (2500) @(posedge clk);     // 排空 (慢侧字节播放: 1 字节/拍)
        $display("--- MAC: frames=%0d bytes=%0d drop=%0d (full=%0d partial=%0d orphanB=%0d ovf=%0d) words_out=%0d",
                 mac_frames, mac_bytes, mac_drop, mac_drop_full, mac_drop_partial,
                 mac_orphan_bytes, mac_ovf, mac_words);
        $display("--- SLOW: commit=%0d drop=%0d frames_seen=%0d | FAST frames_seen=%0d | cls_fast=%0d cls_slow=%0d",
                 sr_commit, sr_drop, nslow_fr, nfast_fr, cls_fast, cls_slow);

        for (fi = 0; fi < nframe; fi = fi + 1) begin
            is_trig = (ttag[fi] % 10) == 0;
            if (dlv[ttag[fi]] == 0) begin
                nmiss = nmiss + 1;
                if (is_trig) begin
                    nf_trig_lost = nf_trig_lost + 1;
                    $display("   TRIGGER tag=%0d LOST (期望被 MAC 层截断)", ttag[fi]);
                end else begin
                    nf_follow_lost = nf_follow_lost + 1;
                    $display("   FOLLOW tag=%0d LOST (期望路=%0d pay=%0d)", ttag[fi],
                             troute[fi], tpay[fi]);
                end
            end else if (dlv[ttag[fi]] != troute[fi]) begin
                nmisr = nmisr + 1;
                if (is_trig) $display("   TRIGGER tag=%0d 交付路=%0d (期望 %0d)",
                                      ttag[fi], dlv[ttag[fi]], troute[fi]);
                else begin
                    nf_follow_misr = nf_follow_misr + 1;
                    $display("   FOLLOW tag=%0d MISROUTE 交付路=%0d 期望=%0d", ttag[fi],
                             dlv[ttag[fi]], troute[fi]);
                end
            end else if (dlv[ttag[fi]] == 1 && dlvb[ttag[fi]] != tpay[fi]) begin
                $display("   FOLLOW tag=%0d SLOW 字节数=%0d 期望=%0d", ttag[fi],
                         dlvb[ttag[fi]], tpay[fi]);
            end else if (dlv[ttag[fi]] == 2 && dlvb[ttag[fi]] != (tpay[fi]+7)/8) begin
                $display("   FOLLOW tag=%0d FAST 词数=%0d 期望=%0d", ttag[fi],
                         dlvb[ttag[fi]], (tpay[fi]+7)/8);
            end
        end
        $display("CHAIN_SUMMARY frames=%0d trigger_lost=%0d follow_lost=%0d follow_misroute=%0d bare_sop=%0d slow_seen=%0d fast_seen=%0d short_slow=%0d",
                 nframe, nf_trig_lost, nf_follow_lost, nf_follow_misr, nbare,
                 nslow_fr, nfast_fr, nshort_slow);
        $display("CHAIN_CHECK keep2n(0): HLS 模型收到 <60 字节的帧 = %0d (必须 0: TERM 被下游 rollback 兜住, 不得被播出)", nshort_slow);
        $display("F4CHAIN_DONE");
        $finish;
    end

    // ---- 时钟化驱动 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            i <= 0; rx_d <= 8'h07; rx_dv <= 0; rx_er <= 0; plan_ready <= 1;
        end else if (i < nstim) begin
            rx_d  <= sd[i];
            rx_dv <= sv[i][0];
            rx_er <= se[i][0];
            plan_ready <= sw[i][0];
            i <= i + 1;
        end else begin
            rx_dv <= 0; rx_er <= 0; plan_ready <= 1;
        end
    end
endmodule
