`timescale 1ns/1ps
// tb_frame_fifo.v -- frame_fifo (W=73) 单元测试: D=512 / D=4096 / D=8192(AW=13) 三实例
// + 队列参考模型逐拍比较 empty/full/dout (73 位全字节级); 驱动侧另持写入日志做 pop
// 内容逐字断言 (日志按 D 最大 8192 环形索引 — 未弹字数恒 <= 深度, 环写不覆盖未弹字)。
// 阶段: (a) 空写直通 FWFT  (b) 每拍流式写读 (深度1 bypass 链)  (b2) 带停顿流
//       (c) 灌满后顺序弹出  (d) snap/rollback  (e) 空读 gating
//       (f) P4c D=8192/AW=13 回归: 8191/8192 灌满边界 + 512k-1/512k 回卷浸泡
//           (占用贴满, 13 位指针回卷 64 次) + 回卷后 snap/rollback
//       (g) P5d 应用侧形态回归 (永久守卫): 长只写 (占用贴满) -> 续读必须逐字精确
//           (全速 / 并发写 / 慢 1/64 / bursty 2/3 四种续读形态)
// 用法: xvlog <frame_fifo 源码> tb_frame_fifo.v glbl; xelab -L unisims_ver tb_frame_fifo glbl
// 驱动约束 (消费端语义同此): rollback 不与 rd/snap 同拍; snap 与帧首字写同拍。
// 空态 dout = 旧槽残留 (不定), 仅 !empty 时比较 dout (消费者亦按 !empty 取用)。
//
// 驱动时序纪律: 每拍在 posedge 后 #2 置激励; cyc_drive 的簿记 (pop 内容断言/写日志)
// 必须在本拍 posedge 之前用边沿前状态完成 —— pop 发生在该 posedge, 消费的是边沿前
// 呈现的 dout; 边沿后再采样 dout 已是下一头字 (错位一字)。

// ---------------- 队列参考模型 (指针无关, 逐拍等价 RTL 合同) ----------------
module frame_fifo_ref #(
    parameter W = 73, D = 512, AW = 9
)(
    input  wire        clk, rst_n, wr, snap, rollback, rd,
    input  wire [W-1:0] din,
    output reg  [W-1:0] dout,
    output wire        empty, full, rd_ok_o, wr_ok_o
);
    reg [W-1:0] q [0:D-1];
    integer     cnt, h, s_cnt;
    wire        rd_ok = rd && !empty;
    wire        wr_ok = wr && !full;
    // bypass 与 RTL 同判定: 写命中读指针 (空推入 / 深度1 pop+push)
    wire        bypass = wr_ok && ((rd_ok && cnt == 1) || (!rd_ok && cnt == 0));
    assign empty  = (cnt == 0);
    assign full   = (cnt == D);
    assign rd_ok_o = rd_ok;
    assign wr_ok_o = wr_ok;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 0; h <= 0; s_cnt <= 0; dout <= 0;
        end else begin
            if (bypass) dout <= din;                     // 直通登记 (等价 dout_r<=din)
            else if (!empty) dout <= rd_ok ? q[(h + 1) % D] : q[h];
            else dout <= 0;                              // 空态残留, 不参与比较
            if (snap) s_cnt <= cnt;
            if (rollback) cnt <= s_cnt;                  // 回卷: 丢弃 snap 后全部
            else cnt <= cnt + (wr_ok ? 1 : 0) - (rd_ok ? 1 : 0);
            if (wr_ok) q[(h + cnt) % D] <= din;          // 尾槽; pop 同拍则写头槽 (RTL 同)
            if (rd_ok) h <= (h + 1) % D;
        end
    end
endmodule

// ---------------- 顶层 TB ----------------
module tb_frame_fifo;
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst_n = 0;
    reg chk_en = 0;

    // 被测三实例: D=512 (slow 通道) / D=4096 (tcp_echo 主 FIFO) / D=8192 (P4c echo FIFO)
    reg        wr_s  [2:0];
    reg [72:0] din_s [2:0];
    reg        snap_s[2:0];
    reg        rb_s  [2:0];
    reg        rd_s  [2:0];
    wire [72:0] dout_s [2:0];
    wire        empty_s[2:0];
    wire        full_s [2:0];
    wire [72:0] dref_s [2:0];
    wire        eref_s [2:0];
    wire        fref_s [2:0];
    wire        rdok_s [2:0];
    wire        wrok_s [2:0];

    // 驱动侧逐字日志 (独立内容断言): 每个被接受写记录 din, 每次实际 pop 比对 dout
    // P4c: 环形容器 8192 槽 (最大深度); 未弹字数 <= 深度 ⇒ 环写绝不覆盖未弹字
    reg [72:0] wlog [2:0][0:8191];
    integer    wpos [2:0], snap_pos[2:0], pop_pos[2:0];
    integer    pop_cnt[2:0], wr_cnt[2:0];
    integer    wbase0, wbase1, pbase0, pbase1;

    genvar gd;
    generate
    for (gd = 0; gd < 3; gd = gd + 1) begin : GEN_FF
        frame_fifo #(.W(73), .D(gd == 0 ? 512 : (gd == 1 ? 4096 : 8192)),
                     .AW(gd == 0 ? 9   : (gd == 1 ? 12   : 13)))
        uut (clk, rst_n, wr_s[gd], din_s[gd], snap_s[gd], rb_s[gd], rd_s[gd],
             dout_s[gd], empty_s[gd], full_s[gd]);

        frame_fifo_ref #(.W(73), .D(gd == 0 ? 512 : (gd == 1 ? 4096 : 8192)),
                         .AW(gd == 0 ? 9   : (gd == 1 ? 12   : 13)))
        uref (clk, rst_n, wr_s[gd], snap_s[gd], rb_s[gd], rd_s[gd], din_s[gd],
              dref_s[gd], eref_s[gd], fref_s[gd], rdok_s[gd], wrok_s[gd]);

        // 逐拍监视: empty/full 恒比; !empty 时 dout 全 73 位比 (含 X 捕获)
        always @(posedge clk) begin : MON
            if (chk_en) begin
                #1;
                if (empty_s[gd] !== eref_s[gd]) begin
                    $display("FATAL SIDE%d T=%0t EMPTY RTL=%b REF=%b", gd, $time,
                             empty_s[gd], eref_s[gd]);
                    $fatal;
                end
                if (full_s[gd] !== fref_s[gd]) begin
                    $display("FATAL SIDE%d T=%0t FULL RTL=%b REF=%b", gd, $time,
                             full_s[gd], fref_s[gd]);
                    $fatal;
                end
                if (!eref_s[gd] && (dout_s[gd] !== dref_s[gd])) begin
                    $display("FATAL SIDE%d T=%0t DOUT RTL=%h REF=%h", gd, $time,
                             dout_s[gd], dref_s[gd]);
                    $fatal;
                end
            end
        end
    end
    endgenerate

    integer cyc = 0;
    integer sd, i, k;
    integer soak_full_cyc;       // (f2) 浸泡期 full=1 拍数 (贴满证据)
    integer ghost2;              // (f2) rollback 幽灵偏移 (见 f1 后注释)

    task automatic step1();
        begin
            @(posedge clk); #2; cyc = cyc + 1;
        end
    endtask

    // 帧字模式 (73 位): bit72=last 标志, [71:64] keep, [63:0] data
    function automatic [72:0] mkword(input integer ph, input integer seq,
                                     input integer last);
        reg [7:0]  k8;
        reg [63:0] d64;
        begin
            k8  = (seq + ph) & 8'hFF;
            d64 = (seq * 8'd97) + (ph * 8'd13);
            mkword = {last ? 1'b1 : 1'b0, k8, d64};
        end
    endfunction

    // 每拍驱动: 簿记 (pop 内容断言 / snap 位 / 写日志 / rb 截断) -> 置激励 -> posedge
    // 簿记判定用 RTL 寄存输出 empty_s/full_s (边沿后稳定, 即下一拍的边沿前状态)
    // 与本次 wr_v/rd_v 计算, 不用 ref 的组合输出 (同块内刚驱动输入会读到旧值)。
    task automatic cyc_drive(input integer wr_v, input integer rd_v,
                             input integer snap_v, input integer rb_v,
                             input [72:0] dnv);
        integer d;
        begin
            if (snap_v) begin
                for (d = 0; d < 3; d = d + 1) snap_pos[d] = wpos[d];  // 写前位
            end
            for (d = 0; d < 3; d = d + 1) begin
                if (wr_v && !full_s[d]) begin             // 本拍将写
                    wlog[d][wpos[d] % 8192] = dnv;        // 环形槽 (见头注释不变量)
                    wpos[d] = wpos[d] + 1;
                    wr_cnt[d] = wr_cnt[d] + 1;
                end
                if (rd_v && !empty_s[d]) begin            // 本拍将 pop
                    if (dout_s[d] !== wlog[d][pop_pos[d] % 8192]) begin
                        $display("FATAL SIDE%d T=%0t POP%0d expect=%h got=%h",
                                 d, $time, pop_pos[d],
                                 wlog[d][pop_pos[d] % 8192], dout_s[d]);
                        $fatal;
                    end
                    pop_pos[d] = pop_pos[d] + 1;
                    pop_cnt[d] = pop_cnt[d] + 1;
                end
            end
            if (rb_v) begin
                for (d = 0; d < 3; d = d + 1) wpos[d] = snap_pos[d];
            end
            for (d = 0; d < 3; d = d + 1) begin
                wr_s[d] = wr_v; rd_s[d] = rd_v; snap_s[d] = snap_v; rb_s[d] = rb_v;
                din_s[d] = dnv;
            end
            step1();
        end
    endtask

    // 空态断言 (在 posedge 之后调用: 读的是边沿后状态)
    task automatic expect_empty(input integer d, input integer v);
        begin
            if (empty_s[d] !== v) begin
                $display("FATAL SIDE%d T=%0t empty=%b expect=%b", d, $time,
                         empty_s[d], v);
                $fatal;
            end
        end
    endtask

    initial begin
        for (sd = 0; sd < 3; sd = sd + 1) begin
            wpos[sd] = 0; snap_pos[sd] = 0; pop_pos[sd] = 0;
            pop_cnt[sd] = 0; wr_cnt[sd] = 0;
        end
        for (sd = 0; sd < 3; sd = sd + 1) begin
            wr_s[sd] = 0; rd_s[sd] = 0; snap_s[sd] = 0; rb_s[sd] = 0; din_s[sd] = 0;
        end

        // ============ 复位 + 空读 gating 预检 ============
        rst_n = 0;
        repeat (6) step1();
        rst_n = 1;               // #2 后释放, 下一 posedge 生效
        step1();
        chk_en = 1;
        for (i = 0; i < 5; i = i + 1) cyc_drive(0, 1, 0, 0, 73'h0); // 空 FIFO 上持续 rd
        expect_empty(0, 1);
        expect_empty(1, 1);
        if (pop_cnt[0] != 0 || pop_cnt[1] != 0) begin
            $display("FATAL empty-rd consumed words"); $fatal;
        end
        $display("PASS_ph_e_pre  empty read gating (no pop, flags hold)");

        // ============ (a) FWFT 空写直通: 空->写, 下拍可见, 可弹 ============
        for (k = 0; k < 3; k = k + 1) begin
            cyc_drive(1, 0, 0, 0, mkword(1, k, 0));       // 空写 (bypass 沿)
            expect_empty(0, 0);                            // 写后 !empty
            cyc_drive(0, 1, 0, 0, 73'h0);                  // 弹回
            expect_empty(0, 1);                            // 弹后空
        end
        // 空写 + rd 同拍 (rd gating: 仍只写 1 字), 再弹
        cyc_drive(1, 1, 0, 0, mkword(1, 99, 0));
        expect_empty(0, 0);
        cyc_drive(0, 1, 0, 0, 73'h0);
        expect_empty(0, 1);
        // 空后连写 3 拍再连弹 3 拍
        cyc_drive(1, 0, 0, 0, mkword(1, 100, 0));
        cyc_drive(1, 0, 0, 0, mkword(1, 101, 0));
        cyc_drive(1, 0, 0, 0, mkword(1, 102, 0));
        cyc_drive(0, 1, 0, 0, 73'h0);
        cyc_drive(0, 1, 0, 0, 73'h0);
        cyc_drive(0, 1, 0, 0, 73'h0);
        expect_empty(0, 1);
        expect_empty(1, 1);
        if (pop_cnt[0] != 7 || wr_cnt[0] != 7) begin
            $display("FATAL (a) counts p%0d w%0d", pop_cnt[0], wr_cnt[0]); $fatal;
        end
        $display("PASS_ph_a  FWFT write-to-empty bypass, 1-cycle visibility, pops byte-exact");

        // ============ (b) 每拍流式 wr+rd (深度1 bypass 链) ============
        for (i = 0; i < 600; i = i + 1) cyc_drive(1, 1, 0, 0, mkword(2, i, 0));
        for (i = 0; i < 8; i = i + 1) cyc_drive(0, 1, 0, 0, 73'h0); // 排空尾字
        expect_empty(0, 1);
        expect_empty(1, 1);
        if (pop_cnt[0] != 607 || wr_cnt[0] != 607) begin
            $display("FATAL (b) cnt p%0d w%0d", pop_cnt[0], wr_cnt[0]); $fatal;
        end
        $display("PASS_ph_b  streaming wr+rd every cycle, 607 words byte-exact");

        // ============ (b2) 带停顿流: rd 每 3 拍停 1 拍 (读捕获/停顿路径) ============
        for (i = 0; i < 400; i = i + 1)
            cyc_drive(1, (i % 3) == 2 ? 0 : 1, 0, 0, mkword(3, i, 0));
        for (i = 0; i < 400; i = i + 1) cyc_drive(0, 1, 0, 0, 73'h0); // 排空
        expect_empty(0, 1);
        expect_empty(1, 1);
        $display("PASS_ph_b2 stall-stream byte-exact (writes=%0d pops=%0d)",
                 wr_cnt[0], pop_cnt[0]);

        // ============ (c) 灌满再顺序弹出 (A:512, B:4096) ============
        wbase0 = wr_cnt[0]; wbase1 = wr_cnt[1];
        pbase0 = pop_cnt[0]; pbase1 = pop_cnt[1];
        for (i = 0; i < 4160 + 32; i = i + 1) begin
            cyc_drive(1, 0, 0, 0, mkword(4, i, 0));
            if (i == 512) begin
                // 写尝试 512 (0 基) 必须被 full 拒绝; full 断言即拒写
                if (full_s[0] !== 1'b1) begin $display("FATAL A not full at 512"); $fatal; end
                if (wr_cnt[0] != wbase0 + 512) begin $display("FATAL A over-accepted"); $fatal; end
            end
            if (i == 4096) begin
                if (full_s[1] !== 1'b1) begin $display("FATAL B not full at 4096"); $fatal; end
                if (wr_cnt[1] != wbase1 + 4096) begin $display("FATAL B over-accepted"); $fatal; end
            end
        end
        // 满后仍试写 (应全部被拒)
        for (i = 0; i < 10; i = i + 1) cyc_drive(1, 0, 0, 0, mkword(4, 9999 + i, 0));
        if (wr_cnt[0] != wbase0 + 512 || wr_cnt[1] != wbase1 + 4096) begin
            $display("FATAL (c) accepted w=%0d/%0d", wr_cnt[0], wr_cnt[1]); $fatal;
        end
        for (i = 0; i < 4160 + 64; i = i + 1) cyc_drive(0, 1, 0, 0, 73'h0); // 排空
        expect_empty(0, 1);
        expect_empty(1, 1);
        if (pop_cnt[0] != pbase0 + 512 || pop_cnt[1] != pbase1 + 4096) begin
            $display("FATAL (c) pops=%0d/%0d", pop_cnt[0], pop_cnt[1]); $fatal;
        end
        $display("PASS_ph_c  fill-to-full (512/4096) + in-order drain byte-exact");

        // ============ (d) snap/rollback 帧回卷 ============
        // 帧1: a0..a3 提交; 帧2: b0..b2 snap 后 rollback 丢弃
        cyc_drive(1, 0, 1, 0, mkword(5, 0, 0));            // a0 (帧首 snap)
        cyc_drive(1, 0, 0, 0, mkword(5, 1, 0));
        cyc_drive(1, 0, 0, 0, mkword(5, 2, 0));
        cyc_drive(1, 0, 0, 0, mkword(5, 3, 1));            // a3 (last)
        cyc_drive(1, 0, 1, 0, mkword(5, 4, 0));            // b0 (帧首 snap)
        cyc_drive(1, 0, 0, 0, mkword(5, 5, 0));
        cyc_drive(1, 0, 0, 0, mkword(5, 6, 1));
        cyc_drive(0, 0, 0, 1, 73'h0);                      // rollback: 帧2 作废
        expect_empty(0, 0);                                // 帧1 仍存
        // 弹 a0, a1; 中段 snap+rollback -> a2,a3 保留
        cyc_drive(0, 1, 0, 0, 73'h0);
        cyc_drive(0, 1, 0, 0, 73'h0);
        cyc_drive(1, 0, 1, 0, mkword(6, 0, 0));            // c0 (帧首 snap)
        cyc_drive(1, 0, 0, 0, mkword(6, 1, 1));
        cyc_drive(0, 0, 0, 1, 73'h0);                      // rollback 帧3
        expect_empty(0, 0);                                // a2,a3 保留
        cyc_drive(0, 1, 0, 0, 73'h0);                      // a2
        cyc_drive(0, 1, 0, 0, 73'h0);                      // a3
        expect_empty(0, 1);
        expect_empty(1, 1);
        // 帧4 (5 字) + 帧5 (5 字) 双提交帧连弹
        cyc_drive(1, 0, 1, 0, mkword(7, 0, 0));
        cyc_drive(1, 0, 0, 0, mkword(7, 1, 0));
        cyc_drive(1, 0, 0, 0, mkword(7, 2, 0));
        cyc_drive(1, 0, 0, 0, mkword(7, 3, 0));
        cyc_drive(1, 0, 0, 0, mkword(7, 4, 1));
        cyc_drive(1, 0, 1, 0, mkword(7, 5, 0));
        cyc_drive(1, 0, 0, 0, mkword(7, 6, 0));
        cyc_drive(1, 0, 0, 0, mkword(7, 7, 0));
        cyc_drive(1, 0, 0, 0, mkword(7, 8, 0));
        cyc_drive(1, 0, 0, 0, mkword(7, 9, 1));
        for (i = 0; i < 10; i = i + 1) cyc_drive(0, 1, 0, 0, 73'h0);
        expect_empty(0, 1);
        expect_empty(1, 1);
        // 大帧 400 字 snap 后 rollback 全丢
        cyc_drive(1, 0, 1, 0, mkword(8, 0, 0));
        for (i = 1; i < 400; i = i + 1)
            cyc_drive(1, 0, 0, 0, mkword(8, i, i == 399 ? 1 : 0));
        cyc_drive(0, 0, 0, 1, 73'h0);
        expect_empty(0, 1);
        expect_empty(1, 1);
        for (i = 0; i < 4; i = i + 1) cyc_drive(0, 1, 0, 0, 73'h0); // 空读无害
        $display("PASS_ph_d  snap/rollback: discarded frames never leak, prior words intact");

        // ============ (e) 空读 gating 收尾 + 完整性复核 ============
        for (i = 0; i < 5; i = i + 1) begin
            cyc_drive(0, 1, 0, 0, 73'h0);
            expect_empty(0, 1);
            expect_empty(1, 1);
            expect_empty(2, 1);
        end
        cyc_drive(1, 0, 0, 0, mkword(9, 0, 0));
        cyc_drive(1, 0, 0, 0, mkword(9, 1, 1));
        cyc_drive(0, 1, 0, 0, 73'h0);
        cyc_drive(0, 1, 0, 0, 73'h0);
        expect_empty(0, 1);
        expect_empty(1, 1);
        expect_empty(2, 1);
        $display("PASS_ph_e  rd gating on empty: no corruption, data intact after");

        // ============ (f) D=8192 (AW=13) 边界回归 (P4c: 12→13 位, 回卷点 4096→8192) ====
        //  (f1) 8191/8192 灌满边界: i=8190 拍后必须未满 (恰 8191 字入, 余 1 槽),
        //       i=8191 拍后必须满且接受数恰 8192, i=8192 拍后再试写被拒 (计数不涨)。
        //       full 判定靠 wptr[13] 回卷位 — 12 位实现在 4096 处提前满/8192 处
        //       不满 → 两处断言 + 逐拍 ref 比较必炸。
        wbase1 = wr_cnt[2]; pbase1 = pop_cnt[2];
        for (i = 0; i < 8192 + 64; i = i + 1) begin
            cyc_drive(1, 0, 0, 0, mkword(10, i, 0));
            if (i == 8190) begin
                if (full_s[2] !== 1'b0) begin
                    $display("FATAL C full early at 8191 words (D=8192)"); $fatal;
                end
                if (wr_cnt[2] != wbase1 + 8191) begin
                    $display("FATAL C wcnt=%0d at 8191 words", wr_cnt[2]); $fatal;
                end
            end
            if (i == 8191) begin
                if (full_s[2] !== 1'b1) begin
                    $display("FATAL C not full at 8192 words (D=8192)"); $fatal;
                end
                if (wr_cnt[2] != wbase1 + 8192) begin
                    $display("FATAL C wcnt=%0d at 8192 words", wr_cnt[2]); $fatal;
                end
            end
            if (i == 8192) begin
                if (full_s[2] !== 1'b1) begin
                    $display("FATAL C full dropped at overflow attempt"); $fatal;
                end
                if (wr_cnt[2] != wbase1 + 8192) begin
                    $display("FATAL C over-accepted at 8192"); $fatal;
                end
            end
        end
        for (i = 0; i < 8192 + 64; i = i + 1) cyc_drive(0, 1, 0, 0, 73'h0);  // 排空
        expect_empty(2, 1);
        if (pop_cnt[2] != pbase1 + 8192) begin
            $display("FATAL C pops=%0d (expect %0d)", pop_cnt[2], pbase1 + 8192); $fatal;
        end
        $display("PASS_ph_f1 D=8192 fill-to-full: not-full@8191, full@8192, drain byte-exact");

        // 占用真值 = (wr_cnt-pop_cnt) - 幽灵偏移: (d)/(f3) 的 rollback 丢弃字仍留在
        // wr_cnt (历史接受数) 里; f1 排空后 FIFO 必空 (上面 expect_empty 已断言) →
        // 此刻的差值即纯幽灵偏移, 后续占用断言全部减去它。
        ghost2 = wr_cnt[2] - pop_cnt[2];

        //  (f2) 512k-1 / 512k 回卷浸泡: 先灌满 (wptr 走 0..8191 停在回卷点), 再持续
        //       wr=1 + rd 每 97 拍停 1 拍 → 占用恒贴满 (8191/8192), 13 位指针在
        //       满态下回卷 ~64 次; 每拍 ref 模型比对 empty/full/dout + 每次 pop 逐字断言。
        //       本阶段是 TB 最慢段 (~52 万拍 x 3 实例)。
        for (i = 0; i < 8192; i = i + 1) cyc_drive(1, 0, 0, 0, mkword(11, i, 0));
        soak_full_cyc = 0;
        for (i = 0; i < 524287; i = i + 1) begin            // 512k-1 拍
            cyc_drive(1, (i % 97) == 96 ? 0 : 1, 0, 0, mkword(11, 8192 + i, 0));
            if (full_s[2] === 1'b1) soak_full_cyc = soak_full_cyc + 1;
        end
        if ((wr_cnt[2] - pop_cnt[2] - ghost2) < 8191) begin
            $display("FATAL C soak occ=%0d at 512k-1 (expect 8191/8192)",
                     wr_cnt[2] - pop_cnt[2] - ghost2); $fatal;
        end
        if ((wr_cnt[2] - pop_cnt[2] - ghost2) > 8192) begin
            $display("FATAL C soak occ=%0d > depth at 512k-1",
                     wr_cnt[2] - pop_cnt[2] - ghost2); $fatal;
        end
        if (soak_full_cyc < 4096) begin
            $display("FATAL C soak full-cycles=%0d at 512k-1", soak_full_cyc); $fatal;
        end
        cyc_drive(1, (524287 % 97) == 96 ? 0 : 1, 0, 0, mkword(11, 8192 + 524287, 0));
        if (full_s[2] === 1'b1) soak_full_cyc = soak_full_cyc + 1;
        if ((wr_cnt[2] - pop_cnt[2] - ghost2) < 8191) begin // 512k 点
            $display("FATAL C soak occ=%0d at 512k", wr_cnt[2] - pop_cnt[2] - ghost2);
            $fatal;
        end
        $display("PASS_ph_f2 D=8192 soak 512k-1/512k cycles pinned at full (occ=%0d, full-cycles=%0d, wptr wraps=%0d)",
                 wr_cnt[2] - pop_cnt[2] - ghost2, soak_full_cyc, wr_cnt[2] / 8192);

        //  (f3) 回卷后 snap/rollback: 满态排半空 → 帧 A (3 字, 提交) 弹 A0 →
        //       帧 B (帧首 snap 后 rollback 全丢; 大帧持续写跨 wptr 回卷点) →
        //       残余 A1/A2 逐字内容仍对 (环形容器 + 13 位回卷快照双路径)
        for (i = 0; i < 4096; i = i + 1) cyc_drive(0, 1, 0, 0, 73'h0);   // 排到半满
        expect_empty(2, 0);
        cyc_drive(1, 0, 1, 0, mkword(12, 0, 0));            // A0 (帧首 snap)
        cyc_drive(1, 0, 0, 0, mkword(12, 1, 0));
        cyc_drive(1, 0, 0, 0, mkword(12, 2, 1));            // A2 (last)
        cyc_drive(0, 1, 0, 0, 73'h0);                       // 弹 A0
        cyc_drive(1, 0, 1, 0, mkword(12, 3, 0));            // B0 (帧首 snap)
        for (i = 1; i < 8192; i = i + 1)                     // 8192 字大帧 (跨回卷点)
            cyc_drive(1, 0, 0, 0, mkword(12, 3 + i, i == 8191 ? 1 : 0));
        cyc_drive(0, 0, 0, 1, 73'h0);                       // rollback: 帧 B 全丢
        expect_empty(2, 0);                                 // 残余未动
        cyc_drive(0, 1, 0, 0, 73'h0);                       // A1 (内容断言)
        cyc_drive(0, 1, 0, 0, 73'h0);                       // A2
        for (i = 0; i < 4200; i = i + 1) cyc_drive(0, 1, 0, 0, 73'h0);   // 排空
        expect_empty(2, 1);
        $display("PASS_ph_f3 D=8192 snap/rollback after pointer wrap: discarded frame gone, prior words intact");

        // ============ (g) 应用侧形态回归: 长只写停顿 -> 续读 (P5d known_idle_fifo 指控复核) =====
        //  背景: P5d 多连接门的 known_idle_fifo 探针报 "帧 FIFO 读侧长只写后续读吐 1 重复
        //  字 + 丢 1 字 (8B 错位)". 独立复核结论 = **非本模块行为**: 写侧流逐字连续
        //  (插桩 WSTRM=0), 错位由 P5d TB 命令脚本 `22: sink_rate = sa[31:0];` 的**阻塞赋值**
        //  在时钟沿同拍改 readiness 引起 (坑 3: 阻塞赋值 + @(posedge) 与 DUT 竞争 ->
        //  frame_fifo 的组合读址 r_ad = rptr + rd_ok 与时钟沿同时间步变化 -> unisim BRAM
        //  在该沿采到"沿后"地址 -> 读输出提前一个字). 把该写改成非阻塞分级后, 同一 RTL
        //  下 P5d 探针与主用例失配字节数均归零 (main: 122 checks / 0 FAIL, miss=0).
        //  本阶段把**应用侧形态**固定为永久回归: 该形态下读侧必须逐字精确 (C 实例 D=8192).
        //  (g1) 20k 拍纯只写 (满后拒写, rd=0) -> 全速续读排空
        for (i = 0; i < 20000; i = i + 1) cyc_drive(1, 0, 0, 0, mkword(13, i, 0));
        if (full_s[2] !== 1'b1) begin
            $display("FATAL (g1) not full after 20k write-only cycles"); $fatal;
        end
        for (i = 0; i < 8300; i = i + 1) cyc_drive(0, 1, 0, 0, 73'h0);
        expect_empty(2, 1);
        $display("PASS_ph_g1 long write-only (20k, pinned full) -> full-speed resume byte-exact");
        //  (g2) 长只写 -> 续读与写并发 (占用贴满; 每拍 rd+wr)
        for (i = 0; i < 12000; i = i + 1) cyc_drive(1, 0, 0, 0, mkword(14, i, 0));
        for (i = 0; i < 30000; i = i + 1) cyc_drive(1, 1, 0, 0, mkword(14, 12000 + i, 0));
        for (i = 0; i < 12000; i = i + 1) cyc_drive(0, 1, 0, 0, 73'h0);
        expect_empty(2, 1);
        $display("PASS_ph_g2 long write-only -> resume with concurrent write byte-exact");
        //  (g3) 长只写 -> 慢续读 (1/64) / bursty 续读 (2/3)
        for (i = 0; i < 12000; i = i + 1) cyc_drive(1, 0, 0, 0, mkword(15, i, 0));
        for (i = 0; i < 64 * 400; i = i + 1)
            cyc_drive(1, (i % 64) == 0 ? 1 : 0, 0, 0, mkword(15, 12000 + i, 0));
        for (i = 0; i < 3000; i = i + 1) cyc_drive(0, 1, 0, 0, 73'h0);
        for (i = 0; i < 12000; i = i + 1) cyc_drive(1, 0, 0, 0, mkword(16, i, 0));
        for (i = 0; i < 20000; i = i + 1)
            cyc_drive(1, (i % 3) != 2 ? 1 : 0, 0, 0, mkword(16, 12000 + i, 0));
        for (i = 0; i < 20000; i = i + 1) cyc_drive(0, 1, 0, 0, 73'h0);
        for (i = 0; i < 4; i = i + 1) begin
            cyc_drive(0, 1, 0, 0, 73'h0);
            expect_empty(2, 1);
        end
        $display("PASS_ph_g3 long write-only -> slow (1/64) / bursty (2/3) resume byte-exact");

        $display("PASS_ALL  frame_fifo unit: writes A=%0d B=%0d C=%0d pops A=%0d B=%0d C=%0d cycles=%0d",
                 wr_cnt[0], wr_cnt[1], wr_cnt[2], pop_cnt[0], pop_cnt[1], pop_cnt[2], cyc);
        $finish;
    end
endmodule
