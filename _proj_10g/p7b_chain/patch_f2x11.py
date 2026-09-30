# -*- coding: utf-8 -*-
"""F2X11 PATCH -- fix the FALSE-POSITIVE trap in the chain gate's wire-frame classifier
and add the TX->RX self-consistency criteria.

(1) sim/tb_p7b_chain.v `f2x_scan` classified frames against the **INJECTED** length
    (`f2x_clen[k2]`) with two hard tests:
        complete : wlen == dn + 7 + 4
        runt     : (wlen - 7) <= dn
    For a frame the MAC pads up to MIN_CLEN=60 (dn < 60) the wire content is 60 bytes
    > dn => neither test can hold => kind stays 0 = "ghost".  (Seen live at
    logs/xsim_p7bchain_oldclassifier_newmac_final.log:1758 and
    logs/f2x11_before_nomac_none.log:1758: `kind=0 content_len_incl_pad=60`, while the
    very same frame is accepted by our own RX on line 1760 -- pure false positive.)
    Fix: classify on the **on-wire decoded** length/bytes:
        expected wire content = injected content ++ zero pad to MIN_CLEN(60)
        kind 2 = exact length + byte-exact content(++pad) + FCS == TB crc32 over the
                 whole on-wire content (independent oracle)
        kind 3 = same but FCS mismatch (still NOT a ghost -- it is our own frame)
        kind 1 = strict prefix of (content ++ zero pad)
        kind 0 = ghost (matches nothing)

(2) dump_raw (tb:1387) still used the OLD decoder's indices (wf_start/wf_stop, stale
    group-8 window = `[3,21)`) instead of the snapshot window that f2x_loop replays.
    Print/forensics only -- not a criterion.

(3) New group X6: own TX -> own RX self-consistency (tcrs=1) for the three padded
    on-wire sizes 20B / 42B (ARP reply) / 54B (TCP pure ACK).

(4) Per-frame `tcrs`/`terr` capture in the delivery observer (needed by X6).
"""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()
orig = s


def rep(old, new, n=1):
    global s
    c = s.count(old)
    if c != n:
        raise SystemExit('ANCHOR x%d (want %d): %r' % (c, n, old[:120]))
    s = s.replace(old, new)


# ---------------------------------------------------------------- (2a) dump_raw clamp
rep('''    task dump_raw;
        input integer from;
        input integer to;
        integer dk, dto;
        begin
            dto = (to < 16383) ? to : 16383;
            $display("  [RAW] span [%0d,%0d) wq_wr=%0d", from, dto, wq_wr);
            for (dk = from; dk < dto; dk = dk + 1) begin''',
    '''    task dump_raw;
        input integer from;
        input integer to;
        integer dk, dto, dfo;
        begin
            // F2X11: 起点钳 >= 0 (idx-4 在前几个字上会是负数; 负下标会越界读)
            dfo = (from > 0) ? from : 0;
            dto = (to < 16383) ? to : 16383;
            $display("  [RAW] span [%0d,%0d) wq_wr=%0d", dfo, dto, wq_wr);
            for (dk = dfo; dk < dto; dk = dk + 1) begin''')

# ---------------------------------------------------------------- (4) tcrs/terr capture
rep('''    integer    got_f_cnt = 0;
    integer    got_last_len = 0;''',
    '''    integer    got_f_cnt = 0;
    integer    got_last_len = 0;
    // F2X11: 每帧 TLAST 拍的交付合同位 (tcrs = FCS 正确 / terr = 帧内错误)
    integer    got_f_crs  [0:127];
    integer    got_f_terr [0:127];''')

rep('''                if (got_f_cnt < 128) begin
                    got_f_len[got_f_cnt] = got_len;
                    got_f_cnt = got_f_cnt + 1;
                end''',
    '''                if (got_f_cnt < 128) begin
                    got_f_len[got_f_cnt]  = got_len;
                    got_f_crs[got_f_cnt]  = u_dut.rx_tcrs;   // F2X11
                    got_f_terr[got_f_cnt] = u_dut.rx_terr;   // F2X11
                    got_f_cnt = got_f_cnt + 1;
                end''')

