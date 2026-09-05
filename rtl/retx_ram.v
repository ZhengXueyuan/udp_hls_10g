`timescale 1ns/1ps
// retx_ram: TCP 重传环形缓冲 (纯存储, 无 TCP 逻辑)。
// 16 conns x 16KB ring (字节偏移 w_seq[13:0], 模 2^14)。64-bit 左对齐: 流内字节 k
// (k=0..w_n-1) = w_data[63-8*k -: 8] 写入 ring 字节 w_seq+k。
// 存储 = 2 个 bank (偶/奇 ring 字) x 16K 字, 每字 64b + 8 字节使能; 简单双口。
// ring 字 w 归 bank (w&1): bank 内地址 = {conn[3:0], w[10:1]} (每 conn 每 bank 1024 字)。
// 写: w_n 1..8 至多落 2 个连续 ring 字, 同拍双写两个 bank 各一次。
// 读: r_data = W_w << 8*o | W_{w+1} >> 8*(8-o), rd_en 后 1 拍有效 (读口寄存器化,
//     rd_en 作读使能, 空闲时保持上一读数)。
module retx_ram (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        wr_en,
    input  wire [3:0]  w_conn,
    input  wire [13:0] w_seq,
    input  wire [63:0] w_data,
    input  wire [3:0]  w_n,
    input  wire        rd_en,
    input  wire [3:0]  r_conn,
    input  wire [13:0] r_seq,
    output wire [63:0] r_data
);
    // ---------------- 写分解 (o = 字内字节偏移, 至多落 2 字) ----------------
    wire [10:0] w     = w_seq[13:3];          // ring 字下标 0..2047
    wire [3:0]  o4    = {1'b0, w_seq[2:0]};   // 0..7
    wire [4:0]  hi    = {1'b0, o4} + {1'b0, w_n};  // o+n = 1..15
    wire [3:0]  lc    = (hi > 4'd8) ? 4'd8 : hi[3:0];  // 首字字节数 min(o+n,8)
    wire [3:0]  hc    = (hi > 4'd8) ? (hi[3:0] - 4'd8) : 4'h0; // 跨字字节数
    wire [7:0]  we_lo = ((16'h0001 << lc) - 16'h0001) & ~((16'h0001 << o4) - 16'h0001);
    wire [7:0]  we_hi = (16'h0001 << hc) - 16'h0001;           // 0 跨字时为 0
    wire [5:0]  sh_lo = o4 << 3;                               // 右移 8*o, <=56
    wire [6:0]  sh_hi = (4'd8 - o4) << 3;                      // 左移 8*(8-o), 8..64
    wire [63:0] d_lo  = w_data >> sh_lo;   // 首字字节 o.. 右移 8o 归位 (高位对齐)
    wire [63:0] d_hi  = (o4 == 0) ? 64'h0 : (w_data << sh_hi);  // 跨字字节左移 8*(8-o)

    // 写端口按 bank 复用 (w_odd = ring 字下标 bit0 = w_seq[3])
    wire [9:0]  wpa   = {w[10:1]};                       // 本字 bank 内位置
    wire [9:0]  wpe   = wpa + {9'b0, w_seq[3]};           // 偶 bank: 奇数跨字 +1, 10 位自然回卷
    wire [13:0] wa_e  = {w_conn, wpe};
    wire [13:0] wa_o  = {w_conn, wpa};
    wire [63:0] d_e   = w_seq[3] ? d_hi : d_lo;
    wire [63:0] d_o   = w_seq[3] ? d_lo : d_hi;
    wire [7:0]  we_e  = w_seq[3] ? we_hi : we_lo;
    wire [7:0]  we_o  = w_seq[3] ? we_lo : we_hi;

    // ---------------- 读分解 ----------------
    wire [10:0] rw    = r_seq[13:3];
    wire [9:0]  rpa   = rw[10:1];
    wire [9:0]  rpe   = rpa + {9'b0, r_seq[3]};
    wire [13:0] ra_e  = {r_conn, rpe};
    wire [13:0] ra_o  = {r_conn, rpa};
    reg  [63:0] q_e, q_o;
    // 混合选择必须与 q 同拍: q = 上拍 rd_en 地址的数据 (rd_en 后 1 拍有效),
    // 故选择 (r_seq[3:0] = 字奇偶 + 字内偏移) 也随 rd_en 寄存器化; 若用当前
    // r_seq, 连续预读 (地址每拍 +8) 时选择超前数据 1 拍 → r_data 错位。
    reg  [3:0]  r_sel;
    wire [63:0] w_w   = r_sel[3] ? q_o : q_e;   // ring 字 rw
    wire [63:0] w_w1  = r_sel[3] ? q_e : q_o;   // ring 字 rw+1 (mod ring)
    wire [3:0]  ro4   = {1'b0, r_sel[2:0]};
    wire [5:0]  rsh_l = ro4 << 3;               // 8*ro
    wire [6:0]  rsh_h = (4'd8 - ro4) << 3;      // 8*(8-ro)
    assign r_data = (w_w << rsh_l) | ((ro4 == 0) ? 64'h0 : (w_w1 >> rsh_h));

    // ---------------- 存储: 偶/奇 bank, 8 字节使能, 无复位块 (推断 BRAM) ----
    reg [63:0] mem_e [0:16383];
    reg [63:0] mem_o [0:16383];

    genvar bj;
    generate
        for (bj = 0; bj < 8; bj = bj + 1) begin : g_byte
            always @(posedge clk) begin
                // lane j (we 位 j) = 字内字节 j = 位 63-8j (byte 0 = MSB)
                if (wr_en && we_e[bj]) mem_e[wa_e][63-8*bj -: 8] <= d_e[63-8*bj -: 8];
                if (wr_en && we_o[bj]) mem_o[wa_o][63-8*bj -: 8] <= d_o[63-8*bj -: 8];
            end
        end
    endgenerate

    // 读口: rd_en 作使能, 复位清零保持信号
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_e <= 64'h0; q_o <= 64'h0; r_sel <= 4'h0;
        end else if (rd_en) begin
            q_e <= mem_e[ra_e];
            q_o <= mem_o[ra_o];
            r_sel <= r_seq[3:0];
        end
    end
endmodule
