`timescale 1ns/1ps
//=============================================================================
// tb_tx_cdc_chain.v -- P6b **TX 跨域边界**整链门 + F11 (帧内中止残字上线) 判定实验
//=============================================================================
// 链路 (逐字镜像 board/wrapper_p4.v:2179-2239):
//   DP 源 (156.25MHz, 模拟 tx_arb 组合输出) -> fifo_async 73/256/FWFT u_txcdc
//                                          -> mac_tx_64 (FE 125MHz) -> GMII 线上流
//   wrapper 逐字:  txsrc_tready = ~tx_fifo_full ;  rd_en = ~empty && mac_tready
//
// 相位: ①帧 B (3 字短帧, content 24B ⇒ 必须补 pad 到 60) ②帧 A 前 40 字
//       ③长断供 (mac_tx 内部 16 深 + CDC 排空后帧内中止) ④帧 A 余下 40..119 字
//       ⑤帧 C (25 字) 正常.
// 判据:
//   T1 正常帧 = 线上 content 逐字节 == 注入帧 (含 pad 规则) + FCS 残差 0xDEBB20E3。
//   T2 边界模型: "CDC 接受写" 与 DUT dbg_wbin 逐拍一致; 取数只在 !empty 时发生。
//   T3 ⭐F11: 除 B/A/C 三个完整帧之外, 线上是否出现**额外的 FCS 正确帧**(幽灵)?
//      是 ⇒ 中终止后的残字被当成新帧发了出去 (= 坏帧当好帧)。
//=============================================================================
module tb_tx_cdc_chain;

    reg dclk = 0, gclk = 0, reset_n = 0;
    always #3.2 dclk = ~dclk;      // 156.25 MHz 数据面 (CDC 写侧)
    always #4.0 gclk = ~gclk;      // 125.00 MHz 前端     (CDC 读侧 / MAC)

    localparam integer NA = 120;    // 帧 A 字数 (960B)
    localparam integer NB = 3;      // 帧 B 字数 (24B -> pad)
    localparam integer NC = 25;     // 帧 C 字数 (200B)
    localparam integer LA = NA*8, LB = NB*8, LC = NC*8;
    reg  [72:0] wa [0:NA-1], wb [0:NB-1], wc [0:NC-1];
    reg  [7:0]  abyte [0:LA-1], bbyte [0:LB-1], cbyte [0:LC-1];
    integer     i, k;

    function [31:0] cstep2;
        input [31:0] c; input [7:0] bb;
        reg [31:0] rr; integer ii;
        begin
            rr = c;
            for (ii = 0; ii < 8; ii = ii + 1)
                rr = (rr[0] ^ bb[ii]) ? ((rr >> 1) ^ 32'hEDB88320) : (rr >> 1);
            cstep2 = rr;
        end
    endfunction

    task mkword;
        output [72:0] wv;
        input [63:0] td; input [7:0] tk; input tl;
        begin
            wv = {td, tk, tl};
        end
    endtask

    initial begin
        for (i = 0; i < NA; i = i + 1) begin
            for (k = 0; k < 8; k = k + 1) abyte[i*8+k] = (((i*8+k)*37) ^ ((i*8+k) >> 5));
            mkword(wa[i], {abyte[i*8+0],abyte[i*8+1],abyte[i*8+2],abyte[i*8+3],
                           abyte[i*8+4],abyte[i*8+5],abyte[i*8+6],abyte[i*8+7]},
                   8'hFF, (i == NA-1));
        end
        for (i = 0; i < NB; i = i + 1) begin
            for (k = 0; k < 8; k = k + 1) bbyte[i*8+k] = ((i*8+k) ^ 8'h3C);
            mkword(wb[i], {bbyte[i*8+0],bbyte[i*8+1],bbyte[i*8+2],bbyte[i*8+3],
                           bbyte[i*8+4],bbyte[i*8+5],bbyte[i*8+6],bbyte[i*8+7]},
                   8'hFF, (i == NB-1));
        end
        for (i = 0; i < NC; i = i + 1) begin
            for (k = 0; k < 8; k = k + 1) cbyte[i*8+k] = ((i*8+k) ^ 8'hC3);
            mkword(wc[i], {cbyte[i*8+0],cbyte[i*8+1],cbyte[i*8+2],cbyte[i*8+3],
                           cbyte[i*8+4],cbyte[i*8+5],cbyte[i*8+6],cbyte[i*8+7]},
                   8'hFF, (i == NC-1));
        end
    end

    // ---------------- 端口线网 ----------------
    reg  [72:0] s_word;
    reg         s_v;
    wire        s_ready;
    wire [72:0] cdc_dout;
    wire        cdc_empty, cdc_full, cdc_rd;
    wire [63:0] m_tdata; wire [7:0] m_tkeep;
    wire        m_tvalid, m_tlast, m_tready;
    wire [7:0]  e_txd; wire e_txen, e_txer;
    wire [31:0] st_frames, st_abort;

    fifo_async #(.WIDTH(73), .DEPTH(256), .FWFT(1), .AW(8)) u_txcdc (
        .wr_clk(dclk), .wr_rst_n(reset_n), .wr_en(s_v), .din(s_word),
        .full(cdc_full),
        .rd_clk(gclk), .rd_rst_n(reset_n), .rd_en(cdc_rd),
        .dout(cdc_dout), .empty(cdc_empty),
        .dbg_wbin(), .dbg_rbin(), .dbg_wgray(), .dbg_rgray(),
        .dbg_occ_w(), .dbg_occ_r()
    );
    assign s_ready  = ~cdc_full;
    assign {m_tdata, m_tkeep, m_tlast} = cdc_dout;
    assign m_tvalid = ~cdc_empty;
    assign cdc_rd   = m_tvalid && m_tready;

    mac_tx_64 u_mac_tx (
        .clk(gclk), .rst_n(reset_n),
        .s_axis_tdata(m_tdata), .s_axis_tkeep(m_tkeep), .s_axis_tvalid(m_tvalid),
        .s_axis_tready(m_tready), .s_axis_tlast(m_tlast),
        .gmii_txd(e_txd), .gmii_tx_en(e_txen), .gmii_tx_er(e_txer),
        .stat_frames(st_frames), .stat_abort(st_abort)
    );

    wire [8:0] cdc_wbin = u_txcdc.dbg_wbin;
    wire [8:0] cdc_rbin = u_txcdc.dbg_rbin;
    // F-2 新计数器: 旧 RTL 没有这两个端口 => 哨兵值 (不用 0, 免"空读数=真 0")
`ifdef F2_RTL
    wire [31:0] tx_flush_words = u_mac_tx.stat_flush_words;
    wire [31:0] tx_flush_done  = u_mac_tx.stat_flush_done;
