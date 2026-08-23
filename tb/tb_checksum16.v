`timescale 1ns/1ps
// checksum16 单模块 TB: 按脚本 (csum_ty.memh 等) 时钟化非阻塞驱动,
// 每拍记录 csum_valid/csum 到 resp_csum.memh, Python 逐拍对拍。
// 脚本行: 0=GAP(n 拍) 1=init(val) 2=word(data,keep) 3=add(val) 4=fin
module tb_checksum16;

    reg        clk, rst_n;
    reg [7:0]  stim_ty [0:2047];
    reg [63:0] stim_d  [0:2047];
    reg [7:0]  stim_k  [0:2047];
    integer    nstim;
    reg [11:0] si;
    reg [15:0] gap_cnt;
    reg        init, den, aen, fin;
    reg [31:0] init_val;
    reg [63:0] ddata;
    reg [7:0]  dkeep;
    reg [17:0] aval;

    wire [15:0] csum;
    wire        csum_valid;
    integer     fd;

    checksum16 dut (
        .clk(clk), .rst_n(rst_n),
        .init(init), .init_val(init_val),
        .den(den), .din(ddata), .dkeep(dkeep),
        .aen(aen), .add_val(aval),
        .fin(fin),
        .csum(csum), .csum_valid(csum_valid)
    );

    always #4 clk = ~clk;     // 125 MHz

    always @(posedge clk) begin
        if (!rst_n) begin
            si <= 0; gap_cnt <= 0; init <= 0; den <= 0; aen <= 0; fin <= 0;
        end else begin
            init <= 0; den <= 0; aen <= 0; fin <= 0;
            if (gap_cnt > 0) begin
                gap_cnt <= gap_cnt - 1;
            end else if (si < nstim) begin
                case (stim_ty[si])
                    8'd0: gap_cnt <= stim_d[si][15:0] - 1;
                    8'd1: begin init <= 1; init_val <= stim_d[si][31:0]; end
                    8'd2: begin den <= 1; ddata <= stim_d[si]; dkeep <= stim_k[si]; end
                    8'd3: begin aen <= 1; aval <= stim_d[si][17:0]; end
                    8'd4: fin <= 1;
                    default: ;
                endcase
                si <= si + 1;
            end
        end
    end

    initial begin
        clk = 0; rst_n = 0;
        $readmemh("csum_ty.memh",   stim_ty);
        $readmemh("csum_data.memh", stim_d);
        $readmemh("csum_keep.memh", stim_k);
        nstim = 0;
        while (nstim < 2048 && stim_ty[nstim] !== 8'hxx) nstim = nstim + 1;
        fd = $fopen("resp_csum.memh", "w");
        #200; rst_n = 1;
        repeat (20000) @(posedge clk);
        $fclose(fd);
        $display("DONE");
        $finish;
    end

    always @(posedge clk)
        if (rst_n) $fwrite(fd, "%d %04h\n", csum_valid, csum);
endmodule
