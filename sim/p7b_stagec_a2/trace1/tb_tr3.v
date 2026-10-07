`timescale 1ns/1ps
module tb_tr3;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;
    reg [1:0] est;
    always @(posedge clk) if (!rst_n) est <= 2'd0; else est <= (est==2'd3)?2'd3:(est+1);
    wire ev_up = (est == 2'd1);
    wire [63:0] d; wire [7:0] k; wire v, l; wire [31:0] txb, txf, badf; wire done;
    app_pattern #(.TX_BYTES(32'd6000), .TX_SEGSZ(12'd1460), .BAD_LEN(12'd2000),
                  .SEED(64'h9E3779B97F4A7C15), .AUTO_CLOSE(1'b1))
    u (.clk(clk), .rst_n(rst_n), .ev_up(ev_up), .ev_down(1'b0), .ev_slot(4'd0),
       .m_tdata(d), .m_tkeep(k), .m_tvalid(v), .m_tready(1'b1), .m_tlast(l), .m_tid(),
       .app_tx_ready(16'hFFFF), .close_req(), .close_id(),
       .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
       .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd3),
       .stat_tx_bytes(txb), .stat_tx_frames(txf), .stat_bad_frames(badf),
       .stat_rx_bytes(), .stat_mismatch(), .active(), .act_id(), .done(done), .dbg_lfsr(), .led());
    integer c; integer nbeat;
    initial begin
        c = 0; nbeat = 0; rst_n = 0; est = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        forever begin
            @(posedge clk); #0.1;
            if (v) begin
                nbeat = nbeat + 1;
                $display("cyc=%0d BEAT#%0d k=%02x last=%b d=%016x seg_len=%0d seg_sent=%0d bcnt=%0d pwv=%b pwn=%0d pwl=%b badf=%b frmidx=%0d remain=%0d txb=%0d txf=%0d",
                  c, nbeat, k, l, d, u.seg_len, u.seg_sent, u.bcnt, u.pw_valid, u.pw_n, u.pw_last,
                  u.bad_frm, u.frm_idx, u.remain, txb, txf);
            end
            if (c > 12000) $finish;
            c = c + 1;
        end
    end
endmodule
