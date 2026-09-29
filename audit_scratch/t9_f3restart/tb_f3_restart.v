`timescale 1ns/1ps
//=============================================================================
// tb_f3_restart.v -- F-3 判定实验: "MMCM 失锁 -> 重锁" 时 DP 侧重启会读到什么?
//=============================================================================
// 链路 (与 wrapper 双域形态同构): GMII 帧源 -> mac_rx_64(FE 125MHz)
//        -> fifo_async 76/256/FWFT (u_rxcdc) -> vlan_strip (真 RTL, DP 156.25MHz)
//        -> DP 水槽 (按 TLAST 成帧, 记录每帧内容/来源/长度)
// 重启模型 (clk_gen_p6b 的等价物): TB 停 DP 时钟 + 断言 dp_rst_dp, 停 N 拍后恢复钟、
//   再 4 个 DP 沿释放 (与 rtl/clk_gen_p6b.v 的"异步置位/同步释放"同形态)。
//
// 两种接线 (编译期宏; 判据全同):
//   WIRE_NEW : u_rxcdc.rd_rst_n = reset_n & dp_rst_n   <-- 本次提议的改法
//   (默认)   : u_rxcdc.rd_rst_n = reset_n              <-- 现行 wrapper
//
// 判据 (每次重启后对"重启后交付的第一个帧"):
//   J1 陈字      : 该帧内容是否匹配**重启前**已开始接收的帧 (源帧下标 <= K)?
//                  (匹配 = 逐字节在某 (帧,偏移) 上全等)
//   J2 截断帧    : 该帧是否**不是完整帧** (偏移 != 0 或 长度 != 整帧) 却带着 tcrs=1?
//   J3 FE 静默丢 : 重启窗口内 FE 侧"被接受的 push"数 vs DUT wbin 增量 (差 = 静默丢字)
//=============================================================================
module tb_f3_restart;

    // ---------------- 时钟 / 复位 ----------------
    reg gclk = 0, dclk = 0;
    reg reset_n = 0, dp_clk_en = 1, dp_rst_dp = 0;
    always #4.0 gclk = ~gclk;              // 125.00 MHz 前端
    always #3.2 dclk = ~dclk;              // 156.25 MHz 数据面
    wire dpc = dp_clk_en ? dclk : 1'b0;
    wire dp_rst_n = ~dp_rst_dp;

    // ---------------- 激励: 12 帧, 每帧 64B 内容, 内容 = f(f, k) ----------------
    localparam integer NFR = 12, CLEN = 64, IFG = 24;
    localparam integer FBYTES = 8 + CLEN + 4;    // 前导8 + 内容 + FCS4
    localparam integer MAXB = NFR * (FBYTES + IFG) + 16;
    reg  [7:0] sd [0:MAXB-1];
    reg  [7:0] sv [0:MAXB-1];
    integer nstim, si;
    // 内容字节: (f*67 + k*29) & 0xFF —— 任 (帧,偏移) 组合唯一
    function [7:0] cbyte;
        input integer f; input integer k;
        begin cbyte = ((f * 67 + k * 29) & 8'hFF);
        end
    endfunction

    // 重启点: 第 3 帧内容中段 (K = 3)
    localparam integer IDX_STOP = 3*(FBYTES+IFG) + 8 + 32;

    function [31:0] cstep;
        input [31:0] c; input [7:0] bb;
        reg [31:0] rr; integer ii;
        begin
            rr = c;
            for (ii = 0; ii < 8; ii = ii + 1)
                rr = (rr[0] ^ bb[ii]) ? ((rr >> 1) ^ 32'hEDB88320) : (rr >> 1);
            cstep = rr;
        end
    endfunction

    integer f, k;
    reg [31:0] cr;
    reg [7:0]  fcs [0:3];
    initial begin
        nstim = 0;
        for (k = 0; k < MAXB; k = k + 1) begin sd[k] = 8'h07; sv[k] = 0; end
        for (f = 0; f < NFR; f = f + 1) begin
            for (k = 0; k < 7; k = k + 1) begin sd[nstim] = 8'h55; sv[nstim] = 1; nstim = nstim + 1; end
            sd[nstim] = 8'hD5; sv[nstim] = 1; nstim = nstim + 1;
            cr = 32'hFFFFFFFF;
            for (k = 0; k < CLEN; k = k + 1) begin
                sd[nstim] = cbyte(f, k); sv[nstim] = 1; nstim = nstim + 1;
                cr = cstep(cr, cbyte(f, k));
            end
            fcs[0] = cr[7:0] ^ 8'hFF; fcs[1] = cr[15:8] ^ 8'hFF;
            fcs[2] = cr[23:16] ^ 8'hFF; fcs[3] = cr[31:24] ^ 8'hFF;
            for (k = 0; k < 4; k = k + 1) begin
                sd[nstim] = fcs[k]; sv[nstim] = 1; nstim = nstim + 1;
                cr = cstep(cr, fcs[k]);
            end
            if (cr !== 32'hDEBB20E3) $display("TB-CRC-SELFTEST-FAIL f=%0d res=%08x", f, cr);
            for (k = 0; k < IFG; k = k + 1) begin sd[nstim] = 8'h07; sv[nstim] = 0; nstim = nstim + 1; end
        end
        $display("TB-STIM frames=%0d bytes=%0d stopIdx=%0d", NFR, nstim, IDX_STOP);
    end

    reg [7:0] gd; reg gdv, gerr;
    always @(posedge gclk) begin
        if (!reset_n) begin si <= 0; gd <= 8'h07; gdv <= 0; gerr <= 0; end
        else if (si < nstim) begin
            gd <= sd[si]; gdv <= sv[si]; gerr <= 0; si <= si + 1;
        end else begin
            gd <= 8'h07; gdv <= 0; gerr <= 0;
        end
    end

    // ---------------- DUT ----------------
    wire [63:0] m_tdata; wire [7:0] m_tkeep;
    wire m_tvalid, m_tlast, m_tuser, m_tcrs, m_terr, m_tready;
    wire [31:0] st_frames, st_crc, st_drop, st_bytes, st_dfull, st_dpart, st_orph, st_ovf, st_words;
    wire [63:0] rx_tdata; wire [7:0] rx_tkeep;
    wire rx_tvalid, rx_tlast, rx_tuser, rx_tcrs, rx_terr, rx_tready;
    wire [75:0] cdc_word;
    wire rx_full, rx_empty, cdc_rd;

    mac_rx_64 u_mac (
        .clk(gclk), .rst_n(reset_n),
        .gmii_rxd(gd), .gmii_rx_dv(gdv), .gmii_rx_er(gerr),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .m_axis_terr(m_terr), .m_axis_tcrs(m_tcrs),
        .stat_frames(st_frames), .stat_crc_err(st_crc), .stat_drop(st_drop),
        .stat_bytes(st_bytes),
        .stat_drop_full(st_dfull), .stat_drop_partial(st_dpart),
        .stat_orphan_bytes(st_orph), .stat_fifo_ovf(st_ovf),
        .dbg_stat_words_out(st_words)
    );

`ifdef WIRE_BOTH
    // 变体 C: 两侧**同源同拍**复位 (契约允许的 "同一时刻断言"; FIFO 被清空)
    wire rx_wr_rst_n = reset_n & dp_rst_n;
    wire rx_rd_rst_n = reset_n & dp_rst_n;
