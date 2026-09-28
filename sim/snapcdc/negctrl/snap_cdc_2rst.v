`timescale 1ns/1ps
//=============================================================================
// snap_cdc_2rst.v — **负对照用的旧结构** (scratch, 不在 rtl/ 里): 两个域各用各的复位
//   目的: 实测验证 "两域复位不同步 ⇒ busy 永久挂死" 这条论断, 而不是只在注释里断言。
//   唯一差异: b 域握手用外部 rst_b_n (独立复位), 不像正式版那样由 rst_n 同步而来。
//   其它逐行与 rtl/snap_cdc.v 相同 (含 ack_b <= ~ack_b 的修正)。
//=============================================================================
module snap_cdc_2rst #(
    parameter W = 32, parameter NW = 6
) (
    input  wire            clk_a, rst_a_n, req_a,
    output wire            busy_a,
    output reg  [NW*W-1:0] dout_a,
    output reg             valid_a,
    input  wire            clk_b, rst_b_n,
    input  wire [NW*W-1:0] din_b
);
    reg toggle_a;
    always @(posedge clk_a or negedge rst_a_n) begin
        if (!rst_a_n)                toggle_a <= 1'b0;
        else if (req_a && !busy_a)   toggle_a <= ~toggle_a;
    end

    reg [2:0] tog_sync_b;
    always @(posedge clk_b or negedge rst_b_n) begin
        if (!rst_b_n) tog_sync_b <= 3'd0;
        else          tog_sync_b <= {tog_sync_b[1:0], toggle_a};
    end
    wire update_b = (tog_sync_b[2] ^ tog_sync_b[1]);

    reg [NW*W-1:0] hold_b;
    always @(posedge clk_b or negedge rst_b_n) begin
        if (!rst_b_n)      hold_b <= {(NW*W){1'b0}};
        else if (update_b) hold_b <= din_b;
    end

    reg ack_b;
    always @(posedge clk_b or negedge rst_b_n) begin
        if (!rst_b_n)      ack_b <= 1'b0;
        else if (update_b) ack_b <= ~ack_b;
    end

    reg [2:0] ack_sync_a;
    always @(posedge clk_a or negedge rst_a_n) begin
        if (!rst_a_n) ack_sync_a <= 3'd0;
        else          ack_sync_a <= {ack_sync_a[1:0], ack_b};
    end

    wire done_a = (ack_sync_a[2] == toggle_a);
    reg  done_r;
    assign busy_a = (ack_sync_a[2] != toggle_a);

    always @(posedge clk_a or negedge rst_a_n) begin
        if (!rst_a_n) begin
            done_r <= 1'b1; dout_a <= {(NW*W){1'b0}}; valid_a <= 1'b0;
        end else begin
            done_r  <= done_a;
            valid_a <= done_a && !done_r;
            if (done_a && !done_r) dout_a <= hold_b;
        end
    end
endmodule
