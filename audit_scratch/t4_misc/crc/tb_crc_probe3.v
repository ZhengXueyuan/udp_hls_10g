`timescale 1ns/1ps
module tb_crc_probe3;
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
    integer k, nbytes;
    reg [31:0] cr;
    reg [7:0] fcs [0:3];
    reg [7:0] pb [0:63];
    initial begin
        nbytes = 60;
        cr = 32'hFFFFFFFF;
        for (k = 0; k < nbytes; k = k + 1) begin
            pb[k] = ((k * 13) ^ (k >> 3)) & 8'hFF;
            cr = cstep(cr, pb[k]);
            if (k < 4) $display("STEP k=%0d byte=%02x raw=%08x", k, pb[k], cr);
        end
        $display("RAW60=%08x", cr);
        cr = cr ^ 32'hFFFFFFFF;
        fcs[0] = cr[7:0]; fcs[1] = cr[15:8]; fcs[2] = cr[23:16]; fcs[3] = cr[31:24];
        $display("FCS=%02x %02x %02x %02x", fcs[0],fcs[1],fcs[2],fcs[3]);
        for (k = 0; k < 4; k = k + 1) begin
            cr = cstep(cr, fcs[k]);
            $display("FCSSTEP k=%0d byte=%02x raw=%08x", k, fcs[k], cr);
        end
        $display("RESIDUE=%08x", cr);
        $finish;
    end
endmodule
