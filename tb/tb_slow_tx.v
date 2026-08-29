`timescale 1ns/1ps
// slow_tx_adp 单元 TB: HLS 字节流源 (时钟化非阻塞, held-valid) -> DUT -> AXIS 字流捕获。
// 模式: 默认 NOSTALL; +STALL (m_axis_tready 3高1低 k%4!=2); +HARD (hardwin_st.memh 窗硬停)。
// 捕获: 接受拍写 "%016h %02h %d" (m_tdata, m_tkeep, m_tlast), 末尾 STATS frames purge。
module tb_slow_tx;

    reg        clk, rst_n;
    reg [15:0] h_tdata;
    reg        h_tvalid;
    wire       h_tready;
    reg        m_rdy;

    reg [7:0]  stim_d [0:8191];
    reg [7:0]  stim_l [0:8191];
    reg [15:0] stim_g [0:8191];
    reg [31:0] nstim_r [0:0];
    reg [31:0] hw [0:1];
    integer    nstim;

    reg [31:0] idx, gap, k;
    reg        done;
    integer    fd;

    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tlast;
    wire [31:0] stat_frames, stat_purge;

    slow_tx_adp dut (
        .clk(clk), .rst_n(rst_n),
        .hls_tx_tdata(h_tdata), .hls_tx_tvalid(h_tvalid), .hls_tx_tready(h_tready),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_rdy), .m_axis_tlast(m_tlast),
        .stat_frames(stat_frames), .stat_purge(stat_purge)
    );

    always #4 clk = ~clk;

    always @(posedge clk) begin
        if (!rst_n) begin
            h_tvalid <= 0; h_tdata <= 0;
            idx <= 0; gap <= 0; k <= 0; done <= 0; m_rdy <= 1;
        end else begin
            k <= k + 1;
            if (h_tvalid && h_tready) h_tvalid <= 0;         // 接受
            if (!h_tvalid || (h_tvalid && h_tready)) begin
                if (gap > 0) gap <= gap - 1;
                else if (idx < nstim) begin
                    h_tdata  <= {6'b0, stim_l[idx][0], stim_d[idx]};
                    gap      <= stim_g[idx];
                    h_tvalid <= 1;
                    idx      <= idx + 1;
                end
            end
            if (idx >= nstim && !h_tvalid) done <= 1;
            if ($test$plusargs("HARD"))
                m_rdy <= !(k >= hw[0] && k < hw[1]);
            else if ($test$plusargs("STALL"))
                m_rdy <= (k % 4 != 2);
            else
                m_rdy <= 1;
        end
    end

    initial begin
        clk = 0; rst_n = 0;
        $readmemh("st_data.memh", stim_d);
        $readmemh("st_last.memh", stim_l);
        $readmemh("st_gap.memh",  stim_g);
        $readmemh("st_nstim.memh", nstim_r);
        nstim = nstim_r[0];
        if ($test$plusargs("HARD")) $readmemh("hardwin_st.memh", hw);
        if ($test$plusargs("STALL"))      fd = $fopen("resp_st_stall.memh", "w");
        else if ($test$plusargs("HARD"))  fd = $fopen("resp_st_hard.memh", "w");
        else                              fd = $fopen("resp_st_nostall.memh", "w");
        #200; rst_n = 1;
        wait (done == 1);
        repeat (8000) @(posedge clk);
        $fwrite(fd, "STATS %0d %0d\n", stat_frames, stat_purge);
        $fclose(fd);
        $display("DONE frames=%0d purge=%0d", stat_frames, stat_purge);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && m_tvalid && m_rdy)
            $fwrite(fd, "%016h %02h %d\n", m_tdata, m_tkeep, m_tlast);
    end
endmodule
