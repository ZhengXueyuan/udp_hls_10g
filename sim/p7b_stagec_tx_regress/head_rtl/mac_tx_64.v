`timescale 1ns/1ps
// 64bit 左对齐 AXI-Stream 字流 -> 1G GMII TX 字节流 (10G-ready MAC 边界, TX 侧)。
//
// 输出帧 = 前导 55x7+D5 | dst..payload (含 pad) | FCS 4B。FCS = (crc^0xFFFFFFFF) 小端
// (线上 LSB-first 铁律); 内容 (dst_mac 起) < 60 字节时补 0 到 60 (帧 >= 64B 含 FCS);
// IFG >= 12 字节; 帧内源流断供 (FIFO 空) -> 立即中止 (runt 由接收方丢弃, stat_abort++)。
// 源约定: 每词 tkeep != 0 (tkeep 高位有效, 与 mac_rx_64 输出一致)。
// gmii_txd/tx_en 为组合输出 (状态 mux), 保证 CRC 输入与本拍发送字节严格同拍。
//
// ---------------------------------------------------------------------------
// P6b F-2 修复 (2026-09-29): 帧内中止后**必须冲刷到本帧 TLAST 才能重开新帧**
// ---------------------------------------------------------------------------
// 缺陷 (修复前): 帧内中止只做 `state <= S_IDLE`。上游在"我们中止"之后才把本帧**余下
//   的字**送来 (它并不知道我们中止了) —— 这些残字压在本模块的 16 深 FIFO 里, 于是被
//   下一个 `S_IDLE -> S_PRE` 当作**新帧的首字**取走, 一路按正常帧发送: 补 pad、算 CRC、
//   发一个 **FCS 完全正确的"幽灵帧"**, 载荷 = 被中止帧的中段残字。对端 (以及本板 RX 侧)
//   无法分辨 ⇒ **坏帧被当好帧收下**。实测: FCS 残留 == 0xDEBB20E3, 载荷 = 被中止帧的
//   字节[320..960) (见 P6B_CDC_AUDIT.md F-2 / audit_scratch/t3_txcdc)。
// 修复: 中止后进 `S_FLUSH` —— **一个字都不发**, 把输入 FIFO 的头字逐个弹掉并计数,
//   直到吞掉**本帧自己的 TLAST 字**(= 唯一可用的帧边界; TX 字流不带 tuser/SOP),
//   再等够 IFG (12 字节) 才回 S_IDLE。此后 FIFO 头字必然是下一帧的首字。
// 覆盖性论证 (为什么所有路径都收口):
//   ① 本模块**只在一处**中止 (S_DATA 的 `!fempty` 分支), 该处是进 S_FLUSH 的唯一入口;
//      其余 S_PRE/S_PAD/S_FCS/S_IFG 都是"帧已完整"或"帧未开始"的路径, 不产生残字。
//   ② 上游帧契约 (tx_arb: `busy` 锁到 tlast 被消费为止; DP 各源都是帧器) ⇒ 每个被中止的
//      帧**必然**还有它的 TLAST 字在路上 ⇒ 冲刷一定终止 (不会永久卡死)。
//   ③ 唯一"没有 TLAST 会到来"的情形 = DP 被复位/放弃该帧: 此时冲刷会把**下一帧整帧**
//      也吃掉, 代价 = 丢 1 帧 (有界、自愈、**有计数** stat_flush_done/stat_flush_words),
//      仍然绝不发坏帧 —— 安全的那个方向。
//   ④ 不触发中止的流量: S_FLUSH 不可达 ⇒ 数据通路/时序/字节流**逐位不变** (实证见
//      audit_scratch/run_t3.bat 的 nostall A/B 指纹)。
//   ⑤ 中止帧本身仍然线上留 runt (接收方按 FCS/长度丢弃) —— 那是既有语义, 未改。
// ---------------------------------------------------------------------------
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
    output reg  [31:0] stat_abort,
    // ---- P6b F-2: 冲刷 (残字丢弃) 的可观测计数 ----
    output reg  [31:0] stat_flush_words,  // 冲刷期被丢弃的输入字数 (任何丢弃都计数)
    output reg  [31:0] stat_flush_done    // 冲刷完成次数 (= 重新对齐到帧边界的次数)
);

    localparam [2:0] S_IDLE = 3'd0, S_PRE = 3'd1, S_DATA = 3'd2,
                     S_PAD = 3'd3, S_FCS = 3'd4, S_IFG = 3'd5,
                     S_FLUSH = 3'd6;   // F-2: 帧内中止后冲刷到本帧 TLAST
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
    // F-2: 冲刷态 (只在中止后使用)
    reg [3:0]  flush_cnt;    // 线空闲计时 (保证 runt 与新帧之间的 IFG >= 12 字节)
    reg        flush_tl;     // 本帧的 TLAST 字已被吞掉 (帧边界已到)

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
            flush_cnt <= 0; flush_tl <= 0;
            frd <= 0;
            stat_frames <= 0; stat_abort <= 0;
            stat_flush_words <= 0; stat_flush_done <= 0;
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
                            // 断供: 中止 (runt) —— 立刻进 S_FLUSH (F-2): 本帧的**残字**
                            // 还在路上, 绝不能让它们成为下一帧的内容。
                            state <= S_FLUSH;
                            flush_cnt <= 4'd0; flush_tl <= 1'b0;
                            cw_v <= 1'b0;
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
                // ---- P6b F-2: 中止后的冲刷 (一个字都不发) ----
                // 弹掉输入字直到吞掉本帧的 TLAST (帧边界), 并保证线空闲 >= IFG 后回 S_IDLE。
                // 期间 gmii_tx_en = 0 (组合 mux 的 default 分支) ⇒ 线上只剩 runt 后的空闲。
                // ⚠️ 时序要点 (第一版就是在这里差了一拍): `frd` 是**寄存的弹出请求** ——
                //   本拍 frd=1 弹出的是**本拍的头字** fdout。所以"本拍弹的正好是 TLAST"时,
                //   必须**同拍停止再请求** (否则下一拍会把 TLAST 之后的第一个字也弹掉 =
                //   吃掉下一帧的首字, 实测: 幽灵帧 = 帧C 的 [1..24] 字)。判据用
                //   `frd && !fempty && fdout[0]` (= 本拍真有弹出, 且弹的就是 TLAST 字)。
                S_FLUSH: begin
                    if (flush_cnt != 4'd12) flush_cnt <= flush_cnt + 4'd1;
                    if (frd && !fempty)                        // 本拍确实弹出了一个字
                        stat_flush_words <= stat_flush_words + 32'd1;
                    if ((frd && !fempty && fdout[0]) || flush_tl)
                        flush_tl <= 1'b1;                      // 帧边界已到
                    // 下一拍是否继续请求弹出: 只在"边界未到且本拍弹的不是边界字"时继续
                    frd <= (!flush_tl) && !(frd && !fempty && fdout[0]) && !fempty;
                    if (flush_tl && (flush_cnt == 4'd12)) begin
                        state <= S_IDLE;
                        stat_flush_done <= stat_flush_done + 32'd1;
                    end
                end
            endcase
        end
    end
endmodule
