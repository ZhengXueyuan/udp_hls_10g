`timescale 1ns/1ps
// 调试: 单帧 len6 直连 tcp_tx_frame, 探内部信号 (一次性, 不进回归)。
module tb_tcp_tx_dbg;
    reg clk, rst_n;
    reg [63:0] tdata; reg [7:0] tkeep; reg tvalid, tlast; reg [3:0] tid;
    wire tready;
    wire [63:0] m_tdata; wire [7:0] m_tkeep; wire m_tvalid, m_tlast;
    reg m_tready;

    tcp_tx_frame dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(tdata), .s_axis_tkeep(tkeep), .s_axis_tvalid(tvalid),
        .s_axis_tready(tready), .s_axis_tlast(tlast), .s_axis_tid(tid),
        .ack_req(1'b0), .ack_id(4'd0), .ack_val(32'd0),
        .rb_id(), .rb_snd_nxt(32'd6000), .rb_rcv_nxt(32'd1000), .rb_rcv_wnd(16'h2000),
        .rb_snd_una(32'd6000), .rb_snd_wnd(16'hFFFF),
        .upd_wr(), .upd_id(), .upd_sel(), .upd_val(),
        .cam_rd_id(), .cam_rd_dmac(48'h112233445566), .cam_rd_dip(32'hC0A86402),
        .cam_rd_sport(16'h3039), .cam_rd_dport(16'h1F90),
        .cfg_src_mac(48'h000A3501FEC1), .cfg_src_ip(32'hC0A86402),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .stat_frames(), .stat_bytes(), .stat_ack(), .stat_ack_drop(), .stat_eend()
    );

    always #4 clk = ~clk;

    integer c = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            c <= 0; tvalid <= 0;
        end else begin
            c <= c + 1;
            if (c == 5) begin
                tvalid <= 1; tdata <= 64'h030A11181F260000; tkeep <= 8'hFC; tlast <= 1; tid <= 0;
            end
            if (tvalid && tready) tvalid <= 0;
            $display("c=%0d state=%0d tvalid=%b tready=%b wr=%b din=%h | fdout=%h empty=%b rd=%b hold48=%h tail_d=%h | m_v=%b m_d=%h m_k=%h m_l=%b",
                     c, dut.state, tvalid, tready, dut.wr, dut.fdin,
                     dut.fdout, dut.pay_empty, dut.rd, dut.hold48, dut.tail_d,
                     m_tvalid, m_tdata, m_tkeep, m_tlast);
        end
    end

    initial begin
        clk = 0; rst_n = 0; tvalid = 0; tdata = 0; tkeep = 0; tlast = 0; tid = 0; m_tready = 1;
        #200 rst_n = 1;
        repeat (200) @(posedge clk);
        $finish;
    end
endmodule
