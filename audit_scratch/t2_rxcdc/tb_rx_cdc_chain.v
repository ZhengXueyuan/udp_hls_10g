`timescale 1ns/1ps
//=============================================================================
// tb_rx_cdc_chain.v -- P6b **RX 跨域边界**整链门 (wrapper 拓扑同构)
//=============================================================================
// 链路 (逐字镜像 board/wrapper_p4.v:391-441):
//   GMII 帧源 -> mac_rx_64 (FE 125MHz, 内含 8 深 fifo_sync)
//             -> AXIS 直连 (搬运 = 握手本身, 无中间模块)
//             -> fifo_async 76/256/FWFT u_rxcdc
//             -> DP 156.25MHz 消费者 (停摆/喷发波形)
//   tready 逐字同 wrapper:  m_axis_tready = ~rx_fifo_full;  rd_en = ~empty && tready
//
// 判据:
//   R1 原子性 (A2 的决定性判据): **逐拍**核对 DUT 自己的两根探针
//        Δdbg_rptr(mac_rx 内 fifo_sync, gmii 域) == Δdbg_wbin(u_rxcdc, gmii 域)
//      "先弹后挡" (弹字与写 CDC 不同拍) 立刻现形 —— 这正是 F4(b) 的形态。
//   R1b 接受写的同一拍, mac_rx 内 FIFO 必须真的弹出了字。
//   R2 帧保真: 每个交付的数据帧逐字节 == 某个注入帧; SOP 唯一; TERM 字 (tkeep=0)
//      只允许作为丢帧标记 (terr=1,tcrs=0)。
//   R3 守恒: 交付数据帧 + stat_drop == 注入帧数;  TERM 数 == stat_drop_partial;
//      stat_fifo_ovf == 0;  mac_rx 出词数 == 交付词数;  CDC 两指针最终相等。
//   R4 正证据: 必须真的撞过 CDC full (refw>0)、丢过帧 (drop>0)、交付过帧 (dframes>=4)。
//
// 变异 (编译期宏; 负对照必须 FAIL):
//   NEG_LATE_GATE : tready 寄存器化 (弹字与写 CDC 差一拍) => R1 抓静默丢失
//   NEG_NO_BP     : tready 恒 1 (忘接 full)               => R1 抓静默丢失
//=============================================================================
module tb_rx_cdc_chain;

    // ---------------- 时钟 / 复位 ----------------
    reg gclk = 0, dclk = 0, reset_n = 0;
    always #4.0 gclk = ~gclk;      // 125.00 MHz  (前端)
    always #3.2 dclk = ~dclk;      // 156.25 MHz  (数据面)

    // ---------------- 激励存储 ----------------
    localparam integer MAXB = 200000;
    localparam integer NFR  = 48;
    reg  [7:0] sd [0:MAXB-1];
    reg  [7:0] sv [0:MAXB-1];
    reg  [7:0] se [0:MAXB-1];
    integer nstim, si;
    reg  [7:0] fbuf [0:NFR*1600-1];
    integer fstart [0:NFR-1];
    integer flen   [0:NFR-1];
    integer nfr;

    // ---------------- 端口线网 ----------------
    reg  [7:0] gd;  reg gdv, gerr;
    wire [63:0] m_tdata; wire [7:0] m_tkeep;
    wire m_tvalid, m_tlast, m_tuser, m_tcrs, m_terr, m_tready;
    wire [31:0] st_frames, st_crc, st_drop, st_bytes;
    wire [31:0] st_dfull, st_dpart, st_orph, st_ovf, st_words;
    wire [63:0] rx_tdata; wire [7:0] rx_tkeep;
    wire rx_tvalid, rx_tlast, rx_tuser, rx_tcrs, rx_terr;
    wire rx_tready;
    wire [75:0] cdc_word_out;
    wire rx_fifo_full, rx_fifo_empty, cdc_rd;
    reg         rv;                  // DP 消费者 ready (必须早声明: cdc_rd 要用)

    // ---------------- DUT ----------------
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

    fifo_async #(.WIDTH(76), .DEPTH(256), .FWFT(1), .AW(8)) u_rxcdc (
        .wr_clk(gclk), .wr_rst_n(reset_n), .wr_en(m_tvalid),
        .din({m_tdata, m_tkeep, m_tuser, m_tlast, m_tcrs, m_terr}),
        .full(rx_fifo_full),
        .rd_clk(dclk), .rd_rst_n(reset_n), .rd_en(cdc_rd),
        .dout(cdc_word_out), .empty(rx_fifo_empty),
        .dbg_wbin(), .dbg_rbin(), .dbg_wgray(), .dbg_rgray(),
        .dbg_occ_w(), .dbg_occ_r()
    );
    assign {rx_tdata, rx_tkeep, rx_tuser, rx_tlast, rx_tcrs, rx_terr} = cdc_word_out;
    assign rx_tvalid = ~rx_fifo_empty;
    assign rx_tready = rv;                        // DP 消费者的 ready (停摆波形)
    assign cdc_rd    = rx_tvalid && rx_tready;

`ifdef NEG_NO_BP
    assign m_tready = 1'b1;
