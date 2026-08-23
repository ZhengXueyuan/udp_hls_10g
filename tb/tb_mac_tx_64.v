`timescale 1ns/1ps
// mac_tx_64 单模块 TB: 按 tx_*.memh 脚本驱动 AXIS 输入 (时钟化非阻塞),
// 全程捕获 GMII TX (en+byte) 到 resp_tx.memh, 末尾附统计。
module tb_mac_tx_64;

    reg        clk, rst_n;
    reg [7:0]  stim_ty [0:4095];
    reg [63:0] stim_d  [0:4095];
    reg [7:0]  stim_k  [0:4095];
    reg        stim_l  [0:4095];
    reg [15:0] stim_n  [0:4095];
    integer    nstim;
    reg [12:0] si;
    reg [15:0] gap_cnt;
    reg        tvalid, tlast, presenting;
    reg [63:0] tdata;
    reg [7:0]  tkeep;

    wire        tready;
    wire [7:0]  gmii_txd;
    wire        gmii_tx_en;
    wire [31:0] stat_frames, stat_abort;
    integer     fd;

    mac_tx_64 dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(tdata), .s_axis_tkeep(tkeep),
        .s_axis_tvalid(tvalid), .s_axis_tready(tready), .s_axis_tlast(tlast),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(),
        .stat_frames(stat_frames), .stat_abort(stat_abort)
    );

    always #4 clk = ~clk;     // 125 MHz

    // ---- 时钟化 AXIS 刺激 (与 Python 模型 1:1) ----
    // 接受拍撤 valid 一拍再装下一词, 保证 tdata 在 valid 期间稳定 (防重复采样)
    always @(posedge clk) begin
        if (!rst_n) begin
            si <= 0; tvalid <= 0; tdata <= 0; tkeep <= 0; tlast <= 0; gap_cnt <= 0; presenting <= 0;
        end else begin
            if (gap_cnt > 0) begin
                presenting <= 0; tvalid <= 0; gap_cnt <= gap_cnt - 1;
            end else if (!presenting) begin
                if (si < nstim) begin
                    if (stim_ty[si]) begin
                        tdata <= stim_d[si]; tkeep <= stim_k[si]; tlast <= stim_l[si];
                        presenting <= 1; tvalid <= 1; si <= si + 1;
                    end else begin
                        tvalid <= 0; gap_cnt <= stim_n[si] - 1; si <= si + 1;
                    end
                end else begin
                    tvalid <= 0;
                end
            end else begin
                if (tvalid && tready) begin
                    presenting <= 0; tvalid <= 0;      // 空一拍再装下一词
                end
            end
        end
    end

    initial begin
        clk = 0; rst_n = 0;
        $readmemh("tx_ty.memh",   stim_ty);
        $readmemh("tx_data.memh", stim_d);
        $readmemh("tx_keep.memh", stim_k);
        $readmemh("tx_last.memh", stim_l);
        $readmemh("tx_gap.memh",  stim_n);
        nstim = 0;
        while (nstim < 4096 && stim_ty[nstim] !== 8'hxx) nstim = nstim + 1;
        fd = $fopen("resp_tx.memh", "w");
        #200; rst_n = 1;
        repeat (30000) @(posedge clk);
        $fwrite(fd, "STATS %0d %0d\n", stat_frames, stat_abort);
        $fclose(fd);
        $display("DONE frames=%0d abort=%0d", stat_frames, stat_abort);
        $finish;
    end

    always @(posedge clk)
        if (rst_n) $fwrite(fd, "%b %02h\n", gmii_tx_en, gmii_txd);
endmodule
