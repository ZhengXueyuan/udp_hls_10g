`timescale 1ns/1ps
// ===========================================================================
// crc32_64 —— 8 字节/拍并行 以太网 CRC-32 (P7b 64 位 XGMII MAC 的 FCS 引擎)
// ===========================================================================
// 三条语义逐条沿用 rtl/crc32_8b.v (板级已验证: ping 5/5 / FCS 错帧恒 0):
//   ① 反射多项式 0xEDB88320 (即 IEEE 802.3 3.2.9 的 G(x), 反射形式)
//   ② 初值 0xFFFFFFFF ("first 32 bits complemented")
//   ③ **无终值取反**: 寄存器里就是反射引擎的原值; 终值取反只在**写 FCS 字段**时做
//      (fcs = crc ^ 0xFFFFFFFF, 小端/低字节先上线) —— 见 rtl/mac_tx_64.v:170,213
//   残留魔数 32'hDEBB20E3 (帧全字节流过后的寄存器值) —— **不是 0xC704DD7B**
//   (后者是 FCS 大端/非反射实现的魔数, 与本魔数互为位反转; 工程 CLAUDE.md 点名勿用)
//
// 接口语义:
//   d[63:56] = 线上第 1 个字节 (与本仓 64 位帧流合同同向: tdata[63:56] = 帧首字节)
//   keep     = 高位有效, popcount(keep) = 本字真正参与计算的字节数 k
//   init 优先于 en; en 与 d/keep **必须同拍** (工程坑 1: 寄存器化 en 会让 CRC 与字节流错位)
//
// ⭐ 部分字 (k<8) 怎么处理 —— 本模块的核心技巧 (推导见 notes/P7B_MAC_DESIGN.md §5):
//   把无效 lane **强制填 0** 后按整字 (8 字节) 推进得到 pad, 再左乘 M^{-(8-k)} 修正:
//       S_k = M^{k}·c ^ Σ_{i<k} M^{k-1-i}·D(b_i)          (真值: 只喂 k 个字节)
//       pad = M^{8}·c ^ Σ_{i<k} M^{7-i}·D(b_i)            (无效 lane 全是 0 ⇒ D(0)=0 自动屏蔽)
//       ⇒ M^{8-k}·S_k == pad  ⇒  S_k = M^{-(8-k)}·pad     (M 可逆: 反射步进矩阵常数项为 1)
//   这样**只需要一套 8 字节并行网络**, 不用为 9 种 k 各做一套偏序网络。
//   ⚠️ 无效 lane 必须真填 0 (D(0)=0), 不能只靠 keep 屏蔽 —— 这一步在 zb* 线里做。
//
// 常量块来源: scripts/gen_crc32_64.py (从 rtl/crc32_8b.v 的 step8 逐位导出),
//   生成器自带三重自检: ① 逆矩阵自检 ② 2000 组"部分字技巧 vs 朴素逐字节"逐位比对 ③ crc32("123456789")==0xCBF43926
// ===========================================================================
module crc32_64 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init,      // 1 拍脉冲: 寄存器复位为全 1 (优先于 en)
    input  wire        en,        // 本拍字参与计算 (与 d/keep 同拍)
    input  wire [63:0] d,         // 合同序: d[63:56] = 线上第 1 字节
    input  wire [7:0]  keep,      // 高位有效 (MSB-first); popcount = 有效字节数
    output reg  [31:0] crc,       // 寄存器值 (不含本拍)
    output wire [31:0] crc_nxt    // 组合: 含本拍 d/keep 的下一值
);
    function [3:0] popc8;
        input [7:0] x;
        reg [3:0] c;
        integer i;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + x[i];
            popc8 = c;
        end
    endfunction

    wire [31:0] crc_r = crc;
    wire [3:0]  m_cnt = 4'd8 - popc8(keep);   // 需要"回退"的字节数

    // ===== 以下常量块由 scripts/gen_crc32_64.py 从 rtl/crc32_8b.v 的 step8 逐位导出 =====
    // R_k = rstep8^k (k 次"喂 0 字节"推进); N_m = M^{-m} (尾部字节数修正的逆矩阵)
    // 无效 lane 必须先按 0 值参与 (D(0)=0 才会把它的贡献屏蔽掉)
    wire [7:0] zb0 = keep[7] ? d[63:56] : 8'h00;
    wire [7:0] zb1 = keep[6] ? d[55:48] : 8'h00;
    wire [7:0] zb2 = keep[5] ? d[47:40] : 8'h00;
    wire [7:0] zb3 = keep[4] ? d[39:32] : 8'h00;
    wire [7:0] zb4 = keep[3] ? d[31:24] : 8'h00;
    wire [7:0] zb5 = keep[2] ? d[23:16] : 8'h00;
    wire [7:0] zb6 = keep[1] ? d[15:8] : 8'h00;
    wire [7:0] zb7 = keep[0] ? d[7:0] : 8'h00;
    // pad = R_8(c) ^ Σ_{i=0..7} R_{7-i} · D(b_i)   (无效字节按 0 值参与: D(0)=0 自动屏蔽)
    wire [31:0] pad_r = {
        ^(crc_r & 32'hA40DA72D) ^ ^(zb0 & 8'h2D) ^ ^(zb1 & 8'hA7) ^ ^(zb2 & 8'h0D) ^ ^(zb3 & 8'hA4) ^ ^(zb4 & 8'hEF) ^ ^(zb5 & 8'h80) ^ ^(zb6 & 8'h68) ^ ^(zb7 & 8'h82),
        ^(crc_r & 32'h760B74BB) ^ ^(zb0 & 8'hBB) ^ ^(zb1 & 8'h74) ^ ^(zb2 & 8'h0B) ^ ^(zb3 & 8'h76) ^ ^(zb4 & 8'h98) ^ ^(zb5 & 8'hC0) ^ ^(zb6 & 8'h5C) ^ ^(zb7 & 8'hC3),
        ^(crc_r & 32'h9F081D70) ^ ^(zb0 & 8'h70) ^ ^(zb1 & 8'h1D) ^ ^(zb2 & 8'h08) ^ ^(zb3 & 8'h9F) ^ ^(zb4 & 8'hA3) ^ ^(zb5 & 8'hE0) ^ ^(zb6 & 8'hC6) ^ ^(zb7 & 8'hE3),
        ^(crc_r & 32'hCF840EB8) ^ ^(zb0 & 8'hB8) ^ ^(zb1 & 8'h0E) ^ ^(zb2 & 8'h84) ^ ^(zb3 & 8'hCF) ^ ^(zb4 & 8'h51) ^ ^(zb5 & 8'h70) ^ ^(zb6 & 8'hE3) ^ ^(zb7 & 8'h71),
        ^(crc_r & 32'h43CFA071) ^ ^(zb0 & 8'h71) ^ ^(zb1 & 8'hA0) ^ ^(zb2 & 8'hCF) ^ ^(zb3 & 8'h43) ^ ^(zb4 & 8'hC7) ^ ^(zb5 & 8'h38) ^ ^(zb6 & 8'h99) ^ ^(zb7 & 8'hBA),
        ^(crc_r & 32'h05EA7715) ^ ^(zb0 & 8'h15) ^ ^(zb1 & 8'h77) ^ ^(zb2 & 8'hEA) ^ ^(zb3 & 8'h05) ^ ^(zb4 & 8'h8C) ^ ^(zb5 & 8'h1C) ^ ^(zb6 & 8'h24) ^ ^(zb7 & 8'hDF),
        ^(crc_r & 32'h02F53B8A) ^ ^(zb0 & 8'h8A) ^ ^(zb1 & 8'h3B) ^ ^(zb2 & 8'hF5) ^ ^(zb3 & 8'h02) ^ ^(zb4 & 8'h46) ^ ^(zb5 & 8'h0E) ^ ^(zb6 & 8'h92) ^ ^(zb7 & 8'h6F),
        ^(crc_r & 32'hA5773AE8) ^ ^(zb0 & 8'hE8) ^ ^(zb1 & 8'h3A) ^ ^(zb2 & 8'h77) ^ ^(zb3 & 8'hA5) ^ ^(zb4 & 8'hCC) ^ ^(zb5 & 8'h87) ^ ^(zb6 & 8'hA1) ^ ^(zb7 & 8'hB5),
        ^(crc_r & 32'hF6B63A59) ^ ^(zb0 & 8'h59) ^ ^(zb1 & 8'h3A) ^ ^(zb2 & 8'hB6) ^ ^(zb3 & 8'hF6) ^ ^(zb4 & 8'h09) ^ ^(zb5 & 8'h43) ^ ^(zb6 & 8'hB8) ^ ^(zb7 & 8'hD8),
        ^(crc_r & 32'hFB5B1D2C) ^ ^(zb0 & 8'h2C) ^ ^(zb1 & 8'h1D) ^ ^(zb2 & 8'h5B) ^ ^(zb3 & 8'hFB) ^ ^(zb4 & 8'h84) ^ ^(zb5 & 8'h21) ^ ^(zb6 & 8'h5C) ^ ^(zb7 & 8'h6C),
        ^(crc_r & 32'hD9A029BB) ^ ^(zb0 & 8'hBB) ^ ^(zb1 & 8'h29) ^ ^(zb2 & 8'hA0) ^ ^(zb3 & 8'hD9) ^ ^(zb4 & 8'h2D) ^ ^(zb5 & 8'h90) ^ ^(zb6 & 8'h46) ^ ^(zb7 & 8'hB4),
        ^(crc_r & 32'h48DDB3F0) ^ ^(zb0 & 8'hF0) ^ ^(zb1 & 8'hB3) ^ ^(zb2 & 8'hDD) ^ ^(zb3 & 8'h48) ^ ^(zb4 & 8'hF9) ^ ^(zb5 & 8'hC8) ^ ^(zb6 & 8'h4B) ^ ^(zb7 & 8'hD8),
        ^(crc_r & 32'h00637ED5) ^ ^(zb0 & 8'hD5) ^ ^(zb1 & 8'h7E) ^ ^(zb2 & 8'h63) ^ ^(zb3 & 8'h00) ^ ^(zb4 & 8'h93) ^ ^(zb5 & 8'h64) ^ ^(zb6 & 8'h4D) ^ ^(zb7 & 8'hEE),
        ^(crc_r & 32'h8031BF6A) ^ ^(zb0 & 8'h6A) ^ ^(zb1 & 8'hBF) ^ ^(zb2 & 8'h31) ^ ^(zb3 & 8'h80) ^ ^(zb4 & 8'h49) ^ ^(zb5 & 8'hB2) ^ ^(zb6 & 8'h26) ^ ^(zb7 & 8'h77),
        ^(crc_r & 32'hC018DFB5) ^ ^(zb0 & 8'hB5) ^ ^(zb1 & 8'hDF) ^ ^(zb2 & 8'h18) ^ ^(zb3 & 8'hC0) ^ ^(zb4 & 8'h24) ^ ^(zb5 & 8'h59) ^ ^(zb6 & 8'h93) ^ ^(zb7 & 8'h3B),
        ^(crc_r & 32'h600C6FDA) ^ ^(zb0 & 8'hDA) ^ ^(zb1 & 8'h6F) ^ ^(zb2 & 8'h0C) ^ ^(zb3 & 8'h60) ^ ^(zb4 & 8'h92) ^ ^(zb5 & 8'hAC) ^ ^(zb6 & 8'hC9) ^ ^(zb7 & 8'h1D),
        ^(crc_r & 32'h940B90C0) ^ ^(zb0 & 8'hC0) ^ ^(zb1 & 8'h90) ^ ^(zb2 & 8'h0B) ^ ^(zb3 & 8'h94) ^ ^(zb4 & 8'hA6) ^ ^(zb5 & 8'h56) ^ ^(zb6 & 8'h8C) ^ ^(zb7 & 8'h8C),
        ^(crc_r & 32'h4A05C860) ^ ^(zb0 & 8'h60) ^ ^(zb1 & 8'hC8) ^ ^(zb2 & 8'h05) ^ ^(zb3 & 8'h4A) ^ ^(zb4 & 8'h53) ^ ^(zb5 & 8'h2B) ^ ^(zb6 & 8'h46) ^ ^(zb7 & 8'h46),
        ^(crc_r & 32'hA502E430) ^ ^(zb0 & 8'h30) ^ ^(zb1 & 8'hE4) ^ ^(zb2 & 8'h02) ^ ^(zb3 & 8'hA5) ^ ^(zb4 & 8'hA9) ^ ^(zb5 & 8'h15) ^ ^(zb6 & 8'h23) ^ ^(zb7 & 8'h23),
        ^(crc_r & 32'hD2817218) ^ ^(zb0 & 8'h18) ^ ^(zb1 & 8'h72) ^ ^(zb2 & 8'h81) ^ ^(zb3 & 8'hD2) ^ ^(zb4 & 8'hD4) ^ ^(zb5 & 8'h8A) ^ ^(zb6 & 8'h91) ^ ^(zb7 & 8'h11),
        ^(crc_r & 32'h6940B90C) ^ ^(zb0 & 8'h0C) ^ ^(zb1 & 8'hB9) ^ ^(zb2 & 8'h40) ^ ^(zb3 & 8'h69) ^ ^(zb4 & 8'h6A) ^ ^(zb5 & 8'hC5) ^ ^(zb6 & 8'hC8) ^ ^(zb7 & 8'h08),
        ^(crc_r & 32'h34A05C86) ^ ^(zb0 & 8'h86) ^ ^(zb1 & 8'h5C) ^ ^(zb2 & 8'hA0) ^ ^(zb3 & 8'h34) ^ ^(zb4 & 8'hB5) ^ ^(zb5 & 8'h62) ^ ^(zb6 & 8'h64) ^ ^(zb7 & 8'h04),
        ^(crc_r & 32'h3E5D896E) ^ ^(zb0 & 8'h6E) ^ ^(zb1 & 8'h89) ^ ^(zb2 & 8'h5D) ^ ^(zb3 & 8'h3E) ^ ^(zb4 & 8'hB5) ^ ^(zb5 & 8'hB1) ^ ^(zb6 & 8'h5A) ^ ^(zb7 & 8'h80),
        ^(crc_r & 32'h3B23639A) ^ ^(zb0 & 8'h9A) ^ ^(zb1 & 8'h63) ^ ^(zb2 & 8'h23) ^ ^(zb3 & 8'h3B) ^ ^(zb4 & 8'h35) ^ ^(zb5 & 8'hD8) ^ ^(zb6 & 8'h45) ^ ^(zb7 & 8'hC2),
        ^(crc_r & 32'h9D91B1CD) ^ ^(zb0 & 8'hCD) ^ ^(zb1 & 8'hB1) ^ ^(zb2 & 8'h91) ^ ^(zb3 & 8'h9D) ^ ^(zb4 & 8'h1A) ^ ^(zb5 & 8'hEC) ^ ^(zb6 & 8'h22) ^ ^(zb7 & 8'h61),
        ^(crc_r & 32'h4EC8D8E6) ^ ^(zb0 & 8'hE6) ^ ^(zb1 & 8'hD8) ^ ^(zb2 & 8'hC8) ^ ^(zb3 & 8'h4E) ^ ^(zb4 & 8'h0D) ^ ^(zb5 & 8'h76) ^ ^(zb6 & 8'h91) ^ ^(zb7 & 8'h30),
        ^(crc_r & 32'h0369CB5E) ^ ^(zb0 & 8'h5E) ^ ^(zb1 & 8'hCB) ^ ^(zb2 & 8'h69) ^ ^(zb3 & 8'h03) ^ ^(zb4 & 8'hE9) ^ ^(zb5 & 8'h3B) ^ ^(zb6 & 8'h20) ^ ^(zb7 & 8'h9A),
        ^(crc_r & 32'h81B4E5AF) ^ ^(zb0 & 8'hAF) ^ ^(zb1 & 8'hE5) ^ ^(zb2 & 8'hB4) ^ ^(zb3 & 8'h81) ^ ^(zb4 & 8'hF4) ^ ^(zb5 & 8'h1D) ^ ^(zb6 & 8'h10) ^ ^(zb7 & 8'h4D),
        ^(crc_r & 32'h40DA72D7) ^ ^(zb0 & 8'hD7) ^ ^(zb1 & 8'h72) ^ ^(zb2 & 8'hDA) ^ ^(zb3 & 8'h40) ^ ^(zb4 & 8'hFA) ^ ^(zb5 & 8'h0E) ^ ^(zb6 & 8'h88) ^ ^(zb7 & 8'h26),
        ^(crc_r & 32'h206D396B) ^ ^(zb0 & 8'h6B) ^ ^(zb1 & 8'h39) ^ ^(zb2 & 8'h6D) ^ ^(zb3 & 8'h20) ^ ^(zb4 & 8'h7D) ^ ^(zb5 & 8'h07) ^ ^(zb6 & 8'h44) ^ ^(zb7 & 8'h13),
        ^(crc_r & 32'h90369CB5) ^ ^(zb0 & 8'hB5) ^ ^(zb1 & 8'h9C) ^ ^(zb2 & 8'h36) ^ ^(zb3 & 8'h90) ^ ^(zb4 & 8'hBE) ^ ^(zb5 & 8'h03) ^ ^(zb6 & 8'hA2) ^ ^(zb7 & 8'h09),
        ^(crc_r & 32'h481B4E5A) ^ ^(zb0 & 8'h5A) ^ ^(zb1 & 8'h4E) ^ ^(zb2 & 8'h1B) ^ ^(zb3 & 8'h48) ^ ^(zb4 & 8'hDF) ^ ^(zb5 & 8'h01) ^ ^(zb6 & 8'hD1) ^ ^(zb7 & 8'h04)
    };
    // 修正: crc_nxt = N_{8-popc(keep)} · pad
    wire [31:0] nv0 = pad_r;
    wire [31:0] nv1 = {
        ^(pad_r & 32'h55800000),
        ^(pad_r & 32'hFF400000),
        ^(pad_r & 32'hAA200000),
        ^(pad_r & 32'h55100000),
        ^(pad_r & 32'h7F080000),
        ^(pad_r & 32'hEA040000),
        ^(pad_r & 32'h75020000),
        ^(pad_r & 32'hEF010000),
        ^(pad_r & 32'h22008000),
        ^(pad_r & 32'h91004000),
        ^(pad_r & 32'h9D002000),
        ^(pad_r & 32'h1B001000),
        ^(pad_r & 32'h58000800),
        ^(pad_r & 32'hAC000400),
        ^(pad_r & 32'hD6000200),
        ^(pad_r & 32'hEB000100),
        ^(pad_r & 32'hA0000080),
        ^(pad_r & 32'hD0000040),
        ^(pad_r & 32'h68000020),
        ^(pad_r & 32'h34000010),
        ^(pad_r & 32'h9A000008),
        ^(pad_r & 32'h4D000004),
        ^(pad_r & 32'hF3000002),
        ^(pad_r & 32'hAC000001),
        ^(pad_r & 32'hD6000000),
        ^(pad_r & 32'h6B000000),
        ^(pad_r & 32'h60000000),
        ^(pad_r & 32'hB0000000),
        ^(pad_r & 32'h58000000),
        ^(pad_r & 32'hAC000000),
        ^(pad_r & 32'h56000000),
        ^(pad_r & 32'hAB000000)
    };
    wire [31:0] nv2 = {
        ^(pad_r & 32'h8D558000),
        ^(pad_r & 32'hCBFF4000),
        ^(pad_r & 32'h68AA2000),
        ^(pad_r & 32'hB4551000),
        ^(pad_r & 32'h577F0800),
        ^(pad_r & 32'hA6EA0400),
        ^(pad_r & 32'hD3750200),
        ^(pad_r & 32'hE4EF0100),
        ^(pad_r & 32'h7F220080),
        ^(pad_r & 32'h3F910040),
        ^(pad_r & 32'h129D0020),
        ^(pad_r & 32'h841B0010),
        ^(pad_r & 32'h4F580008),
        ^(pad_r & 32'h27AC0004),
        ^(pad_r & 32'h93D60002),
        ^(pad_r & 32'h49EB0001),
        ^(pad_r & 32'h29A00000),
        ^(pad_r & 32'h94D00000),
        ^(pad_r & 32'h4A680000),
        ^(pad_r & 32'hA5340000),
        ^(pad_r & 32'h529A0000),
        ^(pad_r & 32'h294D0000),
        ^(pad_r & 32'h99F30000),
        ^(pad_r & 32'hC1AC0000),
        ^(pad_r & 32'h60D60000),
        ^(pad_r & 32'hB06B0000),
        ^(pad_r & 32'h55600000),
        ^(pad_r & 32'hAAB00000),
        ^(pad_r & 32'hD5580000),
        ^(pad_r & 32'h6AAC0000),
        ^(pad_r & 32'h35560000),
        ^(pad_r & 32'h1AAB0000)
    };
    wire [31:0] nv3 = {
        ^(pad_r & 32'h428D5580),
        ^(pad_r & 32'h63CBFF40),
        ^(pad_r & 32'h7368AA20),
        ^(pad_r & 32'hB9B45510),
        ^(pad_r & 32'h9E577F08),
        ^(pad_r & 32'h8DA6EA04),
        ^(pad_r & 32'hC6D37502),
        ^(pad_r & 32'hA1E4EF01),
        ^(pad_r & 32'h927F2200),
        ^(pad_r & 32'h493F9100),
        ^(pad_r & 32'h66129D00),
        ^(pad_r & 32'h71841B00),
        ^(pad_r & 32'h7A4F5800),
        ^(pad_r & 32'h3D27AC00),
        ^(pad_r & 32'h1E93D600),
        ^(pad_r & 32'h8F49EB00),
        ^(pad_r & 32'h8529A000),
        ^(pad_r & 32'h4294D000),
        ^(pad_r & 32'hA14A6800),
        ^(pad_r & 32'hD0A53400),
        ^(pad_r & 32'h68529A00),
        ^(pad_r & 32'hB4294D00),
        ^(pad_r & 32'h9899F300),
        ^(pad_r & 32'h0EC1AC00),
        ^(pad_r & 32'h8760D600),
        ^(pad_r & 32'hC3B06B00),
        ^(pad_r & 32'hA3556000),
        ^(pad_r & 32'h51AAB000),
        ^(pad_r & 32'h28D55800),
        ^(pad_r & 32'h146AAC00),
        ^(pad_r & 32'h0A355600),
        ^(pad_r & 32'h851AAB00)
    };
    wire [31:0] nv4 = {
        ^(pad_r & 32'h64428D55),
        ^(pad_r & 32'hD663CBFF),
        ^(pad_r & 32'h0F7368AA),
        ^(pad_r & 32'h87B9B455),
        ^(pad_r & 32'hA79E577F),
        ^(pad_r & 32'h378DA6EA),
        ^(pad_r & 32'h9BC6D375),
        ^(pad_r & 32'hA9A1E4EF),
        ^(pad_r & 32'h30927F22),
        ^(pad_r & 32'h18493F91),
        ^(pad_r & 32'hE866129D),
        ^(pad_r & 32'h9071841B),
        ^(pad_r & 32'h2C7A4F58),
        ^(pad_r & 32'h963D27AC),
        ^(pad_r & 32'h4B1E93D6),
        ^(pad_r & 32'hA58F49EB),
        ^(pad_r & 32'hB68529A0),
        ^(pad_r & 32'h5B4294D0),
        ^(pad_r & 32'h2DA14A68),
        ^(pad_r & 32'h16D0A534),
        ^(pad_r & 32'h8B68529A),
        ^(pad_r & 32'hC5B4294D),
        ^(pad_r & 32'h869899F3),
        ^(pad_r & 32'hA70EC1AC),
        ^(pad_r & 32'hD38760D6),
        ^(pad_r & 32'hE9C3B06B),
        ^(pad_r & 32'h10A35560),
        ^(pad_r & 32'h8851AAB0),
        ^(pad_r & 32'h4428D558),
        ^(pad_r & 32'h22146AAC),
        ^(pad_r & 32'h910A3556),
        ^(pad_r & 32'hC8851AAB)
    };
    wire [31:0] nv5 = {
        ^(pad_r & 32'hFF64428D),
        ^(pad_r & 32'h80D663CB),
        ^(pad_r & 32'hBF0F7368),
        ^(pad_r & 32'h5F87B9B4),
        ^(pad_r & 32'hD0A79E57),
        ^(pad_r & 32'h17378DA6),
        ^(pad_r & 32'h8B9BC6D3),
        ^(pad_r & 32'hBAA9A1E4),
        ^(pad_r & 32'h2230927F),
        ^(pad_r & 32'h1118493F),
        ^(pad_r & 32'hF7E86612),
        ^(pad_r & 32'h04907184),
        ^(pad_r & 32'h7D2C7A4F),
        ^(pad_r & 32'h3E963D27),
        ^(pad_r & 32'h1F4B1E93),
        ^(pad_r & 32'h8FA58F49),
        ^(pad_r & 32'hB8B68529),
        ^(pad_r & 32'hDC5B4294),
        ^(pad_r & 32'h6E2DA14A),
        ^(pad_r & 32'h3716D0A5),
        ^(pad_r & 32'h9B8B6852),
        ^(pad_r & 32'hCDC5B429),
        ^(pad_r & 32'h99869899),
        ^(pad_r & 32'h33A70EC1),
        ^(pad_r & 32'h99D38760),
        ^(pad_r & 32'h4CE9C3B0),
        ^(pad_r & 32'hD910A355),
        ^(pad_r & 32'hEC8851AA),
        ^(pad_r & 32'hF64428D5),
        ^(pad_r & 32'hFB22146A),
        ^(pad_r & 32'hFD910A35),
        ^(pad_r & 32'hFEC8851A)
    };
    wire [31:0] nv6 = {
        ^(pad_r & 32'h50FF6442),
        ^(pad_r & 32'h7880D663),
        ^(pad_r & 32'hECBF0F73),
        ^(pad_r & 32'h765F87B9),
        ^(pad_r & 32'hEBD0A79E),
        ^(pad_r & 32'hA517378D),
        ^(pad_r & 32'hD28B9BC6),
        ^(pad_r & 32'hB9BAA9A1),
        ^(pad_r & 32'h8C223092),
        ^(pad_r & 32'hC6111849),
        ^(pad_r & 32'hB3F7E866),
        ^(pad_r & 32'h89049071),
        ^(pad_r & 32'h947D2C7A),
        ^(pad_r & 32'h4A3E963D),
        ^(pad_r & 32'h251F4B1E),
        ^(pad_r & 32'h128FA58F),
        ^(pad_r & 32'hD9B8B685),
        ^(pad_r & 32'h6CDC5B42),
        ^(pad_r & 32'h366E2DA1),
        ^(pad_r & 32'h1B3716D0),
        ^(pad_r & 32'h0D9B8B68),
        ^(pad_r & 32'h06CDC5B4),
        ^(pad_r & 32'h53998698),
        ^(pad_r & 32'h7933A70E),
        ^(pad_r & 32'hBC99D387),
        ^(pad_r & 32'hDE4CE9C3),
        ^(pad_r & 32'h3FD910A3),
        ^(pad_r & 32'h1FEC8851),
        ^(pad_r & 32'h0FF64428),
        ^(pad_r & 32'h87FB2214),
        ^(pad_r & 32'h43FD910A),
        ^(pad_r & 32'hA1FEC885)
    };
    wire [31:0] nv7 = {
        ^(pad_r & 32'h9E50FF64),
        ^(pad_r & 32'h517880D6),
        ^(pad_r & 32'h36ECBF0F),
        ^(pad_r & 32'h9B765F87),
        ^(pad_r & 32'h53EBD0A7),
        ^(pad_r & 32'hB7A51737),
        ^(pad_r & 32'hDBD28B9B),
        ^(pad_r & 32'hF3B9BAA9),
        ^(pad_r & 32'hE78C2230),
        ^(pad_r & 32'hF3C61118),
        ^(pad_r & 32'hE7B3F7E8),
        ^(pad_r & 32'hED890490),
        ^(pad_r & 32'hE8947D2C),
        ^(pad_r & 32'hF44A3E96),
        ^(pad_r & 32'h7A251F4B),
        ^(pad_r & 32'h3D128FA5),
        ^(pad_r & 32'h00D9B8B6),
        ^(pad_r & 32'h806CDC5B),
        ^(pad_r & 32'h40366E2D),
        ^(pad_r & 32'h201B3716),
        ^(pad_r & 32'h100D9B8B),
        ^(pad_r & 32'h0806CDC5),
        ^(pad_r & 32'h9A539986),
        ^(pad_r & 32'h537933A7),
        ^(pad_r & 32'h29BC99D3),
        ^(pad_r & 32'h14DE4CE9),
        ^(pad_r & 32'h943FD910),
        ^(pad_r & 32'hCA1FEC88),
        ^(pad_r & 32'hE50FF644),
        ^(pad_r & 32'hF287FB22),
        ^(pad_r & 32'h7943FD91),
        ^(pad_r & 32'h3CA1FEC8)
    };
    wire [31:0] nv8 = {
        ^(pad_r & 32'h699E50FF),
        ^(pad_r & 32'h5D517880),
        ^(pad_r & 32'hC736ECBF),
        ^(pad_r & 32'h639B765F),
        ^(pad_r & 32'hD853EBD0),
        ^(pad_r & 32'h85B7A517),
        ^(pad_r & 32'hC2DBD28B),
        ^(pad_r & 32'h08F3B9BA),
        ^(pad_r & 32'hEDE78C22),
        ^(pad_r & 32'h76F3C611),
        ^(pad_r & 32'h52E7B3F7),
        ^(pad_r & 32'hC0ED8904),
        ^(pad_r & 32'h89E8947D),
        ^(pad_r & 32'h44F44A3E),
        ^(pad_r & 32'hA27A251F),
        ^(pad_r & 32'hD13D128F),
        ^(pad_r & 32'h8100D9B8),
        ^(pad_r & 32'h40806CDC),
        ^(pad_r & 32'hA040366E),
        ^(pad_r & 32'hD0201B37),
        ^(pad_r & 32'h68100D9B),
        ^(pad_r & 32'hB40806CD),
        ^(pad_r & 32'h339A5399),
        ^(pad_r & 32'h70537933),
        ^(pad_r & 32'h3829BC99),
        ^(pad_r & 32'h1C14DE4C),
        ^(pad_r & 32'h67943FD9),
        ^(pad_r & 32'h33CA1FEC),
        ^(pad_r & 32'h99E50FF6),
        ^(pad_r & 32'h4CF287FB),
        ^(pad_r & 32'hA67943FD),
        ^(pad_r & 32'hD33CA1FE)
    };

    // 9 选 1: m = 8 - k
    reg [31:0] corr;
    always @* begin
        case (m_cnt)
            4'd0: corr = nv0;
            4'd1: corr = nv1;
            4'd2: corr = nv2;
            4'd3: corr = nv3;
            4'd4: corr = nv4;
            4'd5: corr = nv5;
            4'd6: corr = nv6;
            4'd7: corr = nv7;
            default: corr = nv8;
        endcase
    end

    assign crc_nxt = init ? 32'hFFFFFFFF : (en ? corr : crc_r);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) crc <= 32'hFFFFFFFF;
        else        crc <= crc_nxt;
    end
endmodule
