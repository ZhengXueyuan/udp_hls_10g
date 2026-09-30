`timescale 1ns/1ps
// ==========================================================================
// P7B latent-FIFO 收口台架 —— 实例 2: `slow_rx_adp` 的 `u_ofifo` (fifo_sync) 写口
// ==========================================================================
// 被测缺陷: 播放器 `o_wr` 是**寄存器** (本轮决定、下拍落笔), 空间门却用**本拍**的
// `o_full` ⇒ 一拍错位。饱和那一拍 (占用 D-1 且有在飞写、下拍还要再写、无 pop)
// ⇒ 下一拍 full=1 ⇒ 该**字节**被 `fifo_sync` 静默丢弃 (无计数、无 abort) ⇒ 交给
// HLS 的帧少 1 字节, 其后的字节全部错位。
//
// 精确构造 (拍级推导, 与 RTL 对齐):
//   · 写 o_wr 在拍 T 决定 ⇒ 拍 T+1 落笔, 门 = full(T+1) = (occ(T+1)==2048)。
//     occ(T+1) = occ(T) + in_flight(T) ⇒ 丢的充要条件:
//       (i) occ(T) = 2047 且 T 拍有在飞写 (说明 T-1 拍也做了写决定), 且
//       (ii) **T 拍本身也做一次写决定** (否则 T+1 拍没有在飞写 = 无字可丢)。
//     (ii) 是关键: 播放器每字之间有一个 P_LOAD 空拍 (无写决定) ⇒ "占用恰好 2047"
//     必须落在**连续两次写决定**的相位上, 否则一个字都不丢。实测钉死: 同一份旧门 RTL,
//     cfg "3008 8 0" 也到满 2048, 但相位落在空拍 ⇒ ovf_cyc=0 零丢;
//     cfg "2100 7 0" (nb=7 改相位) ⇒ ovf_cyc=1 丢 1 字节 (logs/bench_mut.log)。
//   · 由 (i)(ii): 写序号 k 与 occ 的关系 occ(d_k) = k-2 (起播时 FIFO 空, 无 pop)。
//     取 NB=7 字节/字 (tkeep=0xFE) ⇒ 每次 P_LOAD 空拍跟在**每组 7 笔**写之后
//     (前导是 8 笔, 之后每字 7 笔) ⇒ 空拍出现在 k ∈ {8+7m}。k=2048 处 2040%7=3≠0
//     ⇒ 不是空拍 ⇒ d_2048 / d_2049 连续 ⇒ 写 #2049 在 occ=2047 被决定、下拍 (occ=2048)
//     被丢。**恰好丢 1 字节**。
//   · 该字节数是唯一闸: 开播门 `occ<=256` (P_IDLE), 一帧只写 8 + 载荷字节
//     ⇒ 峰值 ≈ 256 + 8 + 载荷 ⇒ 要摸到 2047 需载荷 > 1783 B。
//
// 配置 (plusarg):
//   默认        : NB=7 NP=2100 (过界, 命中相位)   ⇒ 修前丢 1 字节 / 修后零丢
//   NP=1400 NB=8: 不过界 (总写 1408 < 2048)        ⇒ 负对照, 两版都应零丢
//   FREE        : 读者恒就绪 (不饿)                ⇒ 负对照, 两版都应零丢
// 判据: 交付字节流**逐字节**等于期望 (8 前导 + 载荷计数序列) 且计数相等。
module tb_lat_of;
    parameter integer PACE = 8;      // 字间隔 (拍): 1G 线速 ≈ 1 字/8 拍
    parameter integer REL  = 6000;   // 喂完后继续饿读者的拍数 (> 写满 2048 的时间)
    parameter integer TAIL = 9000;   // 放开读者后的排空拍数

    reg clk, rst_n;
    reg [63:0] s_tdata;
    reg [7:0]  s_tkeep;
    reg        s_tvalid, s_tlast, s_tuser, s_tcrs, s_terr;
    wire       s_tready;
    wire       h_rdy;
    reg        freew;                // FREE 模式 (读者恒就绪) —— 负对照

    integer np;                      // 载荷字节数
    integer nb;                      // 每字有效字节数 (1..8)
    integer nw;                      // 载荷字数
    reg [7:0] keep_pat;
    integer wi, gap_cnt, k, phase, rel_cnt;

    wire [15:0] h_tdata;
    wire        h_tvalid;
    wire        h_rst_n;
    wire [31:0] stat_commit, stat_drop, stat_ovf;   // stat_ovf = u_ofifo 拒写字节数

    integer    npopped, first_bad;
    reg [7:0]  exp_b;
    integer    i;
    integer    fd;

    // ---- 可达性/损失探针 (层次引用 DUT 内部) ----
    //  ovf_cyc = 拍数, 其中 `u_ofifo.wr && u_ofifo.full` (即 fifo_sync 的 ovf_pulse)
    //            = **该拍有一次写被拒** (静默丢字节) —— 修前应 ≥1, 修后结构性 0。
    integer    maxocc, full_seen, ovf_cyc;
    always @(posedge clk) begin
        if (!rst_n) begin
            maxocc <= 0; full_seen <= 0; ovf_cyc <= 0;
        end else begin
            if (dut.occ > maxocc) maxocc <= dut.occ;
            if (dut.o_full) full_seen <= 1;
            if (dut.o_wr && dut.o_full) ovf_cyc <= ovf_cyc + 1;
        end
    end

    slow_rx_adp #(.WDOG(1000)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .hls_rx_tdata(h_tdata), .hls_rx_tvalid(h_tvalid), .hls_rx_tready(h_rdy),
        .hls_rst_n(h_rst_n),
        .stat_commit(stat_commit), .stat_drop(stat_drop),
        .stat_fifo_ovf(stat_ovf)
    );

    always #4 clk = ~clk;

    // ---- 读者 (HLS 侧): FREE ⇒ 恒就绪; 否则喂完后 REL 拍才放开 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            phase <= 0; rel_cnt <= 0; k <= 0;
        end else begin
            k <= k + 1;
            if (phase == 0 && wi >= nw && !s_tvalid) begin
                phase <= 1; rel_cnt <= REL;
            end
            if (phase == 1) begin
                if (rel_cnt == 0) phase <= 2;
                else rel_cnt <= rel_cnt - 1;
            end
        end
    end
    assign h_rdy = freew ? 1'b1 : (phase == 2);

    // ---- 字源 (1 字 / PACE 拍; 字内前 nb 字节 = 绝对字节计数, 高位对齐) ----
    always @(posedge clk) begin
        if (!rst_n) begin
            s_tvalid <= 0; s_tdata <= 0; s_tkeep <= 0; s_tlast <= 0;
            s_tuser <= 0; s_tcrs <= 0; s_terr <= 0;
            wi <= 0; gap_cnt <= 0;
        end else begin
            if (s_tvalid && s_tready) s_tvalid <= 0;
            if (!s_tvalid || (s_tvalid && s_tready)) begin
                if (gap_cnt != 0) gap_cnt <= gap_cnt - 1;
                else if (wi < nw) begin
                    s_tdata <= 64'd0;
                    for (i = 0; i < 8; i = i + 1)
                        if (i < nb)
                            s_tdata[63 - 8*i -: 8] <= (wi*nb + i) & 8'hFF;
                    s_tkeep  <= keep_pat;
                    s_tuser  <= (wi == 0);
                    s_tlast  <= (wi == nw - 1);
                    s_tcrs   <= (wi == nw - 1);
                    s_terr   <= 1'b0;
                    s_tvalid <= 1'b1;
                    wi       <= wi + 1;
                    gap_cnt  <= PACE - 1;
                end
            end
        end
    end

    // ---- 交付字节流捕获 + 逐字节判据 (期望: 8 前导 + 载荷计数序列) ----
    always @(posedge clk) begin
        if (!rst_n) begin
            npopped <= 0; first_bad <= -1;
        end else if (h_tvalid && h_rdy) begin
            exp_b = (npopped < 8) ? ((npopped == 7) ? 8'hD5 : 8'h55)
                                  : ((npopped - 8) & 8'hFF);
            if (h_tdata[7:0] !== exp_b && first_bad < 0)
                first_bad <= npopped;
            npopped <= npopped + 1;
        end
    end

    // ⚠️ 配置经**文件**下发, 不用 xsim 的 -testplusarg: 本机 xsim v2025.2 只接受
    //    **不带 `=`** 的 -testplusarg (实测 `-testplusarg NP=1400` ⇒ "Expected a
    //    switch but found 1" 然后打 usage 退出, 且第二次 -testplusarg 也报错)。
    //    格式: 一行三个十进制数 "np nb free"。
    integer cfg_fd;
    initial begin
        clk = 0; rst_n = 0;
        np = 2100; nb = 7; freew = 0;                // 默认 = 命中相位的丢字配置
        cfg_fd = $fopen("lat_of_cfg.txt", "r");
        if (cfg_fd != 0) begin
            if ($fscanf(cfg_fd, "%d %d %d", np, nb, freew) < 1)
                $display("TB_LAT_OF: cfg file unreadable, using defaults");
            $fclose(cfg_fd);
        end
        nw       = np / nb;
        keep_pat = (8'hFF << (8 - nb)) & 8'hFF;
        $display("CFG np=%0d nb=%0d free=%0d keep=%02X nw=%0d", np, nb, freew, keep_pat, nw);
        fd = $fopen("lat_of_out.txt", "w");
        #200; rst_n = 1;
        wait (phase == 2);
        repeat (TAIL) @(posedge clk);
        #100;
        $fwrite(fd, "SENT np %0d nw %0d nb %0d keep %02X\n", np, nw, nb, keep_pat);
        $fwrite(fd, "STATS %0d %0d\n", stat_commit, stat_drop);
        $fwrite(fd, "OUT %0d %0d\n", npopped, first_bad);
        $fwrite(fd, "PROBE maxocc %0d full_seen %0d ovf_cyc %0d stat_fifo_ovf %0d\n",
                maxocc, full_seen, ovf_cyc, stat_ovf);
        $fclose(fd);
        $display("RESULT np=%0d nb=%0d words=%0d commit=%0d drop=%0d popped=%0d expect=%0d first_bad=%0d",
                 np, nb, nw, stat_commit, stat_drop, npopped, np + 8, first_bad);
        $display("PROBE maxocc=%0d full_seen=%0d ovf_cyc=%0d stat_fifo_ovf=%0d",
                 maxocc, full_seen, ovf_cyc, stat_ovf);
        if (npopped === np + 8 && first_bad < 0)
            $display("TB_LAT_OF: PASS (byte-exact)");
        else
            $display("TB_LAT_OF: FAIL (delivered != expected: popped=%0d expect=%0d first_bad_idx=%0d)",
                     npopped, np + 8, first_bad);
        $finish;
    end

    initial begin
        repeat (600000) @(posedge clk);
        $display("TB_LAT_OF: TIMEOUT");
        $finish;
    end
endmodule
