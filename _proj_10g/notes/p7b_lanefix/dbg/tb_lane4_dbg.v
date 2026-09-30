`timescale 1ns/1ps
// ===========================================================================
// tb_lane4_dbg.v -- P7B_LANEFIX 调试台 (scratch; 不是门)
//   只做一件事: 往 mac_rx_10g 的 XGMII 口注入一个 **/S/ 在 lane0 或 lane4** 的帧,
//   把 MAC 交付的字流逐拍打出来, 并与期望字节流逐字节比对。
//   用途 = 修 lane4 重对齐时定位"到底哪一拍丢了/错了"。
// ===========================================================================
module tb_lane4_dbg;

    reg clk = 1'b0, rst_n = 1'b0;
    always #3.2 clk = ~clk;                     // ~156 MHz

    reg  [63:0] drv_d = 64'h0707070707070707;
    reg  [7:0]  drv_c = 8'hFF;

    wire [63:0] m_tdata; wire [7:0] m_tkeep; wire m_tvalid;
    wire        m_tlast, m_tuser, m_tcrs, m_terr;
    reg         m_tready = 1'b1;

    wire [31:0] st_frames, st_crc, st_drop, st_bytes, st_full, st_part, st_orph, st_ovf, st_wo;
    wire [31:0] st_words, st_pay, st_er, st_bad, st_frag, st_no_s, st_q, st_short, st_long;
    wire [15:0] dbg_len; wire [3:0] dbg_tlane; wire [1:0] dbg_state;

    mac_rx_10g u_dut (
        .clk(clk), .rst_n(rst_n),
        .xgmii_rxd(drv_d), .xgmii_rxc(drv_c),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .m_axis_tcrs(m_tcrs), .m_axis_terr(m_terr),
        .stat_frames(st_frames), .stat_crc_err(st_crc), .stat_drop(st_drop), .stat_bytes(st_bytes),
        .stat_drop_full(st_full), .stat_drop_partial(st_part), .stat_orphan_bytes(st_orph),
        .stat_fifo_ovf(st_ovf), .dbg_stat_words_out(st_wo),
        .stat_rx_words(st_words), .stat_rx_pay_bytes(st_pay), .stat_rx_er_words(st_er),
        .stat_rx_bad_words(st_bad), .stat_rx_frag(st_frag), .stat_rx_no_s(st_no_s),
        .stat_rx_q(st_q), .stat_rx_short(st_short), .stat_rx_long(st_long),
        .dbg_rx_last_len(dbg_len), .dbg_rx_last_tlane(dbg_tlane), .dbg_rx_state(dbg_state)
    );

    // ---------------- 帧字节流 (线上字节 + 控制标志) ----------------
    reg [7:0]  fb [0:2047];
    reg        fc [0:2047];
    integer    fn;                       // 字节数
    reg [7:0]  exp [0:2047];             // 期望交付的内容 (不含 FCS)
    integer    exp_n;

    function [31:0] crc_byte;
        input [31:0] c; input [7:0] b;
        integer i; reg [31:0] x;
        begin
            x = c ^ {24'd0, b};
            for (i = 0; i < 8; i = i + 1)
                x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
            crc_byte = x;
        end
    endfunction

    // lane: 0 或 4; clen: 内容字节数 (FCS 由 TB 追加)
    task build(input integer lane, input integer clen);
        integer i; reg [31:0] c;
        begin
            fn = 0;
            for (i = 0; i < lane; i = i + 1) begin fb[fn] = 8'h07; fc[fn] = 1'b1; fn = fn + 1; end
            fb[fn] = 8'hFB; fc[fn] = 1'b1; fn = fn + 1;
            for (i = 0; i < 6; i = i + 1) begin fb[fn] = 8'h55; fc[fn] = 1'b0; fn = fn + 1; end
            fb[fn] = 8'hD5; fc[fn] = 1'b0; fn = fn + 1;
            exp_n = clen;
            c = 32'hFFFFFFFF;
            for (i = 0; i < clen; i = i + 1) begin
                exp[i] = (i[7:0] ^ 8'hA5);
                fb[fn] = exp[i]; fc[fn] = 1'b0; fn = fn + 1;
                c = crc_byte(c, fb[fn-1]);
            end
            c = ~c;
            for (i = 0; i < 4; i = i + 1) begin
                fb[fn] = c[8*i +: 8]; fc[fn] = 1'b0; fn = fn + 1;
                c = crc_byte(c, 8'h00);          // (占位, 不影响比对)
            end
            fb[fn] = 8'hFD; fc[fn] = 1'b1; fn = fn + 1;
            for (i = 0; i < 16; i = i + 1) begin fb[fn] = 8'h07; fc[fn] = 1'b1; fn = fn + 1; end
        end
    endtask

    // ---------------- 驱动 + 采集 ----------------
    integer wr_i;                        // 当前驱动到第几字节
    integer i_lane, i_clen;
    integer o_n = 0;                     // 已交付字数
    reg [7:0] got [0:2047]; integer got_n = 0;
    integer frn = 0, cur_n = 0, sop_tk_bad = 0, sop_tk = 0;
    integer i, k, bad;

    always @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            o_n = o_n + 1;
            $display("  [W%0d] td=%016h tk=%02h last=%b sop=%b crs=%b err=%b",
                     o_n-1, m_tdata, m_tkeep, m_tlast, m_tuser, m_tcrs, m_terr);
            if (m_tuser) begin sop_tk = m_tkeep; if (m_tkeep !== 8'hFF) sop_tk_bad = sop_tk_bad + 1; end
            for (k = 0; k < 8; k = k + 1)
                if (m_tkeep[7-k]) begin got[got_n] = m_tdata[63-8*k -: 8]; got_n = got_n + 1; end
            if (m_tlast) frn = frn + 1;
        end
    end

    task run(input integer lane, input integer clen);
        begin
            $display("==== lane=%0d clen=%0d ====", lane, clen);
            build(lane, clen);
            o_n = 0; got_n = 0; frn = 0; sop_tk_bad = 0;
            @(negedge clk); rst_n = 1'b0;
            repeat (8) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            repeat (4) @(posedge clk);
            wr_i = 0;
            while (wr_i < fn) begin
                @(negedge clk);
                drv_d = 64'h0707070707070707; drv_c = 8'hFF;
                for (k = 0; k < 8; k = k + 1)
                    if (wr_i + k < fn) begin
                        drv_d[8*k +: 8] = fb[wr_i+k];
                        drv_c[k]        = fc[wr_i+k];
                    end
                wr_i = wr_i + 8;
            end
            repeat (16) @(negedge clk);
            drv_d = 64'h0707070707070707; drv_c = 8'hFF;
            repeat (8) @(posedge clk);
            bad = 0;
            for (i = 0; i < exp_n; i = i + 1)
                if (got[i] !== exp[i]) begin
                    if (bad < 6) $display("  [MISMATCH] byte %0d got=%02h exp=%02h", i, got[i], exp[i]);
                    bad = bad + 1;
                end
            $display("  SUM lane=%0d clen=%0d: words=%0d bytes=%0d frn=%0d sop_tk=%02h sop_bad=%0d mism=%0d drop=%0d dropfull=%0d part=%0d frag=%0d frames=%0d stat_bytes=%0d last_len=%0d",
                     lane, clen, o_n, got_n, frn, sop_tk, sop_tk_bad, bad,
                     st_drop, st_full, st_part, st_frag, st_frames, st_bytes, dbg_len);
        end
    endtask

    initial begin
        if (!$value$plusargs("LANE=%d", i_lane)) i_lane = 0;
        if (!$value$plusargs("CLEN=%d", i_clen)) i_clen = 60;
        run(i_lane, i_clen);
        run(0, 60);
        run(4, 60);
        run(4, 61);
        run(4, 62);
        run(4, 63);
        run(4, 64);
        run(4, 1514);
        $display("==== tb_lane4_dbg done ====");
        $finish;
    end

endmodule
