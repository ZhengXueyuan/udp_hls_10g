`timescale 1ns/1ps
// ==========================================================================
// P7B latent-FIFO 收口台架 —— 实例 1: `slow_tx_adp` 的 `u_wf` (frame_fifo) 写口
// ==========================================================================
// 被测缺陷: `wf_wr` 是**寄存器** (本轮决定、下拍落笔), 而空间门用的是**本拍**的
// `wf_full` ⇒ 一拍错位。饱和那一拍: "本拍 full=0 (D-1 占) + 有一笔在飞写" ⇒ 下拍
// full=1 ⇒ 该笔写被 `frame_fifo` 静默丢弃 (无计数、无 abort)。
//
// 精确构造 (拍级推导, 与 RTL 逐拍对齐):
//   · 写 wf_wr 在拍 T 决定 ⇒ 拍 T+1 落笔, 门 = full(T+1)。故"被丢"的充要条件是
//     full(T+1)=1, 即 occ(T)+in_flight(T) == 512。帧的最后一笔写 (带 tlast 的部分字,
//     与前一满字**背靠背**两笔) 在 occ(T)=511 且 in_flight(T)=1 时 ⇒ 丢 + 已 commit
//     + 该拍 FSM 已回 T_IDLE ⇒ abort 安全网不触发 = **静默**。
//   · 占用轨迹: 帧起点 = 前面所有帧的字数之和 (无读)。要 occ=511 落在"末字"那拍,
//     需该帧起点 = 513 - W (W = 本帧字数)。取 W=128 (内容 C=1017B, C%8==1 ⇒ 末字为
//     1 字节部分字) ⇒ 起点须 = 385 = 3*128 + 1 ⇒ 在第 3 个大帧后插一个 **1 字小帧**
//     (内容 8B) 把起点从 384 抬到 385。
//   · 刺激: 帧序列 [C,C,C, 8, C,C,C,C]; m_axis_tready 在喂入期恒 0 (tx_arb 饿死慢
//     路径 ≥33us 合法) ⇒ 无读 ⇒ 占用单调涨到 512。
//
// 判据 (协议合同, 与位流无关):
//   J1  #(输出 tlast) == stat_frames   每个 commit 的帧必须在输出侧恰好出现一次
//   J2  #tlast + stat_purge == N       帧守恒
//   J3  dangling == 0                  排空后不得留下"无 tlast 的裸尾巴"
// 期望: 修前 → frames=5 / tlasts=4 / purge=3 ⇒ J1,J2,J3 全 FAIL;
//       修后 → frames=4 / tlasts=4 / purge=4 ⇒ 三条全 PASS (被丢帧改判为整帧回卷)。
module tb_lat_wf;
    parameter integer C     = 1017;   // 大帧内容字节数 (W = 128 字/帧)
    parameter integer N     = 8;      // 帧数
    parameter integer STALL = 12000;  // m_axis_tready 恒 0 的拍数 (覆盖整个喂入期)
    parameter integer DRAIN = 6000;   // 放开 tready 后的排空拍数

    reg clk, rst_n;
    reg [15:0] h_tdata;
    reg        h_tvalid;
    wire       h_tready;
    reg        m_rdy;

    // ---- 帧尺寸表 + 字节流 ----
    integer   flen [0:N-1];                 // 每帧内容字节数
    localparam integer MAXB = N * (8 + C + 4);
    reg [7:0] bdata [0:MAXB-1];
    reg       blast [0:MAXB-1];
    integer   NS;                           // 实际字节数
    integer   idx;

    reg [31:0] k;
    integer    i, j, off;
    integer    fd;

    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tlast;
    wire [31:0] stat_frames, stat_purge, stat_ovf;   // stat_ovf = u_wf 拒写次数

    slow_tx_adp dut (
        .clk(clk), .rst_n(rst_n),
        .hls_tx_tdata(h_tdata), .hls_tx_tvalid(h_tvalid), .hls_tx_tready(h_tready),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_rdy), .m_axis_tlast(m_tlast),
        .stat_frames(stat_frames), .stat_purge(stat_purge),
        .stat_fifo_ovf(stat_ovf)
    );

    always #4 clk = ~clk;

    // ---- 捕获/判据统计 ----
    integer nword, nlast, runlen, maxrun, dangling;
    always @(posedge clk) begin
        if (!rst_n) begin
            nword <= 0; nlast <= 0; runlen <= 0; maxrun <= 0; dangling <= 0;
        end else if (m_tvalid && m_rdy) begin
            nword <= nword + 1;
            if (m_tlast) begin
                nlast  <= nlast + 1;
                if (runlen + 1 > maxrun) maxrun <= runlen + 1;
                runlen <= 0;
            end else begin
                runlen <= runlen + 1;
                if (runlen + 1 > maxrun) maxrun <= runlen + 1;
            end
        end
    end

    // ---- 字节源 (逐字节, 接受拍换字节) ----
    always @(posedge clk) begin
        if (!rst_n) begin
            h_tvalid <= 0; h_tdata <= 0; idx <= 0; k <= 0; m_rdy <= 1;
        end else begin
            k <= k + 1;
            if (h_tvalid && h_tready) h_tvalid <= 0;
            if (!h_tvalid || (h_tvalid && h_tready)) begin
                if (idx < NS) begin
                    h_tdata  <= {6'b0, blast[idx], bdata[idx]};
                    h_tvalid <= 1;
                    idx      <= idx + 1;
                end
            end
            m_rdy <= (k >= STALL);
        end
    end

    initial begin
        clk = 0; rst_n = 0;
        flen[0] = C; flen[1] = C; flen[2] = C;
        flen[3] = 8;                                  // 1 字小帧: 把下一个大帧起点抬到 385
        flen[4] = C; flen[5] = C; flen[6] = C; flen[7] = C;
        off = 0;
        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < 8; j = j + 1) begin
                bdata[off] = (j == 7) ? 8'hD5 : 8'h55;
                blast[off] = 1'b0;
                off = off + 1;
            end
            for (j = 0; j < flen[i]; j = j + 1) begin
                bdata[off] = (i * 8'h11 + j) & 8'hFF;
                blast[off] = 1'b0;
                off = off + 1;
            end
            bdata[off+0] = 8'hDE; blast[off+0] = 1'b0;
            bdata[off+1] = 8'hAD; blast[off+1] = 1'b0;
            bdata[off+2] = 8'hBE; blast[off+2] = 1'b0;
            bdata[off+3] = 8'hEF; blast[off+3] = 1'b1;   // tlast 在末 FCS 字节
            off = off + 4;
        end
        NS = off;
        if ($test$plusargs("VCD")) begin
            $dumpfile("tb_lat_wf.vcd");
            $dumpvars(0, tb_lat_wf);
        end
        fd = $fopen("lat_wf_out.txt", "w");
        #200; rst_n = 1;
        wait (idx >= NS && !h_tvalid);
        repeat (DRAIN) @(posedge clk);
        #100;
        dangling = (runlen != 0);
        $fwrite(fd, "SENT %0d bytes %0d\n", N, NS);
        $fwrite(fd, "STATS %0d %0d\n", stat_frames, stat_purge);
        $fwrite(fd, "OUT %0d %0d %0d %0d\n", nword, nlast, maxrun, dangling);
        $fwrite(fd, "PROBE fifo_ovf %0d\n", stat_ovf);
        $fclose(fd);
        $display("RESULT sent=%0d frames=%0d purge=%0d words=%0d tlasts=%0d maxrun=%0d dangling=%0d",
                 N, stat_frames, stat_purge, nword, nlast, maxrun, dangling);
        $display("PROBE fifo_ovf=%0d (拒写计数; 恒 0 = 无静默丢失)", stat_ovf);
        if (nlast !== stat_frames)
            $display("J1 FAIL: tlasts=%0d != stat_frames=%0d (committed frame never left the fifo intact)",
                     nlast, stat_frames);
        else
            $display("J1 PASS: tlasts=%0d == stat_frames=%0d", nlast, stat_frames);
        if (nlast + stat_purge !== N)
            $display("J2 FAIL: tlasts+purge=%0d != sent=%0d", nlast + stat_purge, N);
        else
            $display("J2 PASS: tlasts+purge=%0d == sent=%0d", nlast + stat_purge, N);
        if (dangling !== 0)
            $display("J3 FAIL: dangling tail word(s) without tlast: runlen=%0d", runlen);
        else
            $display("J3 PASS: no dangling tail");
        if (nlast === stat_frames && (nlast + stat_purge) === N && dangling === 0)
            $display("TB_LAT_WF: PASS");
        else
            $display("TB_LAT_WF: FAIL");
        $finish;
    end
endmodule