# ---------------------------------------------------------------- (1) classifier fix
rep('''    task f2x_scan;
        integer q, l2, dn, f, k2;
        reg [7:0] byt;
        reg       in_f, done;
        integer   st;''',
    '''    task f2x_scan;
        integer q, l2, dn, f, k2, wl_exp;
        reg [7:0] byt, bexp;
        reg       in_f, done, fcs_ok;
        reg [31:0] fc_tb;
        integer   st;''')

rep('''            // ---- 逐帧分类 (线上帧的前 7 字节 = 前导 55x6+D5, 内容从下标 7 起) ----
            for (f = 0; f < f2x_wn && f < 32; f = f + 1) begin
                f2x_wkind[f] = 0;
                for (k2 = 0; k2 < f2x_cn; k2 = k2 + 1) begin
                    dn = f2x_clen[k2];
                    if (f2x_wlen[f] == dn + 7 + 4) begin       // 完整帧 (内容 + FCS)
                        done = 1'b1;
                        for (q = 0; q < dn; q = q + 1)
                            if (f2x_wire[f][7+q] !== f2x_c[k2*F2X_STRIDE + q]) done = 1'b0;
                        if (done === 1'b1 && f2x_wkind[f] < 2) f2x_wkind[f] = 2;
                    end
                    if ((f2x_wlen[f] >= 7) && ((f2x_wlen[f] - 7) <= dn)) begin  // 残缺前缀
                        done = 1'b1;
                        for (q = 0; q < (f2x_wlen[f] - 7); q = q + 1)
                            if (f2x_wire[f][7+q] !== f2x_c[k2*F2X_STRIDE + q]) done = 1'b0;
                        if (done === 1'b1 && f2x_wkind[f] == 0) f2x_wkind[f] = 1;
                    end
                end
            end''',
    '''            // ---- 逐帧分类 (线上帧的前 7 字节 = 前导 55x6+D5, 内容从下标 7 起) ----
            // ⭐ F2X11 FIX (2026-09-30, 假阳性陷阱): 判据一律按**线上实际解出的长度/字节**
            //   判定; 注入长度只用来定义"期望的线上形态" = 内容 ++ 全 0 pad 补齐到 MIN_CLEN(60)。
            //   旧版直接拿**注入长度**硬比 (`wlen == dn+11` / `wlen-7 <= dn`) ⇒ 凡被 MAC 补过
            //   pad 的帧 (线上内容 60B > 注入 dn) 两条都不成立 ⇒ kind=0 "幽灵" **误标**
            //   (实测: X5a 的 20B 内容帧在自家 RX 判 FCS 正确的同一时刻被标成幽灵)。
            //   kind: 0=幽灵(内容+pad 都对不上 ⇒ FAIL) / 1=残缺前缀 / 2=完整且 FCS ==
            //         TB 独立复算 (覆盖线上全部内容字节, 含 pad) / 3=完整但 FCS 不符
            for (f = 0; f < f2x_wn && f < 32; f = f + 1) begin
                f2x_wkind[f] = 0;
                for (k2 = 0; k2 < f2x_cn; k2 = k2 + 1) begin
                    dn = f2x_clen[k2];
                    wl_exp = (dn >= 60) ? dn : 60;      // 期望线上内容字节数 (含 pad)
                    // (a) 完整帧: 线上内容 == 注入内容 ++ 全 0 pad, 且 FCS == TB crc32(线上内容)
                    if (f2x_wlen[f] == (wl_exp + 7 + 4)) begin
                        done = 1'b1;
                        for (q = 0; q < wl_exp; q = q + 1) begin
                            bexp = (q < dn) ? f2x_c[k2*F2X_STRIDE + q] : 8'h00;
                            if (f2x_wire[f][7+q] !== bexp) done = 1'b0;
                        end
                        if (done === 1'b1) begin
                            fc_tb = 32'hFFFFFFFF;
                            for (q = 0; q < wl_exp; q = q + 1)
                                fc_tb = crc32_byte(fc_tb, f2x_wire[f][7+q]);
                            fc_tb = ~fc_tb;                       // 线上 FCS 序: [7:0] 先
                            fcs_ok = 1'b1;
                            if (f2x_wire[f][7+wl_exp+0] !== fc_tb[7:0])   fcs_ok = 1'b0;
                            if (f2x_wire[f][7+wl_exp+1] !== fc_tb[15:8])  fcs_ok = 1'b0;
                            if (f2x_wire[f][7+wl_exp+2] !== fc_tb[23:16]) fcs_ok = 1'b0;
                            if (f2x_wire[f][7+wl_exp+3] !== fc_tb[31:24]) fcs_ok = 1'b0;
                            if (fcs_ok === 1'b1)                    f2x_wkind[f] = 2;
                            else if (f2x_wkind[f] == 0)             f2x_wkind[f] = 3;
                        end
                    end
                    // (b) 残缺前缀: 线上内容更短, 且逐字节 == (内容 ++ pad) 流的前缀
                    if ((f2x_wlen[f] >= 7) && ((f2x_wlen[f] - 7) < wl_exp)) begin
                        done = 1'b1;
                        for (q = 0; q < (f2x_wlen[f] - 7); q = q + 1) begin
                            bexp = (q < dn) ? f2x_c[k2*F2X_STRIDE + q] : 8'h00;
                            if (f2x_wire[f][7+q] !== bexp) done = 1'b0;
                        end
                        if (done === 1'b1 && f2x_wkind[f] == 0) f2x_wkind[f] = 1;
                    end
                end
            end''')

