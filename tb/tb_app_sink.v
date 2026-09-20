`timescale 1ns/1ps
//=============================================================================
// tb_app_sink: 可编程 AXIS 消费者 (P5b flow 门用, 纯 TB — 不参与综合)
//
// 用途: 在 tb_p5_app 的 flow 模式里替换 app_pattern 当 app RX 消费者 —
// 用"慢消费 + 中途长暂停"把 零拷贝 frame_fifo 填满, 逼出 P5b 的窗口收缩
// (fc 写) 与窗口重开 (wu ACK) 闭环。
//
// 消费模型: 每 RATE 拍消费 1 个 64 位字 (= 8 字节; RATE=8 ⇒ 1 字节/拍 = 1G
// 线速)。暂停 1: 消费到 PAUSE_AT 字节后 tready=0 保持 PAUSE_LEN 拍;
// 暂停 1 之后改用 RATE2。暂停 2 同理 (PAUSE2_AT/PAUSE2_LEN, 0 = 关)。
//
// 逐拍检查 (AXIS 合同 + 数据完整性, 任一超标即计数, 由 TB 落盘给 checker):
//   ① tkeep 必须是高连续掩码 (0x00 非法; 0x80/FE/FC/F8/F0/E0/C0/FF 合法)
//   ② 图案: 字节流必须逐字节 == xorshift64 流 (与 rtl/app_pattern.v /
//      tools/cpp_peer 同式: 先取 s[31:24] 再推进), 从 SEED 起算。flow 用例里
//      对端从 ISN+1 起按序灌数据且零重传 ⇒ 字节流与图案 1:1 对齐; 失配即
//      "静默损坏/丢字/串帧" —— 这是 flow 门最硬的一条 (字节数对但内容错也抓)。
//   ③ 空字 (tvalid && tkeep==0) 计数 (RX 通路不该出现)
//
// 位序: tdata[63:56] = 该 beat 首字节 (本工程 MAC 字流约定, 与 app_pattern 同)
//=============================================================================
module tb_app_sink #(
    parameter integer RATE       = 8,          // N 拍消费 1 字
    parameter integer RATE2      = 8,          // 暂停 1 之后的消费率
    parameter integer PAUSE_AT   = 65536,      // 消费到该字节数后暂停 (0 = 关)
    parameter integer PAUSE_LEN  = 150000,     // 暂停拍数
    parameter integer PAUSE2_AT  = 0,
    parameter integer PAUSE2_LEN = 0,
    parameter [63:0]  SEED       = 64'h9E3779B97F4A7C15,
    parameter         CHECK_PAT  = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    // app RX 口 (= tcp_echo/axis_pipe 输出, 与 wrapper APP_MODE 同源)
    input  wire [63:0] tdata,
    input  wire [7:0]  tkeep,
    input  wire        tvalid,
    output wire        tready,
    input  wire        tlast,
    input  wire [3:0]  tid,
    // 统计/观测
    output reg  [31:0] stat_bytes,      // 已消费字节数
    output reg  [31:0] stat_words,      // 已消费字数
    output reg  [31:0] stat_frames,     // 已消费帧数 (tlast 计数)
    output reg  [31:0] stat_mismatch,   // 图案失配字节数
    output reg  [31:0] stat_kaerr,      // tkeep 非法 (空洞/零) 次数
    output reg  [31:0] stat_evfrm,      // 空字 (tvalid && tkeep==0)
    // 状态
    output reg  [31:0] dbg_pause_cnt,   // 已进入的暂停次数
    output reg  [31:0] dbg_gap_max,     // 最长连续无消费拍数 (窥探活性)
    output reg         paused           // 当前处于暂停期
);

    // ---------------- xorshift64 图案 (与 app_pattern 同式) ----------------
    function [63:0] xs_next;
        input [63:0] s;
        reg   [63:0] t;
        begin
            t = s ^ (s << 13);
            t = t ^ (t >> 7);
            t = t ^ (t << 17);
            xs_next = t;
        end
    endfunction

    // n 步推进 (n <= 8)
    function [63:0] xs_adv;
        input [63:0] s;
        input [3:0]  n;
        integer i;
        reg [63:0] t;
        begin
            t = s;
            for (i = 0; i < 8; i = i + 1)
                if (i < n) t = xs_next(t);
            xs_adv = t;
        end
    endfunction

    // 字内第 i 字节 (i = 0 为 tdata[63:56])
    function [7:0] byte_at;
        input [63:0] d;
        input [3:0]  i;
        begin
            case (i)
                4'd0: byte_at = d[63:56];
                4'd1: byte_at = d[55:48];
                4'd2: byte_at = d[47:40];
                4'd3: byte_at = d[39:32];
                4'd4: byte_at = d[31:24];
                4'd5: byte_at = d[23:16];
                4'd6: byte_at = d[15:8];
                default: byte_at = d[7:0];
            endcase
        end
    endfunction

    function [3:0] pop8;
        input [7:0] v;
        integer i;
        reg [3:0] c;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]};
            pop8 = c;
        end
    endfunction

    // tkeep 合法性: 高连续掩码 (0x80 起逐位补 1 到 0xFF)
    function ka_ok;
        input [7:0] k;
        begin
            ka_ok = (k == 8'hFF) || (k == 8'hFE) || (k == 8'hFC) || (k == 8'hF8) ||
                    (k == 8'hF0) || (k == 8'hE0) || (k == 8'hC0) || (k == 8'h80);
        end
    endfunction

    reg  [31:0] cyc;             // 消费节拍倒计数
    reg  [15:0] pause_cnt;       // 暂停期剩余拍数
    reg         p1_done, p2_done;
    reg  [63:0] lfsr;
    reg  [31:0] gap;             // 当前连续无消费拍数
    reg  [31:0] dbg_mm_ev;       // 失配事件计数 (只印前 8 点)
    integer     rate_cur;
    integer     bi;
    integer     mm;
    reg  [63:0] ew;

    assign      tready = (cyc == 32'd0) && (pause_cnt == 16'd0);

    wire        cons = tvalid && tready;
    wire [3:0]  nk   = pop8(tkeep);

    always @(*) begin
        // 暂停 1 生效后改用 RATE2
        rate_cur = p1_done ? RATE2 : RATE;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cyc <= 32'd0; pause_cnt <= 16'd0; p1_done <= 1'b0; p2_done <= 1'b0;
            lfsr <= SEED; gap <= 32'd0;
            stat_bytes <= 32'd0; stat_words <= 32'd0; stat_frames <= 32'd0;
            stat_mismatch <= 32'd0; stat_kaerr <= 32'd0; stat_evfrm <= 32'd0;
            dbg_pause_cnt <= 32'd0; dbg_gap_max <= 32'd0; paused <= 1'b0;
            dbg_mm_ev <= 32'd0;
        end else begin
            paused <= (pause_cnt != 16'd0);
            // ---- 消费节拍 ----
            if (cyc != 32'd0) cyc <= cyc - 32'd1;
            // ---- 暂停管理 (优先级高于消费) ----
            if (pause_cnt != 16'd0) begin
                pause_cnt <= pause_cnt - 16'd1;
            end else begin
                if (!p1_done && (PAUSE_AT != 0) &&
                    (stat_bytes >= PAUSE_AT)) begin
                    p1_done   <= 1'b1;
                    pause_cnt <= PAUSE_LEN[15:0];
                    dbg_pause_cnt <= dbg_pause_cnt + 32'd1;
                end else if (!p2_done && (PAUSE2_AT != 0) &&
                             (stat_bytes >= PAUSE2_AT)) begin
                    p2_done   <= 1'b1;
                    pause_cnt <= PAUSE2_LEN[15:0];
                    dbg_pause_cnt <= dbg_pause_cnt + 32'd1;
                end
            end
            // ---- 消费 ----
            if (cons) begin
                cyc <= rate_cur[31:0] - 32'd1;
                stat_words <= stat_words + 32'd1;
                stat_bytes <= stat_bytes + {28'b0, nk};
                if (tlast) stat_frames <= stat_frames + 32'd1;
                if (!ka_ok(tkeep)) stat_kaerr <= stat_kaerr + 32'd1;
                if (nk == 4'd0) stat_evfrm <= stat_evfrm + 32'd1;
                if (CHECK_PAT) begin
                    // 期望字节流: 第 j 个字节 = xs_adv(lfsr, j)[31:24]
                    // (坑: 在 for 循环里写 `lfsr <= xs_next(lfsr)` 是非阻塞 —
                    //  8 次赋值只落最后一次, LFSR 每字只推 1 步 ⇒ 期望流错位,
                    //  实测 2179/17388 字节假失配。必须用组合函数 xs_adv。)
                    mm = 0;
                    for (bi = 0; bi < 8; bi = bi + 1) begin
                        if (bi < nk) begin
                            ew = xs_adv(lfsr, bi[3:0]);   // 不能对函数调用取位选
                            if (byte_at(tdata, bi[3:0]) != ew[31:24]) begin
                                mm = mm + 1;
                                // 诊断: 前 8 个失配点印出字节位号/期望/实收
                                // (定位"局部错位 vs 整体漂移": 位号连续 = 局部,
                                //  位号大跳 = 丢/重段)
                                if (dbg_mm_ev < 32'd400) begin
                                    $display("SINKMM byte=%0d word=%0d bi=%0d exp=%02x got=%02x tlast=%0d",
                                             stat_bytes + bi, stat_words, bi,
                                             ew[31:24], byte_at(tdata, bi[3:0]),
                                             tlast);
                                    dbg_mm_ev <= dbg_mm_ev + 32'd1;
                                end
                            end
                        end
                    end
                    if (mm != 0) stat_mismatch <= stat_mismatch + mm;
                    lfsr <= xs_adv(lfsr, nk);
                end
            end
            // ---- 活动窥探 (最长无消费间隔; 对端/板侧真的停了 vs 死锁) ----
            if (cons) begin
                gap <= 32'd0;
            end else begin
                if (gap + 32'd1 > dbg_gap_max) dbg_gap_max <= gap + 32'd1;
                gap <= gap + 32'd1;
            end
        end
    end
endmodule
