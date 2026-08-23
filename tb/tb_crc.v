`timescale 1ns/1ps
// crc32_8b 单元验证: 已知向量 "123456789" -> zlib 0xCBF43926 -> 无终值取反 0x340BC6D9
module tb_crc;

    reg        clk = 0;
    reg        init = 0, en = 0;
    reg  [7:0] d = 0;
    wire [31:0] crc;
    integer i;

    crc32_8b u (.clk(clk), .init(init), .en(en), .d(d), .crc(crc));

    reg [7:0] msg [0:8];
    initial begin
        msg[0] = "1"; msg[1] = "2"; msg[2] = "3"; msg[3] = "4"; msg[4] = "5";
        msg[5] = "6"; msg[6] = "7"; msg[7] = "8"; msg[8] = "9";
    end

    always #5 clk = ~clk;

    initial begin
        @(posedge clk); init = 1;
        @(posedge clk); init = 0;
        for (i = 0; i < 9; i = i + 1) begin
            en = 1; d = msg[i];
            @(posedge clk);
        end
        en = 0;
        #5;
        if (crc == 32'h340BC6D9)
            $display("CRC UNIT PASS: crc=%08h", crc);
        else
            $display("CRC UNIT FAIL: crc=%08h (expect 340BC6D9)", crc);
        $finish;
    end
endmodule
