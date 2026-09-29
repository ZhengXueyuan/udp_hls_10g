`timescale 1ns/1ps
//=============================================================================
// tb_mac_rx_f4.v -- mac_rx_64 FIFO 溢出/截断角落门 (F4 a/b) + 守恒律门
//
// 覆盖:
//   F4(a) 帧中丢帧 -> 已推字变孤儿字 (有 popc 无 TLAST)
//   F4(b) 帧尾决策拍读 full=0, 同拍在飞写把 FIFO 顶满 -> 下一拍 TLAST 字被静默丢弃
// 判据 (见表尾 CHECK):
//   L1 #好帧(TLAST keep!=0) == Dstat_frames
//   L2 Sum popc(全部交付字) == Dstat_bytes - 4*Dstat_frames + Dstat_orphan_bytes
//   L3 #终止帧(TLAST keep==0) == Dstat_drop_partial
//   L4 无裸 SOP (前帧未收 TLAST 又来 SOP) == 0            <- "不留裸尾巴"的结构判据
//      ⚠️ 条件式: 消费者只要在某个 SOP 之后**还接受过 >=1 个字**, 该 SOP 必被 TERM/
//      真 TLAST 收尾; 唯一例外 = 消费者自该 SOP 起**永久不排空** (见 rtl/mac_rx_64.v §4)。
//      本门每例末都有 400 拍排空 ⇒ 判据在本门内无条件成立; 停摆那一幕由
//      sim/f4chain 的 CHAIN_CHECK 与 §4 的实测读数记录。
//   L5 Dstat_fifo_ovf == 0 (fifo_sync 从未拒写 => 无静默丢失)
//   L6 Dstat_drop_partial <= Dstat_drop_full <= Dstat_drop
//   L7 #SOP 帧 == #好帧 + #终止帧
//   L9 每个 TERM 字 (keep==0 的 TLAST) 必须 tcrs==0 且 terr==1
//      —— 下游 (slow_rx_adp.v:80 / tcp_rx.v:354) 按 `!tcrs||terr` 整帧回卷, 这条**标志
//      契约必须在本层判死**, 不得让"靠下游兜"变成隐性依赖 (变异体 mutcrs 专测这条)。
// 另有 A/B 门 (tools/f4_ab_check.py, sim/f4sim/run_f4_ab.bat): **好帧不被白丢** ——
//   任何激励下 NEW 的 DP_good/DP_goodbytes 不得低于修复前 (F4-2 缺陷就是被它抓到的)。
// 编译: 新端口 (stat_drop_full/partial/orphan_bytes/fifo_ovf) 用 +define+F4_NEWPORTS 打开。
//   未定义 = 旧 RTL (修复前) —— 新计数恒 0, L1/L3/L5 必然 FAIL (变异对照用同一 TB)。
//
// 驱动: 全部时钟化非阻塞 (无 TB/DUT 竞争, 见 PORT_NOTES 坑 3/17); tready 按字节索引查
//   f4_wr.memh (与字节流同源索引, 确定性)。
//=============================================================================
module tb_mac_rx_f4;

    reg        clk = 0, rst_n = 0;
    reg [7:0]  rx_d;
    reg        rx_dv, rx_er;
    reg        tready;
    reg [7:0]  stim_d [0:131071];
    reg [7:0]  stim_v [0:131071];
    reg [7:0]  stim_e [0:131071];
    reg [7:0]  stim_w [0:131071];
    integer    nstim;
    integer    i;
    integer    fd;
    integer    trace_ev;
    reg        nodrain;    // +NODRAIN: 激励结束后仍不给 tready (观察停摆终态)

    wire [63:0] tdata;  wire [7:0] tkeep;
    wire        tvalid, tlast, tuser, terr, tcrs;
    wire [31:0] stat_frames, stat_crc_err, stat_drop, stat_bytes, dbg_words;
    wire [31:0] stat_drop_full, stat_drop_partial, stat_orphan_bytes, stat_fifo_ovf;

`ifdef F4_NEWPORTS
    mac_rx_64 dut (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(tdata), .m_axis_tkeep(tkeep), .m_axis_tvalid(tvalid),
        .m_axis_tready(tready), .m_axis_tlast(tlast), .m_axis_tuser(tuser),
        .m_axis_terr(terr), .m_axis_tcrs(tcrs),
        .stat_frames(stat_frames), .stat_crc_err(stat_crc_err),
        .stat_drop(stat_drop), .stat_bytes(stat_bytes),
        .dbg_stat_words_out(dbg_words),
        .stat_drop_full(stat_drop_full), .stat_drop_partial(stat_drop_partial),
        .stat_orphan_bytes(stat_orphan_bytes), .stat_fifo_ovf(stat_fifo_ovf)
    );
