`timescale 1ns/1ps
// 临时调试 TB: 只跑 udp_tx_frame (无 gate), 逐拍打印内部状态
module tb_ovl_dbg;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;

    reg  [63:0] s_d; reg [7:0] s_k; reg s_v, s_l;
    wire        s_r;
    wire [63:0] m_d; wire [7:0] m_k; wire m_v, m_l;
    wire [31:0] st_f, st_b, st_dl;
    wire        busy;

    udp_tx_frame u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_d), .s_axis_tkeep(s_k), .s_axis_tvalid(s_v),
        .s_axis_tready(s_r), .s_axis_tlast(s_l),
        .cfg_src_mac(48'h000A3501FEC0), .cfg_dst_mac(48'h112233445566),
        .cfg_src_ip(32'hC0A86402),      .cfg_dst_ip(32'hC0A86401),
        .cfg_src_port(16'h1F91),        .cfg_dst_port(16'h1F91),
        .cfg_csum_en(1'b1),
        .m_axis_tdata(m_d), .m_axis_tkeep(m_k), .m_axis_tvalid(m_v),
        .m_axis_tready(1'b1), .m_axis_tlast(m_l),
        .stat_frames(st_f), .stat_bytes(st_b), .stat_drop_len(st_dl),
        .o_busy(busy)
    );

    integer cyc, n, i;
    // 3 帧: 0B(1 拍) / 32B(4 拍) / 63B(8 拍)
    reg [63:0] qd [0:12]; reg [7:0] qk [0:12]; reg ql [0:12];
    integer qn;
    initial begin
        qn = 0;
        // 帧0: 零长
        qd[0]=64'd0; qk[0]=8'h00; ql[0]=1'b1; qn=1;
        // 帧1: 32B
        for (i = 0; i < 4; i = i + 1) begin
            qd[qn] = {8'hA9, 8'hA9, 8'hA9, 8'hA9, 8'hA9, 8'hA9, 8'hA9, 8'hA9};
            qk[qn] = 8'hFF; ql[qn] = (i == 3); qn = qn + 1;
        end
        // 帧2: 63B (8 拍, 末拍 7 字节)
        for (i = 0; i < 8; i = i + 1) begin
            qd[qn] = {8'hB7, 8'hB7, 8'hB7, 8'hB7, 8'hB7, 8'hB7, 8'hB7, 8'hB7};
            qk[qn] = (i == 7) ? 8'hFE : 8'hFF; ql[qn] = (i == 7); qn = qn + 1;
        end
    end

    integer qi;
    always @(posedge clk) begin
        if (!rst_n) begin
            s_v <= 1'b0; s_d <= qd[0]; s_k <= qk[0]; s_l <= ql[0]; qi <= 0;
        end else begin
            if (s_v && s_r) begin
                if (ql[qi]) begin s_v <= 1'b0; qi <= qi + 1; end
                else begin
                    qi <= qi + 1; s_v <= 1'b1;
                    s_d <= qd[qi+1]; s_k <= qk[qi+1]; s_l <= ql[qi+1];
                end
            end else if (!s_v && qi < qn) s_v <= 1'b1;
        end
    end

    initial begin
        rst_n = 1'b0;
        cyc = 0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        for (cyc = 0; cyc < 200; cyc = cyc + 1) begin
            @(posedge clk);
            if (cyc > 8 && cyc < 60)
            $display("c=%0d rst=%b qi=%0d sv=%b sr=%b rxst=%0d txst=%0d rxb=%b txb=%b brdy=%b fin=%0d plen=%0d plenr0=%0d plenr1=%0d mv=%b ml=%b mk=%02h busy=%b stf=%0d",
                cyc, rst_n, qi, s_v, s_r,
                u_tx.rx_state, u_tx.tx_state, u_tx.rx_bank, u_tx.tx_bank,
                u_tx.bank_rdy, u_tx.fin_cnt, u_tx.plen, u_tx.plen_r[0], u_tx.plen_r[1],
                m_v, m_l, m_k, busy, st_f);
        end
        $display("DBG DONE frames=%0d bytes=%0d", st_f, st_b);
        $finish;
    end
endmodule