rep('''                $display("  [F2X %0s] frame %0d len=%0d kind=%0d (0=ghost 1=runt 2=complete)",''',
    '''                $display("  [F2X %0s] frame %0d len=%0d kind=%0d (0=ghost 1=runt 2=complete+padFCSok 3=content ok, FCS bad)",''')

# ---------------------------------------------------------------- (3) generic inject helpers
rep('''    // 把捕获窗口 [from,to) 的线上字回放进 RX 注入队列 (TB 侧环回)''',
    '''    // F2X11: 任意长度内容帧的登记 + 连续注入 (1 字/拍, = DP 侧合同)
    //   n 字节 = (n/8) 个满字 + 1 个 keep 高位有效的尾字
    task f2x_addn;
        input integer n;
        input integer base;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) f2x_c[f2x_cn*F2X_STRIDE + i] = PAT[(base+i) % 256];
            f2x_clen[f2x_cn] = n;
            f2x_cn = f2x_cn + 1;
        end
    endtask

    task f2x_streamn;
        input integer f;
        input integer n;
        integer i, k, nw, rem;
        reg [63:0] d;
        begin
            nw  = n / 8;          // 满字数
            rem = n % 8;          // 尾字有效字节数 (0 => 最后一个满字带 TLAST)
            for (i = 0; i < nw; i = i + 1) begin
                @(negedge u_dut.dp_clk);
                d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                     f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                     f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                     f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                force u_dut.txsrc_tdata = d;
                force u_dut.txsrc_tkeep = 8'hFF;
                force u_dut.txsrc_tlast = (rem == 0 && i == nw-1) ? 1'b1 : 1'b0;
                force u_dut.txsrc_tvalid = 1'b1;
            end
            if (rem != 0) begin
                @(negedge u_dut.dp_clk);
                d = 64'd0;
                for (k = 0; k < rem; k = k + 1)
                    d[63 - 8*k -: 8] = f2x_c[f*F2X_STRIDE + nw*8 + k];
                force u_dut.txsrc_tdata = d;
                force u_dut.txsrc_tkeep = 8'hFF << (4'd8 - rem[3:0]);
                force u_dut.txsrc_tlast = 1'b1;
                force u_dut.txsrc_tvalid = 1'b1;
            end
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tvalid = 1'b0;
        end
    endtask

    // 把捕获窗口 [from,to) 的线上字回放进 RX 注入队列 (TB 侧环回)''')

# ---------------------------------------------------------------- (2b) dump_raw call site
rep('''                $display("  [F2X X5c] DUT replay window raw words:");
                dump_raw(wf_start[0] - 4, wf_stop[0] + 5);''',
    '''                $display("  [F2X X5c] DUT replay window raw words (F2X11: snapshot window = the span f2x_loop replays):");
                if (f2x_wn >= 1) dump_raw(f2x_wstart[0] - 4, f2x_wstop[0] + 5);''')