`elsif WIRE_NEW
    // 变体 B: 只复位读侧 (= 协调者字面建议; **违反 fifo_async 的复位硬契约**)
    wire rx_wr_rst_n = reset_n;
    wire rx_rd_rst_n = reset_n & dp_rst_n;
`else
    // 变体 A: 现行 wrapper (两侧都只接 reset_n)
    wire rx_wr_rst_n = reset_n;
    wire rx_rd_rst_n = reset_n;
`endif

    fifo_async #(.WIDTH(76), .DEPTH(256), .FWFT(1), .AW(8)) u_rxcdc (
        .wr_clk(gclk), .wr_rst_n(rx_wr_rst_n), .wr_en(m_tvalid),
        .din({m_tdata, m_tkeep, m_tuser, m_tlast, m_tcrs, m_terr}),
        .full(rx_full),
        .rd_clk(dpc), .rd_rst_n(rx_rd_rst_n), .rd_en(cdc_rd),
        .dout(cdc_word), .empty(rx_empty),
        .dbg_wbin(), .dbg_rbin(), .dbg_wgray(), .dbg_rgray(), .dbg_occ_w(), .dbg_occ_r()
    );
    assign {rx_tdata, rx_tkeep, rx_tuser, rx_tlast, rx_tcrs, rx_terr} = cdc_word;
    assign rx_tvalid = ~rx_empty;
    assign rx_tready = 1'b1;                      // 全速消费者 (停摆由停钟实现)
    assign cdc_rd    = rx_tvalid && rx_tready;
    assign m_tready  = ~rx_full;

    // vlan_strip (真 DP 首级)
    wire [63:0] vs_tdata; wire [7:0] vs_tkeep;
    wire vs_tvalid, vs_tready, vs_tlast, vs_tuser, vs_tcrs, vs_terr;
    vlan_strip u_vs (
        .clk(dpc), .rst_n(dp_rst_n),
        .s_axis_tdata(rx_tdata), .s_axis_tkeep(rx_tkeep), .s_axis_tvalid(rx_tvalid),
        .s_axis_tready(rx_tready), .s_axis_tlast(rx_tlast), .s_axis_tuser(rx_tuser),
        .s_axis_tcrs(rx_tcrs), .s_axis_terr(rx_terr),
        .m_axis_tdata(vs_tdata), .m_axis_tkeep(vs_tkeep), .m_axis_tvalid(vs_tvalid),
        .m_axis_tready(vs_tready), .m_axis_tlast(vs_tlast), .m_axis_tuser(vs_tuser),
        .m_axis_tcrs(vs_tcrs), .m_axis_terr(vs_terr),
        .stat_stripped(), .dbg_vlan()
    );
    assign vs_tready = 1'b1;                      // 水槽永远能吞

    // ---------------- DP 水槽: 按 TLAST 成帧, 记录每帧 ----------------
    localparam integer MAXF = 64;
    reg  [7:0] rbuf [0:511];
    reg  [7:0] deliv [0:MAXF*512-1];
    integer    dlen  [0:MAXF-1];
    reg        dcrs  [0:MAXF-1];
    reg        dtuser[0:MAXF-1];
    integer    ndel, rlen, p, q, off, found, srcf, srco;
    reg [7:0]  inp;
    reg        in_frame;
    reg [31:0] n_frag, n_stale, n_whole, n_unrec, n_trunc_crs;
    reg [31:0] restart_seen;      // 重启后已交付帧计数
    integer    K_restart;         // 重启瞬间正在接收的帧号
    reg [31:0] rd_stall_cycles;   // 重启窗口内 DP 侧未消费的拍数 (由 TB 数)
    // FE 侧静默丢字计数
    reg [8:0]  wbin_r;
    reg [31:0] fe_acc, fe_dut_acc;
    wire       wbin_moved = (u_rxcdc.dbg_wbin !== wbin_r);
    wire       acc_now    = m_tvalid && !rx_full;

    always @(posedge gclk or negedge reset_n) begin
        if (!reset_n) begin
            wbin_r <= 0; fe_acc <= 0; fe_dut_acc <= 0;
        end else begin
            if (acc_now) fe_acc <= fe_acc + 32'd1;             // FE 侧"以为被接受"的 push
            if (wbin_moved) fe_dut_acc <= fe_dut_acc + 32'd1;   // DUT 真接受的写
            wbin_r <= u_rxcdc.dbg_wbin;
        end
    end

    reg        rec_pend;
    reg [31:0] rec_len; reg rec_crs, rec_tuser; reg [7:0] rec_nb;
    reg [31:0] dw_all;      // 重启后 DP 消费的字数 (dp_rst_n 清零)
    reg [7:0]  nb;
    always @(posedge dpc or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            rlen <= 0; in_frame <= 0; ndel <= 0; rec_pend <= 0; rec_len <= 0;
            rec_crs <= 0; rec_tuser <= 0; rec_nb <= 0; dw_all <= 0;
        end else begin
            nb = (vs_tkeep[0]?1'b1:1'b0)+(vs_tkeep[1]?1'b1:1'b0)+(vs_tkeep[2]?1'b1:1'b0)+(vs_tkeep[3]?1'b1:1'b0)
                +(vs_tkeep[4]?1'b1:1'b0)+(vs_tkeep[5]?1'b1:1'b0)+(vs_tkeep[6]?1'b1:1'b0)+(vs_tkeep[7]?1'b1:1'b0);
            // ---- 上一拍收尾的帧在这里落盘 (rbuf 已全部写完; 避开 NBA 竞争) ----
            if (rec_pend) begin
                rec_pend <= 1'b0;
                if (ndel < MAXF) begin
                    for (q = 0; q < 512; q = q + 1)
                        deliv[ndel*512 + q] <= rbuf[q];
                    dlen[ndel]   <= rec_len;
                    dcrs[ndel]   <= rec_crs;
                    dtuser[ndel] <= rec_tuser;
                end
                ndel <= ndel + 1;
            end
            if (vs_tvalid) begin
                dw_all <= dw_all + 32'd1;
                for (p = 0; p < 8; p = p + 1)
                    if (vs_tkeep[7-p] && ((rlen + p) < 512)) rbuf[rlen+p] <= vs_tdata[63 - 8*p -: 8];
                if (!in_frame) in_frame <= 1'b1;
                if (vs_tlast) begin
                    rec_pend  <= 1'b1;
                    rec_len   <= rlen + nb;
                    rec_nb    <= nb;
                    rec_crs   <= vs_tcrs;
                    rec_tuser <= (!in_frame) ? vs_tuser : 1'b0;   // 帧首字的 SOP
                    rlen <= 0; in_frame <= 0;
                end else begin
                    rlen <= rlen + nb;
                end
            end
        end
    end

    // ---------------- 重启时序 + 终判 ----------------
    integer guard;
    reg [31:0] W_snap, dw_snap, pushes_after, stale_words;
    initial begin
        reset_n = 0; dp_clk_en = 1; dp_rst_dp = 0;
        repeat (20) @(posedge gclk);
        reset_n = 1;
        // 跑到重启点 (FE 正在收第 3 帧的中段)
        guard = 0;
        while ((si < IDX_STOP) && (guard < 2000000)) begin @(posedge gclk); guard = guard + 1; end
        K_restart = 3;
        W_snap = fe_dut_acc;               // 重启前已被 FIFO 接受的字数 (DUT 探针计数)
        $display("F3 STOP at si=%0d (frame K=%0d mid-content); dp side now restarts; W_snap=%0d",
                 si, K_restart, W_snap);
        dp_rst_dp = 1;                     // 失锁: 复位断言 (异步)
        repeat (2) @(posedge gclk);
        dp_clk_en = 0;                     // 时钟停摆
        repeat (1500) @(posedge gclk);     // 停 1500 拍 (=1500 字节的帧流量)
        dp_clk_en = 1;                     // 重锁: 时钟恢复
        repeat (4) @(posedge dclk);
        dp_rst_dp = 0;                     // 4 个 clk_dp 后释放 (同 clk_gen_p6b)
        $display("F3 RELOCK: fe_acc=%0d dut_acc=%0d (窗口内静默丢 %0d)",
                 fe_acc, fe_dut_acc, fe_acc - fe_dut_acc);
        // 跑完所有帧 + 排空
        guard = 0;
        while ((si < nstim) && (guard < 4000000)) begin @(posedge gclk); guard = guard + 1; end
        repeat (4000) @(posedge gclk);
        // ---- 判定每个交付帧 ----
        n_frag = 0; n_stale = 0; n_whole = 0; n_unrec = 0; n_trunc_crs = 0;
        for (p = 0; p < ndel && p < MAXF; p = p + 1) begin
            found = -1; srcf = -1; srco = -1;
            // 注意: 不能用 `found < 0` 做循环条件 —— 候选不匹配时 found 被置 0,
            // 会把循环一起终止 (第一版 TB 的 bug, 导致全部报 UNRECOGNIZED)。
            for (f = 0; f < NFR; f = f + 1) begin
                for (off = 0; off <= CLEN; off = off + 8) begin
                    if (((off + dlen[p]) <= CLEN) && (srcf < 0)) begin
                        found = 1;
                        for (q = 0; q < dlen[p]; q = q + 1)
                            if (deliv[p*512 + q] !== cbyte(f, off + q)) found = 0;
                        if (found == 1) begin srcf = f; srco = off; end
                    end
                end
            end
            if (found != 1) begin
                n_unrec = n_unrec + 1;
                $display("F3 DELIV[%0d] len=%0d UNRECOGNIZED crs=%b", p, dlen[p], dcrs[p]);
                if (p < 2) begin
                    $write("   ACT: ");
                    for (q = 0; q < 16 && q < dlen[p]; q = q + 1) $write("%02x ", deliv[p*512+q]);
                    $write("   EXP(f3,24): ");
                    for (q = 0; q < 16; q = q + 1) $write("%02x ", cbyte(3, 24+q));
                    $write("   EXP(f4,0 ): ");
                    for (q = 0; q < 16; q = q + 1) $write("%02x ", cbyte(4, q));
                    $write("\n");
                end
            end else if ((srco == 0) && (dlen[p] == CLEN)) begin
                n_whole = n_whole + 1;
                $display("F3 DELIV[%0d] len=%0d WHOLE 帧%0d crs=%b tuser=%b", p, dlen[p], srcf, dcrs[p], dtuser[p]);
            end else begin
                n_frag = n_frag + 1;
                if (srcf <= K_restart) n_stale = n_stale + 1;
                if (dcrs[p]) n_trunc_crs = n_trunc_crs + 1;
                $display("F3 DELIV[%0d] len=%0d **片段** 源帧=%0d 偏移=%0d crs=%b tuser=%b %s",
                         p, dlen[p], srcf, srco, dcrs[p], dtuser[p],
                         (srcf <= K_restart) ? "<== 陈字(重启前就开始收的帧)" : "(重启后才收到的字)");
            end
        end
        $display("F3 SUMMARY ndel=%0d whole=%0d frag=%0d stale_frag=%0d trunc_with_crs=%0d unrec=%0d",
                 ndel, n_whole, n_frag, n_stale, n_trunc_crs, n_unrec);
        $display("F3 SUMMARY fe_acc=%0d dut_acc=%0d silent_drop=%0d mac_frames=%0d mac_drop=%0d ovf=%0d",
                 fe_acc, fe_dut_acc, fe_acc - fe_dut_acc, st_frames, st_drop, st_ovf);
        // ---- 陈字判据 (守恒式, 与"帧身份"无关, 因此对"C 变体"也成立) ----
        // 重启后 DP 消费的字数 应当 == 重启后 FE 新推入的字数;
        // 多出来的部分 = **重启前就已在 FIFO 里 / 已被消费过的字** = 陈字。
        pushes_after = fe_dut_acc - W_snap;
        stale_words  = (dw_all > pushes_after) ? (dw_all - pushes_after) : 32'd0;
        $display("F3 STALE-CONSERV dw_all=%0d pushes_after=%0d => stale_words=%0d %s",
                 dw_all, pushes_after, stale_words,
                 (stale_words != 0) ? "<== 重启后交付了重启前的字!" : "(无陈字)");
        $display("F3 VERDICT stale_frag=%0d stale_words=%0d silent_drop=%0d", n_stale, stale_words, fe_acc - fe_dut_acc);
        $finish;
    end
    initial begin
        #200000000;
        $display("F3 TIMEOUT si=%0d ndel=%0d", si, ndel);
        $finish;
    end
endmodule