`else
    // 修复前的 RTL: 无新端口 -> 计数按 0 参与判据 (门必然 FAIL, 正是变异对照要的)
    mac_rx_64 dut (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(tdata), .m_axis_tkeep(tkeep), .m_axis_tvalid(tvalid),
        .m_axis_tready(tready), .m_axis_tlast(tlast), .m_axis_tuser(tuser),
        .m_axis_terr(terr), .m_axis_tcrs(tcrs),
        .stat_frames(stat_frames), .stat_crc_err(stat_crc_err),
        .stat_drop(stat_drop), .stat_bytes(stat_bytes),
        .dbg_stat_words_out(dbg_words)
    );
    assign stat_drop_full     = 32'd0;
    assign stat_drop_partial  = 32'd0;
    assign stat_orphan_bytes  = 32'd0;
    assign stat_fifo_ovf      = 32'd0;
`endif

    always #4 clk = ~clk;      // 125 MHz

    // ---------------- 交付流观测 (m_axis 握手) ----------------
    integer dp_words, dp_popc, dp_sop, dp_good, dp_term, dp_good_bytes, dp_term_bytes;
    integer dp_bare_sop, dp_stray, dp_last_words, dp_term_badflag;
    integer open_frame;        // 已收 SOP 未收 TLAST
    integer cur_popc;
    function integer pc; input [7:0] kb; integer j; begin
        pc = 0; for (j = 0; j < 8; j = j + 1) pc = pc + kb[j];
    end endfunction

    always @(posedge clk) begin
        if (tvalid && tready) begin
            dp_words = dp_words + 1;
            dp_popc  = dp_popc + pc(tkeep);
            if (tuser) begin
                if (open_frame) begin
                    dp_bare_sop = dp_bare_sop + 1;
                    $display("   [BARE-SOP] t=%0t prev frame had no TLAST (orphan run) cur_popc=%0d",
                             $time, cur_popc);
                end
                dp_sop = dp_sop + 1; open_frame = 1; cur_popc = pc(tkeep);
            end else if (!open_frame) begin
                dp_stray = dp_stray + 1;         // 帧外字 (无 SOP 领)
                cur_popc = cur_popc + pc(tkeep);
            end else begin
                cur_popc = cur_popc + pc(tkeep);
            end
            if (tlast) begin
                if (!open_frame) dp_stray = dp_stray + 1;
                if (tkeep != 8'd0) begin
                    dp_good = dp_good + 1; dp_good_bytes = dp_good_bytes + cur_popc;
                    if (!tkeep[7]) $display("   [WARN] good frame TLAST keep[7]=0 keep=%02h", tkeep);
                end else begin
                    dp_term = dp_term + 1; dp_term_bytes = dp_term_bytes + cur_popc;
                    // TERM 字的**标志契约** (下游 (slow_rx_adp.v:80/tcp_rx.v:354) 按
                    // `!tcrs||terr` 判坏帧整帧回卷 ⇒ TERM 必须自带 tcrs=0 + terr=1。
                    // 这条契约必须在本层就判, 不得让"靠下游兜"变成隐性依赖。
                    if (!(tcrs === 1'b0 && terr === 1'b1)) begin
                        dp_term_badflag = dp_term_badflag + 1;
                        $display("   [TERM-BADFLAG] t=%0t keep=0 的 TLAST 字 tcrs=%b terr=%b (必须 0/1)",
                                 $time, tcrs, terr);
                    end
                end
                dp_last_words = dp_last_words + 1;
                open_frame = 0; cur_popc = 0;
            end
        end
    end

    // ---------------- 事件轨迹 (原始读数: 丢帧/终止发生的那几拍) ----------------
    reg [31:0] drop_q, term_q, ovf_q;
`ifdef F4_NEWPORTS
    wire dbg_full_next = dut.fifo_full_next;   // 修复后的精确满预测 (旧 RTL 无此信号)
    wire dbg_term_pend = dut.term_pend;
`else
    wire dbg_full_next = 1'b0;
    wire dbg_term_pend = 1'b0;
`endif
    always @(posedge clk) begin
        if (stat_drop !== drop_q) begin
            if (trace_ev < 400)
                $display("   [drop]  t=%0t state=%0d fbytes=%0d bcnt=%0d hwv=%0d first_done=%0d full=%0d full_next=%0d wptr=%0d rptr=%0d | stat_drop=%0d frames=%0d bytes=%0d dpart=%0d",
                         $time, dut.state, dut.fbytes, dut.bcnt, dut.hwv, dut.first_done,
                         dut.fifo_full, dbg_full_next, dut.u_fifo.wptr, dut.u_fifo.rptr,
                         stat_drop, stat_frames, stat_bytes, stat_drop_partial);
            trace_ev = trace_ev + 1;
            drop_q = stat_drop;
        end
        if (stat_drop_partial !== term_q) begin
            if (trace_ev < 400)
                $display("   [partial] t=%0t 帧被丢且已推过字 (孤儿) first_done=%0d fbytes=%0d state=%0d stat_drop_partial=%0d",
                         $time, dut.first_done, dut.fbytes, dut.state, stat_drop_partial);
            trace_ev = trace_ev + 1;
            term_q = stat_drop_partial;
        end
        if (stat_fifo_ovf !== ovf_q) begin
            $display("   [FIFO-OVF] t=%0t fifo_sync 拒写 = 静默丢失! stat_fifo_ovf=%0d",
                     $time, stat_fifo_ovf);
            ovf_q = stat_fifo_ovf;
        end
    end

`ifdef F4_STTRACE
    // 状态迁移轨迹 (调试用; -d F4_STTRACE 打开, 只印前 80 条)
    reg [2:0] st_q = 3'd0;
    integer st_n = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.state !== st_q) begin
                if (st_n < 80)
                    $display("   [st] t=%0t %0d->%0d fbytes=%0d bcnt=%0d dv=%0d d=%02h pre=%0d hwv=%0d",
                             $time, st_q, dut.state, dut.fbytes, dut.bcnt, rx_dv, rx_d,
                             dut.pre_cnt, dut.hwv);
                st_n = st_n + 1;
            end
            st_q <= dut.state;
        end
    end