# ---------------------------------------------------------------- X5a positive control
rep('''            $display("  [F2X X5a] injected 20B-content frame: wire frames=%0d kind=%0d content_len_incl_pad=%0d",
                     f2x_wn, f2x_wkind[0], f2x_wlen[0] - 7 - 4);''',
    '''            $display("  [F2X X5a] injected 20B-content frame: wire frames=%0d kind=%0d content_len_incl_pad=%0d",
                     f2x_wn, f2x_wkind[0], f2x_wlen[0] - 7 - 4);
            // F2X11 正对照: 补 pad 的最小帧**不得**被判成幽灵。修 F2X11 前同一个 DUT 帧
            //   (线上内容 60B, 注入 20B) 会被旧分类器判 kind=0 -- 证据:
            //   logs/f2x11_before_nomac_none.log:1758 (`kind=0 content_len_incl_pad=60`),
            //   而同一帧在同一份日志 1760 行被自家 RX 接受 (crc_err 2->2)。
            chk("X5a pad frame not ghost (F2X11)",
                (f2x_wn == 1) && (f2x_wkind[0] === 2), "F2X11: on-wire len + crc32");''')

# ---------------------------------------------------------------- (3) X6 group
X6 = r'''        // =============================================================
        // X6 (F2X11): **原生 TX -> 原生 RX 自洽** —— 自家 TX 发出的帧必须能被自家 RX 收到
        //   (交付合同: tcrs=1)。覆盖 3 个"必须补 pad 到 60"的线上尺寸:
        //     20B = 本工程图案短帧 (X5a 同款, 2 满字 + 4B 尾字)
        //     42B = ARP 应答的线上内容长度  (14 eth + 28 ARP)
        //     54B = TCP 纯 ACK 的线上内容长度 (14 eth + 20 IP + 20 TCP)
        //   每尺寸 3 条判据:
        //     a) 线上帧 = 完整 (kind=2): 长度/内容含 pad 逐字节 + FCS == TB crc32(线上全部内容)
        //        —— 与自家 RX 无关的**独立 oracle** (pad 不进 CRC 时立刻翻红)
        //     b) 回放进自家 RX 后**恰 1 帧交付**, 且 tcrs=1 / terr=0 / 交付长度 60
        //     c) 交付字节逐字节 == 内容 ++ 全 0 pad
        //   ⚠️ 回放窗口 = f2x_loop(f2x_wstart[0]-4, f2x_wstop[0]+5) (快照基准, 与 X5 同款)
        // =============================================================
        begin : x6
            integer si, n6, gc0, q6, rc6;
            reg okb;
            integer ga, gb, gc;
            $display("==== F2X11 X6: own TX -> own RX self-consistency (tcrs=1) ====");
            for (si = 0; si < 3; si = si + 1) begin
                n6 = (si == 0) ? 20 : ((si == 1) ? 42 : 54);
                $display("  ---- X6.%0d: DUT TX %0dB-content frame (pad -> 60) -> own RX ----", si, n6);
                f2x_begin;
                f2x_addn(n6, 1);
                f2x_streamn(0, n6);
                f2x_settle;
                f2x_scan;
                $display("  [F2X X6.%0d] inj=%0dB wire frames=%0d kind=%0d wlen=%0d (window [%0d,%0d) inj_n=%0d)",
                         si, n6, f2x_wn, (f2x_wn >= 1) ? f2x_wkind[0] : -1,
                         (f2x_wn >= 1) ? f2x_wlen[0] : 0, wq_base, wq_wr, f2x_cn);
                if (f2x_wn >= 1)
                    for (q6 = 0; q6 < f2x_wlen[0] && q6 < 80; q6 = q6 + 8)
                        $display("      [%03d] %02h %02h %02h %02h %02h %02h %02h %02h", q6,
                            f2x_wire[0][q6], f2x_wire[0][q6+1], f2x_wire[0][q6+2], f2x_wire[0][q6+3],
                            f2x_wire[0][q6+4], f2x_wire[0][q6+5], f2x_wire[0][q6+6], f2x_wire[0][q6+7]);
                ga = ((f2x_wn == 1) && (f2x_wkind[0] === 2)) ? 1 : 0;
                gc0 = got_f_cnt;
                rc6 = u_dut.rx_stat_crc_err;
                if (f2x_wn >= 1) f2x_loop(f2x_wstart[0] - 4, f2x_wstop[0] + 5);
                repeat (400) @(posedge u_dut.rx_clk_out_1);
                $display("  [F2X X6.%0d] replayed -> got_frames %0d->%0d last_len=%0d tcrs=%0d terr=%0d | rx_frames %0d crc_err %0d (was %0d)",
                         si, gc0, got_f_cnt, got_last_len, got_f_crs[gc0], got_f_terr[gc0],
                         u_dut.rx_stat_frames, u_dut.rx_stat_crc_err, rc6);
                gb = ((got_f_cnt === (gc0 + 1)) && (got_f_len[gc0] === 60) &&
                      (got_f_crs[gc0] === 1) && (got_f_terr[gc0] === 0) &&
                      (u_dut.rx_stat_crc_err === rc6)) ? 1 : 0;
                okb = 1'b1;
                for (q6 = 0; q6 < 60; q6 = q6 + 1)
                    if (got_buf[q6] !== ((q6 < n6) ? PAT[(1+q6) % 256] : 8'h00)) okb = 1'b0;
                gc = ((okb === 1'b1) && (got_f_cnt === (gc0 + 1))) ? 1 : 0;
                if (si == 0) begin
                    chk("X6a 20B wire complete+padFCS", ga === 1, "F2X11: on-wire len + crc32");
                    chk("X6a 20B RX tcrs=1 len=60",     gb === 1, "F2X11: self TX->RX contract");
                    chk("X6a 20B RX bytes==content+pad", gc === 1, "F2X11: content + zero pad");
                end else if (si == 1) begin
                    chk("X6b 42B wire complete+padFCS", ga === 1, "F2X11: on-wire len + crc32");
                    chk("X6b 42B RX tcrs=1 len=60",     gb === 1, "F2X11: self TX->RX contract");
                    chk("X6b 42B RX bytes==content+pad", gc === 1, "F2X11: content + zero pad");
                end else begin
                    chk("X6c 54B wire complete+padFCS", ga === 1, "F2X11: on-wire len + crc32");
                    chk("X6c 54B RX tcrs=1 len=60",     gb === 1, "F2X11: self TX->RX contract");
                    chk("X6c 54B RX bytes==content+pad", gc === 1, "F2X11: content + zero pad");
                end
            end
        end

'''
rep('''        release u_dut.txsrc_tdata;  release u_dut.txsrc_tkeep;
        release u_dut.txsrc_tvalid; release u_dut.txsrc_tlast;

        $display("==== tb_p7b_chain done: %0d checks, %0d fail ====", checks, fails);''',
    X6 + '''        release u_dut.txsrc_tdata;  release u_dut.txsrc_tkeep;
        release u_dut.txsrc_tvalid; release u_dut.txsrc_tlast;

        $display("==== tb_p7b_chain done: %0d checks, %0d fail ====", checks, fails);''')

