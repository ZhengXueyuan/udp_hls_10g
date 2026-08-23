`timescale 1ns/1ps
// 1G GMII 字节流 -> 64bit 左对齐 AXI-Stream 字流 (10G-ready MAC 边界)。
//
// 字流约定 (10G 升级时 PG157 的 AXIS 输出加一层 shim 对齐到同一约定):
//  - tdata[63:56] = 帧首字节 (dst_mac[0]), 字内字节从高到低连续
//  - SOP 字总是满对齐 (tkeep[7]=1); TLAST 字 tkeep 高位有效
//  - FCS 在本层校验并剥离: crc 残留 == 32'hC704DD7B 为正确 (tcrs, TLAST 有效)
//  - 剥离实现: 4 字节前瞻延迟线, 打包落后 CRC 输入 4 字节, 帧尾 4 字节 FCS 自然不打包
//  - 背压: 内部 8 深 FIFO, 满则整帧丢弃 (消费者按 TLAST 完整性丢弃半帧)
module mac_rx_64 (
    input  wire        clk,          // 125 MHz (GMII 域)
    input  wire        rst_n,
    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rx_dv,
    input  wire        gmii_rx_er,
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_tuser,  // SOP
    output wire        m_axis_terr,   // TLAST 有效: 帧内 rx_er
    output wire        m_axis_tcrs,   // TLAST 有效: FCS 正确
    output reg  [31:0] stat_frames,
    output reg  [31:0] stat_crc_err,
    output reg  [31:0] stat_drop,
    output reg  [31:0] stat_bytes
);

    localparam [2:0] S_IDLE = 3'd0, S_PRE = 3'd1, S_DATA = 3'd2,
                     S_DROP = 3'd3, S_FLUSH = 3'd4;
    // 线上 FCS = zlib.crc32(payload) 值小端 (LSB-first, 铁律) -> 反射 CRC (无终值取反)
    // 全帧流过后的残留 == raw(0xFFFFFFFF) == 32'hDEBB20E3 (帧长无关, Python 实测)。
    // 0xC704DD7B 是 FCS 大端/非反射实现的魔数, 勿用。
    localparam [31:0] CRC_RESIDUE = 32'hDEBB20E3;

    reg  [2:0]  state;
    reg  [5:0]  pre_cnt;
    reg  [2:0]  bcnt;          // 当前累积字内字节数
    reg  [63:0] wreg;
    reg  [7:0]  wkeep;
    reg  [31:0] dline;         // FCS 前瞻: 打包消费旧 dline[31:24]
    reg  [15:0] fbytes;        // 帧字节总数 (含 FCS)
    reg         ferr;
    reg         first_done;    // 本帧 SOP 已发出
    reg  [63:0] hwreg;         // 已完成整字保持 (延迟一拍以标记 TLAST)
    reg  [7:0]  hwkeep;
    reg         hwv;
    // CRC 使能/初值必须与 gmii_rxd 同拍 (组合), 否则漏首字节/多算尾字节
    wire        crc_en   = (state == S_DATA) && gmii_rx_dv;
    wire        crc_init = (state == S_PRE) && gmii_rx_dv &&
                           (gmii_rxd == 8'hD5) && (pre_cnt >= 6'd6);
    wire [31:0] crc;

    reg         push, push_last, push_sop, push_crs, push_err;
    reg  [63:0] push_data;
    reg  [7:0]  push_keep;
    wire        fifo_full;

    crc32_8b u_crc (.clk(clk), .init(crc_init), .en(crc_en), .d(gmii_rxd), .crc(crc));

    // 右累积字 (首字节在 [8*n-1:8*n-8]) -> 左对齐 (首字节在 [63:56]); 用拼接免移位歧义
    function [63:0] ljust64;
        input [63:0] w;
        input [2:0]  n;
        begin
            case (n)
                3'd1: ljust64 = {w[7:0],   56'b0};
                3'd2: ljust64 = {w[15:0],  48'b0};
                3'd3: ljust64 = {w[23:0],  40'b0};
                3'd4: ljust64 = {w[31:0],  32'b0};
                3'd5: ljust64 = {w[39:0],  24'b0};
                3'd6: ljust64 = {w[47:0],  16'b0};
                3'd7: ljust64 = {w[55:0],   8'b0};
                default: ljust64 = w;
            endcase
        end
    endfunction

    function [7:0] ljust8;
        input [7:0] k;
        input [2:0] n;
        begin
            case (n)
                3'd1: ljust8 = {k[0],   7'b0};
                3'd2: ljust8 = {k[1:0], 6'b0};
                3'd3: ljust8 = {k[2:0], 5'b0};
                3'd4: ljust8 = {k[3:0], 4'b0};
                3'd5: ljust8 = {k[4:0], 3'b0};
                3'd6: ljust8 = {k[5:0], 2'b0};
                3'd7: ljust8 = {k[6:0], 1'b0};
                default: ljust8 = k;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; pre_cnt <= 0; bcnt <= 0; wreg <= 0; wkeep <= 0;
            dline <= 0; fbytes <= 0; ferr <= 0; first_done <= 0;
            hwreg <= 0; hwkeep <= 0; hwv <= 0;
            push <= 0; push_last <= 0; push_sop <= 0; push_crs <= 0; push_err <= 0;
            push_data <= 0; push_keep <= 0;
            stat_frames <= 0; stat_crc_err <= 0; stat_drop <= 0; stat_bytes <= 0;
        end else begin
            push      <= 1'b0;
            push_last <= 1'b0;
            push_sop  <= 1'b0;
            push_crs  <= 1'b0;
            push_err  <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (gmii_rx_dv && gmii_rxd == 8'h55) begin
                        state <= S_PRE; pre_cnt <= 1;
                    end
                end
                S_PRE: begin
                    if (!gmii_rx_dv) begin
                        state <= S_IDLE;
                    end else if (gmii_rxd == 8'h55) begin
                        pre_cnt <= (pre_cnt == 6'd63) ? pre_cnt : pre_cnt + 1;
                    end else if (gmii_rxd == 8'hD5 && pre_cnt >= 6'd6) begin
                        state <= S_DATA; bcnt <= 0; wreg <= 0; wkeep <= 0;
                        dline <= 0; fbytes <= 0; ferr <= 0; first_done <= 0;
                        hwreg <= 0; hwkeep <= 0; hwv <= 0;
                    end else begin
                        state <= S_IDLE;      // 前导内垃圾 -> 重新找前导
                    end
                end
                S_DATA: begin
                    if (!gmii_rx_dv) begin
                        // ---- 帧尾 ----
                        if (hwv && !fifo_full) begin
                            push <= 1'b1; push_data <= hwreg; push_keep <= hwkeep;
                            push_last <= (bcnt == 3'd0); push_sop <= !first_done;
                            first_done <= 1'b1;
                            push_crs <= (bcnt == 3'd0) && (crc == CRC_RESIDUE);
                            push_err <= (bcnt == 3'd0) && ferr;
                            if (bcnt == 3'd0) begin
                                state <= S_IDLE; hwv <= 0;
                                stat_frames <= stat_frames + 1;
                                if (crc != CRC_RESIDUE) stat_crc_err <= stat_crc_err + 1;
                                stat_bytes <= stat_bytes + fbytes;
                            end else begin
                                state <= S_FLUSH; hwv <= 0;
                            end
                        end else if (hwv && fifo_full) begin
                            state <= S_DROP; hwv <= 0;
                            stat_drop <= stat_drop + 1;
                        end else if (bcnt == 3'd0) begin
                            state <= S_IDLE;      // 零字节净荷帧: 丢弃
                            stat_drop <= stat_drop + 1;
                        end else begin
                            // 短帧 (<8 字节净荷, 无保持字): 单字 TLAST 交付
                            push <= 1'b1;
                            push_data <= ljust64(wreg, bcnt);
                            push_keep <= ljust8(wkeep, bcnt);
                            push_last <= 1'b1; push_sop <= 1'b1;
                            push_crs <= (crc == CRC_RESIDUE); push_err <= ferr;
                            state <= S_IDLE;
                            stat_frames <= stat_frames + 1;
                            if (crc != CRC_RESIDUE) stat_crc_err <= stat_crc_err + 1;
                            stat_bytes <= stat_bytes + fbytes;
                        end
                    end else begin
                        // ---- 帧内字节 ----
                        ferr   <= ferr | gmii_rx_er;
                        fbytes <= fbytes + 1;
                        dline  <= {dline[23:0], gmii_rxd};
                        if (fbytes >= 16'd4) begin
                            if (bcnt == 3'd7) begin
                                // 整字完成 -> 进保持字; 旧保持字先推
                                if (hwv && fifo_full) begin
                                    state <= S_DROP; hwv <= 0;
                                    stat_drop <= stat_drop + 1;
                                end else begin
                                    if (hwv) begin
                                        push <= 1'b1; push_data <= hwreg; push_keep <= hwkeep;
                                        push_last <= 1'b0; push_sop <= !first_done;
                                        first_done <= 1'b1;
                                    end
                                    hwreg  <= {wreg[55:0], dline[31:24]};
                                    hwkeep <= 8'hFF; hwv <= 1'b1;
                                    wreg <= 0; wkeep <= 0; bcnt <= 0;
                                end
                            end else begin
                                wreg  <= {wreg[55:0], dline[31:24]};
                                wkeep <= {wkeep[6:0], 1'b1};
                                bcnt  <= bcnt + 1;
                            end
                        end
                    end
                end
                S_FLUSH: begin
                    if (fifo_full) begin
                        state <= S_IDLE;
                        stat_drop <= stat_drop + 1;
                    end else begin
                        push <= 1'b1;
                        push_data <= ljust64(wreg, bcnt);
                        push_keep <= ljust8(wkeep, bcnt);
                        push_last <= 1'b1; push_sop <= !first_done;
                        push_crs <= (crc == CRC_RESIDUE); push_err <= ferr;
                        state <= S_IDLE;
                        stat_frames <= stat_frames + 1;
                        if (crc != CRC_RESIDUE) stat_crc_err <= stat_crc_err + 1;
                        stat_bytes <= stat_bytes + fbytes;
                    end
                end
                S_DROP: begin
                    if (!gmii_rx_dv) state <= S_IDLE;
                end
            endcase
        end
    end

    // ---- 输出 FIFO + AXIS ----
    localparam FW = 76;   // tdata[75:12] tkeep[11:4] sop[3] last[2] crs[1] err[0]
    wire [FW-1:0] fdin  = {push_data, push_keep, push_sop, push_last, push_crs, push_err};
    wire [FW-1:0] fdout;
    wire          fempty;
    wire          rd = m_axis_tvalid && m_axis_tready;   // 组合: 与 valid 同拍消费

    fifo_sync #(.W(FW), .D(8), .AW(3)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr(push), .din(fdin),
        .rd(rd), .dout(fdout),
        .empty(fempty), .full(fifo_full)
    );

    assign m_axis_tdata  = fdout[75:12];
    assign m_axis_tkeep  = fdout[11:4];
    assign m_axis_tuser  = fdout[3];
    assign m_axis_tlast  = fdout[2];
    assign m_axis_tcrs   = fdout[1];
    assign m_axis_terr   = fdout[0];
    assign m_axis_tvalid = !fempty;
endmodule
