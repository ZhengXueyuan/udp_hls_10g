`timescale 1ns/1ps
// retx_ram: TCP 重传环形缓冲 (纯存储, 无 TCP 逻辑)。
// P4c: 16 conns x 64KB ring (字节偏移 w_seq[15:0], 模 2^16)。64-bit 左对齐: 流内
// 字节 k (k=0..w_n-1) = w_data[63-8*k -: 8] 写入 ring 字节 w_seq+k。
// 容量取 64KB/conn (而非逻辑窗 48KB) 的理由: 硬 ring 界须容最坏在飞 =
// (RING_CAP 0xBFFE - 1) + plen_max 4095 = 53244 字节, 且 2^16 使回绕 = 掩码
// (地址路径零新增逻辑, 不碰 P6 时序修复); 48KB 物理容不下该最坏值。
// 存储 = 2 个 bank (偶/奇 ring 字) x 64K 字, 每字 64b + 8 字节使能; 简单双口。
// ring 字 w 归 bank (w&1): bank 内地址 = {conn[3:0], w[12:1]} (每 conn 每 bank 4096 字)。
// 写: w_n 1..8 至多落 2 个连续 ring 字, 同拍双写两个 bank 各一次。
// 写流水 (P6 时序修复 步骤 1, 2026-09-12): 写地址/数据/使能入口寄存 1 拍 (地址
//   max_fanout=64, 复制交工具) => 写延迟 1 拍。
// 读流水 (P6 时序修复 步骤 3, 2026-09-12): 读地址/低 4 位选择入口寄存 1 拍 (rd_en
//   门控, 地址 max_fanout=32 交工具复制) => rd_en 拍后 2 拍出数 (原 1 拍);
//   调用方 ring 消费窗口整体后移 1 拍 (rd_tap/r_tap_seq 时序不变)。
// 读: r_data = W_w << 8*o | W_{w+1} >> 8*(8-o), rd_en 后 2 拍有效 (读口寄存器化,
//     rd_en 作读使能, 空闲时保持上一读数)。
module retx_ram (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        wr_en,
    input  wire [3:0]  w_conn,
    input  wire [15:0] w_seq,
    input  wire [63:0] w_data,
    input  wire [3:0]  w_n,
    input  wire        rd_en,
    input  wire [3:0]  r_conn,
    input  wire [15:0] r_seq,
    output wire [63:0] r_data
);
    // ---------------- 写分解 (o = 字内字节偏移, 至多落 2 字) ----------------
    wire [12:0] w     = w_seq[15:3];          // ring 字下标 0..8191 (P4c: 13 位)
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
    wire [11:0] wpa   = {w[12:1]};                       // 本字 bank 内位置
    wire [11:0] wpe   = wpa + {11'b0, w_seq[3]};          // 偶 bank: 奇数跨字 +1, 12 位自然回卷
    wire [15:0] wa_e  = {w_conn, wpe};
    wire [15:0] wa_o  = {w_conn, wpa};
    wire [63:0] d_e   = w_seq[3] ? d_hi : d_lo;
    wire [63:0] d_o   = w_seq[3] ? d_lo : d_hi;
    wire [7:0]  we_e  = w_seq[3] ? we_hi : we_lo;
    wire [7:0]  we_o  = w_seq[3] ? we_lo : we_hi;

    // ---------------- P6 时序修复: 写口寄存一拍 + 写地址复制 2 份 ----------------
    // 最差路径 (impl 报告 WNS -0.848, 912 failing endpoints 同族): u_tcp_tx FSM
    // state_reg -> 256 片 RAMB36 的 ADDRBWRADDR (写地址 w_ad={conn,w_seq[12:1]}
    // 巨大 fanout + 布线拥塞, route 6.30ns vs logic 1.53ns)。
    // 修复: (1) 写地址/数据/字节使能/写使能在模块入口寄存一拍 —— 解耦 FSM/TCB
    //  mux 组合路径, 终点不再直接落在 256 个写地址脚; (2) 地址寄存器带
    //  max_fanout=64, 由工具复制并就近布局 (每份 ~64 地址脚; 原 128/bank)。
    //  注: 不可手工复制成两个寄存器分驱两半 lane —— 同一 mem 数组出现两个写地址
    //  信号会被判为多写口, RAMB36 推断失败 (Synth 8-2914/8-5743, 实测踩坑);
    //  复制交给 max_fanout/phys_opt 在推断之后做, 不影响 BRAM 映射。
    // 写延迟 = 1 拍 (地址/数据/使能同延, 相互对齐不变)。**读侧未动**: 重传读点由
    // rb_snd_nxt 驱动, 与写游标 tap_seq 至少差 RTT/RTO (>= 数百拍), 1 拍写延迟无
    // 语义影响 (tap_seq 是 FSM 自身游标, 不依赖 ram 写完成)。
    (* max_fanout = 64 *) reg [15:0] wa_e_r;
    (* max_fanout = 64 *) reg [15:0] wa_o_r;
    reg [63:0] d_e_r, d_o_r;
    reg [7:0]  we_e_r, we_o_r;
    reg        wr_r;
    always @(posedge clk) begin
        wr_r   <= wr_en;
        wa_e_r <= wa_e;
        wa_o_r <= wa_o;
        d_e_r  <= d_e;  d_o_r  <= d_o;
        we_e_r <= we_e; we_o_r <= we_o;
    end

    // ---------------- 读分解 ----------------
    wire [12:0] rw    = r_seq[15:3];
    wire [11:0] rpa   = rw[12:1];
    wire [11:0] rpe   = rpa + {11'b0, r_seq[3]};
    wire [15:0] ra_e  = {r_conn, rpe};
    wire [15:0] ra_o  = {r_conn, rpa};
    reg  [63:0] q_e, q_o;

    // ---- P6 时序修复 步骤 3: 读地址入口寄存 1 拍 + 复制 (2026-09-12) ----
    // 依据 (routed 报告): 读地址网 rpe[*] 扇出 128 (全为 RAMB36 ADDRBWRADDR 宏
    //  负载), 布线 2.43ns; XDC FORCE_MAX_FANOUT 对宏负载 CARRY 驱动网复制无效
    //  (phys_opt 32-702 "Optimizations did not improve timing on the net")。
    //  改与写口同法: 地址入口寄存 (rd_en 门控), max_fanout 交综合/phys_opt 复制
    //  (写口 wa_e_r/wa_o_r 即按此法被复制成 384/1152 个网, 布线 0.19ns)。
    // 读延迟: 地址拍 (rd_en) → 2 拍出数。低 4 位选择 (字奇偶 + 字内偏移) 与地址
    //  同拍寄存、与数据同拍对齐 (r_sel 与 q 同由 rd_d1 使能) → 字节旋转不错位。
    //  调用方 (tcp_tx_frame S_RING) 只把 ring 消费窗口整体后移 1 拍, 读请求
    //  (rd_tap / r_tap_seq) 时序完全不变。
    (* max_fanout = 32 *) reg [15:0] ra_e_r, ra_o_r;
    (* max_fanout = 32 *) reg        rd_d1;   // 读使能也复制 (驱动 256 个 ENBWREN)
    reg  [3:0]  ra_sel_r;
    always @(posedge clk) begin
        rd_d1 <= rd_en;
        if (rd_en) begin
            ra_e_r   <= ra_e;
            ra_o_r   <= ra_o;
            ra_sel_r <= r_seq[3:0];
        end
    end

    reg  [3:0]  r_sel;
    wire [63:0] w_w   = r_sel[3] ? q_o : q_e;   // ring 字 rw
    wire [63:0] w_w1  = r_sel[3] ? q_e : q_o;   // ring 字 rw+1 (mod ring)
    wire [3:0]  ro4   = {1'b0, r_sel[2:0]};
    wire [5:0]  rsh_l = ro4 << 3;               // 8*ro
    wire [6:0]  rsh_h = (4'd8 - ro4) << 3;      // 8*(8-ro)
    assign r_data = (w_w << rsh_l) | ((ro4 == 0) ? 64'h0 : (w_w1 >> rsh_h));

    // ---------------- 存储: 偶/奇 bank, 8 字节使能, 无复位块 (推断 BRAM) ----
    reg [63:0] mem_e [0:65535];   // P4c: 每 bank 64K 字 (16 conns x 4096 字)
    reg [63:0] mem_o [0:65535];

    genvar bj;
    generate
        for (bj = 0; bj < 8; bj = bj + 1) begin : g_byte
            always @(posedge clk) begin
                // lane j (we 位 j) = 字内字节 j = 位 63-8j (byte 0 = MSB)
                if (wr_r && we_e_r[bj]) mem_e[wa_e_r][63-8*bj -: 8] <= d_e_r[63-8*bj -: 8];
                if (wr_r && we_o_r[bj]) mem_o[wa_o_r][63-8*bj -: 8] <= d_o_r[63-8*bj -: 8];
            end
        end
    endgenerate

    // 读口: 地址寄存拍 (rd_en) → 读拍 (rd_d1), 复位清零保持信号
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_e <= 64'h0; q_o <= 64'h0; r_sel <= 4'h0;
        end else if (rd_d1) begin
            q_e <= mem_e[ra_e_r];
            q_o <= mem_o[ra_o_r];
            r_sel <= ra_sel_r;
        end
    end
endmodule