# ---------------------------------------------------------------- stale DEFECT-REG text
rep('''            $display("  [DEFECT-REG #1] mac_tx_10g padded-frame FCS scope: DUT TX frame of a 20B-content frame (padded to 60) is rejected by OUR OWN RX (crc_err +1); TB-built frame with the pad inside the FCS is accepted (X5d-1) and the same bytes with a data-only FCS is rejected (X5d-2). 1G mac_tx_64 feeds the pad into the CRC (crc_en = S_DATA || S_PAD); mac_tx_10g does not (crc_en = S_DATA only, rtl/mac_tx_10g.v:207). UNFIXED in this round (rtl/ off-limits).");''',
    '''            $display("  [DEFECT-REG #1] mac_tx_10g padded-frame FCS scope (FIXED 2026-09-30: pad is fed into the CRC; crc_keep/crc_en in rtl/mac_tx_10g.v now cover the pad lanes). This criterion + F2X11 X6 stay as the REGRESSION GUARD: mutation MUT-PADNOCRC (pad removed from the CRC in a scratch copy) re-reds it. History: X5a/X5d-2 vs X5d-1 calibration, see notes/P7B_F2_CHAIN_ATTRIB.md section 10.");''')

if s == orig:
    raise SystemExit('no change')
io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('F2X11 patch applied: %d -> %d chars' % (len(orig), len(s)))