`else
    wire [31:0] tx_flush_words = 32'hDEAD_BEEF;
    wire [31:0] tx_flush_done  = 32'hDEAD_BEEF;
`endif

    // ---------------- DP 源驱动 ----------------
    // ⚠️ 复位释放门: fifo_async 写域复位由**本域两级同步器**释放 ⇒ rst_n 后还要 3 个
    //    dclk 写才被承认 (期间 full 读 0 而写被静默丢弃, 见 P6B_CDC_AUDIT F-1)。
    //    真实设计里 DP 功能逻辑由 clk_gen_p6b 的 rst_dp 复位, 其释放**晚于** FIFO 写域
    //    (MMCM 锁定 + 4 拍), 故本门刻意等 8 拍 —— 与真实先后次序同向。
    reg [3:0] wgo;
    wire      w_go = (wgo == 4'hF);
    always @(posedge dclk or negedge reset_n)
        if (!reset_n) wgo <= 4'h0; else if (!w_go) wgo <= wgo + 4'h1;

    // 字表: 0..NB-1 = 帧B ; NB..NB+NA-1 = 帧A ; 再接帧C
    localparam integer NS = NB + NA + NC;
    function [72:0] selw;
        input [31:0] idx;
        begin
            if (idx < NB)              selw = wb[idx];
            else if (idx < NB + NA)    selw = wa[idx - NB];
            else                       selw = wc[idx - NB - NA];
        end
    endfunction

    reg [15:0] gap;
    reg [31:0] bidx, wacc, wref;
    reg        src_done;
    integer    gaptgt;
    initial begin                           // 断供拍数 (dclk); +GAP=0 => 不断供 (无中止 A/B)
        // ⚠️ cmd 下 `-testplusarg GAP=12000` 会被 xsim 拆成两段 ("Expected a switch but
        //    found 1") => 用**无等号**的开关式 plusarg。
        if ($test$plusargs("NOSTALL")) gaptgt = 0;
        else if (!$value$plusargs("GAP=%d", gaptgt)) gaptgt = 12000;
    end
    always @(posedge dclk or negedge reset_n) begin
        if (!reset_n) begin
            gap <= 0; bidx <= 0; s_v <= 1'b0; s_word <= 0;
            wacc <= 0; wref <= 0; src_done <= 0;
        end else if (!w_go) begin
            gap <= 0; bidx <= 0; s_v <= 1'b0; s_word <= 0; src_done <= 0;
        end else begin
            src_done <= 1'b0;
            if (s_v && !s_ready) wref <= wref + 32'd1;
            if (gap != 16'd0) begin
                // 断供窗: 一个字都不发
                gap <= gap - 16'd1;
                s_v <= 1'b0;
                if (gap == 16'd1) begin
                    s_word <= selw(bidx);
                    s_v    <= 1'b1;
                end
            end else if (!s_v) begin
                if (bidx < NS) begin
                    s_word <= selw(bidx);
                    s_v    <= 1'b1;
                end else begin
                    src_done <= 1'b1;
                end
            end else if (s_ready) begin
                wacc <= wacc + 32'd1;
                bidx <= bidx + 32'd1;
                if ((bidx + 32'd1) < NS) s_word <= selw(bidx + 32'd1);
                else                     s_v    <= 1'b0;
                if ((bidx + 32'd1) == (NB + 40)) begin      // A 前 40 字发完 -> 断供
                    gap <= gaptgt[15:0];
                    s_v <= 1'b0;      // ⚠️ 必须同拍撤 valid, 否则下一拍同一字被**重写一次**
                end
            end
        end
    end

    // ---------------- 记账: 逐拍模型 vs DUT 指针 ----------------
    reg  [8:0] wbin_r, rbin_r;
    reg        accd, popd;
    reg [31:0] model_bad, fullcyc, pop_bad, rpop;
    wire       wbin_moved = (cdc_wbin !== wbin_r);
    wire       rbin_moved = (cdc_rbin !== rbin_r);
    wire       acc_now    = s_v && !cdc_full;
    wire       pop_now    = cdc_rd;
    always @(posedge dclk or negedge reset_n) begin
        if (!reset_n) begin wbin_r <= 0; model_bad <= 0; fullcyc <= 0; accd <= 0; end
        else begin
            if (accd !== wbin_moved) begin
                model_bad <= model_bad + 32'd1;
                if (model_bad < 32'd4)
                    $display("TXCHAIN MODEL-FAIL(w) t=%0t accd=%b wbin_moved=%b wbin=%0d full=%b s_v=%b",
                             $time, accd, wbin_moved, cdc_wbin, cdc_full, s_v);
            end
            wbin_r <= cdc_wbin;
            accd   <= acc_now;
            if (cdc_full) fullcyc <= fullcyc + 32'd1;
        end
    end
    always @(posedge gclk or negedge reset_n) begin
        if (!reset_n) begin rbin_r <= 0; pop_bad <= 0; rpop <= 0; popd <= 0; end
        else begin
            if (popd !== rbin_moved) begin
                pop_bad <= pop_bad + 32'd1;
                if (pop_bad < 32'd4)
                    $display("TXCHAIN MODEL-FAIL(r) t=%0t popd=%b rbin_moved=%b rbin=%0d empty=%b tvalid=%b",
                             $time, popd, rbin_moved, cdc_rbin, cdc_empty, m_tvalid);
            end
            if (cdc_rd) rpop <= rpop + 32'd1;
            rbin_r <= cdc_rbin;
            popd   <= pop_now;
        end
    end

    // ---------------- F-2 冲刷态逐拍追踪 (诊断; 只在 F2_RTL 构建里编) ----------------
`ifdef F2_RTL
    always @(posedge gclk) begin
        if (u_mac_tx.state == 3'd6) begin
            if (u_mac_tx.frd)
                $display("FLUSHDBG t=%0t POP word byte0=%02x tlast=%b tkeep=%02x",
                         $time, u_mac_tx.fdout[72:65], u_mac_tx.fdout[0], u_mac_tx.fdout[8:1]);
            else
                $display("FLUSHDBG t=%0t wait tl_seen=%b cnt=%0d fempty=%b",
                         $time, u_mac_tx.flush_tl, u_mac_tx.flush_cnt, u_mac_tx.fempty);
        end
    end
`endif

    // ---------------- GMII 线上解码 ----------------
    reg  [7:0]  wbuf [0:2047];
    integer     wlen, flen;
    reg         won, fdone;
    reg [31:0]  nframes, badfcs, shortfrm, n_match, n_ghost, n_extra;
    integer     p, q, off, foundi;
    reg [31:0]  crc32, jmax;

    // 线上字节流指纹: wf = fold(前导帧前的空闲拍数, 全部 tx_en 字节) —— 帧边界与内容都进指纹
    reg [31:0] wf;
    reg [15:0] idleq;
    always @(posedge gclk or negedge reset_n) begin
        if (!reset_n) begin
            won <= 0; wlen <= 0; fdone <= 0; flen <= 0;
            wf <= 32'h1234_5678; idleq <= 16'd0;
        end else begin
            fdone <= 1'b0;
            if (e_txen) begin
                if (!won) begin            // 帧首: 显式写下标 0 (NBA 下 wlen 更新晚一拍!)
                    won <= 1'b1; wlen <= 1; wbuf[0] <= e_txd;
                    wf  <= ((wf * 32'd31) + {16'h0, idleq}) * 32'd31 + {24'h0, e_txd};
                end else begin
                    wlen <= wlen + 1; wbuf[wlen] <= e_txd;
                    wf   <= (wf * 32'd31) + {24'h0, e_txd};
                end
                idleq <= 16'd0;
            end else begin
                if (idleq != 16'hFFFF) idleq <= idleq + 16'd1;
                if (won) begin
                    won <= 1'b0; fdone <= 1'b1; flen <= wlen;
                end
            end
        end
    end

    // 帧判定: MATCH = 与某个注入帧的**完整内容**逐字节相符 (含 pad 规则)
    always @(posedge gclk or negedge reset_n) begin
        if (!reset_n) begin
            nframes <= 0; badfcs <= 0; shortfrm <= 0; n_match <= 0; n_ghost <= 0; n_extra <= 0;
        end else if (fdone) begin
            nframes <= nframes + 32'd1;
            if (nframes < 2) begin
                $display("DUMP frame#%0d len=%0d:", nframes, flen);
                $write("   ");
                for (q = 0; q < flen; q = q + 1) begin
                    $write("%02x ", wbuf[q]);
                    if ((q % 16) == 15) $write("\n   ");
                end
                $write("\n");
            end
            if (flen < 68) begin
                shortfrm <= shortfrm + 32'd1;
                $display("WIRE  frame#%0d len=%0d **太短/被中止** (无 FCS): 首8=%02x %02x %02x %02x %02x %02x %02x %02x",
                         nframes, flen, wbuf[0],wbuf[1],wbuf[2],wbuf[3],wbuf[4],wbuf[5],wbuf[6],wbuf[7]);
            end else begin
                crc32 = 32'hFFFFFFFF;
                for (q = 8; q < flen; q = q + 1) crc32 = cstep2(crc32, wbuf[q]);
                if (crc32 !== 32'hDEBB20E3) begin
                    badfcs <= badfcs + 32'd1;
                    $display("WIRE  frame#%0d len=%0d FCS-BAD (残留=%08x) 首8=%02x %02x %02x %02x %02x %02x %02x %02x",
                             nframes, flen, crc32, wbuf[8],wbuf[9],wbuf[10],wbuf[11],
                             wbuf[12],wbuf[13],wbuf[14],wbuf[15]);
                end else begin
                    foundi = 0;
                    // ---- 帧 A (len = 8 + 960 + 4) ----
                    if (flen == (8 + LA + 4)) begin
                        foundi = 1;
                        for (q = 0; q < LA; q = q + 1) if (wbuf[8+q] !== abyte[q]) foundi = 0;
                        if (foundi == 1) $display("WIRE  frame#%0d len=%0d FCS-OK  完整匹配帧A ✓", nframes, flen);
                    end
                    // ---- 帧 B (短帧, content 24 -> pad 到 60) ----
                    if ((foundi == 0) && (flen == (8 + 60 + 4))) begin
                        foundi = 2;
                        for (q = 0; q < LB; q = q + 1) if (wbuf[8+q] !== bbyte[q]) foundi = 0;
                        for (q = LB; q < 60; q = q + 1) if (wbuf[8+q] !== 8'h00) foundi = 0;
                        if (foundi == 2) $display("WIRE  frame#%0d len=%0d FCS-OK  完整匹配帧B (含 pad 到 60) ✓", nframes, flen);
                        else begin
                            $display("WIRE  frame#%0d len=%0d B-检查失败: 首24=%02x %02x %02x %02x ... pad区[24..31]=%02x %02x %02x %02x %02x %02x %02x %02x",
                                     nframes, flen, wbuf[8],wbuf[9],wbuf[10],wbuf[11],
                                     wbuf[8+24],wbuf[8+25],wbuf[8+26],wbuf[8+27],
                                     wbuf[8+28],wbuf[8+29],wbuf[8+30],wbuf[8+31]);
                        end
                    end
                    // ---- 帧 C ----
                    if ((foundi == 0) && (flen == (8 + LC + 4))) begin
                        foundi = 3;
                        for (q = 0; q < LC; q = q + 1) if (wbuf[8+q] !== cbyte[q]) foundi = 0;
                        if (foundi == 3) $display("WIRE  frame#%0d len=%0d FCS-OK  完整匹配帧C ✓", nframes, flen);
                    end
                    if (foundi != 0) n_match <= n_match + 32'd1;
                    else begin
                        // 是帧 A 的一段后缀吗? (中终止后的残字指纹)
                        off = -1;
                        for (p = 0; p <= (LA - (flen-12)); p = p + 8)
                            if ((off < 0) && ((LA - p) >= (flen-12))) begin
                                off = p; foundi = 1;
                                for (q = 0; q < (flen-12); q = q + 1)
                                    if (wbuf[8+q] !== abyte[p+q]) foundi = 0;
                                if (foundi == 0) off = -1;
                            end
                        n_ghost <= n_ghost + 32'd1;
                        if (off >= 0)
                            $display("WIRE  frame#%0d len=%0d FCS-OK  **幽灵帧**: content = 帧A 的字节[%0d..%0d) (中终止后的残字被当新帧发出!)",
                                     nframes, flen, off, off + (flen-12));
                        else
                            $display("WIRE  frame#%0d len=%0d FCS-OK  **幽灵帧**: content 与任何注入帧都不匹配 首8=%02x %02x %02x %02x %02x %02x %02x %02x",
                                     nframes, flen, wbuf[8],wbuf[9],wbuf[10],wbuf[11],
                                     wbuf[12],wbuf[13],wbuf[14],wbuf[15]);
                    end
                end
            end
        end
    end

    // ---------------- 终判 ----------------
    integer guard;
    initial begin
        reset_n = 0;
        repeat (20) @(posedge gclk);
        reset_n = 1;
        guard = 0;
        while (!src_done && (guard < 4000000)) begin @(posedge dclk); guard = guard + 1; end
        repeat (6000) @(posedge gclk);
        $display("TXCHAIN FINAL mac_frames=%0d mac_abort=%0d wire_frames=%0d match=%0d short=%0d badfcs=%0d ghost=%0d",
                 st_frames, st_abort, nframes, n_match, shortfrm, badfcs, n_ghost);
        $display("TXCHAIN FINAL dp_acc=%0d refw=%0d cdc_wbin=%0d cdc_rbin=%0d mac_pop=%0d fullcyc=%0d model_bad=%0d pop_bad=%0d",
                 wacc, wref, cdc_wbin, cdc_rbin, rpop, fullcyc, model_bad, pop_bad);
        if (model_bad != 0)  $display("TXCHAIN FAIL: T2 写侧模型 != DUT 指针");
        if (pop_bad != 0)    $display("TXCHAIN FAIL: T2 读侧模型 != DUT 指针");
        if (n_match == 0)    $display("TXCHAIN NO-EVIDENCE: 没有一个完整帧被收到");
        if (st_abort == 0)   $display("TXCHAIN NO-EVIDENCE: stat_abort==0 (没触发帧内中止)");
        if (n_ghost != 0)    $display("TXCHAIN **F11-CONFIRMED**: %0d 个 FCS 正确的幽灵帧上线 (坏帧当好帧)", n_ghost);
        // F-2 判据: 幽灵帧必须为 0 (F-2 后); 无中止流量另看指纹 (由 runner 比对)
        if (n_ghost != 0)
            $display("TXCHAIN FAIL: F-2 幽灵帧 = %0d (残字被当新帧发出)", n_ghost);
        $display("TXCHAIN FPRINT wf=%08x frames=%0d abort=%0d flush_words=%0d flush_done=%0d wire_frames=%0d",
                 wf, st_frames, st_abort, tx_flush_words, tx_flush_done, nframes);
        if ((model_bad == 0) && (pop_bad == 0) && (n_match > 0) && (n_ghost == 0))
            $display("TXCHAIN: PASS_ALL");
        else
            $display("TXCHAIN: FAIL");
        $finish;
    end
    initial begin
        #60000000;
        $display("TXCHAIN: TIMEOUT bidx=%0d gap=%0d", bidx, gap);
        $finish;
    end
endmodule