`endif

`ifdef F4_STTRACE
    // 短帧帧尾决策拍轨迹 (定位 C=0/C=1 那一支)
    always @(posedge clk) begin
        if (rst_n && dut.state == 3'd2 && !rx_dv && dut.fbytes < 32)
            $display("   [FE] t=%0t fbytes=%0d bcnt=%0d hwv=%0d first_done=%0d full=%0d full_next=%0d term_pend=%0d fpushed=%0d",
                     $time, dut.fbytes, dut.bcnt, dut.hwv, dut.first_done, dut.fifo_full,
                     dbg_full_next, dut.term_pend, dut.fpushed);
    end
`endif
    // ---------------- 例表 ----------------
    integer ncase;
    reg  [8*32-1:0] cname [0:255];
    integer c_i0 [0:255], c_i1 [0:255], c_sf [0:255], c_st [0:255];
    integer c_nf [0:255], c_pb [0:255];
    integer ci;
    integer k;
    integer sf0, w0p, b0p, f0p, d0p, dp0, pc0, g0, t0, bs0, o0, fp0, of0, df0, pw0, tb0;
    integer fail_n;
    integer fd_ab;
    // 判据计票 (每个判据的 通过/总数) —— 例数很多时保持日志可读
    integer ck_p [0:8], ck_t [0:8];
    integer gb0;

    task snap; begin
        sf0 = stat_frames; w0p = stat_bytes; b0p = stat_crc_err; f0p = stat_drop;
        dp0 = dp_words; pc0 = dp_popc; g0 = dp_good; t0 = dp_term;
        bs0 = dp_bare_sop; o0 = dp_sop; fp0 = stat_drop_full; of0 = stat_fifo_ovf;
        df0 = stat_drop_partial; pw0 = stat_orphan_bytes; tb0 = dp_term_bytes;
        gb0 = dp_good_bytes;
    end endtask

    // 判据计票: idx 0..7 = L1..L8; 只在 FAIL 时打印细节, 末尾给 PASS (n/N)
    task chk; input integer idx; input [8*40-1:0] tag; input cond; begin
        ck_t[idx] = ck_t[idx] + 1;
        if (cond) ck_p[idx] = ck_p[idx] + 1;
        else begin
            fail_n = fail_n + 1;
            $display("   CHK %0s : FAIL (%0s)", tag, cname[ci]);
        end
    end endtask

    initial begin
        clk = 0; rst_n = 0; rx_d = 8'h07; rx_dv = 0; rx_er = 0; tready = 1;
        i = 0; nstim = 0; trace_ev = 0; fail_n = 0; nodrain = $test$plusargs("NODRAIN");
        dp_words=0; dp_popc=0; dp_sop=0; dp_good=0; dp_term=0; dp_good_bytes=0;
        dp_term_bytes=0; dp_bare_sop=0; dp_stray=0; dp_last_words=0; dp_term_badflag=0;
        open_frame=0; cur_popc=0;
        drop_q=0; term_q=0; ovf_q=0;
        $readmemh("f4_data.memh", stim_d);
        $readmemh("f4_dv.memh",   stim_v);
        $readmemh("f4_er.memh",   stim_e);
        $readmemh("f4_wr.memh",   stim_w);
        while (nstim < 131072 && stim_d[nstim] !== 8'hxx) nstim = nstim + 1;
        fd_ab = $fopen("f4_case_stats.txt", "w");
        for (k = 0; k < 9; k = k + 1) begin ck_p[k] = 0; ck_t[k] = 0; end
        fd = $fopen("f4_cases.txt", "r");
        if (fd == 0) begin $display("F4_GATE: FAIL (f4_cases.txt 打不开)"); $finish; end
        ncase = 0;
        while (!$feof(fd) && ncase < 256) begin
            if ($fscanf(fd, "%s %d %d %d %d %d %d\n", cname[ncase], c_i0[ncase],
                        c_i1[ncase], c_sf[ncase], c_st[ncase], c_nf[ncase],
                        c_pb[ncase]) == 7)
                ncase = ncase + 1;
        end
        $fclose(fd);
        $display("F4 TB: nstim=%0d ncase=%0d", nstim, ncase);

        repeat (25) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);
        snap;
        ci = 0;

        while (ci < ncase) begin
            @(posedge clk);
            if (i == c_i1[ci] && (ci == ncase-1) && !nodrain) begin
                // 常规档末例 (nodrain): 观察点延到排空之后 (见下方 last-case 判据), 这里只推进
                ci = ci + 1;
            end else if (i == c_i1[ci]) begin
                // ---- 例末判据 ----
                $display("CASE %0s : FE dF=%0d dB=%0d dCRC=%0d dDROP=%0d dDropFull=%0d dPartial=%0d dOrphanB=%0d dOvf=%0d | DP dWords=%0d dPopc=%0d dSOP=%0d dGood=%0d dTerm=%0d dTermB=%0d dBareSOP=%0d dStray=%0d",
                         cname[ci], stat_frames-sf0, stat_bytes-w0p, stat_crc_err-b0p,
                         stat_drop-f0p, stat_drop_full-fp0, stat_drop_partial-df0,
                         stat_orphan_bytes-pw0, stat_fifo_ovf-of0,
                         dp_words-dp0, dp_popc-pc0, dp_sop-o0, dp_good-g0, dp_term-t0,
                         dp_term_bytes-tb0, dp_bare_sop-bs0, dp_stray);
                // (TERM 标志契约计数在 L9/G9 判据里)
                // A/B 统计行 (给 tools/f4_ab_check.py: "好帧不被白丢" 判据用)
                $fwrite(fd_ab, "STAT %0s %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                        cname[ci], stat_frames-sf0, stat_bytes-w0p, stat_drop-f0p,
                        stat_drop_full-fp0, stat_drop_partial-df0,
                        stat_orphan_bytes-pw0, stat_fifo_ovf-of0,
                        dp_words-dp0, dp_popc-pc0, dp_sop-o0, dp_good-g0,
                        dp_good_bytes-gb0, dp_term-t0, dp_bare_sop-bs0);
                chk(0, "L1 good_frames==dFrames",
                    (dp_good-g0) == (stat_frames-sf0));
                chk(1, "L2 popc==dBytes-4*dFrames+dOrphanB",
                    (dp_popc-pc0) == ((stat_bytes-w0p) - 4*(stat_frames-sf0)
                                      + (stat_orphan_bytes-pw0)));
                chk(2, "L3 term_frames==dPartial",
                    (dp_term-t0) == (stat_drop_partial-df0));
                chk(3, "L4 bare_sop==0", (dp_bare_sop-bs0) == 0);
                chk(4, "L5 fifo_ovf==0", (stat_fifo_ovf-of0) == 0);
                chk(5, "L6 dPartial<=dDropFull<=dDrop",
                    ((stat_drop_partial-df0) <= (stat_drop_full-fp0)) &&
                    ((stat_drop_full-fp0) <= (stat_drop-f0p)));
                chk(6, "L7 sop_frames==good+term",
                    (dp_sop-o0) == ((dp_good-g0) + (dp_term-t0)));
                chk(7, "L8 stray_words==0", (dp_stray) == 0);
                chk(8, "L9 TERM_flag(tcrs=0,terr=1)", (dp_term_badflag) == 0);
                snap;
                ci = ci + 1;
            end
        end

        // ---- 尾部排空 + 全局判据 (计数器与交付流的最终对账) ----
        repeat (600) @(posedge clk);
        // 常规档: 末例 (nodrain) 的判据在这里判 (它的观察点在排空之后; +NODRAIN 档在上面的循环里判)
        if (!nodrain) begin
            $display("CASE(last,nodrain,排空后) : FE dF=%0d dB=%0d dDROP=%0d dPartial=%0d dOrphanB=%0d | DP dGood=%0d dTerm=%0d dBareSOP=%0d",
                     stat_frames-sf0, stat_bytes-w0p, stat_drop-f0p, stat_drop_partial-df0,
                     stat_orphan_bytes-pw0, dp_good-g0, dp_term-t0, dp_bare_sop-bs0);
            chk(0, "L1 good_frames==dFrames", (dp_good-g0) == (stat_frames-sf0));
            chk(1, "L2 popc==dBytes-4*dFrames+dOrphanB",
                (dp_popc-pc0) == ((stat_bytes-w0p) - 4*(stat_frames-sf0)
                                  + (stat_orphan_bytes-pw0)));
            chk(2, "L3 term_frames==dPartial", (dp_term-t0) == (stat_drop_partial-df0));
            chk(3, "L4 bare_sop==0", (dp_bare_sop-bs0) == 0);
            chk(6, "L7 sop_frames==good+term", (dp_sop-o0) == ((dp_good-g0) + (dp_term-t0)));
        end
        $display("TOTAL: dWords=%0d dPopc=%0d dSOP=%0d dGood=%0d dTerm=%0d dTermBadFlag=%0d dBareSOP=%0d | F=%0d B=%0d DROP=%0d DropFull=%0d Partial=%0d OrphanB=%0d OVF=%0d WORDS_OUT=%0d",
                 dp_words, dp_popc, dp_sop, dp_good, dp_term, dp_term_badflag,
                 dp_bare_sop,
                 stat_frames, stat_bytes, stat_drop, stat_drop_full,
                 stat_drop_partial, stat_orphan_bytes, stat_fifo_ovf, dbg_words);
        chk(0, "G1 words_out_counter==observed_words", dbg_words == dp_words);
        chk(0, "G2 good_frames==stat_frames", dp_good == stat_frames);
        chk(1, "G3 popc==bytes-4*frames+orphanB",
            dp_popc == (stat_bytes - 4*stat_frames + stat_orphan_bytes));
        chk(2, "G4 term_frames==partial", dp_term == stat_drop_partial);
        chk(3, "G5 no bare sop", dp_bare_sop == 0);
        chk(4, "G6 fifo_ovf==0", stat_fifo_ovf == 0);
        if (!nodrain) chk(6, "G7 open_frame==0 (流以 TLAST 收尾)", open_frame == 0);
        else begin
            // 停摆终态契约 (头注释 §4 的条件式声明): 恰好 1 个已开始的帧欠 TLAST,
            // 无静默丢失 (ovf=0), 后续帧照常被收下/丢 (无死锁), TERM 仍挂着等空间。
            $display("NODRAIN 终态: SOP=%0d TLAST=%0d TERM=%0d open_frame=%0d term_pend=%0d ovf=%0d drop_partial=%0d",
                     dp_sop, dp_last_words, dp_term, open_frame, dbg_term_pend,
                     stat_fifo_ovf, stat_drop_partial);
            chk(6, "G7n 停摆终态: 恰 1 帧欠 TLAST", (dp_sop - dp_last_words) == 1);
            chk(8, "G9n 停摆终态: TERM 契约仍成立", dp_term_badflag == 0);
            chk(4, "G6n 停摆终态: 无静默丢失", stat_fifo_ovf == 0);
            chk(7, "G7b 停摆终态: TERM 仍挂着 (不死锁)", dbg_term_pend == 1);
        end
        chk(8, "G9 TERM_flag_contract", dp_term_badflag == 0);
        chk(5, "G8 drop_partial<=drop_full<=drop",
            (stat_drop_partial <= stat_drop_full) && (stat_drop_full <= stat_drop));

        $fclose(fd_ab);
        $display("CHKSUM L1=%0d/%0d L2=%0d/%0d L3=%0d/%0d L4=%0d/%0d L5=%0d/%0d L6=%0d/%0d L7=%0d/%0d L8=%0d/%0d L9=%0d/%0d",
                 ck_p[0],ck_t[0],ck_p[1],ck_t[1],ck_p[2],ck_t[2],ck_p[3],ck_t[3],
                 ck_p[4],ck_t[4],ck_p[5],ck_t[5],ck_p[6],ck_t[6],ck_p[7],ck_t[7],
                 ck_p[8],ck_t[8]);
        if (fail_n == 0) $display("F4_GATE: PASS_ALL");
        else             $display("F4_GATE: FAIL (%0d 条判据不成立)", fail_n);
        $display("F4_DONE");
        $finish;
    end

    // ---- 时钟化驱动: 字节 + tready 计划 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            i <= 0; rx_d <= 8'h07; rx_dv <= 0; rx_er <= 0; tready <= 1;
        end else if (i < nstim) begin
            rx_d  <= stim_d[i];
            rx_dv <= stim_v[i][0];
            rx_er <= stim_e[i][0];
            tready <= stim_w[i][0];
            i <= i + 1;
        end else begin
            rx_dv <= 0; rx_er <= 0;
            tready <= nodrain ? 1'b0 : 1'b1;   // 停摆模式: 激励结束后也永不排空
        end
    end
endmodule
