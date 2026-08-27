`timescale 1ns/1ps
// 64bit 左对齐 AXI-Stream 字流 -> 1G GMII TX 字节流 (10G-ready MAC 边界, TX 侧)。
//
// 输出帧 = 前导 55x7+D5 | dst..payload (含 pad) | FCS 4B。FCS = (crc^0xFFFFFFFF) 小端
// (线上 LSB-first 铁律); 内容 (dst_mac 起) < 60 字节时补 0 到 60 (帧 >= 64B 含 FCS);
// IFG >= 12 字节; 帧内源流断供 (FIFO 空) -> 立即中止 (runt 由接收方丢弃, stat_abort++)。
// 源约定: 每词 tkeep != 0 (tkeep 高位有效, 与 mac_rx_64 输出一致)。
// gmii_txd/tx_en 为组合输出 (状态 mux), 保证 CRC 输入与本拍发送字节严格同拍。
module mac_tx_64 (
    input  wire        clk,          // 125 MHz
    input  wire        rst_n,
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    output wire [7:0]  gmii_txd,
    output wire        gmii_tx_en,
    output wire        gmii_tx_er,   // 预留, 恒 0
    output reg  [31:0] stat_frames,
    output reg  [31:0] stat_abort
);

    localparam [2:0] S_IDLE = 3'd0, S_PRE = 3'd1, S_DATA = 3'd2,
                     S_PAD = 3'd3, S_FCS = 3'd4, S_IFG = 3'd5;
    // plen 计全部内容字节 (含 14B 以太头); 802.3 最小帧 60B 内容 (64B 含 FCS)
    // — 曾用 46 (payload 基准) 判 pad, content∈[46,60) 的帧 (如 TCP 纯 ACK 54B)
    // 不补 pad 上线成 runt (#48 全链实测抓到)
    localparam [15:0] MIN_CLEN = 16'd60;

    reg [2:0] state;

    // ---- 字 FIFO (73b = tdata+tkeep+tlast) ----
    localparam FW = 73;
    wire [FW-1:0] fdin = {s_axis_tdata, s_axis_tkeep, s_axis_tlast};
    wire [FW-1:0] fdout;
    wire          fempty, ffull;
    wire          fwr = s_axis_tvalid && s_axis_tready;
    reg           frd;
    assign s_axis_tready = !ffull;
    fifo_sync #(.W(FW), .D(16), .AW(4)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr(fwr), .din(fdin),
        .rd(frd), .dout(fdout),
        .empty(fempty), .full(ffull)
    );

    // ---- 当前字 cw ----
    reg [63:0] cw_data;
    reg [7:0]  cw_keep;
    reg        cw_last, cw_v;
    reg [2:0]  cw_idx;
    reg [3:0]  cw_len;
    wire [5:0] cw_off = 6'd63 - {cw_idx, 3'b000};

    reg [5:0]  pre_cnt;
    reg [15:0] plen;
    reg [5:0]  pad_cnt;
    reg [31:0] fcs_shr;
    reg [1:0]  fcs_cnt;
    reg [3:0]  ifg_cnt;

    // ---- 组合 TX 输出 ----
    reg [7:0] txd_c;
    always @* begin
        case (state)
            S_PRE:  txd_c = (pre_cnt == 6'd7) ? 8'hD5 : 8'h55;
            S_DATA: txd_c = cw_data[cw_off -: 8];
            S_PAD:  txd_c = 8'h00;
            S_FCS:  txd_c = fcs_shr[7:0];
            default: txd_c = 8'h07;      // IDLE / IFG
        endcase
    end
    assign gmii_txd  = txd_c;
    assign gmii_tx_en = (state == S_PRE) || (state == S_DATA) ||
                        (state == S_PAD) || (state == S_FCS);
    assign gmii_tx_er = 1'b0;

    wire        crc_init = (state == S_PRE) && (pre_cnt == 6'd7);
    wire        crc_en   = (state == S_DATA) || (state == S_PAD);
    wire [31:0] crc, crc_nxt;
    crc32_8b u_crc (.clk(clk), .init(crc_init), .en(crc_en), .d(txd_c),
                    .crc(crc), .crc_nxt(crc_nxt));

    function [3:0] popc8;
        input [7:0] x;
        reg [3:0] c;
        integer i;
        begin
            c = 0;
            for (i = 0; i < 8; i = i + 1) c = c + x[i];
            popc8 = c;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            cw_data <= 0; cw_keep <= 0; cw_last <= 0; cw_v <= 0; cw_idx <= 0; cw_len <= 0;
            pre_cnt <= 0; plen <= 0; pad_cnt <= 0; fcs_shr <= 0; fcs_cnt <= 0; ifg_cnt <= 0;
            frd <= 0;
            stat_frames <= 0; stat_abort <= 0;
        end else begin
            frd <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (!fempty) begin state <= S_PRE; pre_cnt <= 0; end
                end
                S_PRE: begin
                    if (pre_cnt == 6'd7) begin
                        if (!fempty) begin
                            frd <= 1'b1;
                            cw_data <= fdout[72:9];
                            cw_keep <= fdout[8:1];
                            cw_last <= fdout[0];
                            cw_idx <= 0;
                            cw_len <= popc8(fdout[8:1]);
                            cw_v <= 1'b1;
                            plen <= 0;
                            state <= S_DATA;
                        end else begin
                            // 保险 (IDLE 已查非空, 正常到不了): 空帧直接收尾
                            state <= S_IFG; ifg_cnt <= 0; cw_v <= 1'b0;
                        end
                    end else begin
                        pre_cnt <= pre_cnt + 1;
                    end
                end
                S_DATA: begin
                    plen <= plen + 1;
                    if (cw_idx == {1'b0, cw_len} - 3'd1) begin     // 本字末字节
                        if (cw_last) begin
                            // 本拍 crc_nxt 已含末字节
                            if (plen + 1 >= MIN_CLEN) begin
                                state <= S_FCS; fcs_cnt <= 0;
                                fcs_shr <= crc_nxt ^ 32'hFFFFFFFF;
                            end else begin
                                state <= S_PAD;
                                pad_cnt <= MIN_CLEN - plen - 1;
                            end
                        end else if (!fempty) begin
                            frd <= 1'b1;
                            cw_data <= fdout[72:9];
                            cw_keep <= fdout[8:1];
                            cw_last <= fdout[0];
                            cw_idx <= 0;
                            cw_len <= popc8(fdout[8:1]);
                        end else begin
                            // 断供: 中止 (runt)
                            state <= S_IDLE; cw_v <= 1'b0;
                            stat_abort <= stat_abort + 1;
                        end
                    end else begin
                        cw_idx <= cw_idx + 1;
                    end
                end
                S_PAD: begin
                    if (pad_cnt == 6'd0) begin
                        // 不再送 pad: 本拍转 FCS (crc 已含全部 pad 字节)
                        state <= S_FCS; fcs_cnt <= 0;
                        fcs_shr <= crc_nxt ^ 32'hFFFFFFFF;
                    end else begin
                        pad_cnt <= pad_cnt - 1;
                        if (pad_cnt == 6'd1) begin
                            // 本拍是最后一个 pad; crc_nxt 已含本拍 0x00
                            state <= S_FCS; fcs_cnt <= 0;
                            fcs_shr <= crc_nxt ^ 32'hFFFFFFFF;
                        end
                    end
                end
                S_FCS: begin
                    if (fcs_cnt == 2'd3) begin
                        state <= S_IFG; ifg_cnt <= 0;
                    end else begin
                        fcs_cnt <= fcs_cnt + 1;
                        fcs_shr <= fcs_shr >> 8;
                    end
                end
                S_IFG: begin
                    if (ifg_cnt == 4'd11) begin
                        state <= S_IDLE;
                        stat_frames <= stat_frames + 1;
                    end else begin
                        ifg_cnt <= ifg_cnt + 1;
                    end
                end
            endcase
        end
    end
endmodule
