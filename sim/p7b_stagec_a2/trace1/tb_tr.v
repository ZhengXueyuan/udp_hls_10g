`timescale 1ns/1ps
module tb_tr;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;
    reg [1:0] est;
    always @(posedge clk) if (!rst_n) est <= 2'd0; else est <= (est==2'd3)?2'd3:(est+1);
    wire ev_up = (est == 2'd1);
    wire [63:0] d; wire [7:0] k; wire v, l; wire [31:0] txb; wire [63:0] dl;
    app_pattern #(.TX_BYTES(32'd64), .TX_SEGSZ(12'd7), .SEED(64'h9E3779B97F4A7C15), .AUTO_CLOSE(1'b1))
    u (.clk(clk), .rst_n(rst_n), .ev_up(ev_up), .ev_down(1'b0), .ev_slot(4'd0),
       .m_tdata(d), .m_tkeep(k), .m_tvalid(v), .m_tready(1'b1), .m_tlast(l), .m_tid(),
       .app_tx_ready(16'hFFFF), .close_req(), .close_id(),
       .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
       .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
       .stat_tx_bytes(txb), .stat_tx_frames(), .stat_bad_frames(),
       .stat_rx_bytes(), .stat_mismatch(), .active(), .act_id(), .done(), .dbg_lfsr(dl), .led());
    integer c;
    initial begin
        c = 0; rst_n = 0; est = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (30) begin
            @(posedge clk);
            #0.1;
            $display("cyc=%0d ev=%b v=%b k=%02x last=%b d=%016x lfsr=%016x txb=%0d",
                     c, ev_up, v, k, l, d, dl, txb);
            c = c + 1;
        end
        $finish;
    end
endmodule
