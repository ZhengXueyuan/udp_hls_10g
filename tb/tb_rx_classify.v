`timescale 1ns/1ps
// rx_classify 单元 TB: 字流源 (时钟化非阻塞, gap 脚本) -> DUT -> fast/slow 两路捕获。
// 模式: 默认 NOSTALL; +STALL (fast 3高1低 k%4!=3, slow 2高1低 k%3!=0);
//       +HARD (hardwin_rc.memh 窗 [hw0,hw1) 双路硬停)。
// 捕获: 接受拍写 "F|S <data> <keep> <last> <user> <crs> <err>", 末尾 STATS。
module tb_rx_classify;

    reg        clk, rst_n;
    reg [63:0] s_tdata;
    reg [7:0]  s_tkeep;
    reg        s_tvalid, s_tlast, s_tuser, s_tcrs, s_terr;
    wire       s_tready;
    reg        f_rdy, s_rdy;

    reg [63:0] stim_d [0:4095];
    reg [7:0]  stim_k [0:4095];
    reg [7:0]  stim_l [0:4095];
    reg [7:0]  stim_u [0:4095];
    reg [7:0]  stim_c [0:4095];
    reg [7:0]  stim_e [0:4095];
    reg [15:0] stim_g [0:4095];
    reg [31:0] nstim_r [0:0];
    reg [31:0] hw [0:1];
    integer    nstim;

    reg [31:0] idx, gap, k;
    reg        done;
    integer    fd;

    wire [63:0] f_tdata, sl_tdata;
    wire [7:0]  f_tkeep, sl_tkeep;
    wire        f_tvalid, f_tlast, f_tuser, f_tcrs, f_terr;
    wire        sl_tvalid, sl_tlast, sl_tuser, sl_tcrs, sl_terr;
    wire [31:0] stat_fast, stat_slow;

    rx_classify dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .m_fast_tdata(f_tdata), .m_fast_tkeep(f_tkeep), .m_fast_tvalid(f_tvalid),
        .m_fast_tready(f_rdy), .m_fast_tlast(f_tlast), .m_fast_tuser(f_tuser),
        .m_fast_tcrs(f_tcrs), .m_fast_terr(f_terr),
        .m_slow_tdata(sl_tdata), .m_slow_tkeep(sl_tkeep), .m_slow_tvalid(sl_tvalid),
        .m_slow_tready(s_rdy), .m_slow_tlast(sl_tlast), .m_slow_tuser(sl_tuser),
        .m_slow_tcrs(sl_tcrs), .m_slow_terr(sl_terr),
        .stat_fast(stat_fast), .stat_slow(stat_slow)
    );

    always #4 clk = ~clk;   // 125 MHz

    // ---- 时钟化非阻塞激励 + 背压 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            s_tvalid <= 0; s_tdata <= 0; s_tkeep <= 0; s_tlast <= 0;
            s_tuser <= 0; s_tcrs <= 0; s_terr <= 0;
            idx <= 0; gap <= 0; k <= 0; done <= 0;
            f_rdy <= 1; s_rdy <= 1;
        end else begin
            k <= k + 1;
            // 源: 与 Python 模型 1:1
            if (s_tvalid && s_tready) s_tvalid <= 0;
            if (!s_tvalid || (s_tvalid && s_tready)) begin
                if (gap > 0) gap <= gap - 1;
                else if (idx < nstim) begin
                    s_tdata  <= stim_d[idx];
                    s_tkeep  <= stim_k[idx];
                    s_tlast  <= stim_l[idx][0];
                    s_tuser  <= stim_u[idx][0];
                    s_tcrs   <= stim_c[idx][0];
                    s_terr   <= stim_e[idx][0];
                    gap      <= stim_g[idx];
                    s_tvalid <= 1;
                    idx      <= idx + 1;
                end
            end
            if (idx >= nstim && !s_tvalid) done <= 1;
            // 背压
            if ($test$plusargs("HARD")) begin
                f_rdy <= !(k >= hw[0] && k < hw[1]);
                s_rdy <= !(k >= hw[0] && k < hw[1]);
            end else if ($test$plusargs("STALL")) begin
                f_rdy <= (k % 4 != 3);
                s_rdy <= (k % 3 != 0);
            end else begin
                f_rdy <= 1; s_rdy <= 1;
            end
        end
    end

    initial begin
        clk = 0; rst_n = 0;
        $readmemh("rc_data.memh", stim_d);
        $readmemh("rc_keep.memh", stim_k);
        $readmemh("rc_last.memh", stim_l);
        $readmemh("rc_user.memh", stim_u);
        $readmemh("rc_crs.memh",  stim_c);
        $readmemh("rc_err.memh",  stim_e);
        $readmemh("rc_gap.memh",  stim_g);
        $readmemh("rc_nstim.memh", nstim_r);
        nstim = nstim_r[0];
        if ($test$plusargs("HARD")) $readmemh("hardwin_rc.memh", hw);
        if ($test$plusargs("STALL"))      fd = $fopen("resp_rc_stall.memh", "w");
        else if ($test$plusargs("HARD"))  fd = $fopen("resp_rc_hard.memh", "w");
        else                              fd = $fopen("resp_rc_nostall.memh", "w");
        #200; rst_n = 1;
        wait (done == 1);
        repeat (400) @(posedge clk);
        $fwrite(fd, "STATS %0d %0d\n", stat_fast, stat_slow);
        $fclose(fd);
        $display("DONE fast=%0d slow=%0d", stat_fast, stat_slow);
        $finish;
    end

    // ---- 接受拍捕获 ----
    always @(posedge clk) begin
        if (rst_n && f_tvalid && f_rdy)
            $fwrite(fd, "F %016h %02h %d %d %d %d\n",
                    f_tdata, f_tkeep, f_tlast, f_tuser, f_tcrs, f_terr);
        if (rst_n && sl_tvalid && s_rdy)
            $fwrite(fd, "S %016h %02h %d %d %d %d\n",
                    sl_tdata, sl_tkeep, sl_tlast, sl_tuser, sl_tcrs, sl_terr);
    end
endmodule
