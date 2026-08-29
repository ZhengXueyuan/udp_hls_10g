`timescale 1ns/1ps
// tx_arb 单元 TB: 两路独立字流源 (时钟化非阻塞, held-valid, 接受拍可同拍重载)
// -> DUT -> 捕获 m 侧接受拍。模式: NOSTALL / +STALL (m_tready k%4!=2) / +HARD (窗)。
// 捕获: "%016h %02h %d" (m_tdata, m_tkeep, m_tlast)。
module tb_tx_arb;

    reg         clk, rst_n;
    reg  [63:0] f_tdata;
    reg  [7:0]  f_tkeep;
    reg         f_tvalid, f_tlast;
    wire        f_tready;
    reg  [63:0] s_tdata;
    reg  [7:0]  s_tkeep;
    reg         s_tvalid, s_tlast;
    wire        s_tready;
    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tlast;
    reg         m_rdy;

    reg [63:0] fa_d [0:1023];
    reg [7:0]  fa_k [0:1023];
    reg [7:0]  fa_l [0:1023];
    reg [15:0] fa_g [0:1023];
    reg [63:0] sa_d [0:1023];
    reg [7:0]  sa_k [0:1023];
    reg [7:0]  sa_l [0:1023];
    reg [15:0] sa_g [0:1023];
    reg [31:0] fa_n [0:0];
    reg [31:0] sa_n [0:0];
    reg [31:0] hw [0:1];
    integer    fn, sn;

    reg [31:0] fi, si, fgap, sgap, k;
    integer    fd;

    tx_arb dut (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(f_tdata), .s_fast_tkeep(f_tkeep), .s_fast_tvalid(f_tvalid),
        .s_fast_tready(f_tready), .s_fast_tlast(f_tlast),
        .s_slow_tdata(s_tdata), .s_slow_tkeep(s_tkeep), .s_slow_tvalid(s_tvalid),
        .s_slow_tready(s_tready), .s_slow_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_rdy), .m_axis_tlast(m_tlast)
    );

    always #4 clk = ~clk;

    // ---- fast 源 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            f_tvalid <= 0; f_tdata <= 0; f_tkeep <= 0; f_tlast <= 0;
            fi <= 0; fgap <= 0;
        end else begin
            if (f_tvalid && f_tready) f_tvalid <= 0;
            if (!f_tvalid || (f_tvalid && f_tready)) begin
                if (fgap > 0) fgap <= fgap - 1;
                else if (fi < fn) begin
                    f_tdata  <= fa_d[fi];
                    f_tkeep  <= fa_k[fi];
                    f_tlast  <= fa_l[fi][0];
                    fgap     <= fa_g[fi];
                    f_tvalid <= 1;
                    fi       <= fi + 1;
                end
            end
        end
    end

    // ---- slow 源 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            s_tvalid <= 0; s_tdata <= 0; s_tkeep <= 0; s_tlast <= 0;
            si <= 0; sgap <= 0;
        end else begin
            if (s_tvalid && s_tready) s_tvalid <= 0;
            if (!s_tvalid || (s_tvalid && s_tready)) begin
                if (sgap > 0) sgap <= sgap - 1;
                else if (si < sn) begin
                    s_tdata  <= sa_d[si];
                    s_tkeep  <= sa_k[si];
                    s_tlast  <= sa_l[si][0];
                    sgap     <= sa_g[si];
                    s_tvalid <= 1;
                    si       <= si + 1;
                end
            end
        end
    end

    // ---- m_tready 模式 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            m_rdy <= 1; k <= 0;
        end else begin
            k <= k + 1;
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
        $readmemh("fa_data.memh", fa_d);
        $readmemh("fa_keep.memh", fa_k);
        $readmemh("fa_last.memh", fa_l);
        $readmemh("fa_gap.memh",  fa_g);
        $readmemh("sa_data.memh", sa_d);
        $readmemh("sa_keep.memh", sa_k);
        $readmemh("sa_last.memh", sa_l);
        $readmemh("sa_gap.memh",  sa_g);
        $readmemh("fa_nstim.memh", fa_n);
        $readmemh("sa_nstim.memh", sa_n);
        fn = fa_n[0];
        sn = sa_n[0];
        if ($test$plusargs("HARD")) $readmemh("hardwin_ta.memh", hw);
        if ($test$plusargs("STALL"))      fd = $fopen("resp_ta_stall.memh", "w");
        else if ($test$plusargs("HARD"))  fd = $fopen("resp_ta_hard.memh", "w");
        else                              fd = $fopen("resp_ta_nostall.memh", "w");
        #200; rst_n = 1;
        wait (fi >= fn && si >= sn && !f_tvalid && !s_tvalid);
        repeat (2000) @(posedge clk);
        $fclose(fd);
        $display("DONE");
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && m_tvalid && m_rdy)
            $fwrite(fd, "%016h %02h %d\n", m_tdata, m_tkeep, m_tlast);
    end
endmodule
