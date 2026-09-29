`timescale 1ns/1ps
module tb_crc_probe;
    function [31:0] cstep;
        input [31:0] c; input [7:0] bb;
        reg [31:0] r; integer i;
        begin
            r = c;
            for (i = 0; i < 8; i = i + 1)
                r = (r[0] ^ bb[i]) ? ((r >> 1) ^ 32'hEDB88320) : (r >> 1);
            cstep = r;
        end
    endfunction
    reg [31:0] cr; integer k; integer io;
    reg [7:0] s [0:8];
    initial begin
        s[0]="1"; s[1]="2"; s[2]="3"; s[3]="4"; s[4]="5"; s[5]="6"; s[6]="7"; s[7]="8"; s[8]="9";
        cr = 32'hFFFFFFFF;
        for (k = 0; k < 9; k = k + 1) cr = cstep(cr, s[k]);
        $display("A raw(123456789)=%08x  zlib=%08x (exp CBF43926)", cr, cr ^ 32'hFFFFFFFF);
        cr = cr ^ 32'hFFFFFFFF;   // FCS
        $display("B fcs bytes = %02x %02x %02x %02x", cr[7:0], cr[15:8], cr[23:16], cr[31:24]);
        for (k = 0; k < 4; k = k + 1) begin
            io = (k==0)? cr[7:0] : (k==1)? cr[15:8] : (k==2)? cr[23:16] : cr[31:24];
            cr = cstep(cr, io[7:0]);
        end
        $display("C residue=%08x (exp DEBB20E3)", cr);
        $finish;
    end
endmodule
