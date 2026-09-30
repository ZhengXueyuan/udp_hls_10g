`timescale 1ns/1ps
// ===========================================================================
// tb_mac_10g —— 64 位 XGMII MAC 单元门 (mac_rx_10g / mac_tx_10g / crc32_64)
// ===========================================================================
// 纪律 (本工程硬规矩):
//   · 判据一律写 `cond !== 1'b1` (X 乐观陷阱)
//   · 每条判据的「期望来源」写在所属组的头注释里 —— 期望值全部由本 TB 独立算
//     (位串行 CRC + 逐字节内容), **不由 DUT 生成**
//   · 激励在 posedge 之后 #1 驱动; TX 用队列 + tvalid/tready 握手 (不与 DUT 竞争)
//   · 逐字节比对汇总成"错误计数"再判一次 (避免几百条同名判据淹没日志)
//   · ⚠️ 2026-09-29: `chk` 的 name 端口是 [8*80-1:0] 的**位向量** —— xsim 把它写日志时
//     **非 ASCII 字节全部变成 0xff 垃圾** (实测: 旧日志同一现象, 非本轮引入), 且 >20 个
//     CJK 字会超出 80 字节被截断 ⇒ **新加/改名的判据一律用 ASCII** 名字, 这样日志行可
//     逐字引用作证据 (中文解释写在组头注释与 P7B_MAC_GATEFIX.md 里)。
// ===========================================================================
module tb_mac_10g;

    // ---------------- 时钟 / 复位 ----------------
    reg clk = 1'b0;
    always #3.2 clk = ~clk;             // 6.4 ns = 156.25 MHz
    reg rst_n = 1'b0;

    integer nchk = 0, nfail = 0;
    task chk;
        input            cond;
        input [8*80-1:0] name;
        begin
            nchk = nchk + 1;
            if (cond !== 1'b1) begin
                nfail = nfail + 1;
                $display("  [FAIL] %0s", name);
            end else begin
                $display("  [ ok ] %0s", name);
            end
        end
    endtask

    // =====================================================================
    // TB 自己的位串行 CRC-32 —— 独立实现, 只共享三条语义:
    //   反射多项式 0xEDB88320 / 初值 0xFFFFFFFF / 无终值取反
    //   期望来源: IEEE 802.3 3.2.9 + rtl/crc32_8b.v 头注释 (板级验证过的约定)
    // =====================================================================
    function [31:0] tb_crc_bit;
        input [31:0] c;
        input        b;
        reg          m;
        begin
            m = c[0] ^ b;
            tb_crc_bit = {1'b0, c[31:1]};
            if (m) tb_crc_bit = tb_crc_bit ^ 32'hEDB88320;
        end
    endfunction
    function [31:0] tb_crc_byte;
        input [31:0] c;
        input [7:0]  d;
        integer i;
        reg [31:0] t;
        begin
            t = c;
            for (i = 0; i < 8; i = i + 1) t = tb_crc_bit(t, d[i]);
            tb_crc_byte = t;
        end
    endfunction

    // ---------------- 内容图案 / FCS (TB 自算) ----------------
    reg [7:0] cbuf [0:2047];
    reg [7:0] fcsb [0:3];
    task fill_content(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) cbuf[i] = i[7:0] ^ 8'hA5;
        end
    endtask
    task calc_fcs(input integer n);
        integer i;
        reg [31:0] c;
        begin
            c = 32'hFFFFFFFF;
            for (i = 0; i < n; i = i + 1) c = tb_crc_byte(c, cbuf[i]);
            c = c ^ 32'hFFFFFFFF;
            fcsb[0] = c[7:0];   fcsb[1] = c[15:8];
            fcsb[2] = c[23:16]; fcsb[3] = c[31:24];
        end
    endtask

    // =====================================================================
    // CRC 单元门 (组 1)
    // =====================================================================
    reg         ut_init = 1'b0, ut_en = 1'b0;
    reg  [63:0] ut_d = 64'd0;
    reg  [7:0]  ut_keep = 8'd0;
    wire [31:0] ut_crc, ut_crc_nxt;
    reg  [31:0] ut_crc_final, ut_res_full, ut_res_bad, ut_split_a, ut_split_b;

    crc32_64 u_crc_ut (
        .clk(clk), .rst_n(rst_n), .init(ut_init), .en(ut_en),
        .d(ut_d), .keep(ut_keep), .crc(ut_crc), .crc_nxt(ut_crc_nxt)
    );

    task ut_feed(input [63:0] d, input [7:0] kp);
        begin
            ut_d = d; ut_keep = kp; ut_en = 1'b1;
            @(posedge clk); #1;
            ut_en = 1'b0;
        end
    endtask
    task ut_init_reset;
        begin
            ut_init = 1'b1; ut_en = 1'b0;
            @(posedge clk); #1;
            ut_init = 1'b0;
        end
    endtask
    task ut_run;
        integer i2;
        begin
            // (a) crc32("123456789")
            ut_init_reset;
            ut_feed(64'h3132333435363738, 8'hFF);      // "12345678"
            ut_feed(64'h3900000000000000, 8'h80);      // "9"
            @(posedge clk); #1;
            ut_crc_final = ut_crc ^ 32'hFFFFFFFF;
            // (b) 帧残留: 60 字节内容 + 4 字节 FCS 逐字流过
            fill_content(60); calc_fcs(60);
            ut_init_reset;
            for (i2 = 0; i2 < 7; i2 = i2 + 1)
                ut_feed({cbuf[i2*8], cbuf[i2*8+1], cbuf[i2*8+2], cbuf[i2*8+3],
                         cbuf[i2*8+4], cbuf[i2*8+5], cbuf[i2*8+6], cbuf[i2*8+7]}, 8'hFF);
            ut_feed({cbuf[56], cbuf[57], cbuf[58], cbuf[59], 32'd0}, 8'hF0);
            ut_feed({fcsb[0], fcsb[1], fcsb[2], fcsb[3], 32'd0}, 8'hF0);
            @(posedge clk); #1;
            ut_res_full = ut_crc;
            // (c) 负对照: FCS 首字节改 1 位
            ut_init_reset;
            for (i2 = 0; i2 < 7; i2 = i2 + 1)
                ut_feed({cbuf[i2*8], cbuf[i2*8+1], cbuf[i2*8+2], cbuf[i2*8+3],
                         cbuf[i2*8+4], cbuf[i2*8+5], cbuf[i2*8+6], cbuf[i2*8+7]}, 8'hFF);
            ut_feed({cbuf[56], cbuf[57], cbuf[58], cbuf[59], 32'd0}, 8'hF0);
            ut_feed({fcsb[0]^8'h01, fcsb[1], fcsb[2], fcsb[3], 32'd0}, 8'hF0);
            @(posedge clk); #1;
            ut_res_bad = ut_crc;
            // (d) 部分字等价性: "两个整字" == "4+3+1+0 字节" 两种喂法
            ut_init_reset;
            ut_feed(64'h0123456789ABCDEF, 8'hFF);
            ut_feed(64'hFEDCBA9876543210, 8'hFF);
            @(posedge clk); #1;
            ut_split_a = ut_crc;
            ut_init_reset;
            ut_feed(64'h0123456789ABCDEF, 8'hF0);   // 线上第 1..4 字节
            ut_feed(64'h89ABCDEF00000000, 8'hF0);   // 线上第 5..8 字节
            ut_feed(64'hFEDCBA9800000000, 8'hF0);   // 线上第 9..12 字节
            ut_feed(64'h7654321000000000, 8'hF0);   // 线上第 13..16 字节
            @(posedge clk); #1;
            ut_split_b = ut_crc;
        end
    endtask

    // =====================================================================
    // RX DUT
    // =====================================================================
    reg  [63:0] rx_d;
    reg  [7:0]  rx_c;
    reg         rx_tready;
    wire [63:0] rx_tdata;
    wire [7:0]  rx_tkeep;
    wire        rx_tvalid, rx_tlast, rx_tuser, rx_tcrs, rx_terr;
    wire [31:0] rx_stat_frames, rx_stat_crc_err, rx_stat_drop, rx_stat_bytes;
    wire [31:0] rx_stat_drop_full, rx_stat_drop_partial, rx_stat_orphan_bytes, rx_stat_fifo_ovf;
    wire [31:0] rx_dbg_words;
    wire [31:0] rx_stat_words, rx_stat_pay_bytes, rx_stat_er_words, rx_stat_bad_words;
    wire [31:0] rx_stat_frag, rx_stat_no_s, rx_stat_q, rx_stat_short, rx_stat_long;
    wire [15:0] rx_dbg_last_len;
    wire [3:0]  rx_dbg_last_tlane;
    wire [1:0]  rx_dbg_state;

    mac_rx_10g u_rx (
        .clk(clk), .rst_n(rst_n),
        .xgmii_rxd(rx_d), .xgmii_rxc(rx_c),
        .m_axis_tdata(rx_tdata), .m_axis_tkeep(rx_tkeep), .m_axis_tvalid(rx_tvalid),
        .m_axis_tready(rx_tready), .m_axis_tlast(rx_tlast), .m_axis_tuser(rx_tuser),
        .m_axis_tcrs(rx_tcrs), .m_axis_terr(rx_terr),
        .stat_frames(rx_stat_frames), .stat_crc_err(rx_stat_crc_err),
        .stat_drop(rx_stat_drop), .stat_bytes(rx_stat_bytes),
        .stat_drop_full(rx_stat_drop_full), .stat_drop_partial(rx_stat_drop_partial),
        .stat_orphan_bytes(rx_stat_orphan_bytes), .stat_fifo_ovf(rx_stat_fifo_ovf),
        .dbg_stat_words_out(rx_dbg_words),
        .stat_rx_words(rx_stat_words), .stat_rx_pay_bytes(rx_stat_pay_bytes),
        .stat_rx_er_words(rx_stat_er_words), .stat_rx_bad_words(rx_stat_bad_words),
        .stat_rx_frag(rx_stat_frag), .stat_rx_no_s(rx_stat_no_s), .stat_rx_q(rx_stat_q),
        .stat_rx_short(rx_stat_short), .stat_rx_long(rx_stat_long),
        .dbg_rx_last_len(rx_dbg_last_len), .dbg_rx_last_tlane(rx_dbg_last_tlane),
        .dbg_rx_state(rx_dbg_state)
    );

    // ---------------- RX 采集器 ----------------
    reg  [7:0]  rx_got [0:16383];
    integer     rx_gn_global = 0;
    integer     rx_frn = 0;
    integer     rx_fs [0:255];
    integer     rx_fl [0:255];
    integer     rx_fcrs [0:255];
    integer     rx_fterr [0:255];
    integer     rx_fterm [0:255];
    integer     rx_fsop [0:255];
    integer     rx_fwcnt [0:255];
    integer     rx_gn = 0, rx_wcnt = 0, jj;
    reg         rx_saw_user;
    integer     rx_sop_ok;

    always @(posedge clk) if (rst_n) begin
        if (rx_tvalid && rx_tready) begin
            if (rx_tuser === 1'b1) begin
                rx_gn   = 0;
                rx_sop_ok = (rx_wcnt === 0) ? 1 : 0;   // 帧首字必须是本帧第 0 个字
                rx_saw_user = 1'b1;
                rx_fs[rx_frn] = rx_gn_global;
            end
            for (jj = 0; jj < 8; jj = jj + 1)
                if (rx_tkeep[7-jj] === 1'b1) begin
                    rx_got[rx_gn_global] = rx_tdata[63 - 8*jj -: 8];
                    rx_gn_global = rx_gn_global + 1;
                    rx_gn = rx_gn + 1;
                end
            rx_wcnt = rx_wcnt + 1;
            if (rx_tlast === 1'b1) begin
                rx_fl[rx_frn]    = (rx_saw_user === 1'b1) ? rx_gn : 0;
                rx_fwcnt[rx_frn] = (rx_saw_user === 1'b1) ? rx_wcnt : 0;
                rx_fsop[rx_frn]  = (rx_saw_user === 1'b1) ? rx_sop_ok : 0;
                rx_fcrs[rx_frn]  = (rx_tcrs === 1'b1) ? 1 : 0;
                rx_fterr[rx_frn] = (rx_terr === 1'b1) ? 1 : 0;
                rx_fterm[rx_frn] = (rx_tkeep === 8'h00) ? 1 : 0;
                rx_frn = rx_frn + 1;
                rx_saw_user = 1'b0;
                rx_wcnt = 0;
            end
        end
    end

    // ---------------- RX 驱动 ----------------
    reg [63:0] drv_d [0:4095];
    reg [7:0]  drv_c [0:4095];
    reg [7:0]  gb [0:8191];
    reg        gc [0:8191];
    integer    gn, frm_L;

    task drv_idle_all;
        integer i;
        begin
            for (i = 0; i < 4096; i = i + 1) begin
                drv_d[i] = 64'h0707070707070707;
                drv_c[i] = 8'hFF;
            end
        end
    endtask
    task drv_run(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk); #1;
                rx_d = drv_d[i];
                rx_c = drv_c[i];
            end
            for (i = 0; i < 24; i = i + 1) begin     // settle (空转, 让流水排空)
                @(posedge clk); #1;
                rx_d = 64'h0707070707070707;
                rx_c = 8'hFF;
            end
        end
    endtask
    // 把字符流 gb/gc 的 [c0, c0+nc) 段按 8 字符/字打进 drv_d/drv_c 的第 w0 个字起
    task pack_words(input integer w0, input integer nw, input integer c0, input integer nc);
        integer k, l, idx;
        begin
            for (k = 0; k < nw; k = k + 1) begin
                drv_d[w0+k] = 64'h0707070707070707;
                drv_c[w0+k] = 8'hFF;
                for (l = 0; l < 8; l = l + 1) begin
                    idx = c0 + k*8 + l;
                    if (idx < c0 + nc) begin
                        drv_d[w0+k][8*l +: 8] = gb[idx];
                        drv_c[w0+k][l]        = gc[idx];
                    end
                end
            end
        end
    endtask

    // =====================================================================
    // 组装 XGMII 接收字符流 (追加在 gb/gc 当前 gn 处; 调用者先把 gn 清 0)
    //   ch0       = /S/(c=1)   [EX]:995,1147-1149 ; ch1..6 = 0x55 ; ch7 = 0xD5
    //   ch8..     = 内容 + FCS (c=0)
    //   ch8+L     = /T/(c=1)   L = 内容+FCS = 线上帧长  [S1] 49.2.4.9
    //   ch8+L+1.. = /I/(c=1)   nidle 个
    //   s_lane4=1 ⇒ /S/ 落 lane4 (前导组跨字), 数据从下一字 lane4 起
    //   e_at>=0   ⇒ 把内容第 e_at 字节换成 /E/ (控制字符)
    // =====================================================================
    task build_rx_frame(input integer clen, input integer badfcs, input integer e_at,
                        input integer s_lane4, input integer nidle);
        integer i, g0;
        begin
            g0 = gn;      // 本帧起点 (gb/gc 是累加数组)
            fill_content(clen);
            calc_fcs(clen);
            if (s_lane4 === 1) begin
                for (i = 0; i < 4; i = i + 1) begin gb[gn]=8'h07; gc[gn]=1; gn=gn+1; end
                gb[gn]=8'hFB; gc[gn]=1; gn=gn+1;
                for (i = 0; i < 3; i = i + 1) begin gb[gn]=8'h55; gc[gn]=0; gn=gn+1; end
                for (i = 0; i < 3; i = i + 1) begin gb[gn]=8'h55; gc[gn]=0; gn=gn+1; end
                gb[gn]=8'hD5; gc[gn]=0; gn=gn+1;
            end else begin
                gb[gn]=8'hFB; gc[gn]=1; gn=gn+1;
                for (i = 0; i < 6; i = i + 1) begin gb[gn]=8'h55; gc[gn]=0; gn=gn+1; end
                gb[gn]=8'hD5; gc[gn]=0; gn=gn+1;
            end
            for (i = 0; i < clen; i = i + 1) begin gb[gn]=cbuf[i]; gc[gn]=0; gn=gn+1; end
            for (i = 0; i < 4; i = i + 1) begin
                gb[gn] = (badfcs===1 && i===0) ? (fcsb[0] ^ 8'hFF) : fcsb[i];
                gc[gn] = 0; gn = gn + 1;
            end
            frm_L = clen + 4;
            if (e_at >= 0) begin gb[g0 + 8 + e_at] = 8'hFE; gc[g0 + 8 + e_at] = 1; end
            gb[gn]=8'hFD; gc[gn]=1; gn=gn+1;
            for (i = 0; i < nidle; i = i + 1) begin gb[gn]=8'h07; gc[gn]=1; gn=gn+1; end
        end
    endtask

    // =====================================================================
    // TX DUT
    // =====================================================================
    reg  [63:0] txq_d [0:8191];
    reg  [7:0]  txq_k [0:8191];
    reg         txq_l [0:8191];
    integer     txq_n = 0, txq_i = 0;
    reg         tx_en = 1'b0;
    wire [63:0] tx_tdata;
    wire [7:0]  tx_tkeep;
    wire        tx_tvalid, tx_tready, tx_tlast;
    wire [63:0] xt_d;
    wire [7:0]  xt_c;
    wire [31:0] tx_stat_frames, tx_stat_abort, tx_stat_flush_words, tx_stat_flush_done;
    wire [31:0] tx_stat_words, tx_stat_ctrl, tx_stat_short;
    wire [15:0] tx_dbg_clen;
    wire [1:0]  tx_dbg_state;

    assign tx_tdata  = (tx_en === 1'b1 && txq_i < txq_n) ? txq_d[txq_i] : 64'd0;
    assign tx_tkeep  = (tx_en === 1'b1 && txq_i < txq_n) ? txq_k[txq_i] : 8'd0;
    assign tx_tlast  = (tx_en === 1'b1 && txq_i < txq_n) ? txq_l[txq_i] : 1'b0;
    assign tx_tvalid = (tx_en === 1'b1 && txq_i < txq_n) ? 1'b1 : 1'b0;

    mac_tx_10g u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(tx_tdata), .s_axis_tkeep(tx_tkeep),
        .s_axis_tvalid(tx_tvalid), .s_axis_tready(tx_tready), .s_axis_tlast(tx_tlast),
        .xgmii_txd(xt_d), .xgmii_txc(xt_c),
        .stat_frames(tx_stat_frames), .stat_abort(tx_stat_abort),
        .stat_flush_words(tx_stat_flush_words), .stat_flush_done(tx_stat_flush_done),
        .stat_tx_words(tx_stat_words), .stat_tx_ctrl_char(tx_stat_ctrl),
        .stat_tx_short(tx_stat_short), .dbg_tx_last_clen(tx_dbg_clen),
        .dbg_tx_state(tx_dbg_state)
    );

    always @(posedge clk) if (rst_n === 1'b1 && tx_tvalid === 1'b1 && tx_tready === 1'b1)
        txq_i <= txq_i + 1;

    reg [63:0] xcap_d [0:65535];
    reg [7:0]  xcap_c [0:65535];
    integer    xcap_n = 0;
    always @(posedge clk) if (rst_n === 1'b1) begin
        xcap_d[xcap_n] = xt_d;
        xcap_c[xcap_n] = xt_c;
        xcap_n = xcap_n + 1;
    end

    reg [7:0] expb [0:4095];
    integer   idx, t_lane, nidle, ndata_after_t, badctrl, bads;

    // 装帧进 TX 队列
    task tx_load_frame(input integer clen);
        integer i, wp, nw;
        reg [63:0] dw;
        begin
            fill_content(clen);
            calc_fcs(clen);
            nw = (clen + 7) / 8;
            for (wp = 0; wp < nw; wp = wp + 1) begin
                dw = 64'd0;
                for (i = 0; i < 8; i = i + 1)
                    if (wp*8 + i < clen) dw[63 - 8*i -: 8] = cbuf[wp*8 + i];
                txq_d[txq_n] = dw;
                txq_k[txq_n] = (clen - wp*8 >= 8) ? 8'hFF : (8'hFF << (8 - (clen - wp*8)));
                txq_l[txq_n] = (wp === nw-1) ? 1'b1 : 1'b0;
                txq_n = txq_n + 1;
            end
            tx_en = 1'b1;
        end
    endtask
    task tx_wait;
        integer i;
        begin
            while (txq_i < txq_n) @(posedge clk);
            for (i = 0; i < 40; i = i + 1) @(posedge clk);
        end
    endtask
    task tx_push(input [63:0] d, input [7:0] kp, input lst);
        begin
            txq_d[txq_n] = d; txq_k[txq_n] = kp; txq_l[txq_n] = lst;
            txq_n = txq_n + 1;
            tx_en = 1'b1;
        end
    endtask

    function integer find_s(input integer b0);
        integer q;
        begin
            find_s = -1;
            for (q = b0; q < xcap_n; q = q + 1)
                if (find_s === -1 && xcap_c[q] === 8'h01 && xcap_d[q][7:0] === 8'hFB)
                    find_s = q;
        end
    endfunction

    // 从 xcap[wi+1] 起解码: expb[] 数据字节, idx 个数, t_lane, nidle(/T/ 后 /I/ 数),
    //   ndata_after_t(/T/ 后数据 lane 数, 必须 0), badctrl(非法控制码数)
    task tx_decode(input integer wi);
        integer q, ln, t_word;
        reg     done;
        begin
            idx = 0; t_lane = -1; nidle = 0; ndata_after_t = 0; badctrl = 0; done = 0;
            t_word = -1;
            for (q = wi+1; q < xcap_n && !done; q = q + 1) begin
                for (ln = 0; ln < 8; ln = ln + 1) begin
                    if (t_lane < 0) begin
                        if (xcap_c[q][ln] === 1'b1) begin
                            if (xcap_d[q][8*ln +: 8] === 8'hFD && t_lane < 0) begin
                                t_lane = ln; t_word = q;
                            end else badctrl = badctrl + 1;
                        end else begin
                            if (idx < 4096) expb[idx] = xcap_d[q][8*ln +: 8];
                            idx = idx + 1;
                        end
                    end else begin
                        if (xcap_c[q][ln] === 1'b1) begin
                            if (xcap_d[q][8*ln +: 8] === 8'h07) nidle = nidle + 1;
                            else badctrl = badctrl + 1;
                        end else ndata_after_t = ndata_after_t + 1;
                    end
                end
                // ⭐ 扫描窗只到 /T/ 字之后 2 个字为止 —— 否则会把**后续无关的空闲字**
                //   也算进 nidle, 于是"IFG 阈值被改小"这类变异永远看得出来 (实测踩过)
                if (t_lane >= 0 && (nidle >= 12 || q > t_word + 2)) done = 1;
            end
        end
    endtask

    // =====================================================================
    // ⭐ 独立 FCS oracle (2026-09-30, DEFECT #1 的**判据结构**修复)
    // ---------------------------------------------------------------------
    // oracle 的输入 = **线上实际发出去的字节** (tx_decode 解出的 expb[0..clen-1], 含 DUT
    //   自己补的 pad), **不是** TB 喂进去的内容 ⇒ 覆盖集由线上内容定义, 与 DUT 内部
    //   "CRC 覆盖哪些字节"的写法无关。
    // ⚠️ 对照被替换掉的那条同源 oracle (原组 8.2):
    //     `chk(expb[60] === fcsb[0] && expb[63] === fcsb[3], ...)` 里的 fcsb 来自
    //     `calc_fcs(n)` = **只对内容字节**做 CRC —— 与当时实现 (mac_tx_10g: crc_en 只在
    //     S_DATA)&(crc_keep = tkeep) 的覆盖面**逐字相同** ⇒ 实现把 pad 漏掉时 oracle 同步
    //     漏掉 ⇒ 结构上判不出来 (实测 pristine 252 checks / 0 fail)。
    //     算术不是同源的 (tb_crc_byte 是独立位串行实现, 组 1 用标准向量校准), 同源的是
    //     **覆盖集的定义** —— 缺陷正好落在覆盖集上, 所以它藏得住。
    //   本 oracle 两条判据:
    //     (a) DUT 写在线上的 FCS 字段 == CRC(线上全部内容字节 incl pad) 的终值取反,
    //     (b) 自洽残差: 线上内容+FCS 全部流过 ⇒ 0xDEBB20E3 (与 mac_rx_10g 同一魔数)
    // =====================================================================
    task fcs_chk_wire(input [8*16-1:0] tag, input integer clen);
        integer i2, e2;
        reg [31:0] c2;
        begin
            c2 = 32'hFFFFFFFF;
            for (i2 = 0; i2 < clen; i2 = i2 + 1) c2 = tb_crc_byte(c2, expb[i2]);
            c2 = c2 ^ 32'hFFFFFFFF;
            $display("     [FCSW] %0s clen=%0d oracle=%02x %02x %02x %02x | wire=%02x %02x %02x %02x",
                     tag, clen, c2[7:0], c2[15:8], c2[23:16], c2[31:24],
                     expb[clen], expb[clen+1], expb[clen+2], expb[clen+3]);
            e2 = 0;
            if (expb[clen+0] !== c2[7:0])   e2 = e2 + 1;
            if (expb[clen+1] !== c2[15:8])  e2 = e2 + 1;
            if (expb[clen+2] !== c2[23:16]) e2 = e2 + 1;
            if (expb[clen+3] !== c2[31:24]) e2 = e2 + 1;
            chk(e2 === 0, {tag, " FCS == CRC(wire bytes incl pad)"});
            c2 = 32'hFFFFFFFF;
            for (i2 = 0; i2 < clen + 4; i2 = i2 + 1) c2 = tb_crc_byte(c2, expb[i2]);
            chk(c2 === 32'hDEBB20E3, {tag, " wire residue == 0xDEBB20E3"});
        end
    endtask

    // =====================================================================
    // F-2 幽灵帧检测器 (基于**线上内容**, 与计数器无关) —— 2026-09-29 新增 (GATEFIX D1)
    //   判据形态取自 P6B_CDC_AUDIT.md B8 (F11 判定实验的三条判据):
    //     ① 该帧 FCS 残差合法 (== 0xDEBB20E3) —— ⚠️ 幽灵帧恰恰是 **FCS 正确**的,
    //        所以单靠 ① **判不出来** (B8 原文: "坏帧被包装成 FCS 正确的好帧发出")
    //     ② **该帧 content 与任何注入帧都不等** ⇒ 幽灵帧 ← 本检测器的主判据
    //     ③ 线上帧数 > 注入帧数 ⇒ 幽灵帧        ← 本检测器同时实现
    //   ⇒ 判据**逐帧独立**: 每解出一帧单独判一条, 不靠"总数对账"。
    //   为什么不能用计数器代替: 变异 M7b 把 stat_flush_done/words 伪装好、照样发幽灵帧,
    //     旧判据 229/0 全 PASS (见 notes/P7B_MAC_GATEFIX.md D1) —— 计数器可以被伪装,
    //     线上内容不能。
    // =====================================================================
    localparam WFR_STRIDE = 2048;           // 每帧字节预算 (最大帧 1518+4 << 2048)
    localparam WFR_MAXF   = 8;              // 最多解 8 帧 (M7b 实测 3 帧)
    reg  [7:0]  wfr_b [0:WFR_MAXF*WFR_STRIDE-1];   // 线上第 f 帧第 k 字节 = [f*WFR_STRIDE+k]
    integer     wfr_start [0:WFR_MAXF-1];
    integer     wfr_len   [0:WFR_MAXF-1];
    integer     wfr_kind  [0:WFR_MAXF-1];   // 0=幽灵(FAIL) 1=残缺前缀(中止帧) 2=完整注入帧
    integer     wfr_nf = 0, wfr_ghost_n = 0;
    reg  [7:0]  inj_b [0:WFR_MAXF*WFR_STRIDE-1];   // **注入帧**内容 (TB 自算, 不含 FCS)
    reg  [7:0]  inj_f [0:WFR_MAXF*4-1];            // 注入帧 FCS (4 字节/帧, TB 自算)
    integer     inj_len [0:WFR_MAXF-1];
    integer     inj_n = 0;
    // FSM 看门狗 (D3): 连续处于"帧活跃"状态的拍数
    integer     ts_run = 0, ts_maxrun = 0;
    always @(posedge clk) if (rst_n === 1'b1) begin
        if (rx_dbg_state !== 2'd0) begin
            ts_run = ts_run + 1;
            if (ts_run > ts_maxrun) ts_maxrun = ts_run;
        end else ts_run = 0;
    end

    // 登记一个**注入帧** (期望来源: 本 TB 自己的内容图案 + 位串行 CRC, 不由 DUT 生成)
    task inj_add(input integer n);
        integer i2;
        begin
            fill_content(n); calc_fcs(n);
            for (i2 = 0; i2 < n; i2 = i2 + 1) inj_b[inj_n*WFR_STRIDE + i2] = cbuf[i2];
            for (i2 = 0; i2 < 4; i2 = i2 + 1) inj_f[inj_n*4 + i2] = fcsb[i2];
            inj_len[inj_n] = n;
            inj_n = inj_n + 1;
        end
    endtask

    function [7:0] wfb;                     // 线上第 f 帧第 i 字节
        input integer f, i;
        begin wfb = wfr_b[f*WFR_STRIDE + i]; end
    endfunction
    function [7:0] ifb;                     // 注入第 f 帧第 i 字节
        input integer f, i;
        begin ifb = inj_b[f*WFR_STRIDE + i]; end
    endfunction

    // 把 xcap[ws..we) 解码成"线上的每一帧"的**实际内容** (含 FCS), 并逐帧分类。
    //   成帧约定与 mac_rx_10g 同: /S/ 只认 lane0/lane4 (在 l..7 lane 上 = 前导组, 不算数据;
    //   数据从**下一字**的 lane l 起 —— [S1] 46.2.2 + rtl/mac_rx_10g.v:143-145);
    //   /T/ 结帧 (自身不算数据), 其余控制字符忽略。
    task tx_scan_frames(input integer ws, input integer we);
        integer q, l, k, i2, st, nf, bad2, pre_w, pre_l;
        reg     in_f;
        reg [7:0] byt;
        begin
            nf = 0; in_f = 1'b0; st = 0; pre_w = -1; pre_l = 0;
            for (q = ws; q < we; q = q + 1) begin
                for (l = 0; l < 8; l = l + 1) begin
                    byt = xcap_d[q][8*l +: 8];
                    if (in_f !== 1'b1) begin
                        if (xcap_c[q][l] === 1'b1 && byt === 8'hFB && (l === 0 || l === 4)) begin
                            if (nf < WFR_MAXF) begin
                                in_f = 1'b1; st = 0; pre_w = q; pre_l = l;
                                wfr_start[nf] = q;
                            end
                        end
                    end else if (xcap_c[q][l] === 1'b1) begin
                        if (byt === 8'hFD) begin              // /T/ ⇒ 本帧结束
                            wfr_len[nf] = (st < WFR_STRIDE) ? st : WFR_STRIDE;
                            nf = nf + 1;
                            in_f = 1'b0;
                        end
                    end else if ((q === pre_w) || ((q === pre_w + 1) && (l < pre_l))) begin
                        // 前导组 (本字 /S/ 之后到字尾) 与本帧首字的 lane<pre_l **都不是帧数据**
                        //   [S1] 46.2.2: 数据从**下一字**的 lane pre_l 起 (lane4 起帧时前 4 lane 是前导)
                        //   ⚠️ 第一版这里只跳了 l 个字节 ⇒ 每帧多算 7 字节 (含 0x55×6+0xD5),
                        //      判据立刻在干净件上 FAIL —— 正是这条判据自己在抓自己 (实测)。
                    end else begin
                        if (st < WFR_STRIDE) wfr_b[nf*WFR_STRIDE + st] = byt;
                        st = st + 1;
                    end
                end
            end
            wfr_nf = nf;
            // ---- 逐帧分类 (判据 B8②/③ 的判定面) ----
            wfr_ghost_n = 0;
            for (k = 0; k < nf && k < WFR_MAXF; k = k + 1) begin
                wfr_kind[k] = 0;                              // 默认 = 幽灵帧
                for (l = 0; l < inj_n; l = l + 1) begin
                    if (wfr_len[k] === (inj_len[l] + 4)) begin
                        // 完整帧: 内容 + FCS 逐字节 == 某注入帧
                        bad2 = 0;
                        for (i2 = 0; i2 < inj_len[l]; i2 = i2 + 1)
                            if (wfb(k, i2) !== ifb(l, i2)) bad2 = 1;
                        for (i2 = 0; i2 < 4; i2 = i2 + 1)
                            if (wfb(k, inj_len[l] + i2) !== inj_f[l*4 + i2]) bad2 = 1;
                        if (bad2 === 0) wfr_kind[k] = 2;
                    end else if ((wfr_len[k] < inj_len[l]) && (wfr_kind[k] !== 2)) begin
                        // 被中止的帧: 前缀 + 无 FCS (802.3 允许多发 runt; 但**只能是前缀**)
                        bad2 = 0;
                        for (i2 = 0; i2 < wfr_len[k]; i2 = i2 + 1)
                            if (wfb(k, i2) !== ifb(l, i2)) bad2 = 1;
                        if (bad2 === 0) wfr_kind[k] = 1;
                    end
                end
                if (wfr_kind[k] === 0) wfr_ghost_n = wfr_ghost_n + 1;
            end
        end
    endtask

    task reset_all;
        begin
            rst_n = 1'b0;
            tx_en = 1'b0; txq_n = 0; txq_i = 0;
            rx_tready = 1'b1;
            rx_d = 64'h0707070707070707; rx_c = 8'hFF;
            #80 rst_n = 1'b1;
            #40;
        end
    endtask
    task rx_clr;
        begin
            rx_gn_global = 0; rx_frn = 0; rx_saw_user = 1'b0;
        end
    endtask

    // =====================================================================
    // 主流程
    // =====================================================================
    integer i, k, w, base, wi, gA, gB, ecnt, sum_len;
    integer sz;                       // 组 11 的每档内容长度
    integer clen_w;                   // 组 11 的线上内容长度 (含 pad)
    reg [8*16-1:0] tagbuf;            // 组 11 的判据名前缀 (ASCII; 8*16 = 16 字符)

    initial begin
        $display("=== tb_mac_10g start ===");
        drv_idle_all;
        reset_all;

        // =============================================================
        // 组 1: CRC32 (期望来源: 标准校验向量 + crc32_8b.v 三条语义 + mac_rx_64.v:99 魔数)
        // =============================================================
        $display("-- 组 1: CRC32");
        ut_run;
        chk(ut_crc_final === 32'hCBF43926, "CRC: crc32(\"123456789\") == 0xCBF43926 (标准向量)");
        chk(ut_res_full === 32'hDEBB20E3,  "CRC: 帧全字节(含 FCS)流过后的残留 == 0xDEBB20E3");
        chk(ut_res_bad !== 32'hDEBB20E3,   "CRC 负对照: FCS 改 1 位后残留 != 0xDEBB20E3");
        chk(ut_split_a === ut_split_b,     "CRC: '两个整字' == '拆成 4+3+1+0 字节' 两条喂法");

        // =============================================================
        // 组 2: 字节序镜像 (用 /S/ 的 lane 位置反推)
        //   期望来源: P7B_GATE1.md §C.2 镜像表 (板级 c1_sword=0xD5555555555555FB 反推)
        //             + 官方例程 pcs64_pkt_gen_mon.v:995/1148/1240
        //   ⚠️ 2026-09-29 (GATEFIX D2): 下面**前两条**检的是 TB 自己的激励数组
        //      drv_d/drv_c (pack_words 的输出) ⇒ **对 DUT 零判别力** (构造性恒真),
        //      已在判据名里显式标「自检(激励)」, **不得当 DUT 判据引用**。
        //      本组对 DUT 的字节序判别力 = 下面 4 条 (rx_got*/rx_fwcnt: 全是 DUT 输出);
        //      TX 侧同一属性由 8.1 的 xcap_d[wi] + expb 内容/FCS 逐字节判据承担;
        //      lane 算术由 组 3 的 rx_dbg_last_tlane 承担。变异实证: M1 / M1b。
        // =============================================================
        $display("-- 组 2: 字节序镜像");
        reset_all; rx_clr;
        gn = 0; build_rx_frame(60, 0, -1, 0, 16);
        pack_words(0, 24, 0, gn);
        drv_run(24);
        chk(drv_d[0] === 64'hD5555555555555FB, "SELFCHECK(stim only, no DUT power): inj first word == 0xD5555555555555FB");
        chk(drv_c[0] === 8'h01,               "SELFCHECK(stim only, no DUT power): inj first word ctrl only lane0");
        chk(rx_frn === 1,                     "收到 1 帧");
        chk(rx_fl[0] === 60,                  "交付字节数 == 线上帧长-4 == 60");
        chk(rx_got[rx_fs[0]+0] === (8'h00^8'hA5), "交付首字节 == 内容[0] ⇒ tdata[63:56] 是帧首字节");
        chk(rx_got[rx_fs[0]+7] === (8'h07^8'hA5), "交付第 8 字节 == 内容[7]");
        chk(rx_got[rx_fs[0]+59] === (8'd59^8'hA5), "交付末字节 == 内容[59]");
        chk(rx_got[rx_fs[0]+0] !== 8'hFB,     "交付流里没有 /S/(0xFB) ⇒ 前导被剥离");
        chk(rx_fwcnt[0] === ((60+7)/8),       "交付字数 == ceil(60/8) == 8 (真流水: 1 字/拍)");

        // =============================================================
        // 组 3: 帧长扫描 + 最小/最大/超长
        //   期望来源: /T/ 在 lane (L mod 8); 最小帧 64B / 最大 1518B / Q-tag 1522B [S1] Clause 4.4
        // =============================================================
        $display("-- 组 3: 帧长扫描");
        for (k = 60; k <= 68; k = k + 1) begin
            reset_all; rx_clr;
            gn = 0; build_rx_frame(k, 0, -1, 0, 16);
            pack_words(0, 32, 0, gn);
            drv_run(32);
            chk(rx_frn === 1,           "帧长扫描: 收到 1 帧");
            chk(rx_fl[0] === k,         "帧长扫描: 交付字节数 == 内容长度");
            chk(rx_fcrs[0] === 1,       "帧长扫描: tcrs == 1");
            chk(rx_fterr[0] === 0,      "帧长扫描: terr == 0");
            chk(rx_fsop[0] === 1,       "帧长扫描: SOP 落在首字");
            chk(rx_fterm[0] === 0,      "帧长扫描: 不是 TERM 字");
            chk(rx_got[rx_fs[0]+k-1] === cbuf[k-1], "帧长扫描: 末字节内容正确");
            chk(rx_dbg_last_tlane === ((k+4) % 8), "帧长扫描: /T/ lane == (L mod 8)");
            chk(rx_stat_frames === 1,   "帧长扫描: stat_frames == 1");
            chk(rx_stat_bytes === (k+4), "帧长扫描: stat_bytes == 线上帧长");
            chk(rx_stat_pay_bytes === k, "帧长扫描: Σpopc(tkeep) == 交付字节数");
        end
        reset_all; rx_clr;
        gn = 0; build_rx_frame(1514, 0, -1, 0, 16);
        pack_words(0, 200, 0, gn);
        drv_run(200);
        chk(rx_frn === 1,             "最大帧 (1514 内容 / 1518 线上): 收到 1 帧");
        chk(rx_fl[0] === 1514,        "最大帧: 交付 1514 字节");
        chk(rx_fcrs[0] === 1,         "最大帧: tcrs == 1");
        chk(rx_stat_long === 0,       "最大帧: 不触发 stat_rx_long (1518 <= 1522)");
        chk(rx_dbg_last_len === 1518, "最大帧: 线上长度 1518");
        reset_all; rx_clr;
        gn = 0; build_rx_frame(1519, 0, -1, 0, 16);
        pack_words(0, 200, 0, gn);
        drv_run(200);
        chk(rx_frn === 1,        "超长帧 (1519 内容 / 1523 线上): 仍交付 (本层不截断)");
        chk(rx_stat_long === 1,  "超长帧: stat_rx_long == 1 (1523 > 1522)");

        // =============================================================
        // 组 4: /S/ 在 lane4 (32 位 XGMII 的第二次传输) ⇒ 数据起始 lane == 4
        //   期望来源: [S1] 46.2.2 (前导跨 2 次 32 位传输, SFD 落 lane3) + 64 位视图【推论】
        //             + 官方监视器同查 lane0/lane4 (pcs64_pkt_gen_mon.v:1366 / :1379 —— 同构两处)
        //   ⚠️ 2026-09-29 (GATEFIX D6): 原引 :1374 是 `start_flag = 0;`; 正确落位见上
        //      (行号漂移/笔误已订正, 约定本身不变)
        // =============================================================
        $display("-- 组 4: /S/ 在 lane4");
        reset_all; rx_clr;
        gn = 0; build_rx_frame(60, 0, -1, 1, 16);
        pack_words(0, 32, 0, gn);
        drv_run(32);
        chk(rx_frn === 1,      "/S/@lane4: 收到 1 帧");
        chk(rx_fl[0] === 60,   "/S/@lane4: 交付 60 字节 (数据从 lane4 起)");
        chk(rx_fcrs[0] === 1,  "/S/@lane4: tcrs == 1 (起始 lane 判定正确)");
        chk(rx_fterr[0] === 0, "/S/@lane4: terr == 0 (前导尾未被算进帧)");

        // =============================================================
        // 组 5: 坏 FCS ⇒ tcrs=0 ; /E/ ⇒ terr=1 ; 保留控制码 ⇒ terr=1 (都有负对照)
        //   期望来源: 合同 §3/§6 + mac_rx_64.v:99 的 CRC_RESIDUE
        // =============================================================
        $display("-- 组 5: 坏 FCS / /E/ / 保留控制码");
        reset_all; rx_clr;
        gn = 0; build_rx_frame(60, 1, -1, 0, 16);
        pack_words(0, 32, 0, gn);
        drv_run(32);
        chk(rx_frn === 1,          "坏FCS: 仍交付 1 帧 (帧边界由 /T/ 定)");
        chk(rx_fl[0] === 60,       "坏FCS: 交付字节数不变");
        chk(rx_fcrs[0] === 0,      "坏FCS: tcrs == 0 (负对照成立)");
        chk(rx_stat_crc_err === 1, "坏FCS: stat_crc_err == 1");
        chk(rx_stat_frames === 1,  "坏FCS: 仍计 1 帧 (坏帧也交付, 由下游按 tcrs 丢)");
        reset_all; rx_clr;
        gn = 0; build_rx_frame(60, 0, 10, 0, 16);
        pack_words(0, 32, 0, gn);
        drv_run(32);
        chk(rx_frn === 1,          "/E/: 仍交付 1 帧");
        chk(rx_fl[0] === 60,       "/E/: 交付字节数不变 (窗宽按 lane 算)");
        chk(rx_fterr[0] === 1,     "/E/ 在帧内 ⇒ terr == 1");
        chk(rx_stat_er_words >= 1, "/E/: stat_rx_er_words >= 1");
        reset_all; rx_clr;
        gn = 0; build_rx_frame(60, 0, -1, 0, 16);
        gb[8+12] = 8'h1C; gc[8+12] = 1;      // /R/ (保留控制码) 落在帧内
        pack_words(0, 32, 0, gn);
        drv_run(32);
        chk(rx_frn === 1,           "保留控制码: 仍交付 1 帧");
        chk(rx_fterr[0] === 1,      "保留控制码在帧内 ⇒ terr == 1");
        chk(rx_stat_bad_words >= 1, "保留控制码: stat_rx_bad_words >= 1");

        // =============================================================
        // 组 6: 背靠背 (最小 IPG) + /Q/ + T/S 同拍鲁棒性
        //   期望来源: [S1] 46.2.1 (接收侧 XGMII 最小 IPG = 5 octets)
        //             [S1] Figure 49-7 (T 与 S 不可能同块 ⇒ 同拍 T+S 是**非规范**输入,
        //                  这里只判"不卡死 + 不污染其后规范帧")
        // =============================================================
        $display("-- 组 6: 背靠背 + /Q/ + T/S 同拍");
        reset_all; rx_clr;
        gn = 0;
        build_rx_frame(60, 0, -1, 0, 7);   // 8+64+1+7 = 80 字符 = 10 字 (字对齐)
        gA = gn;
        build_rx_frame(61, 0, -1, 0, 7);
        pack_words(0, 24, 0, gA);
        pack_words(10, 24, gA, gn - gA);
        drv_run(40);
        chk(rx_frn === 2,       "背靠背: 两帧都收到 (7 个 /I/ 的 IPG)");
        chk(rx_fl[0] === 60,    "背靠背: 帧1 = 60 字节");
        chk(rx_fl[1] === 61,    "背靠背: 帧2 = 61 字节");
        chk(rx_fcrs[0] === 1 && rx_fcrs[1] === 1, "背靠背: 两帧 FCS 都正确");
        chk(rx_fsop[0] === 1 && rx_fsop[1] === 1, "背靠背: 两帧 SOP 都正确");
        chk(rx_stat_frames === 2, "背靠背: stat_frames == 2");
        // /Q/ (无帧时)
        reset_all; rx_clr;
        gn = 0; build_rx_frame(60, 0, -1, 0, 16);
        gb[gn]=8'h9C; gc[gn]=1; gn=gn+1;
        pack_words(0, 32, 0, gn);
        drv_run(32);
        chk(rx_stat_q >= 1, "设备 /Q/: stat_rx_q >= 1");
        chk(rx_frn === 1,   "/Q/ 不起新帧");
        // T/S 同拍 (非规范输入) + 之后一个规范帧
        //   ⚠️ 2026-09-29 (GATEFIX D3) 两处订正:
        //   ① **激励**: 原词 lane0 是 /I/(0x07) ⇒ 整块里**根本没有 /T/** —— "T/S 同拍"的前根
        //      不成立。现改成真·同拍块: lane0 = /T/(0xFD,c=1) + lane4 = /S/(0xFB,c=1)。
        //      [S1] Figure 49-7 的 16 种格式里 T 与 S 不可能同块 ⇒ 这是非规范输入, 本组只判
        //      "不卡死 + 不污染其后规范帧" (声明诚实, 不声称这是合法帧)。
        //   ② **判据**: 原 `rx_dbg_state !== 2'bx` 是**恒真** (该 2 位寄存器 mac_rx_10g.v:382
        //      每拍都有确定赋值, 永不可能是 X) ⇒ 零判别力, 已删。换成两条**能取到失败模态**的:
        //      (a) 看门狗 ts_maxrun (连续"帧活跃"拍数上界) —— 期望来源: mac_rx_10g.v:370-380
        //          的帧闭合条件 (/T/ 或下一个 /S/); 两个模态实测见 P7B_MAC_GATEFIX.md D3;
        //      (b) 静默窗后 FSM 回到 IDLE (2'd0) —— 期望来源: mac_rx_10g.v:382 的状态编码。
        //      卡死模态由变异 M10 实证 (帧闭合条件去掉 ⇒ 该判据响)。
        reset_all; rx_clr;
        drv_idle_all;
        drv_d[4] = {8'h55, 8'h55, 8'h55, 8'hFB, 8'h07, 8'h07, 8'h07, 8'hFD};
        drv_c[4] = 8'b01110001;     // lane4 = /S/, lane0 = /T/, lane1..3 = /I/
        ts_run = 0; ts_maxrun = 0;  // 看门狗清零 (只覆盖本用例窗口)
        gn = 0; build_rx_frame(60, 0, -1, 0, 16);
        pack_words(10, 32, 0, gn);
        drv_run(50);
        $display("  -- T/S 同拍: 帧活跃连续拍数实测最大 %0d (看门狗阈值 32)", ts_maxrun);
        chk(ts_maxrun <= 32,       "T/S same-word: frame-active run <= 32 cyc (watchdog: no hang)");
        chk(rx_dbg_state === 2'd0, "T/S same-word: FSM back to IDLE after settle (no hang)");
        chk(rx_stat_frag >= 1,     "T/S 同拍: 计为未闭合帧 (stat_rx_frag >= 1)");
        chk(rx_frn >= 1,           "T/S 同拍: 之后仍能正常收帧");
        begin : ts_last
            integer li;
            li = rx_frn - 1;
            chk(rx_fl[li] === 60,   "T/S 同拍后: 最后一个交付帧 == 60 字节");
            chk(rx_fcrs[li] === 1,  "T/S 同拍后: FCS 正确 (未受污染)");
            ecnt = 0;
            for (i = 0; i < 60; i = i + 1)
                if (rx_got[rx_fs[li]+i] !== cbuf[i]) ecnt = ecnt + 1;
            chk(ecnt === 0,         "T/S 同拍后: 60 字节逐字节一致");
        end

        // =============================================================
        // 组 7: F4 —— 空间门 / 整帧丢弃 / TERM (含负对照)
        //   期望来源: rtl/mac_rx_64.v:131/136/138 + 头注释 §4/§5 (合同条文)
        //   ⚠️ 2026-09-29 (GATEFIX D6): 原引 :128/133/135 —— 行号漂移 3 行, 成因 =
        //      同日该文件头注释插入了 3 行订正 (mac_rx_64.v:7-9 的 CRC 魔数订正)
        // =============================================================
        $display("-- 组 7: F4");
        reset_all; rx_clr;
        gn = 0; build_rx_frame(60, 0, -1, 0, 16);
        pack_words(0, 32, 0, gn);
        drv_run(32);
        chk(rx_stat_drop === 0,     "F4 正例: 无背压时 stat_drop == 0");
        chk(rx_stat_fifo_ovf === 0, "F4 正例: stat_fifo_ovf == 0 (无静默丢失)");
        chk(rx_frn === 1,           "F4 正例: 交付 1 帧");
        // 负对照: 消费者停摆
        reset_all; rx_clr;
        rx_tready = 1'b0;
        for (k = 0; k < 6; k = k + 1) begin
            gn = 0; build_rx_frame(140, 0, -1, 0, 4);
            pack_words(k*32, 24, 0, gn);
        end
        drv_run(6*32 + 24);
        chk(rx_stat_drop >= 1,         "F4 负对照: 停摆 ⇒ stat_drop >= 1 (不静默)");
        chk(rx_stat_drop_full >= 1,    "F4 负对照: stat_drop_full >= 1 (归因到空间不足)");
        chk(rx_stat_fifo_ovf === 0,    "F4 负对照: stat_fifo_ovf == 0 (无字被 FIFO 静默丢)");
        chk(rx_stat_drop_partial >= 1, "F4 负对照: stat_drop_partial >= 1 (孤儿帧有计数)");
        chk(rx_stat_orphan_bytes >= 8, "F4 负对照: stat_orphan_bytes >= 8 (孤儿字节按 popc 计)");
        rx_tready = 1'b1;
        for (i = 0; i < 200; i = i + 1) @(posedge clk);
        sum_len = 0;
        for (i = 0; i < rx_frn; i = i + 1) sum_len = sum_len + rx_fl[i];
        chk(sum_len === (rx_stat_bytes - 4*rx_stat_frames + rx_stat_orphan_bytes),
            "F4 守恒律: Σpopc(交付字) == stat_bytes - 4*frames + orphan_bytes");
        begin : f4_term
            integer nt;
            nt = 0;
            for (i = 0; i < rx_frn; i = i + 1) if (rx_fterm[i] === 1) nt = nt + 1;
            chk(nt >= 1, "F4: 交付流里出现过 TERM 字 (tlast & tkeep==0)");
        end
        reset_all; rx_clr;
        gn = 0; build_rx_frame(60, 0, -1, 0, 16);
        pack_words(0, 32, 0, gn);
        drv_run(32);
        chk(rx_frn === 1,     "F4 恢复后: 新帧完好交付");
        chk(rx_fl[0] === 60,  "F4 恢复后: 字节数正确");
        chk(rx_fcrs[0] === 1, "F4 恢复后: FCS 正确 (未被残字污染)");
        ecnt = 0;
        for (i = 0; i < 60; i = i + 1)
            if (rx_got[rx_fs[0]+i] !== cbuf[i]) ecnt = ecnt + 1;
        chk(ecnt === 0,       "F4 恢复后: 60 字节逐字节一致");

        // =============================================================
        // 组 8: TX 帧格式/前导/FCS/IFG/块格式合法性
        //   期望来源: [EX]:995,1147-1149 (前导拍) ; [S1] Figure 49-7 (T 之后只能是控制字符)
        //             [S1] Clause 4.4 (最小帧 64B) ; BASER_TABLES §3 (IFG)
        // =============================================================
        $display("-- 组 8: TX 帧格式");
        reset_all;
        txq_n = 0; txq_i = 0; base = xcap_n;
        tx_load_frame(60);
        tx_wait;
        wi = find_s(base);
        chk(wi >= 0, "TX: 找到 /S/ 起始字");
        chk(xcap_d[wi] === 64'hD5555555555555FB, "TX: 帧首字 == 0xD5555555555555FB");
        chk(xcap_c[wi] === 8'h01, "TX: 帧首字只有 lane0 是控制字符");
        tx_decode(wi);
        chk(t_lane >= 0,          "TX: 找到 /T/");
        chk(ndata_after_t === 0,  "TX: /T/ 之后没有任何数据 lane (Figure 49-7)");
        chk(badctrl === 0,        "TX: 帧内(/T/ 前)无 /T/ 之外的控制字符");
        chk(idx === 64,           "TX: 线上数据字节数 == 60 内容 + 4 FCS");
        chk(nidle >= 12,          "TX: /T/ 之后 >= 12 个 /I/ (IFG)");
        ecnt = 0;
        for (k = 0; k < 60; k = k + 1) if (expb[k] !== cbuf[k]) ecnt = ecnt + 1;
        chk(ecnt === 0, "TX: 60 字节内容逐字节一致");
        chk(expb[60] === fcsb[0] && expb[61] === fcsb[1] &&
            expb[62] === fcsb[2] && expb[63] === fcsb[3],
            "TX: FCS == TB 独立算出的 (crc^0xFFFFFFFF) 小端 4 字节");
        chk(tx_stat_frames === 1, "TX: stat_frames == 1");
        chk(tx_stat_abort  === 0, "TX: stat_abort == 0");

        // 8.2 pad: 内容 20 ⇒ 补 0 到 60
        reset_all;
        txq_n = 0; txq_i = 0; base = xcap_n;
        tx_load_frame(20);
        tx_wait;
        wi = find_s(base);
        chk(wi >= 0, "TX pad: 找到 /S/");
        tx_decode(wi);
        chk(idx === 64, "TX pad: 线上数据字节数 == 20 + 40 pad + 4 FCS");
        ecnt = 0;
        for (k = 0; k < 20; k = k + 1) if (expb[k] !== cbuf[k]) ecnt = ecnt + 1;
        for (k = 20; k < 60; k = k + 1) if (expb[k] !== 8'h00) ecnt = ecnt + 1;
        chk(ecnt === 0, "TX pad: 前 20 字节 == 内容, 后 40 字节 == 0");
        // ⚠️ 2026-09-30 判据结构修复: 原判据
        //   `chk(expb[60] === fcsb[0] && expb[63] === fcsb[3], "TX pad: FCS 逐字节正确")`
        //   **已删除** —— fcsb 来自 calc_fcs(20) = **只对内容字节**的 CRC, 与当时实现的
        //   覆盖面同源 ⇒ 实现漏掉 pad 时 oracle 同步漏掉 (DEFECT #1 就是这么藏的)。
        //   替代 = fcs_chk_wire (独立 oracle: 输入是**线上字节**, 含 DUT 补的 pad)。
        fcs_chk_wire("TX pad(20B)     ", 60);

        // 8.3 非 8 字节整数倍 (内容与 FCS 跨字)
        //   ⚠️ 2026-09-29 (GATEFIX D4): 用例从 61..63 扩到 **61..65** —— 补上 /T/ 落
        //   **lane4** (内容 64 ⇒ 线上 68) 与 **lane5** (内容 65 ⇒ 线上 69) 两个此前
        //   TX 侧完全无覆盖的落位 (原覆盖 {0,1,2,3,6,7}, lane4 只在环回出现且不做格式判据)。
        //   期望来源: /T/ 落 lane (L mod 8) = [S1] 49.2.4.9 + rtl/mac_10g_defs.vh(§/T/ 落位)
        //             + 与 组 3 的 RX 侧同式判据 (`rx_dbg_last_tlane == (L mod 8)`) 对偶。
        for (k = 61; k <= 65; k = k + 1) begin
            $display("  -- 8.3 内容 %0d B / 线上 %0d B ⇒ /T/ 应在 lane %0d", k, k+4, (k+4)%8);
            reset_all;
            txq_n = 0; txq_i = 0; base = xcap_n;
            tx_load_frame(k);
            tx_wait;
            wi = find_s(base);
            chk(wi >= 0, "TX 非整拍: 找到 /S/");
            tx_decode(wi);
            chk(idx === k + 4, "TX 非整拍: 数据字节数 == 内容 + 4");
            chk(t_lane === ((k+4) % 8), "TX non-mult-8: /T/ lane == (L mod 8)");
            ecnt = 0;
            for (w = 0; w < k; w = w + 1) if (expb[w] !== cbuf[w]) ecnt = ecnt + 1;
            chk(ecnt === 0, "TX 非整拍: 内容逐字节一致");
            chk(expb[k] === fcsb[0] && expb[k+1] === fcsb[1] &&
                expb[k+2] === fcsb[2] && expb[k+3] === fcsb[3],
                "TX 非整拍: FCS 跨字后仍逐字节正确");
            chk(ndata_after_t === 0, "TX 非整拍: /T/ 之后无数据 lane");
            chk(nidle >= 12, "TX 非整拍: /T/ 之后 >= 12 个 /I/ (IFG)");
        end

        // 8.3b ⭐ /T/ 落在 lane7 的那种帧 (内容 67 ⇒ 线上 71 ⇒ 末内容字 3 字节 ⇒ /T/ 在 lane 7):
        //   这一条专门管 IFG —— 该情形下尾字里**一个 /I/ 都没有**, 全靠 S_IFG 补够 12 个,
        //   所以它是"IFG 阈值被改小"这类变异的唯一判别面
        //   (期望来源: [S1] 46.2.1/49.2.4.9 + BASER_TABLES §3 的 IFG 要求)
        reset_all;
        txq_n = 0; txq_i = 0; base = xcap_n;
        tx_load_frame(67);
        tx_wait;
        wi = find_s(base);
        chk(wi >= 0, "TX t_start=3: 找到 /S/");
        tx_decode(wi);
        chk(idx === 71, "TX t_start=3: 数据字节数 == 67 + 4");
        chk(t_lane === 7, "TX t_start=3: /T/ 落在 lane7");
        chk(nidle >= 12, "TX t_start=3: /T/ 之后 >= 12 个 /I/ (IFG 全靠 S_IFG 补)");
        chk(ndata_after_t === 0, "TX t_start=3: /T/ 之后无数据 lane");
        ecnt = 0;
        for (k = 0; k < 67; k = k + 1) if (expb[k] !== cbuf[k]) ecnt = ecnt + 1;
        chk(ecnt === 0, "TX t_start=3: 内容逐字节一致");
        chk(expb[67] === fcsb[0] && expb[70] === fcsb[3], "TX t_start=3: FCS 逐字节正确");

        // 8.3c ⭐ 两帧连发 ⇒ /S/ 到 /S/ 的**字数 = 帧周期** (IFG 的判别面):
        //   clen=67 ⇒ 线上 71B; 前导 1 拍 + 内容/合并 9 拍 + 尾 0 拍 + IFG 2 拍 = 12 拍。
        //   期望来源 = 本设计的拍数算式 (notes §7) + [S1] Clause 4.4 的帧长/IFG 常量;
        //   ⚠️ 这条是唯一能区分"IFG 阈值被改小"的判据 (单帧用例里 S_IDLE 的空闲字
        //      与 IFG 空闲字不可区分 —— 实测踩过)
        reset_all;
        txq_n = 0; txq_i = 0; base = xcap_n;
        tx_load_frame(67);
        tx_load_frame(67);
        tx_wait;
        begin : tx_period
            integer s1, s2;
            s1 = find_s(base);
            chk(s1 >= 0, "TX 周期: 找到第 1 个 /S/");
            s2 = find_s(s1 + 1);
            chk(s2 >= 0, "TX 周期: 找到第 2 个 /S/");
            chk((s2 - s1) === 12, "TX 周期: /S/→/S/ == 12 拍 (IFG 12 个 /I/ 的算术结果)");
            chk(tx_stat_frames === 2, "TX 周期: 两帧都发完");
        end

        // 8.3d ⭐ 帧周期第二档 (内容 63 ⇒ 线上 67B) —— **实测复核 D5 的那一行**
        //   拍数推导 (逐常量核对 rtl/mac_tx_10g.v): 1(前导) + 8(内容字, 末字与尾合并 ⇒ 无额外尾字)
        //   + 1(S_TAIL1 尾字: lw_ts=7 ⇒ m_tptr=1 ⇒ /T/ 落 lane3, 该字自带 4 个 /I/)
        //   + 1(S_IFG: m_idle=4, 4+8 >= 12 ⇒ 恰 1 拍) = **11 拍**
        //   ⇒ 实占 88 B; 线侧预算 = 8(前导) + 67(线上帧) + 12(IPG) = 87 B ⇒ 效率 98.9%
        //   期望来源: 本设计拍数算式 (P7B_MAC_DESIGN.md §7 的公式, 逐常量手推) + [S1] Clause 4.4
        //   ⚠️ 2026-09-29 (GATEFIX D5): 文档 §7 表 L=63 那行原写 "12 拍 / 90.6%" = **手算笔误**
        //      (与文档自己的算式 1+ceil(63/8)+T+I 矛盾), 实测 = 11 拍 (本条判据即该实测的固化)。
        reset_all;
        txq_n = 0; txq_i = 0; base = xcap_n;
        tx_load_frame(63);
        tx_load_frame(63);
        tx_wait;
        begin : tx_period63
            integer s1b, s2b;
            s1b = find_s(base);
            chk(s1b >= 0, "TX period63: found /S/ #1");
            s2b = find_s(s1b + 1);
            chk(s2b >= 0, "TX period63: found /S/ #2");
            chk((s2b - s1b) === 11, "TX period63: /S/->/S/ == 11 cycles (D5 row L=63)");
            chk(tx_stat_frames === 2, "TX period63: both frames sent");
        end

        // 8.4 最大帧
        reset_all;
        txq_n = 0; txq_i = 0; base = xcap_n;
        tx_load_frame(1514);
        tx_wait;
        wi = find_s(base);
        chk(wi >= 0, "TX 最大帧: 找到 /S/");
        tx_decode(wi);
        chk(idx === 1518, "TX 最大帧: 线上数据字节数 == 1514 + 4");
        ecnt = 0;
        for (k = 0; k < 1514; k = k + 1) if (expb[k] !== cbuf[k]) ecnt = ecnt + 1;
        chk(ecnt === 0, "TX 最大帧: 1514 字节内容逐字节一致");
        chk(expb[1514] === fcsb[0] && expb[1517] === fcsb[3], "TX 最大帧: FCS 逐字节正确");
        chk(nidle >= 12, "TX 最大帧: IFG >= 12 /I/");
        chk(tx_stat_frames === 1, "TX 最大帧: stat_frames == 1");

        // =============================================================
        // 组 9: F-2 —— 帧内中止 + 冲刷 (一个字都不发, 吞掉 TLAST 后重对齐)
        //   期望来源: rtl/mac_tx_64.v:224-244 (S_FLUSH 语义与判据原文)
        //   ⭐ 幽灵帧判据 = **基于线上内容**的逐帧检测器 (2026-09-29 GATEFIX D1 重写)。
        //      形态取自 P6B_CDC_AUDIT.md B8 (F11 判定实验) 的三条:
        //        ① 该帧 FCS 残差合法 (== 0xDEBB20E3) —— ⚠️ 幽灵帧恰恰**是** FCS 正确的,
        //           单靠它判不出来 (原文: "坏帧被包装成 FCS 正确的好帧发出")
        //        ② **该帧 content 与任何注入帧都不等** ⇒ 幽灵帧   ← 主判据 (节末逐帧判)
        //        ③ 线上帧数 > 注入帧数 ⇒ 幽灵帧                 ← 节末同时判
        //      为什么必须换掉旧判据: 旧的靠 find_s(base+100) 的**魔数偏移**找"第二个 /S/",
        //      而幽灵帧自己带一个 /S/, 正好落在 base+100 之前 ⇒ 判据取到的是幽灵**之后**
        //      那个本来正确的帧; 另一个 `bad==0` 扫描在第二个 /S/ 处收工 ⛔ 结构性看不到
        //      幽灵帧的载荷。实证: 变异 M7b 真的发幽灵帧 + 伪装计数器 ⇒ 旧门 229/0 PASS。
        //      ⇒ 计数器 (stat_flush_done/words) 不是本合同判据 (它们可以被伪装);
        //        "线上每一帧逐字节必须是某个注入帧" 才是。
        // =============================================================
        $display("-- 组 9: F-2 中止/冲刷");
        reset_all;
        txq_n = 0; txq_i = 0; base = xcap_n;
        fill_content(200); calc_fcs(200);
        inj_n = 0;
        inj_add(200);            // 注入帧 A = 被中止的 200 字节帧 (期望: 线上只能是它的残前缀)
        for (w = 0; w < 4; w = w + 1)
            tx_push({cbuf[w*8+0], cbuf[w*8+1], cbuf[w*8+2], cbuf[w*8+3],
                     cbuf[w*8+4], cbuf[w*8+5], cbuf[w*8+6], cbuf[w*8+7]}, 8'hFF, 1'b0);
        while (txq_i < txq_n) @(posedge clk);
        for (i = 0; i < 80; i = i + 1) @(posedge clk);
        chk(tx_stat_abort === 1, "F-2: 断供 ⇒ stat_abort == 1");
        for (w = 4; w < 25; w = w + 1) begin
            if (200 - w*8 >= 8)
                tx_push({cbuf[w*8+0], cbuf[w*8+1], cbuf[w*8+2], cbuf[w*8+3],
                         cbuf[w*8+4], cbuf[w*8+5], cbuf[w*8+6], cbuf[w*8+7]},
                        8'hFF, (w === 24) ? 1'b1 : 1'b0);
            else
                tx_push({cbuf[192], cbuf[193], cbuf[194], cbuf[195], cbuf[196],
                         cbuf[197], cbuf[198], cbuf[199], 8'd0},
                        (8'hFF << (8 - (200 - w*8))), 1'b1);
        end
        tx_load_frame(60);
        inj_add(60);             // 注入帧 B = 冲刷后应**完整**发出的新帧
        tx_wait;
        begin : f2_chk
            integer f_t1, ns, bad;
            f_t1 = 0; ns = 0; bad = 0;
            for (i = base; i < xcap_n; i = i + 1) begin
                for (k = 0; k < 8; k = k + 1) begin
                    if (xcap_c[i][k] === 1'b1) begin
                        // 第 1 个 /S/ = 被中止帧自己的前导; 第 2 个 = 冲刷后的新帧
                        if (xcap_d[i][8*k +: 8] === 8'hFB && k === 0) ns = ns + 1;
                        if ((ns >= 1) && (xcap_d[i][8*k +: 8] === 8'hFD)) f_t1 = 1;
                        if (ns >= 2) i = xcap_n;      // 到第二帧 /S/ 即收工
                    end else if ((ns === 1) && (f_t1 === 1'b1)) begin
                        bad = bad + 1;
                    end
                end
            end
            chk(f_t1 === 1, "F-2: 中止后线上出现结帧 /T/ (802.3 要求)");
            chk(ns >= 2,    "F-2: 冲刷后重新对齐并发出下一帧 /S/");
            // ⚠️ 本条只覆盖"中止帧 /T/ 与新帧 /S/ **之间**"这段窄窗口 (802.3: /T/ 之后
            //    到下一个 /S/ 只能有控制字符)。**它判不出幽灵帧** —— 幽灵帧自己带
            //    完整前导, 中间那段仍然是干净的 ⇒ 幽灵帧的判别力在节末的逐帧内容检测器。
            chk(bad === 0,  "F-2: 中止帧 /T/ 与新帧 /S/ 之间无任何数据字");
            chk(tx_stat_flush_done === 1, "F-2: stat_flush_done == 1");
            chk(tx_stat_flush_words >= 1, "F-2: stat_flush_words >= 1");
            chk(tx_stat_frames >= 1,      "F-2: 新帧正常发完");
        end
        // F-2 幽灵帧检测 (B8②/③): 从 DUT 的 TX XGMII 输出**解出每一帧的实际内容**,
        //   逐帧断言"它必须是某个被注入的帧" —— 任何"不是任何注入帧"的帧 = 幽灵帧 = FAIL。
        //   判定逐帧独立 (每帧一条判据), 不靠"总数对账"。
        //   被中止帧 A 的合法形态 = 它的**残缺前缀** (无 FCS, /T/ 提前结帧, 802.3 允许多发 runt);
        //   新帧 B 的合法形态 = 完整内容 + FCS 逐字节相等。
        //   ⚠️ 为什么"前缀"是安全的: 幽灵帧的载荷是 A 的**尾段** (残字), 不是 A 的开头 ⇒
        //      它通不过前缀比对 (M7/M7b 实证)。
        begin : f2_ghost
            integer q2, nfull;
            tx_scan_frames(base, xcap_n);
            $display("  -- F-2 幽灵检测: 注入 %0d 帧 / 线上解出 %0d 帧 (幽灵 %0d)",
                     inj_n, wfr_nf, wfr_ghost_n);
            chk(wfr_nf === inj_n, "F-2 ghost: wire frame count == injected count (B8 #3)");
            nfull = 0;
            for (q2 = 0; q2 < wfr_nf && q2 < WFR_MAXF; q2 = q2 + 1) begin
                $display("  -- F-2 幽灵检测: 线上第 %0d 帧 @xcap[%0d] %0d 字节, kind=%0d (0=幽灵 1=残缺前缀 2=完整)",
                         q2, wfr_start[q2], wfr_len[q2], wfr_kind[q2]);
                chk(wfr_kind[q2] !== 0,
                    "F-2 ghost: every wire frame == some injected frame (B8 #2)");
                if (wfr_kind[q2] === 2) nfull = nfull + 1;
            end
            chk(nfull >= 1, "F-2 ghost: post-flush new frame == injected B, byte-exact");
        end

        // =============================================================
        // 组 10: TX→RX 环回 (强判据, 但**对称** ⇒ 对绝对字节序零判别力,
        //   判别力声明见 P7B_SPEC.md §3.3)
        //   期望来源: 内容 + FCS 由 TB 独立算
        // =============================================================
        $display("-- 组 10: TX→RX 环回");
        reset_all;
        txq_n = 0; txq_i = 0; base = xcap_n;
        tx_load_frame(200);
        tx_wait;
        wi = find_s(base);
        chk(wi >= 0, "环回: 找到 /S/");
        reset_all;
        rx_clr;
        drv_idle_all;
        for (i = 0; i < 220; i = i + 1) begin
            drv_d[i] = xcap_d[wi + i];
            drv_c[i] = xcap_c[wi + i];
        end
        drv_run(220);
        chk(rx_frn >= 1,      "环回: RX 至少收到 1 帧");
        chk(rx_fl[0] === 200, "环回: 交付 200 字节 == 原始内容长度");
        chk(rx_fcrs[0] === 1, "环回: FCS 正确 (TX/RX 的 CRC+FCS 约定自洽)");
        ecnt = 0;
        for (i = 0; i < 200; i = i + 1)
            if (rx_got[rx_fs[0]+i] !== cbuf[i]) ecnt = ecnt + 1;
        chk(ecnt === 0, "环回: 200 字节逐字节一致");

        // =============================================================
        // 组 11: TX→RX 自洽 (2026-09-30 新增; DEFECT #1 的**常驻**判据)
        //   判据 = **自家 TX 发出的帧, 回放进自家 RX 必须被接受** (rx_fcrs == 1),
        //          且交付内容**逐帧逐字节** == 内容 + pad 0 (不靠计数器对账)。
        //   覆盖: L=1 (极端最小) / 18 (F2 文档原案) / 42 (ARP 应答尺寸) /
        //         54 (TCP 纯 ACK 尺寸) / 57 (pad 全落在末内容字, 无 S_TAIL0 纯 pad 字) /
        //         60 (无 pad 对照) / 200 (>60 普通帧对照)
        //   期望来源: 802.3 (FCS 覆盖收到的**全部**字节) + 我们自己的 RX 是独立实现
        //     (mac_rx_10g + 另一个 crc32_64 实例; 其覆盖集 = **收到的**字节流)
        //     ⇒ TX/RX 的 FCS 覆盖面若不一致, 回放必然 crc_err ⇒ tcrs=0。
        //   为什么必须常驻: 这正是 2026-09-30 抓到 DEFECT #1 的手段 (校准过的 A/B 回放),
        //     而当时单元门 252 checks / 0 fail 全 PASS —— 同源 oracle 与计数器都看不见它。
        // =============================================================
        $display("-- 组 11: TX->RX 自洽 (own TX frame must be ACCEPTED by own RX)");
        for (k = 0; k < 7; k = k + 1) begin
            case (k)
                0: begin sz = 1;   tagbuf = "TX->RX L=1      "; end
                1: begin sz = 18;  tagbuf = "TX->RX L=18     "; end
                2: begin sz = 42;  tagbuf = "TX->RX L=42     "; end
                3: begin sz = 54;  tagbuf = "TX->RX L=54     "; end
                4: begin sz = 57;  tagbuf = "TX->RX L=57     "; end
                5: begin sz = 60;  tagbuf = "TX->RX L=60     "; end
                default: begin sz = 200; tagbuf = "TX->RX L=200    "; end
            endcase
            clen_w = (sz < 60) ? 60 : sz;                 // 线上内容长度 (含 pad)
            $display("  -- 11.%0d 内容 %0d B ⇒ 线上内容 %0d B (pad %0d B)",
                     k, sz, clen_w, clen_w - sz);
            reset_all;
            txq_n = 0; txq_i = 0; base = xcap_n; rx_clr;
            tx_load_frame(sz);
            tx_wait;
            wi = find_s(base);
            chk(wi >= 0, {tagbuf, "TX found /S/"});
            tx_decode(wi);
            chk(idx === clen_w + 4,   {tagbuf, "wire bytes == content+pad+FCS"});
            chk(ndata_after_t === 0,  {tagbuf, "no data lane after /T/"});
            chk(nidle >= 12,          {tagbuf, "IFG >= 12 /I/"});
            ecnt = 0;
            for (w = 0; w < sz; w = w + 1) if (expb[w] !== cbuf[w]) ecnt = ecnt + 1;
            for (w = sz; w < clen_w; w = w + 1) if (expb[w] !== 8'h00) ecnt = ecnt + 1;
            chk(ecnt === 0, {tagbuf, "payload then zero pad, byte-exact"});
            fcs_chk_wire(tagbuf, clen_w);      // 独立 oracle (输入 = 线上字节, 含 pad)
            // ---- 回放: 线上捕获字 (自 /S/ 起) 打进自家 RX ----
            //   48 拍 ≥ 最长档 (L=200 ⇒ 线上 204B ⇒ 27 拍) + IFG 余量
            reset_all;
            rx_clr;
            drv_idle_all;
            for (i = 0; i < 48; i = i + 1) begin
                drv_d[i] = xcap_d[wi + i];
                drv_c[i] = xcap_c[wi + i];
            end
            rx_fcrs[0] = 0; rx_fl[0] = 0; rx_fterr[0] = 0;   // 清陈旧值 (计数器不可信)
            drv_run(48);
            chk(rx_frn === 1,      {tagbuf, "RX delivered exactly 1 frame"});
            chk(rx_fcrs[0] === 1,  {tagbuf, "RX tcrs==1 (own TX frame ACCEPTED by own RX)"});
            chk(rx_fl[0] === clen_w, {tagbuf, "RX payload == content+pad bytes"});
            chk(rx_fterr[0] === 0, {tagbuf, "RX terr==0"});
            ecnt = 0;
            for (i = 0; i < sz; i = i + 1)
                if (rx_got[rx_fs[0] + i] !== cbuf[i]) ecnt = ecnt + 1;
            for (i = sz; i < clen_w; i = i + 1)
                if (rx_got[rx_fs[0] + i] !== 8'h00) ecnt = ecnt + 1;
            chk(ecnt === 0, {tagbuf, "RX payload byte-exact (content + zero pad)"});
        end

        $display("=== tb_mac_10g done: %0d checks, %0d fail ===", nchk, nfail);
        if (nfail !== 0) $display("VERDICT = FAIL");
        else             $display("VERDICT = PASS");
        $finish;
    end

endmodule