`elsif NEG_LATE_GATE
    reg m_tready_r;
    always @(posedge gclk or negedge reset_n)
        if (!reset_n) m_tready_r <= 1'b0; else m_tready_r <= ~rx_fifo_full;
    assign m_tready = m_tready_r;
`else
    assign m_tready = ~rx_fifo_full;
`endif

    // ---------------- DUT 内部探针 (只读; 用 DUT 自己的观测点) ----------------
    wire [3:0] mrx_rptr = u_mac.u_fifo.dbg_rptr;   // 8 深 fifo_sync, AW=3
    wire [3:0] mrx_wptr = u_mac.u_fifo.dbg_wptr;
    wire       mrx_full = u_mac.u_fifo.dbg_full;
    wire [8:0] cdc_wbin = u_rxcdc.dbg_wbin;        // 跨域 FIFO, AW=8
    wire [8:0] cdc_rbin = u_rxcdc.dbg_rbin;

    // ---------------- GMII 帧源 (非阻塞时钟化驱动) ----------------
    always @(posedge gclk) begin
        if (!reset_n) begin
            si <= 0; gd <= 8'h07; gdv <= 1'b0; gerr <= 1'b0;
        end else if (si < nstim) begin
            gd <= sd[si]; gdv <= sv[si]; gerr <= se[si];
            si <= si + 1;
        end else begin
            gd <= 8'h07; gdv <= 1'b0; gerr <= 1'b0;
        end
    end

    // ---------------- CRC / popcount ----------------
    function [31:0] cstep;
        input [31:0] c; input [7:0] bb;
        reg [31:0] r; integer i;
        begin
            r = c;
            for (i = 0; i < 8; i = i + 1)
                r = (r[0] ^ bb[i]) ? ((r >> 1) ^ 32'hEDB88320) : (r >> 1);
            cstep = r;
        end
    endfunction
    function [7:0] p8;
        input [7:0] x; integer i;
        begin
            p8 = 0;
            for (i = 0; i < 8; i = i + 1) p8 = p8 + x[i];
        end
    endfunction

    // ---------------- 激励生成 ----------------
    integer k, f, nbytes, io;
    reg [31:0] cr;
    reg [7:0]  fcs [0:3];
    initial begin
        nstim = 0; nfr = 0;
        for (k = 0; k < MAXB; k = k + 1) begin sd[k] = 8'h07; sv[k] = 0; se[k] = 0; end
        for (k = 0; k < NFR*1600; k = k + 1) fbuf[k] = 0;
        for (f = 0; f < NFR; f = f + 1) begin
            case (f % 8)
                0: nbytes = 60;   1: nbytes = 64;   2: nbytes = 100;
                3: nbytes = 200;  4: nbytes = 500;  5: nbytes = 1000;
                6: nbytes = 1514; default: nbytes = 14 + 46 + ((f * 37) % 400);
            endcase
            if (nbytes < 60)   nbytes = 60;
            if (nbytes > 1514) nbytes = 1514;
            fstart[f] = nstim + 8;
            flen[f]   = nbytes;
            for (k = 0; k < 7; k = k + 1) begin sd[nstim] = 8'h55; sv[nstim] = 1; nstim = nstim + 1; end
            sd[nstim] = 8'hD5; sv[nstim] = 1; nstim = nstim + 1;
            cr = 32'hFFFFFFFF;
            for (k = 0; k < nbytes; k = k + 1) begin
                io = ((f * 7 + k * 13) ^ (k >> 3)) & 8'hFF;
                fbuf[f*1600 + k] = io[7:0];
                sd[nstim] = io[7:0]; sv[nstim] = 1; nstim = nstim + 1;
                cr = cstep(cr, io[7:0]);
            end
            fcs[0] = cr[7:0] ^ 8'hFF; fcs[1] = cr[15:8] ^ 8'hFF;
            fcs[2] = cr[23:16] ^ 8'hFF; fcs[3] = cr[31:24] ^ 8'hFF;   // FCS = ~raw, 线上 LSB-first
            for (k = 0; k < 4; k = k + 1) begin
                sd[nstim] = fcs[k]; sv[nstim] = 1; nstim = nstim + 1;
                cr = cstep(cr, fcs[k]);                                // 寄存器不取反, 只喂字节
            end
            if (cr !== 32'hDEBB20E3)
                $display("TB-CRC-SELFTEST-FAIL f=%0d residue=%08x (FCS 生成错)", f, cr);
            for (k = 0; k < (24 + (f % 5) * 9); k = k + 1) begin
                sd[nstim] = 8'h07; sv[nstim] = 0; nstim = nstim + 1;
            end
        end
        nfr = NFR;
        $display("TB-STIM frames=%0d stim_bytes=%0d", nfr, nstim);
    end

    // ---------------- 读域: DP 消费者 (停摆/喷发波形) ----------------
    reg  [15:0] rc;
    reg  [31:0] dwords, dframes, dterm, dbad, dorph;
    reg  [7:0]  rbuf [0:1599];
    integer     rlen;
    integer     sot;
    reg         in_frame;
    reg         cmp_pend;
    reg  [31:0] cmp_len;
    reg         cmp_crs;
    integer     j, m, kk, ok;
    reg  [7:0]  nb;
    reg  [7:0]  raw_a, raw_b;

    always @(posedge dclk or negedge reset_n) begin
        if (!reset_n) begin
            rc <= 0; rv <= 1'b0; dwords <= 0; dframes <= 0; dterm <= 0;
            dbad <= 0; dorph <= 0; rlen <= 0; sot <= 0; in_frame <= 1'b0;
            cmp_pend <= 1'b0; cmp_len <= 0; cmp_crs <= 0;
        end else begin
            rc <= rc + 16'd1;
            // 相位: ① 快 ② 长停 (灌满 CDC + mac_rx 8 深 ⇒ 整帧丢)
            //       ③ 快 (排空积压)  ④ 半速率 (占用贴满, 边框反复撞 full)
            if (rc < 16'd40)         rv <= 1'b1;
            else if (rc < 16'd3400)  rv <= 1'b0;
            else if (rc < 16'd4400)  rv <= 1'b1;
            else                     rv <= ((rc % 16'd20) < 16'd1);

            // ---- 上一拍收尾的帧在这里判定 (rbuf 已全部落地; 避开 NBA 竞争) ----
            if (cmp_pend) begin
                cmp_pend <= 1'b0;
                m = -1;
                for (kk = sot; kk < NFR; kk = kk + 1) begin
                    if ((m < 0) && (flen[kk] == cmp_len)) begin
                        ok = 1;
                        for (j = 0; j < flen[kk]; j = j + 1)
                            if (fbuf[kk*1600 + j] !== rbuf[j]) ok = 0;
                        if (ok) m = kk;
                    end
                end
                if (m < 0) begin
                    dbad <= dbad + 32'd1;
                    if (dbad < 32'd3) begin
                        $display("RXCHAIN BAD-FRAME len=%0d (无匹配注入帧 sot=%0d) crs=%b",
                                 cmp_len, sot, cmp_crs);
                        for (kk = 0; kk < 16; kk = kk + 1)
                            $display("   rcv[%0d]=%02x exp[%0d]=%02x", kk, rbuf[kk], kk, fbuf[kk]);
                    end
                end else begin
                    sot <= m + 1;
                end
                if (!cmp_crs) begin
                    dbad <= dbad + 32'd1;
                    $display("RXCHAIN BAD-CRS: 交付帧 tcrs=0");
                end
            end

            if (rv && !rx_fifo_empty) begin
                dwords <= dwords + 32'd1;
                nb = p8(rx_tkeep);
                if (rx_tlast && (nb == 8'd0)) begin
                    dterm <= dterm + 32'd1;
                    if (!(rx_terr && !rx_tcrs))
                        $display("RXCHAIN BAD-TERM err=%b crs=%b", rx_terr, rx_tcrs);
                    in_frame <= 1'b0;
                    rlen     <= 0;
                end else begin
                    for (j = 0; j < 8; j = j + 1)
                        if (rx_tkeep[7-j] && ((rlen + j) < 1600))
                            rbuf[rlen + j] <= rx_tdata[63 - 8*j -: 8];
                    if (!in_frame && !rx_tuser) $display("RXCHAIN BAD-SOP: 帧首字 tuser=0");
                    if (in_frame  &&  rx_tuser) $display("RXCHAIN BAD-SOP: 帧内字 tuser=1");
                    if (!in_frame) in_frame <= 1'b1;
                    rlen <= rlen + nb;
                    if (rx_tlast) begin
                        dframes  <= dframes + 32'd1;
                        cmp_pend <= 1'b1;
                        cmp_len  <= rlen + nb;
                        cmp_crs  <= rx_tcrs;
                        in_frame <= 1'b0;
                        rlen     <= 0;
                    end
                end
            end
        end
    end

    // ---------------- 写域: 逐拍原子性 / 记账 ----------------
    reg  [3:0]  mrx_rptr_r;
    reg  [8:0]  cdc_wbin_r;
    reg  [31:0] atoms_ok, atoms_bad, stall_bad, wr_cycles, accw, refw, fullcyc;
    reg         mtr_r, accd, popd;
    wire        wbin_moved = (cdc_wbin !== cdc_wbin_r);
    wire        rptr_moved = (mrx_rptr !== mrx_rptr_r);
    wire        acc_now    = m_tvalid && !rx_fifo_full;      // 本拍 "接受写" 的模型
    wire        pop_now    = m_tvalid && m_tready;           // 本拍 "弹出" 的模型
    always @(posedge gclk or negedge reset_n) begin
        if (!reset_n) begin
            mrx_rptr_r <= 0; cdc_wbin_r <= 0; atoms_ok <= 0; atoms_bad <= 0;
            stall_bad <= 0; accw <= 0; refw <= 0; wr_cycles <= 0; mtr_r <= 0;
            fullcyc <= 0; accd <= 0; popd <= 0;
        end else begin
            // R1: 两个 DUT 探针必须同拍走 (原子性)
            if (rptr_moved || wbin_moved) begin
                if (rptr_moved && wbin_moved) atoms_ok <= atoms_ok + 32'd1;
                else begin
                    atoms_bad <= atoms_bad + 32'd1;
                    if (atoms_bad < 32'd6)
                        $display("RXCHAIN ATOMIC-FAIL t=%0t rptr %0d->%0d wbin %0d->%0d tvalid=%b tready=%b full=%b",
                                 $time, mrx_rptr_r, mrx_rptr, cdc_wbin_r, cdc_wbin,
                                 m_tvalid, m_tready, rx_fifo_full);
                end
            end
            // R1b: 我记账的 "接受写/弹出" 模型 必须与 DUT 指针的实际走位逐拍一致
            //      (上一拍的模型 vs 本拍观测到的变化, 因为 NBA 在沿后落地)
            if ((accd !== wbin_moved) || (popd !== rptr_moved)) begin
                stall_bad <= stall_bad + 32'd1;
                if (stall_bad < 32'd4)
                    $display("RXCHAIN MODEL-FAIL t=%0t accd=%b wbin_moved=%b (wbin=%0d) popd=%b rptr_moved=%b (rptr=%0d) full=%b tvalid=%b tready=%b",
                             $time, accd, wbin_moved, cdc_wbin, popd, rptr_moved, mrx_rptr,
                             rx_fifo_full, m_tvalid, m_tready);
            end
            mrx_rptr_r <= mrx_rptr;
            cdc_wbin_r <= cdc_wbin;
            accd <= acc_now;
            popd <= pop_now;
            if (rx_fifo_full) fullcyc <= fullcyc + 32'd1;
            if (m_tvalid) begin
                wr_cycles <= wr_cycles + 32'd1;
                if (rx_fifo_full) refw <= refw + 32'd1;
                else              accw <= accw + 32'd1;
            end
            mtr_r <= pop_now;
        end
    end

    // ---------------- 终判 ----------------
    integer guard;
    initial begin
        reset_n = 0;
        repeat (20) @(posedge gclk);
        reset_n = 1;
        guard = 0;
        while ((si < nstim) && (guard < 4000000)) begin @(posedge gclk); guard = guard + 1; end
        repeat (14000) @(posedge dclk);
        $display("RXCHAIN FINAL frames_in=%0d mac_frames=%0d crc_err=%0d drop=%0d dfull=%0d dpart=%0d orph=%0d ovf=%0d mac_words=%0d",
                 nfr, st_frames, st_crc, st_drop, st_dfull, st_dpart, st_orph, st_ovf, st_words);
        $display("RXCHAIN FINAL dp_words=%0d dp_frames=%0d term=%0d bad=%0d cdc_wbin=%0d cdc_rbin=%0d mrx_rptr=%0d",
                 dwords, dframes, dterm, dbad, cdc_wbin, cdc_rbin, mrx_rptr);
        $display("RXCHAIN FINAL atomic_ok=%0d atomic_bad=%0d wr_cycles=%0d acc=%0d refw=%0d fullcyc=%0d stall_bad=%0d",
                 atoms_ok, atoms_bad, wr_cycles, accw, refw, fullcyc, stall_bad);
        if (atoms_bad != 0)           $display("RXCHAIN FAIL: R1 原子性 atomic_bad=%0d", atoms_bad);
        if (stall_bad != 0)           $display("RXCHAIN FAIL: R1b 接受写未同拍弹字 stall_bad=%0d", stall_bad);
        if (dbad != 0)                $display("RXCHAIN FAIL: R2 帧保真 bad=%0d", dbad);
        if (st_ovf != 0)              $display("RXCHAIN FAIL: R3 fifo_sync 拒写 ovf=%0d", st_ovf);
        if ((dframes + st_drop) != nfr) $display("RXCHAIN FAIL: R3 帧守恒 %0d+%0d!=%0d", dframes, st_drop, nfr);
        if (dterm != st_dpart)        $display("RXCHAIN FAIL: R3 TERM=%0d != drop_partial=%0d", dterm, st_dpart);
        if (st_words != dwords)       $display("RXCHAIN FAIL: R3 词守恒 mac=%0d cdc=%0d", st_words, dwords);
        if (cdc_wbin != cdc_rbin)     $display("RXCHAIN FAIL: R3 CDC 指针未归零 %0d/%0d", cdc_wbin, cdc_rbin);
        if ((atoms_bad == 0) && (stall_bad == 0) && (dbad == 0) && (st_ovf == 0) &&
            ((dframes + st_drop) == nfr) && (dterm == st_dpart) && (st_words == dwords) &&
            (cdc_wbin == cdc_rbin) && (refw > 0) && (st_drop > 0) && (dframes >= 4))
            $display("RXCHAIN: PASS_ALL");
        else begin
            if (refw == 0)     $display("RXCHAIN NO-EVIDENCE: refw==0");
            if (st_drop == 0)  $display("RXCHAIN NO-EVIDENCE: stat_drop==0");
            if (dframes < 4)   $display("RXCHAIN NO-EVIDENCE: dframes=%0d <4", dframes);
            $display("RXCHAIN: FAIL");
        end
        $finish;
    end
    initial begin
        #30000000;
        $display("RXCHAIN: TIMEOUT si=%0d/%0d dp_words=%0d", si, nstim, dwords);
        $finish;
    end
endmodule
