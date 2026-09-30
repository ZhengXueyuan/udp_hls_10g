#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""P7b chain-gate F-2 attribution, step 2: discriminating experiments.

Adds a new "F2X" section (runs after group 7, before the summary) that drives the
REAL wrapper with deterministic, single-cycle injection (negative-edge landing,
i.e. avoiding the 0-delay race of PORT_NOTES #17) and judges the wire by CONTENT,
with a window that cannot go stale:  [wq_base, wq_wr)  where wq_base is a SNAPSHOT
of wq_wr taken at the start of the experiment (never a `wq_wr = 0` reset, which
the capture block's NBA update clobbers -- measured: 1202 -> 1205).

Experiments (all injected content = 60 bytes = MIN_CLEN, so no pad; FCS = the
TB's own bit-serial crc32 over exactly those 60 bytes):
  X1  one frame                      -> exactly 1 wire frame, content byte-exact
  X2  two frames back-to-back        -> exactly 2 wire frames, both byte-exact
  X3  abort with A's tail arriving   -> runt(prefix of A) + complete B byte-exact
      (this is the scenario the DESIGN contract was written for; the unit gate's
       group 9 uses it too)
  X4  abort with A's tail NEVER      -> exactly 1 wire frame = runt(prefix of A);
      arriving (= the chain probe's    B is swallowed by the flush (contract 3),
       own stimulus)                   counters must show it, no ghost
Classification (same shape as tb_mac_10g's tx_scan_frames):
  kind 2 = complete: len == injlen+4 and bytes[0..injlen-1] == injected content
  kind 1 = runt    : len <= injlen and bytes[0..len-1] == a prefix of injected content
  kind 0 = ghost   : anything else  -> FAIL

Run:  <anaconda>/python.exe patch_f2x.py
"""
import io
import sys

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

if 'F2X-PATCH' in s:
    print('already patched')
    sys.exit(0)


def sub(old, new, tag):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit('anchor %s occurs %d times' % (tag, n))
    s = s.replace(old, new)
    print('anchor %s ok' % tag)


# ------------------------------------------------- declarations + tasks
sub("""    task diag;
        input [127:0] tag;""",
    """    // ================== F2X-PATCH: F-2 attribution experiments ==================
    localparam F2X_STRIDE = 64;
    reg [7:0]  f2x_c [0:15*F2X_STRIDE-1];   // injected frame content bytes (contract order)
    integer    f2x_clen [0:15];
    integer    f2x_cn = 0;
    integer    wq_base = 0;
    reg [7:0]  f2x_wire [0:31][0:255];      // decoded wire-frame content bytes
    integer    f2x_wlen [0:31];
    integer    f2x_wkind [0:31];
    integer    f2x_wn = 0;
    integer    f2x_cls_n = 0;
    reg [31:0] f2x_abort0 = 0, f2x_flw0 = 0, f2x_fld0 = 0;

    // 内容图案 (与 PAT 相同的前 60 字节); 每帧独立登记, 支持多帧期望
    task f2x_add60;
        input integer base;
        integer i;
        begin
            for (i = 0; i < 60; i = i + 1) f2x_c[f2x_cn*F2X_STRIDE + i] = PAT[(base+i) % 256];
            f2x_clen[f2x_cn] = 60;
            f2x_cn = f2x_cn + 1;
        end
    endtask

    // 单拍确定性注入: force 在 negedge 落地/撤销 => 恰好跨过 1 个 posedge (坑 17)
    task f2x_push;
        input [63:0] d;
        input [7:0]  k;
        input        l;
        begin
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tdata = d;
            force u_dut.txsrc_tkeep = k;
            force u_dut.txsrc_tlast = l;
            force u_dut.txsrc_tvalid = 1'b1;
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tvalid = 1'b0;
        end
    endtask

    // 把登记的第 f 帧按 7 满字 + 1 个 tkeep=F0 尾字推入 (总 60 内容字节, 无 pad)
    task f2x_push_frame;
        input integer f;
        integer i;
        reg [63:0] d;
        begin
            for (i = 0; i < 7; i = i + 1) begin
                d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                     f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                     f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                     f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                f2x_push(d, 8'hFF, 1'b0);
            end
            d = {f2x_c[f*F2X_STRIDE+56], f2x_c[f*F2X_STRIDE+57],
                 f2x_c[f*F2X_STRIDE+58], f2x_c[f*F2X_STRIDE+59], 32'd0};
            f2x_push(d, 8'hF0, 1'b1);
        end
    endtask

    // 推入第 f 帧的头 nw 个字 (不结束该帧)
    task f2x_push_head;
        input integer f;
        input integer nw;
        integer i;
        reg [63:0] d;
        begin
            for (i = 0; i < nw; i = i + 1) begin
                d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                     f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                     f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                     f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                f2x_push(d, 8'hFF, 1'b0);
            end
        end
    endtask

    // 推入第 f 帧的第 w0..w1 个字, 最后一个字带 TLAST (残字段)
    task f2x_push_tail;
        input integer f;
        input integer w0;
        input integer w1;
        integer i;
        reg [63:0] d;
        begin
            for (i = w0; i <= w1; i = i + 1) begin
                d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                     f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                     f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                     f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                if (i == w1) f2x_push(d, 8'hF0, 1'b1);   // 末字: 60B 内容 = 4 有效字节
                else         f2x_push(d, 8'hFF, 1'b0);
            end
        end
    endtask

    // 在 [wq_base, wq_wr) 上解码线上帧并逐帧分类 (kind 0=幽灵/1=残缺前缀/2=完整)
    task f2x_scan;
        integer q, l2, dn, f, k2;
        reg [7:0] byt;
        reg       in_f, done;
        integer   st;
        begin
            f2x_wn = 0; in_f = 1'b0; st = 0;
            for (q = wq_base; q < wq_wr; q = q + 1) begin
                for (l2 = 0; l2 < 8; l2 = l2 + 1) begin
                    byt = wq_d[q][l2*8 +: 8];
                    if (in_f !== 1'b1) begin
                        if (wq_c[q][l2] === 1'b1 && byt === 8'hFB && l2 == 0) begin
                            if (f2x_wn < 32) begin in_f = 1'b1; st = 0; end
                        end
                    end else if (wq_c[q][l2] === 1'b1) begin
                        if (byt === 8'hFD) begin
                            if (f2x_wn < 32) begin
                                f2x_wlen[f2x_wn] = (st < 256) ? st : 256;
                                f2x_wn = f2x_wn + 1;
                            end
                            in_f = 1'b0;
                        end
                    end else begin
                        if (st < 256 && f2x_wn < 32) begin
                            f2x_wire[f2x_wn][st] = byt;
                            st = st + 1;
                        end
                    end
                end
            end
            // ---- 逐帧分类 (线上帧的前 7 字节 = 前导 55x6+D5, 内容从下标 7 起) ----
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
            end
        end
    endtask

    task f2x_show;
        input [255:0] tag;
        integer f, q;
        begin
            $display("  [F2X %0s] wire frames=%0d (window [%0d,%0d) inj=%0d)",
                     tag, f2x_wn, wq_base, wq_wr, f2x_cn);
            for (f = 0; f < f2x_wn && f < 32; f = f + 1) begin
                $display("  [F2X %0s] frame %0d len=%0d kind=%0d (0=ghost 1=runt 2=complete)",
                         tag, f, f2x_wlen[f], f2x_wkind[f]);
                for (q = 0; q < f2x_wlen[f] && q < 80; q = q + 8)
                    $display("      [%03d] %02h %02h %02h %02h %02h %02h %02h %02h", q,
                        f2x_wire[f][q], f2x_wire[f][q+1], f2x_wire[f][q+2], f2x_wire[f][q+3],
                        f2x_wire[f][q+4], f2x_wire[f][q+5], f2x_wire[f][q+6], f2x_wire[f][q+7]);
            end
        end
    endtask

    task f2x_begin;
        begin
            repeat (120) @(posedge u_dut.tx_mii_clk_1);   // 排空
            f2x_cn = 0;
            wq_base = wq_wr;
            f2x_abort0 = u_dut.u_mac_tx.stat_abort;
            f2x_flw0   = u_dut.u_mac_tx.stat_flush_words;
            f2x_fld0   = u_dut.u_mac_tx.stat_flush_done;
        end
    endtask

    task f2x_settle;
        begin
            repeat (250) @(posedge u_dut.tx_mii_clk_1);
        end
    endtask

    // 等到 stat_abort 递增 (= DUT 已经确认中止, 残字尚未注入) —— 消除激励竞争
    task f2x_wait_abort;
        integer n;
        begin
            n = 0;
            while ((u_dut.u_mac_tx.stat_abort === f2x_abort0) && (n < 2000)) begin
                n = n + 1;
                @(posedge u_dut.tx_mii_clk_1);
            end
            $display("  [F2X] abort observed after %0d tx cycles (abort %0d -> %0d)", n,
                     f2x_abort0, u_dut.u_mac_tx.stat_abort);
        end
    endtask

    task diag;
        input [127:0] tag;""", 'f2x_tasks')

# ------------------------------------------------------------ new section
sub("""        $display("==== tb_p7b_chain done: %0d checks, %0d fail ====", checks, fails);""",
    """        // =============================================================
        // F2X-PATCH: F-2 归因实验 (窗口 = 快照基准, 判据 = 线上逐帧内容)
        //   判据的判别力来源: 逐帧"内容必须等于某个注入帧 (完整或残缺前缀)", 任何
        //   "不是任何注入帧"的线上帧 = 幽灵帧 = FAIL。全部注入帧内容 = 60 字节
        //   (= MIN_CLEN, 无 pad), FCS 由 TB 位串行 crc32 独立算 (Python 侧复核)。
        // =============================================================
        $display("==== F2X: F-2 chain attribution experiments ====");

        // -------- X1: 单帧 (逐字节已知) --------
        f2x_begin;
        f2x_add60(1);                       // 帧 0 = PAT[1..60]
        f2x_push_frame(0);
        f2x_settle;
        f2x_scan;
        f2x_show("X1");
        chk("X1 one frame on the wire", f2x_wn === 1, "derived: 1 injected tlast frame");
        chk("X1 frame is complete (60B content + FCS)",
            (f2x_wn == 1) && (f2x_wkind[0] === 2), "derived: content byte-exact + FCS len");
        chk("X1 no ghost", (f2x_wn <= 0) || (f2x_wkind[0] !== 0), "derived: classification");

        // -------- X2: 两帧背靠背 --------
        f2x_begin;
        f2x_add60(1);
        f2x_add60(100);                     // 帧 1 = PAT[100..159] (与帧 0 逐字节不同)
        f2x_push_frame(0);
        f2x_push_frame(1);
        f2x_settle;
        f2x_scan;
        f2x_show("X2");
        chk("X2 two frames back-to-back", f2x_wn === 2, "derived: 2 injected tlast frames");
        chk("X2 both frames complete/byte-exact",
            (f2x_wn == 2) && (f2x_wkind[0] === 2) && (f2x_wkind[1] === 2),
            "derived: per-frame content compare");

        // -------- X3: 帧内中止 + 残字 (含本帧 TLAST) 随后到达 + 完整 B --------
        //   = 设计合同 F-2 针对的场景 (单元门组 9 同构): 残字必须被冲刷掉, B 必须完整上线
        f2x_begin;
        f2x_add60(1);                       // 帧 0 = A (被中止, 60B)
        f2x_add60(100);                     // 帧 1 = B (冲刷后应完整发出)
        f2x_push_head(0, 2);                // A 的头 2 个字 (16B) => 之后断供
        f2x_wait_abort;                     // 等 DUT 确认中止 (runt 已上线)
        f2x_push_tail(0, 2, 7);             // A 的残字 + 本帧 TLAST (必须被冲刷)
        f2x_push_frame(1);                  // B
        f2x_settle;
        f2x_scan;
        f2x_show("X3");
        chk("X3 exactly 2 wire frames (runt + B)", f2x_wn === 2,
            "derived: 1 aborted runt + 1 complete B");
        chk("X3 frame0 is a runt (strict prefix of A)",
            (f2x_wn >= 1) && (f2x_wkind[0] === 1), "derived: prefix compare vs injected A");
        chk("X3 frame1 is B byte-exact",
            (f2x_wn >= 2) && (f2x_wkind[1] === 2), "derived: complete-frame compare vs B");
        chk("X3 no ghost at all",
            (f2x_wn >= 2) && (f2x_wkind[0] !== 0) && (f2x_wkind[1] !== 0),
            "derived: classification");

        // -------- X4: 帧内中止 + A 的 TLAST 永不到达 + B (链级探针的原始激励) --------
        //   合同 (mac_tx_10g.v:24-31 情形3): 冲刷会吃掉 B 整帧 => 线上只有 runt,
        //   且 stat_flush_done == 1 / stat_flush_words >= 1
        f2x_begin;
        f2x_add60(1);                       // A
        f2x_add60(100);                     // B (注入但不许上线)
        f2x_push_head(0, 2);
        f2x_wait_abort;
        f2x_push_frame(1);                  // B: 这帧必须被冲刷吞掉
        f2x_settle;
        f2x_scan;
        f2x_show("X4");
        chk("X4 exactly 1 wire frame (runt only)", f2x_wn === 1,
            "contract: flush swallows the next frame when the aborted one has no TLAST");
        chk("X4 that frame is a runt (prefix of A)",
            (f2x_wn == 1) && (f2x_wkind[0] === 1), "derived: prefix compare vs injected A");
        chk("X4 no ghost", (f2x_wn >= 1) && (f2x_wkind[0] !== 0), "derived: classification");
        chk("X4 flush counters advanced",
            (u_dut.u_mac_tx.stat_flush_done === (f2x_fld0 + 32'd1)) &&
            (u_dut.u_mac_tx.stat_flush_words > f2x_flw0),
            "design bookkeeping (NOT the primary criterion)");
        chk("X4 no B on the wire",
            ((f2x_wn >= 1) && ((f2x_wlen[0] - 7) < 60)) ||
            ((f2x_wn >= 1) && (f2x_wire[0][7] !== f2x_c[F2X_STRIDE + 0])),
            "derived: B's first content byte must not appear as a frame start");

        release u_dut.txsrc_tdata;  release u_dut.txsrc_tkeep;
        release u_dut.txsrc_tvalid; release u_dut.txsrc_tlast;

        $display("==== tb_p7b_chain done: %0d checks, %0d fail ====", checks, fails);""",
    'f2x_section')

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('patched OK')
