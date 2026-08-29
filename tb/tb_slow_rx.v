`timescale 1ns/1ps
// slow_rx_adp 单元 TB: 字流源 (时钟化非阻塞) -> DUT -> hls_rx 字节流捕获。
// 模式: 默认 NOSTALL; +STALL (hls_rx_tready 3高1低 k%4!=2);
//       +HARD (hardwin_sr.memh 窗硬停)。
// 捕获: 接受拍写 "%04h" hls_rx_tdata, 末尾 STATS commit drop。
module tb_slow_rx;

    reg        clk, rst_n;
    reg [63:0] s_tdata;
    reg [7:0]  s_tkeep;
    reg        s_tvalid, s_tlast, s_tuser, s_tcrs, s_terr;
    wire       s_tready;
    reg        h_rdy;

    reg [63:0] stim_d [0:8191];
    reg [7:0]  stim_k [0:8191];
    reg [7:0]  stim_l [0:8191];
    reg [7:0]  stim_u [0:8191];
    reg [7:0]  stim_c [0:8191];
    reg [7:0]  stim_e [0:8191];
    reg [15:0] stim_g [0:8191];
    reg [31:0] nstim_r [0:0];
    reg [31:0] hw [0:1];
    integer    nstim;

    reg [31:0] idx, gap, k;
    reg        done;
    integer    fd;

    wire [15:0] h_tdata;
    wire        h_tvalid;
    wire [31:0] stat_commit, stat_drop;

    slow_rx_adp dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .hls_rx_tdata(h_tdata), .hls_rx_tvalid(h_tvalid), .hls_rx_tready(h_rdy),
        .stat_commit(stat_commit), .stat_drop(stat_drop)
    );

    always #4 clk = ~clk;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_tvalid <= 0; s_tdata <= 0; s_tkeep <= 0; s_tlast <= 0;
            s_tuser <= 0; s_tcrs <= 0; s_terr <= 0;
            idx <= 0; gap <= 0; k <= 0; done <= 0; h_rdy <= 1;
        end else begin
            k <= k + 1;
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
            if ($test$plusargs("HARD"))
                h_rdy <= !(k >= hw[0] && k < hw[1]);
            else if ($test$plusargs("STALL"))
                h_rdy <= (k % 4 != 2);
            else
                h_rdy <= 1;
        end
    end

    initial begin
        clk = 0; rst_n = 0;
        $readmemh("sr_data.memh", stim_d);
        $readmemh("sr_keep.memh", stim_k);
        $readmemh("sr_last.memh", stim_l);
        $readmemh("sr_user.memh", stim_u);
        $readmemh("sr_crs.memh",  stim_c);
        $readmemh("sr_err.memh",  stim_e);
        $readmemh("sr_gap.memh",  stim_g);
        $readmemh("sr_nstim.memh", nstim_r);
        nstim = nstim_r[0];
        if ($test$plusargs("HARD")) $readmemh("hardwin_sr.memh", hw);
        if ($test$plusargs("STALL"))      fd = $fopen("resp_sr_stall.memh", "w");
        else if ($test$plusargs("HARD"))  fd = $fopen("resp_sr_hard.memh", "w");
        else                              fd = $fopen("resp_sr_nostall.memh", "w");
        #200; rst_n = 1;
        wait (done == 1);
        repeat (8000) @(posedge clk);
        $fwrite(fd, "STATS %0d %0d\n", stat_commit, stat_drop);
        $fclose(fd);
        $display("DONE commit=%0d drop=%0d", stat_commit, stat_drop);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && h_tvalid && h_rdy)
            $fwrite(fd, "%04h\n", h_tdata);
    end
endmodule
